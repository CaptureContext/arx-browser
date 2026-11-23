import AppKit
import BrowserCaptureClient
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import BrowserExtensionsClient
import BrowserMediaClient
import BrowserPageInspectionClient
import BrowserPageInteractionClient
import BrowserPageWaitClient
import BrowserSurfaceClient
import BrowserSiteIconClient
import ChromiumEngine

extension ChromiumBrowserEngine {
	// MARK: - Back/forward history (DEV-878)

	/// Keeps each ordinary tab's back/forward history in `directory`, saved 2.5 s after its page
	/// changes and as it closes, so reopening the tab, undoing its close or relaunching brings the
	/// history back. Forgets the history of tabs not in `tabs`: the workspace's and its archive's.
	public func keepNavigationHistory(
		in directory: URL,
		keeping tabs: Set<Tab.ID>
	) {
		let store = TabNavigationStore(directory: directory)
		store.prune(keeping: tabs)
		navigationStore = store
	}

	/// The back/forward history `copy`'s first page takes from `source`: Duplicate Tab, and a tab
	/// reopened from the archive under a new identity.
	internal func cloneNavigation(
		from source: Tab,
		to copy: Tab.ID
	) {
		guard let navigationStore, runtime.supportsNavigationState else { return }

		let live = pages[source.id].flatMap { page in
			page.isPrivate || forgottenNavigation.contains(source.id) ? nil : runtime.navigationState(page)
		}
		guard let data = live ?? navigationStore.load(source.id, profile: source.profileID)
		else { return }

		// Saved under the copy at once, so a copy that isn't shown before a relaunch keeps it too.
		navigationStore.save(data, for: copy, profile: source.profileID)
	}

	/// Reset Tab: a saved tab reopens at its saved page without the history it had (DEV-878).
	internal func discardNavigation(
		of tab: Tab.ID,
		profile: Profile.ID
	) {
		navigationSaves.removeValue(forKey: tab)?.cancel()
		navigationStore?.remove(tab, profile: profile)
	}

	/// Clear History: the profile's tabs forget their saved back/forward history, and its open
	/// tabs keep none until they close.
	internal func forgetNavigation(_ profile: Profile.ID) {
		navigationStore?.removeProfile(profile)
		for (id, owner) in pageProfiles where owner == profile {
			navigationSaves.removeValue(forKey: id)?.cancel()
			forgottenNavigation.insert(id)
		}
	}

	internal func scheduleNavigationSave(_ id: Tab.ID) {
		guard
			navigationStore != nil,
			runtime.supportsNavigationState,
			!forgottenNavigation.contains(id)
		else { return }

		navigationSaves[id]?.cancel()
		navigationSaves[id] = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .milliseconds(2_500))
			guard !Task.isCancelled, let self else { return }

