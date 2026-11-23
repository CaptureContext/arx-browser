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
	// MARK: - Adopted contents

	internal func adoptContents(
		_ child: ChromiumPage,
		from source: ChromiumPage,
		generation: UInt64,
		url: URL,
		intent: ChromiumNewContentsDisposition
	) -> Bool {
		let recorded: NewContentsRecord.Disposition = switch intent {
		case .foregroundTab: .foregroundTab
		case .backgroundTab: .backgroundTab
		case .window: .window
		case .popup: .popup
		}
		let sourceID = tabID(of: source)
		#if DEBUG
		newContentsRequests += 1
		let request = newContentsRequests
		let sourceRevision = sourceID.flatMap { sessionRevisions[$0] }
		#endif
		// Each refusal names its step, so a smoke that clicked can say where the request stopped.
		func note(_ outcome: NewContentsRecord.Outcome) {
			#if DEBUG
			lastNewContents = .init(
				sequence: request,
				sourceTabID: sourceID,
				sourceRevision: sourceRevision,
				disposition: recorded,
				outcome: outcome
			)
			#endif
		}

		guard let sourceID, let profileID = pageProfiles[sourceID] else {
			note(.unknownSource)
			return false
		}
		guard !retiringProfiles.contains(profileID), !retirementIntents.contains(profileID) else {
			note(.retiringProfile)
			return false
		}
		guard source.isPrivate == child.isPrivate else {
			note(.privacyMismatch)
			return false
		}
		guard runtime.documentRevision(for: source) == generation else {
			note(.staleDocument)
			return false
		}
		guard
			let host = hosts[sourceID]?.view,
			source.view.superview === host,
			let window = host.window
		else {
			note(.noHost)
			return false
		}
		guard window.isVisible, !window.isMiniaturized else {
			note(.windowHidden)
			return false
		}
		guard !source.view.isHiddenOrHasHiddenAncestor, !source.view.visibleRect.isEmpty else {
			note(.pageHidden)
			return false
		}

		let tab = Tab(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			restoration: .init(title: "", url: url)
		)
		let disposition: BrowserNewContents.Disposition = switch recorded {
		case .foregroundTab: .foregroundTab
		case .backgroundTab: .backgroundTab
		case .window: .window
		case .popup: .popup
		}
		let offer = BrowserNewContents(
			sourceTabID: sourceID,
			sourceSessionRevision: sessionRevisions[sourceID, default: 0],
			sourceDocumentRevision: generation,
			tab: tab,
			disposition: disposition,
			isPrivate: child.isPrivate
		)
		do {
			if mediaService != nil, !child.isPrivate { try runtime.observeMedia(child) }
		} catch {
			note(.mediaFailed)
			return false
		}

		setPage(child, for: tab.id)
		mediaService?.register(
			page: child.identifier,
			tabID: tab.id,
			profileID: profileID,
			isPrivate: child.isPrivate
		)
		pageProfiles[tab.id] = profileID

		// An adopted page knows its profile only now (DEV-1020).
		applyDarkPages(to: tab.id)
		sessionRevisions[tab.id] = 1
		downloadSourceTabs[child.identifier] = tab.id
		child.onNavigation = { [weak self, weak child] navigation in
			guard
				let self,
				let child,
				self.pages[tab.id] === child
			else { return }

			self.sessionRevisions[tab.id, default: 0] &+= 1
			if !child.isPrivate {
				self.scheduleNavigationSave(tab.id)
				self.pageSettled(tab.id, navigation)
			}
			self.unreadBadgeNavigated(tab.id, navigation)
			self.publish(self.snapshot(navigation, tab: tab.id), for: tab.id)
		}
		observeColors(of: child, tab: tab.id)

		// Before the callback, which may navigate or close the source.
		note(.declined)
		guard onNewContents?(offer) == true else {
			// Native owns rejection destruction after the callback. Never call close
			// here, and never invalidate the opener's session or host.
			mediaService?.remove(page: child.identifier)
			removePage(tab.id)
			pageProfiles[tab.id] = nil
			sessionRevisions[tab.id] = nil
			observers.removeValue(forKey: tab.id)?.values.forEach { $0.finish() }
			entryObservers.removeValue(forKey: tab.id)?.values.forEach { $0.finish() }
			shownEntries[tab.id] = nil
			hosts[tab.id] = nil
			downloadSourceTabs[child.identifier] = nil
			child.onNavigation = nil
			return false
		}

		note(.adopted)
		if let host = hosts[tab.id]?.view { mount(child, in: host) }
		return true
	}

	internal func adoptExtensionOptions(
		_ child: ChromiumPage,
		profileID: Profile.ID,
		extensionID: String
	) -> Bool {
		guard
			enableExtensionViews,
			!retiringProfiles.contains(profileID),
			!retirementIntents.contains(profileID),
			!child.isPrivate,
			let url = child.navigation.url,
			url.scheme == "chrome-extension",
			url.host == extensionID
		else { return false }

		let tab = Tab(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			restoration: .init(title: "", url: url)
		)
		setPage(child, for: tab.id)
		pageProfiles[tab.id] = profileID

		// An adopted page knows its profile only now (DEV-1020).
		applyDarkPages(to: tab.id)
		sessionRevisions[tab.id] = 1
		downloadSourceTabs[child.identifier] = tab.id
		child.onNavigation = { [weak self, weak child] navigation in
			guard
				let self,
				let child,
				self.pages[tab.id] === child
			else { return }

			self.sessionRevisions[tab.id, default: 0] &+= 1
			if !child.isPrivate {
				self.scheduleNavigationSave(tab.id)
				self.pageSettled(tab.id, navigation)
			}
			self.unreadBadgeNavigated(tab.id, navigation)
			self.publish(self.snapshot(navigation, tab: tab.id), for: tab.id)
		}
		observeColors(of: child, tab: tab.id)
		let offer = BrowserExtensionViewOffer(
			profileID: profileID,
			extensionID: extensionID,
			tab: tab
		)

		initialExtensionOptions[child.identifier] = offer
		guard onExtensionView?(offer) == true else {
			initialExtensionOptions[child.identifier] = nil
			if pages[tab.id] === child {
				removePage(tab.id)
				pageProfiles[tab.id] = nil
				sessionRevisions[tab.id] = nil
				downloadSourceTabs[child.identifier] = nil
				child.onNavigation = nil
				observers.removeValue(forKey: tab.id)?.values.forEach { $0.finish() }
				entryObservers.removeValue(forKey: tab.id)?.values.forEach { $0.finish() }
				shownEntries[tab.id] = nil
				hosts[tab.id] = nil
			}
			return false
		}

		guard
			pages[tab.id] === child,
			pageProfiles[tab.id] == profileID,
			!child.isClosed
		else { return false }

		if let host = hosts[tab.id]?.view { mount(child, in: host) }
		return true
	}

	/// ABI55 (DEV-885). A service worker's `clients.openWindow()` page, kept as a new tab in
	/// its profile when the app takes it.
	internal func adoptNotificationWindow(
		_ child: ChromiumPage,
		profileID: Profile.ID
	) -> Bool {
		guard
			!retiringProfiles.contains(profileID),
			!retirementIntents.contains(profileID),
			!child.isPrivate,
			let url = child.navigation.url
		else { return false }

		let tab = Tab(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			restoration: .init(title: "", url: url)
		)
		do {
			if mediaService != nil { try runtime.observeMedia(child) }
		} catch {
			return false
		}

		setPage(child, for: tab.id)
		mediaService?.register(
			page: child.identifier,
			tabID: tab.id,
			profileID: profileID,
			isPrivate: false
		)
		pageProfiles[tab.id] = profileID

		// An adopted page knows its profile only now (DEV-1020).
		applyDarkPages(to: tab.id)
		sessionRevisions[tab.id] = 1
		downloadSourceTabs[child.identifier] = tab.id
		child.onNavigation = { [weak self, weak child] navigation in
			guard
				let self,
				let child,
				self.pages[tab.id] === child
			else { return }

			self.sessionRevisions[tab.id, default: 0] &+= 1
			self.publish(self.snapshot(navigation, tab: tab.id), for: tab.id)
		}
		observeColors(of: child, tab: tab.id)

		guard onNotificationWindow?(tab) == true else {
			// Native destroys the refused page; never close it here.
			mediaService?.remove(page: child.identifier)
			if pages[tab.id] === child { removePage(tab.id) }
			pageProfiles[tab.id] = nil
			sessionRevisions[tab.id] = nil
			downloadSourceTabs[child.identifier] = nil
			child.onNavigation = nil
			observers.removeValue(forKey: tab.id)?.values.forEach { $0.finish() }
			entryObservers.removeValue(forKey: tab.id)?.values.forEach { $0.finish() }
			shownEntries[tab.id] = nil
			hosts[tab.id] = nil
			return false
		}

		guard
			pages[tab.id] === child,
			!child.isClosed
		else { return false }

		if let host = hosts[tab.id]?.view { mount(child, in: host) }
		return true
	}

	internal func revokeExtensionOptions(
		_ child: ChromiumPage,
		profileID: Profile.ID,
		extensionID: String
	) {
		guard
			let offer = initialExtensionOptions[child.identifier],
			offer.profileID == profileID,
			offer.extensionID == extensionID
		else { return }

		initialExtensionOptions[child.identifier] = nil

		guard
			pages[offer.tab.id] === child,
			pageProfiles[offer.tab.id] == profileID
		else {
			onExtensionOptionsSettled?(offer)
			return
		}

		removePage(offer.tab.id)
		pageProfiles[offer.tab.id] = nil
		sessionRevisions[offer.tab.id] = nil
		downloadSourceTabs[child.identifier] = nil
		mediaService?.remove(page: child.identifier)
		child.onNavigation = nil
		observers.removeValue(forKey: offer.tab.id)?.values.forEach { $0.finish() }
		entryObservers.removeValue(forKey: offer.tab.id)?.values.forEach { $0.finish() }
		shownEntries[offer.tab.id] = nil
		hosts[offer.tab.id] = nil
		onExtensionOptionsRevoked?(offer)
	}

	internal func linkForceClick(
		_ page: ChromiumPage,
		generation: UInt64,
		url: URL
	) -> Bool {
		guard
			let tabID = self.tabID(of: page),
			let profileID = pageProfiles[tabID],
			let host = hosts[tabID]?.view,
			page.view.superview === host,
			let window = host.window,
			window.isVisible,
			!window.isMiniaturized
		else { return false }

		let forceClick = BrowserLinkForceClick(
			sourceTabID: tabID,
			profileID: profileID,
			sourceSessionRevision: sessionRevisions[tabID, default: 0],
			sourceDocumentRevision: generation,
			url: url,
			isPrivate: page.isPrivate
		)
		return onLinkForceClick?(forceClick) ?? false
	}

	internal func crossSiteLink(
		_ page: ChromiumPage,
		generation: UInt64,
		url: URL
	) -> Bool {
		guard
			!page.isPrivate,
			let tabID = self.tabID(of: page),
			let profileID = pageProfiles[tabID],
			let host = hosts[tabID]?.view,
			page.view.superview === host,
			let window = host.window,
			window.isVisible,
			!window.isMiniaturized
		else { return false }

		let link = BrowserCrossSiteLink(
			sourceTabID: tabID,
			profileID: profileID,
			sourceSessionRevision: sessionRevisions[tabID, default: 0],
			sourceDocumentRevision: generation,
			url: url
		)
		return onCrossSiteLink?(link) ?? false
	}

	internal func externalLink(
		_ page: ChromiumPage,
		link: ChromiumExternalLink
	) -> Bool {
		guard
			page.isPrivate == link.isPrivate,
			let tabID = self.tabID(of: page),
			let profileID = pageProfiles[tabID],
			let host = hosts[tabID]?.view,
			page.view.superview === host,
			let window = host.window,
			window.isVisible,
			!window.isMiniaturized
		else { return false }

		return onExternalLink?(.init(
			sourceTabID: tabID,
			profileID: profileID,
			isPrivate: page.isPrivate,
			sourceDocumentRevision: link.documentRevision,
			sourceToken: link.token,
			link: link.link,
			sourceOrigin: link.sourceOrigin,
			hasUserGesture: link.hasUserGesture,
			isRedirect: link.isRedirect
		)) ?? false
	}

	internal func focusedLink(_ tabID: Tab.ID) async -> BrowserFocusedLink? {
		guard
			let page = pages[tabID],
			!page.isPrivate,
			let profileID = pageProfiles[tabID]
		else { return nil }

		let sessionRevision = sessionRevisions[tabID, default: 0]
		guard
			let link = await runtime.focusedLink(on: page),
			pages[tabID] === page,
			pageProfiles[tabID] == profileID
		else { return nil }

		return .init(
			sourceTabID: tabID,
			profileID: profileID,
			sourceSessionRevision: sessionRevision,
			sourceDocumentRevision: link.documentRevision,
			url: link.url,
			isPrivate: page.isPrivate
		)
	}

	/// DEV-1084: whether the tab's page holds typed, unsent form input in any frame. Nil when the
	/// engine can't check, or the tab's page changed before it answered.
	internal func formEdits(_ tabID: Tab.ID) async -> BrowserFormEdits? {
		guard let page = pages[tabID] else { return nil }

		guard let edits = await runtime.formEdits(on: page) else { return nil }
		guard pages[tabID] === page else { return .unknown }

		switch edits {
		case .clean: return .clean
		case .typed: return .typed
		case .unknown: return .unknown
		}
	}

	internal func unhandledEscape(
		_ page: ChromiumPage,
		generation: UInt64
	) -> Bool {
		guard
			let tabID = self.tabID(of: page),
			let host = hosts[tabID]?.view
		else { return false }

		return escapeHosts.accept(tabID, in: host) { [weak self, weak page, weak host] in
			guard
				let self,
				let page,
				let host,
				self.pages[tabID] === page,
				self.hosts[tabID]?.view === host,
				page.view.superview === host,
				self.runtime.documentRevision(for: page) == generation,
				let window = host.window,
				window.isKeyWindow,
				window.isVisible,
				!window.isMiniaturized,
				!page.view.isHiddenOrHasHiddenAncestor,
				!page.view.visibleRect.isEmpty,
				let responder = window.firstResponder as? NSView
			else { return false }

			return responder === page.view || responder.isDescendant(of: page.view)
		}
	}
}