			self.navigationSaves[id] = nil
			self.saveNavigation(id)
		}
	}

	private func saveNavigation(_ id: Tab.ID) {
		guard
			let navigationStore,
			!forgottenNavigation.contains(id),
			let page = pages[id],
			!page.isPrivate,
			let profile = pageProfiles[id],
			let data = runtime.navigationState(page)
		else { return }

		navigationStore.save(data, for: id, profile: profile)
	}

	/// A page for the tab: with its saved back/forward history when it has one that ends at the
	/// page it reopens, or a fresh one.
	internal func makePage(
		for tab: Tab,
		profile: UUID?
	) async throws -> (page: ChromiumPage, isRestored: Bool) {
		let saved = navigationStore?.load(tab.id, profile: tab.profileID)
		if let saved, let page = try await runtime.makePage(profile: profile, restoring: saved, at: tab.reopeningURL) {
			return (page, true)
		}
		return (try await runtime.makePage(profile: profile), false)
	}

	internal func open(
		_ tab: Tab,
		authorize: @escaping @MainActor @Sendable () -> Bool = { true }
	) async throws {
		guard authorize() else { throw AutomationFailure.denied }
		guard !retiringProfiles.contains(tab.profileID), !retirementIntents.contains(tab.profileID)
		else { throw ProfileRetirementFailure.busy }
		if let profile = pageProfiles[tab.id], profile != tab.profileID {
			throw BrowserEngineClient.Failure.unsupportedProfile
		}

		if let page = pages[tab.id] {
			// DEV-873: opening an unloaded tab, to show it or for an agent, loads it again.
			runtime.restoreUnloadedPage(page)
			return
		}
		if let pending = pendingOpens[tab.id] {
			try await pending.value
			guard authorize() else { throw AutomationFailure.denied }
			return
		}
		openGenerations[tab.id, default: 0] += 1
		let generation = openGenerations[tab.id]
		pageProfiles[tab.id] = tab.profileID
		let task = Task { @MainActor [self] in
			try Task.checkCancellation()
			let profileKey = tab.profileID.chromiumProfile(legacy: legacyProfileID)
			let (page, isRestored) = try await makePage(for: tab, profile: profileKey)
			do {
				try Task.checkCancellation()
				guard authorize() else { throw AutomationFailure.denied }
				if enableContentHosting { try runtime.configureContentHosting(on: page, enabled: true) }
				if isRestored {
					try runtime.loadRestoredPage(page)
				} else {
					try page.navigate(to: tab.reopeningURL)
				}
				if mediaService != nil, !page.isPrivate {
					try runtime.observeMedia(page)
				}
			} catch {
				page.close()
				throw error
			}
			setPage(page, for: tab.id)
			if !isRestored { blankStartPages.insert(page.identifier) }
			mediaService?.register(
				page: page.identifier,
				tabID: tab.id,
				profileID: tab.profileID,
				isPrivate: page.isPrivate
			)
			sessionRevisions[tab.id, default: 0] &+= 1
			downloadSourceTabs[page.identifier] = tab.id
			page.onNavigation = { [weak self, weak page] navigation in
				guard let self, let page, self.pages[tab.id] === page else { return }
				self.sessionRevisions[tab.id, default: 0] &+= 1
				if !page.isPrivate {
					self.scheduleNavigationSave(tab.id)
					self.pageSettled(tab.id, navigation)
				}
				self.unreadBadgeNavigated(tab.id, navigation)
				self.publish(self.snapshot(navigation, tab: tab.id), for: tab.id)
			}
			observeColors(of: page, tab: tab.id)
			if let host = hosts[tab.id]?.view { mount(page, in: host) }
		}
		pendingOpens[tab.id] = task
		defer {
			if openGenerations[tab.id] == generation { pendingOpens[tab.id] = nil }
		}
		do {
			try await task.value
		} catch {
			if openGenerations[tab.id] == generation { pageProfiles[tab.id] = nil }
			throw error
		}
	}

	internal func command(
		_ id: Tab.ID,
		_ command: BrowserEngineClient.Command,
		expectedRevision: UInt64? = nil,
		authorize: @escaping @MainActor @Sendable () -> Bool = { true }
	) async throws {
		if let pending = pendingOpens[id] { try await pending.value }
		guard let page = pages[id] else { throw BrowserEngineClient.Failure.missingSession }
		guard authorize() else { throw AutomationFailure.denied }
		guard expectedRevision == nil || sessionRevisions[id] == expectedRevision
		else { throw AutomationFailure.staleTarget }

		// DEV-1009: a page that stopped answering never reads a reload, a stop or a new
		// address; its renderer ends first, and the command runs on a new one.
		let generation = command.leavesTheDocument ? documentCommands[id, default: 0] &+ 1 : 0
		if command.leavesTheDocument { documentCommands[id] = generation }
		if command.leavesTheDocument, page.navigation.unresponsive != 0 { endRenderer(id, page) }
		if command.leavesTheDocument, endingRenderers[id] != nil {
			// Authorized above: the end this command caused moves the page's revision, so it
			// isn't asked again. A cancelled caller (Stop, a lost client) stops here.
			try await settleEndedRenderer(id, page)
			try Task.checkCancellation()
			guard pages[id] === page else { throw BrowserEngineClient.Failure.missingSession }

			// A newer reload or navigation came while this one waited: it wins.
			guard documentCommands[id] == generation else { throw CancellationError() }
		}

		switch command {
		case let .navigate(url):
			try page.navigate(to: url)

		case .back:
			try page.goBack()

		case .forward:
			try page.goForward()

		case .clearCacheAndReload:
			try page.clearCacheAndReload()

		case .reloadBypassingCache:
			try page.reloadBypassingCache()

		case .openDeveloperTools:
			guard runtime.openDeveloperTools(for: page) == .opened
			else { throw BrowserEngineClient.Failure.unavailable }

		case .toggleDeveloperTools:
			if runtime.developerToolsAreOpen(for: page) {
				runtime.closeDeveloperTools(for: page)
			} else {
				guard runtime.openDeveloperTools(for: page) == .opened
				else { throw BrowserEngineClient.Failure.unavailable }
			}

		case let .showDeveloperToolsPanel(panel):
			guard runtime.showDeveloperToolsPanel(panel.rawValue, for: page) == .opened
			else { throw BrowserEngineClient.Failure.unavailable }

		case .inspectElementMode:
			guard runtime.startDeveloperToolsInspection(for: page) == .opened
			else { throw BrowserEngineClient.Failure.unavailable }

		case .reload:
			try page.reload()

		case .stop:
			try page.stop()

		case let .historyEntry(id):
			try page.goToEntry(id)

		case let .find(text, forward, newSession):
			try page.find(text, forward: forward, newSession: newSession)

		case .stopFind:
			try page.stopFind()

		case let .zoom(step):
			guard let levels = runtime.pageZoomLevels(page)
			else { throw BrowserEngineClient.Failure.unavailable }
			let current = levels.factor
			let target = step.factor(from: current, default: levels.defaultFactor) ?? 0
			guard target == 0 || target != current
			else { return }
			guard runtime.setPageZoom(page, target) != nil
			else { throw BrowserEngineClient.Failure.unavailable }

		case .exitFullScreen:
			runtime.exitFullScreen(page)
		}
	}

	internal func closeAuthorized(
		_ id: Tab.ID,
		revision: UInt64?,
		authorize: @escaping @MainActor @Sendable () -> Bool,
		didClose: @escaping @MainActor @Sendable () -> Void
	) async throws -> Bool {
		try Task.checkCancellation()
		guard authorize()
		else { throw AutomationFailure.denied }
		guard runtime.state == .running
		else { throw AutomationFailure.unsupported }
		guard pendingOpens[id] == nil
		else { throw AutomationFailure.staleTarget }

		guard let page = pages[id] else {
			guard revision == nil
			else { throw AutomationFailure.staleTarget }

			// Dormant metadata has no native document. No await occurs before publication.
			close(id)
			didClose()
			return true
		}

		guard
			let revision,
			sessionRevisions[id] == revision,
			let profile = pageProfiles[id]
		else { throw AutomationFailure.staleTarget }

		let generation = openGenerations[id]
		return try await ChromiumCloseAdapter.perform(
			authorize: authorize,
			isCurrent: { [self] in
				runtime.state == .running
				&& pages[id] === page
				&& pageProfiles[id] == profile
				&& openGenerations[id] == generation
				&& pendingOpens[id] == nil
				&& sessionRevisions[id] == revision
			},
			approve: { [runtime] in try await runtime.approveClose(page) },
			consume: { [self] approval in

				// Consuming disposes the page, so its history is read first (DEV-878).
				navigationSaves.removeValue(forKey: id)?.cancel()
				let history = forgottenNavigation.contains(id) ? nil : runtime.navigationState(page)
				try runtime.consumeClose(approval, for: page)
				if let history { navigationStore?.save(history, for: id, profile: profile) }

				// The runtime has disposed both native and Swift ownership. This close
				// clears the service registry; page.close() is now an idempotent no-op.
				close(id)
			},
			cancel: { [runtime] in runtime.cancelClose($0) },
			didClose: didClose
		)
	}

	internal func requestPrivateProfileRelease(_ profileID: Profile.ID) {
		pendingPrivateProfileReleases.insert(profileID)
		releaseUnusedPrivateProfile(profileID)
	}

	private func releaseUnusedPrivateProfile(_ profileID: Profile.ID) {
		guard
			pendingPrivateProfileReleases.contains(profileID),
			!pageProfiles.values.contains(profileID)
		else { return }

		pendingPrivateProfileReleases.remove(profileID)
		runtime.releasePrivateProfile(profileID.rawValue)
	}

	internal func close(_ id: Tab.ID) {
		// The tab's history as it closes, so reopening it or undoing the close brings it back.
		navigationSaves.removeValue(forKey: id)?.cancel()
		saveNavigation(id)
		forgottenNavigation.remove(id)

		// The app keeps the last badge for the closed tab; its next page starts afresh.
		unreadBadges[id] = nil
		settledPages[id] = nil
		rendererEnds.forget(id)
		let profileID = pageProfiles[id]
		sessionRevisions[id, default: 0] &+= 1
		openGenerations[id, default: 0] += 1
		pendingOpens.removeValue(forKey: id)?.cancel()
		pageProfiles[id] = nil

		// DEV-1009: a page that stopped answering closes without waiting on its renderer.
		if let page = pages[id], page.navigation.unresponsive != 0 { runtime.endRenderer(page) }
		endingRenderers[id] = nil
		documentCommands[id] = nil
		if let page = removePage(id) {
			if let offer = initialExtensionOptions.removeValue(forKey: page.identifier) {
				onExtensionOptionsSettled?(offer)
			}
			mediaService?.remove(page: page.identifier)
			page.close()
		}
		for observer in observers.removeValue(forKey: id)?.values ?? [:].values {
			observer.finish()
		}
		for observer in entryObservers.removeValue(forKey: id)?.values ?? [:].values {
			observer.finish()
		}
		shownEntries[id] = nil

		if let profileID { releaseUnusedPrivateProfile(profileID) }
	}

	internal func events(_ id: Tab.ID) -> AsyncStream<BrowserNavigation> {
		let token = UUID()
		let (stream, continuation) = AsyncStream<BrowserNavigation>
			.makeStream(bufferingPolicy: .bufferingNewest(1))
		observers[id, default: [:]][token] = continuation
		if let page = pages[id] { continuation.yield(snapshot(page.navigation, tab: id)) }
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in self?.observers[id]?[token] = nil }
		}
		return stream
	}

	/// Every change of the tab's current history entry, none dropped (DEV-1063).
	internal func entryChanges(_ id: Tab.ID) -> AsyncStream<BrowserNavigation> {
		let token = UUID()
		let (stream, continuation) = AsyncStream<BrowserNavigation>.makeStream()
		entryObservers[id, default: [:]][token] = continuation
		if let page = pages[id] { continuation.yield(Self.snapshot(page.navigation)) }
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in self?.entryObservers[id]?[token] = nil }
		}
		return stream
	}

	/// Passes a tab's navigation to its `events` subscribers, and to its `entryChanges` ones when
	/// its current history entry changed, or started or finished loading.
	internal func publish(
		_ navigation: BrowserNavigation,
		for id: Tab.ID
	) {
		for observer in observers[id, default: [:]].values { observer.yield(navigation) }
		guard
			let entry = navigation.history.first(where: \.isCurrent),
			shownEntries[id].map({
				$0.entry.id == entry.id && $0.entry.url == entry.url && $0.isLoading == navigation.isLoading
			}) != true
		else { return }

		shownEntries[id] = (entry, navigation.isLoading)
		for observer in entryObservers[id, default: [:]].values { observer.yield(navigation) }
	}
}
