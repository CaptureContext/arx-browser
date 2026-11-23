import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserHistoryClient
import BrowserPagePreviewClient
import CommandBarFeature
import Foundation
import MainFeature
import PageTextIndexClient
import _ComposableArchitecture

/// Records only durable, ordinary tabs; the service owns serialization and revision ordering.
@Reducer
internal struct ProfileHistory {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserHistory)
	private var client

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.browserPagePreviews)
	private var pagePreviews

	@Dependency(\.pageTextIndex)
	private var pageText

	@Dependency(\.continuousClock)
	private var clock

	/// How long after a visit its page's text is read, so a page that fills itself in has.
	internal static let pageTextDelay: Duration = .seconds(2)

	@Dependency(\.date.now)
	private var now

	internal var body: some ReducerOf<Self> {
		Pullback(\.main) { state, action in
			guard client.isAvailable else { return .none }

			let host = state.main
			return .merge(configure(state: &state), navigation(action, host: host, state: &state))
		}

		Pullback(\.windows) { state, action in
			guard
				client.isAvailable,
				case let .element(id, action) = action,
				let host = state.windows[id: id]
			else { return .none }

			return .merge(configure(state: &state), navigation(action, host: host, state: &state))
		}

		// Page PiP's address bar opened a typed address in a space's tab (DEV-1124). A private
		// window's page, a Peek's and Little Arx's aren't in the workspace's tabs: none is
		// remembered here, as from their own windows.
		Pullback(\.event.pagePictureInPictureTypedAddressOpened) { state, value in
			let (url, tabID) = value
			guard client.isAvailable, let tab = state.workspace.tabs[id: tabID] else { return .none }

			rememberTypedAddress(url, tabID: tabID, profileID: tab.profileID, state: &state)
			return .none
		}

		// Little Arx pages are ordinary profile pages too (DEV-728). Its windows host no
		// private pages. A Peek over one has its own viewer, whose events come through
		// `.peeks` and are never recorded; the source page keeps recording meanwhile.
		// Little Arx's own command bar opens what's typed in its tab (DEV-1015).
		Pullback(\.littleWindows) { state, action in
			guard
				client.isAvailable,
				case let .element(id, .delegate(.typedAddressOpened(url, tabID))) = action,
				let little = state.littleWindows[id: id],
				little.tab.id == tabID
			else { return .none }

			rememberTypedAddress(url, tabID: tabID, profileID: little.tab.profileID, state: &state)
			return .none
		}

		Pullback(\.littleWindows) { state, action in
			guard
				client.isAvailable,
				case let .element(id, .viewer(.delegate(.navigation(tabID, navigation)))) = action,
				let little = state.littleWindows[id: id],
				little.tab.id == tabID,
				state.workspace.profiles.ids.contains(little.tab.profileID)
			else { return .none }

			return record(
				navigation,
				tabID: tabID,
				profileID: little.tab.profileID,
				spaceID: little.spaceID,
				state: &state
			)
		}

		// A page floating in Page PiP records its visits itself, since no window may show it
		// (DEV-1105). Only a space's tab: a private window's and a Peek's never record, and
		// Little Arx's viewer keeps recording its own. A window that shows it too records the same
		// navigation, which `record` takes once.
		Pullback(\.event.pagePictureInPictureNavigation) { state, value in
			let (tabID, navigation) = value
			guard
				client.isAvailable,
				let current = state.pagePictureInPicture,
				current.tabID == tabID,
				let tab = state.workspace.tabs[id: tabID],
				// A saved tab Peek opened is Peek's page while it floats, which history never
				// records.
				!state.peeks.contains(where: { $0.tab.id == tabID })
			else { return .none }

			// A Favorite's visits stay in its own profile's spaces, whatever space the window it
			// floats from switches to (DEV-1154).
			let spaceID: Space.ID? = switch state.workspace.location(of: tabID) {
			case let .pinned(spaceID, _), let .unpinned(spaceID): spaceID
			case .favorite, nil: state.floatingSpace(of: tab.profileID, windowID: current.windowID)
			}
			return record(
				navigation,
				tabID: tabID,
				profileID: tab.profileID,
				spaceID: spaceID,
				state: &state
			)
		}

		Pullback(\.ui) { state, _ in client.isAvailable ? configure(state: &state) : .none }

		Pullback(\.event) { state, _ in client.isAvailable ? configure(state: &state) : .none }

		Pullback(\.settings.delegate.clearHistory) { state, profileID in
			guard client.isAvailable, state.workspace.profiles.ids.contains(profileID)
			else { return .none }

			state.history.epochs[profileID, default: 0] += 1
			state.history.pendingClear.insert(profileID)
			state.history.pendingRemovals[profileID] = nil
			state.history.queuedVisits[profileID] = nil
			state.history.snapshots[profileID] = .init(
				profileID: profileID,
				revision: state.history.snapshots[profileID]?.revision ?? 0
			)
			state.syncHistory()
			return .concatenate(.cancel(id: HistoryRequestID(profileID)), clear(profileID, state: state))
		}

		// Clear Browsing Data with a time range (DEV-647): older entries stay.
		Pullback(\.settings.delegate.clearHistorySince) { state, value in
			let (profileID, since) = value
			guard client.isAvailable, state.workspace.profiles.ids.contains(profileID)
			else { return .none }

			state.history.snapshots[profileID]?.remove(since: since)
			state.history.queuedVisits[profileID]?.removeAll { $0.date >= since }
			if let snapshot = state.history.snapshots[profileID] {
				state.settings.historyStatus[profileID, default: .init()].count = snapshot.entries.count
			}

			// As for clearing everything: a record still waiting can't land after the
			// clear and bring back a visit in the range, and older answers are ignored.
			state.history.epochs[profileID, default: 0] += 1
			state.syncHistory()
			let epoch = state.history.epochs[profileID, default: 0]
			return .concatenate(
				.cancel(id: HistoryRequestID(profileID)),
				request(profileID, epoch: epoch) { [client] in try await client.clearSince(profileID, since) }
			)
		}

		// Delete from History (DEV-810), from the command bar of any window. The Library's
		// History page sends the same delegate.
		Pullback(\.main.delegate.removeHistory) { state, value in
			let (profileID, removal) = value
			return remove(removal, profileID: profileID, state: &state)
		}

		Pullback(\.windows) { state, action in
			guard
				case let .element(id, .delegate(.removeHistory(profileID, removal))) = action,
				state.windows[id: id]?.isPrivate == false
			else { return .none }

			return remove(removal, profileID: profileID, state: &state)
		}

		// Saved page pictures and fetched site details go with the history they show (DEV-730),
		// even when the history itself can't be reached.
		Pullback(\.settings.delegate.clearHistory) { state, profileID in
			guard state.workspace.profiles.ids.contains(profileID) else { return .none }
			return removePagePreviews(profileID, since: nil)
		}

		Pullback(\.settings.delegate.clearHistorySince) { state, value in
			let (profileID, since) = value
			guard state.workspace.profiles.ids.contains(profileID) else { return .none }
			return removePagePreviews(profileID, since: since)
		}

		// Site details were fetched with the profile's cookies (DEV-1142): clearing them, or the
		// cache, forgets the details too. Saved pictures are the profile's own and stay.
		Pullback(\.settings.delegate.clearedSiteData) { state, profileID in
			guard state.workspace.profiles.ids.contains(profileID) else { return .none }
			return .run { _ in await SidebarPageDetails.shared.forget([profileID]) }
		}

		// And the tabs' saved back/forward history (DEV-878), whatever the range: it can't be
		// cut by date.
		Pullback(\.settings.delegate.clearHistory) { state, profileID in
			guard state.workspace.profiles.ids.contains(profileID) else { return .none }
			return .run { @MainActor [engine] _ in engine.forgetNavigation(profileID) }
		}

		Pullback(\.settings.delegate.clearHistorySince) { state, value in
			guard state.workspace.profiles.ids.contains(value.0) else { return .none }
			return .run { @MainActor [engine] _ in engine.forgetNavigation(value.0) }
		}

		Pullback(\.settings.delegate.retryHistory) { state, profileID in
			guard client.isAvailable, state.workspace.profiles.ids.contains(profileID)
			else { return .none }

			if state.history.pendingClear.contains(profileID) { return clear(profileID, state: state) }
			return request(profileID, epoch: state.history.epochs[profileID, default: 0]) { [client] in
				try await client.retry(profileID)
			}
		}

		Pullback(\.history.received) { state, value in
			let (outcome, epoch) = value
			let id = outcome.snapshot.profileID
			guard state.workspace.profiles.ids.contains(id), state.history.epochs[id, default: 0] == epoch
			else { return .none }

			state.history.loading.remove(id)
			guard outcome.snapshot.revision >= state.history.snapshots[id]?.revision ?? 0
			else { return .none }

			var snapshot = outcome.snapshot
			if let pending = state.history.pendingRemovals[id] {
				snapshot.entries.removeAll { entry in pending.contains { $0.hides(entry) } }
			}
			state.history.snapshots[id] = snapshot
			state.history.failures[id] = outcome.failure
			state.settings.historyStatus[id] = .init(
				count: snapshot.entries.count,
				error: outcome.failure.map(Self.message)
			)
			state.syncHistory()
			let reconciles = reconcilePageText(id, snapshot: snapshot, outcome: outcome, state: &state)
			guard outcome.failure == nil, state.history.pendingClear.remove(id) != nil
			else { return reconciles }

			let queued = state.history.queuedVisits.removeValue(forKey: id) ?? []
			return .merge([reconciles] + queued.map { record($0, profileID: id, epoch: epoch) })
		}

		Pullback(\.history.failed) { state, value in
			let (id, failure, epoch) = value
			guard state.workspace.profiles.ids.contains(id), state.history.epochs[id, default: 0] == epoch
			else { return .none }

			state.history.loading.remove(id)
			state.history.failures[id] = failure
			state.settings.historyStatus[id] = .init(
				count: state.history.snapshots[id]?.entries.count ?? 0,
				error: Self.message(failure)
			)
			state.syncHistory()
			return .none
		}

		Pullback(\.history.removalFinished) { state, value in
			let (profileID, pending) = value
			guard let index = state.history.pendingRemovals[profileID]?.firstIndex(of: pending)
			else { return .none }

			state.history.pendingRemovals[profileID]?.remove(at: index)
			if state.history.pendingRemovals[profileID]?.isEmpty == true {
				state.history.pendingRemovals[profileID] = nil
			}
			return .none
		}

		// A page's text is kept only while its history is as it was when it was read: a clear
		// since then wins (DEV-1068).
		Pullback(\.history.pageTextRead) { state, value in
			let (tabID, profileID, page, generation) = value
			state.history.pageTextReads[tabID] = nil
			guard
				let page,
				state.history.pageTextGenerations[profileID, default: 0] == generation,
				!state.history.pendingClear.contains(profileID),
				state.workspace.profiles.ids.contains(profileID)
			else { return .none }

			// The store checks the generation again: a clear can reach it before this save does.
			return .run { [pageText] _ in await pageText.save(profileID, page, generation) }
		}

		// The page text goes with the history it belongs to (DEV-1068), and a read still on its
		// way is dropped.
		Pullback(\.settings.delegate.clearHistory) { state, profileID in
			guard state.workspace.profiles.ids.contains(profileID) else { return .none }
			let generation = state.history.advancePageTextGeneration(profileID)
			return .run { [pageText] _ in await pageText.clear(profileID, generation) }
		}

		// A range takes the pages history no longer has; the index's own visit times can be older
		// than history's, after a reload, so it goes by what history kept when it can.
		Pullback(\.settings.delegate.clearHistorySince) { state, value in
			let (profileID, since) = value
			guard state.workspace.profiles.ids.contains(profileID) else { return .none }
			let generation = state.history.advancePageTextGeneration(profileID)
			guard let snapshot = state.history.snapshots[profileID] else {
				return .run { [pageText] _ in await pageText.clearSince(profileID, since, generation) }
			}
			let kept = Set(snapshot.entries.map(\.url))
			return .run { [pageText] _ in await pageText.retain(profileID, kept, generation) }
		}

		// iCloud sync brought visits or clears from other Macs (DEV-984): the store takes them into
		// the profiles' history, and its answers are shown like any other.
		Pullback(\.event.historySyncChanged) { state in
			guard client.isAvailable else { return .none }

			return applySynced(Set(state.workspace.profiles.map(\.id)), state: state)
		}

		Pullback(\.history.syncApplied) { state, value in
			let (outcomes, epochs) = value

			// A profile clearing now gets its history with the clear's answer. The epochs are the
			// ones asked at, so a clear or Clear History Since sent meanwhile drops a stale answer.
			let effects: [Effect<Action>] = outcomes
				.filter { !state.history.pendingClear.contains($0.snapshot.profileID) }
				.compactMap { outcome in
					epochs[outcome.snapshot.profileID].map { epoch in
						.send(.history(.received(outcome, epoch: epoch)))
					}
				}

			// Pages a clear on another Mac took from this one's history lose their words here too
			// (DEV-1068), and a read still on its way is dropped.
			var prunes: [Effect<Action>] = []
			for outcome in outcomes where outcome.failure == nil {
				let profileID = outcome.snapshot.profileID

				// As `received` takes it: an answer older than the history shown, such as one a
				// visit since overtook, prunes nothing.
				guard
					!state.history.pendingClear.contains(profileID),
					epochs[profileID] == state.history.epochs[profileID, default: 0],
					let current = state.history.snapshots[profileID],
					outcome.snapshot.revision >= current.revision
				else { continue }

				let kept = Set(outcome.snapshot.entries.map(\.url))
				guard current.entries.contains(where: { !kept.contains($0.url) }) else { continue }

				let generation = state.history.advancePageTextGeneration(profileID)
				prunes.append(.run { [pageText] _ in await pageText.retain(profileID, kept, generation) })
			}
			return .merge(effects + prunes)
		}

		Pullback(\.history.removed) { state, value in
			if value.1 {
				state.settings.historyRemovalError = String.localized(.appUI.history.removeFailed)
			}
			return .none
		}
	}

	private func configure(state: inout State) -> Effect<Action> {
		let ids = Set(state.workspace.profiles.map(\.id))
		var effects: [Effect<Action>] = []

		// At launch, and for a profile that arrives later, such as from iCloud: what History sync
		// already fetched for it is taken in now, not at the next change.
		let added: Set<Profile.ID> = ids.subtracting(state.history.knownProfiles)
		if !added.isEmpty {
			effects.append(applySynced(added, state: state))
		}
		for removed in state.history.knownProfiles.subtracting(ids) {
			state.history.snapshots[removed] = nil
			state.history.failures[removed] = nil
			state.history.queuedVisits[removed] = nil
			state.history.typedAddresses[removed] = nil
			state.history.loading.remove(removed)
			state.history.pendingClear.remove(removed)
			state.history.pageTextReconciled.remove(removed)
			state.history.pendingRemovals[removed] = nil
			state.settings.historyStatus[removed] = nil
			let removal: Effect<Action> = .run { [client, pageText] send in

				// No read of a removed profile's pages is saved again.
				await pageText.clear(removed, .max)
				do {
					try await client.remove(removed)
					await send(.history(.removed(removed, failed: false)))
				} catch {
					await send(.history(.removed(removed, failed: true)))
				}
			}
			effects.append(.concatenate(.cancel(id: HistoryRequestID(removed)), removal))
		}
		state.history.knownProfiles = ids

		let tabIDs = Set(state.workspace.tabs.map(\.id)).union(state.littleWindows.map(\.tab.id))
		state.history.lastNavigation = state.history.lastNavigation.filter { tabIDs.contains($0.key) }
		state.history.lastVisit = state.history.lastVisit.filter { tabIDs.contains($0.key) }
		state.history.pageTextReads = state.history.pageTextReads.filter { tabIDs.contains($0.key) }
		for id in ids {
			let needsLoad = state.history.snapshots[id] == nil
			&& state.history.failures[id] == nil
			&& !state.history.loading.contains(id)
			guard needsLoad else { continue }

			state.history.loading.insert(id)
			effects.append(request(id, epoch: state.history.epochs[id, default: 0]) { [client] in
				try await client.load(id)
			})
		}
		state.syncHistory()
		return .merge(effects)
	}

	private func navigation(
		_ action: MainFeature.Action,
		host: MainFeature.State,
		state: inout State
	) -> Effect<Action> {
		guard !host.isPrivate else { return .none }

		let id: BrowserCore.Tab.ID
		let navigation: BrowserNavigation
		switch action {
		case let .viewer(.item(.delegate(.navigation(tabID, value)))),
			let .viewer(.panes(.element(_, .item(.delegate(.navigation(tabID, value)))))):
			id = tabID
			navigation = value

		case let .delegate(.typedAddressOpened(url, tabID)):
			guard let tab = state.workspace.tabs[id: tabID] else { return .none }
			rememberTypedAddress(url, tabID: tabID, profileID: tab.profileID, state: &state)
			return .none

		default:
			return .none
		}

		guard let tab = state.workspace.tabs[id: id] else { return .none }

		// A background tab, such as an agent's, may be in another space than the window shows;
		// a Favorite belongs to none, so it takes the window's.
		let spaceID: Space.ID = switch state.workspace.location(of: id) {
		case let .pinned(spaceID, _), let .unpinned(spaceID): spaceID
		case .favorite, nil: host.sidebar.spaceID
		}
		return record(
			navigation,
			tabID: id,
			profileID: tab.profileID,
			spaceID: spaceID,
			state: &state
		)
	}

	/// Notes an address a command bar opened from typed text in `tabID`, once its window has
	/// opened it, so the page's visit there counts as typed (DEV-1015).
	private func rememberTypedAddress(
		_ url: URL,
		tabID: BrowserCore.Tab.ID,
		profileID: Profile.ID,
		state: inout State
	) {
		guard let host = url.host() else { return }

		var waiting = state.history.typedAddresses[profileID, default: []]
		waiting.removeAll { now.timeIntervalSince($0.openedAt) > ProfileHistoryState.typedAddressLifetime }
		waiting.append(.init(url: url, site: BrowsingHistoryRemoval.siteKey(host), tabID: tabID, openedAt: now))
		state.history.typedAddresses[profileID] = Array(waiting.suffix(8))
	}

	private func record(
		_ navigation: BrowserNavigation,
		tabID id: BrowserCore.Tab.ID,
		profileID: Profile.ID,
		spaceID: Space.ID? = nil,
		state: inout State
	) -> Effect<Action> {
		if navigation.isLoading {
			state.history.lastNavigation[id] = nil

			// The page being read is going: its text mustn't be read from the next one. If the
			// same page view comes back, as after a reload, it's read then.
			state.history.pageTextReads[id]?.isInterrupted = true
			return .cancel(id: PageTextReadID(tabID: id))
		}

		// A tab with nothing committed only tried to open its address, as one that became a
		// download did (DEV-1116): no visit, and no page to read.
		guard
			navigation.errorCode == nil,
			!navigation.hasNoPage,
			let url = navigation.url,
			BrowsingHistoryEntry.accepts(url)
		else { return .none }

		let key = ProfileHistoryState.NavigationKey(
			url: url,
			title: BrowsingHistoryEntry.boundedTitle(navigation.title),
			entryID: navigation.history.first(where: \.isCurrent)?.id
		)
		guard state.history.lastNavigation[id] != key else { return .none }

		state.history.lastNavigation[id] = key

		// A new page view counts as a visit; a title update or reload of the same one doesn't.
		let visitKey = ProfileHistoryState.VisitKey(
			url: url,
			entryID: key.entryID,
			historyLength: navigation.history.count
		)
		let isNew = state.history.lastVisit[id] != visitKey
		state.history.lastVisit[id] = visitKey
		let visit = ProfileHistoryState.Visit(
			url: url,
			title: key.title,
			date: now,
			isNew: isNew,
			isTyped: state.history.takeTypedAddress(
				for: url,
				isNew: isNew,
				tabID: id,
				profileID: profileID,
				at: now
			),
			spaceID: spaceID
		)
		if state.history.pendingClear.contains(profileID) {
			state.history.queuedVisits[profileID, default: []].append(visit)
			let queued = state.history.queuedVisits[profileID, default: []]
			state.history.queuedVisits[profileID] = Array(queued.suffix(BrowsingHistorySnapshot.limit))
			return .none
		}
		let epoch = state.history.epochs[profileID, default: 0]
		let reading = readPageTextIfOwed(
			tabID: id,
			visit: visitKey,
			isNew: isNew,
			navigation: navigation,
			title: key.title,
			profileID: profileID,
			state: &state
		)
		return .merge(record(visit, profileID: profileID, epoch: epoch), reading)
	}

	/// A new page view's text is read; so is one whose read a load cut short, once it settles
	/// again. A title update while the read waits leaves it waiting.
	private func readPageTextIfOwed(
		tabID: BrowserCore.Tab.ID,
		visit: ProfileHistoryState.VisitKey,
		isNew: Bool,
		navigation: BrowserNavigation,
		title: String,
		profileID: Profile.ID,
		state: inout State
	) -> Effect<Action> {
		let owed = state.history.pageTextReads[tabID]
		let isInterrupted = owed?.visit == visit && owed?.isInterrupted == true
		guard
			isNew || isInterrupted,
			pageText.isAvailable,
			navigation.engine != .webKit,
			let url = navigation.url
		else {
			if isNew { state.history.pageTextReads[tabID] = nil }
			return .none
		}

		state.history.pageTextReads[tabID] = .init(visit: visit)
		return readPageText(
			tabID: tabID,
			url: url,
			title: title,
			profileID: profileID,
			generation: state.history.pageTextGenerations[profileID, default: 0]
		)
	}

	/// Reads a newly visited page's text in the engine's developer world for history search
	/// (DEV-1068), once it has had a moment to fill itself in, asking again while another script
	/// holds the page. A private page is never recorded,
	/// so never read; nor is one in WebKit, whose text the engine can't read.
	private func readPageText(
		tabID: BrowserCore.Tab.ID,
		url: URL,
		title: String,
		profileID: Profile.ID,
		generation: Int
	) -> Effect<Action> {
		.run { [engine, clock, now] send in
			try await clock.sleep(for: Self.pageTextDelay)

			// Reading mode's check for an article (DEV-1028) can hold the page just then: ask again
			// rather than lose its text (DEV-1164).
			let outcome = try? await BrowserEngineClient.evaluateWhenFree(clock: clock) { () throws(BrowserDeveloperFailure) in
				try await engine.evaluateScript(tabID, Self.pageTextScript, 96 * 1_024, 2_000) { true }
			}
			try Task.checkCancellation()
			var page: PageText?
			if
				case let .value(json)? = outcome,
				let read = try? JSONDecoder().decode(PageTextRead.self, from: Data(json.utf8)),
				!read.text.isEmpty,
				// The document read is still the one visited, its fragment aside.
				Self.samePage(read.url, url)
			{
				page = PageText(url: url, title: title, text: read.text, visited: now)
			}

			// Sent even with nothing to keep, so the tab no longer owes a read; a cancelled
			// read sends nothing.
			await send(.history(.pageTextRead(tabID, profileID, page, generation: generation)))
		}
		.cancellable(id: PageTextReadID(tabID: tabID), cancelInFlight: true)
	}

	/// The page's address, and its visible text with its spaces folded, cut to what the index keeps.
	internal static let pageTextScript: String = """
	const body = document.body;
	let text = body ? (body.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, \(PageTextIndexClient.maximumCharacters)) : '';
	// A cut through an emoji's pair leaves half of it, which the result's JSON can't carry.
	if (/[\\uD800-\\uDBFF]$/.test(text)) text = text.slice(0, -1);
	return { url: location.href, text };
	"""

	private struct PageTextRead: Decodable {
		let url: String
		let text: String
	}

	private static func samePage(
		_ read: String,
		_ visited: URL
	) -> Bool {
		guard var components = URLComponents(string: read), var expected = URLComponents(url: visited, resolvingAgainstBaseURL: false)
		else { return false }

		components.fragment = nil
		expected.fragment = nil
		return components.string == expected.string
	}

	/// Removes entries at once in every window, then writes. Visits still being recorded go on:
	/// the store applies them in order, and an answer older than the removal's revision is
	/// ignored, so a removed entry comes back only with a newer visit.
	private func remove(
		_ removal: BrowsingHistoryRemoval,
		profileID: Profile.ID,
		state: inout State
	) -> Effect<Action> {
		guard
			client.isAvailable,
			state.workspace.profiles.ids.contains(profileID),
			!state.history.pendingClear.contains(profileID)
		else { return .none }

		state.history.snapshots[profileID]?.remove(removal)
		let pending = ProfileHistoryState.PendingRemoval(removal: removal, requestedAt: now)
		state.history.pendingRemovals[profileID, default: []].append(pending)
		if let snapshot = state.history.snapshots[profileID] {
			state.settings.historyStatus[profileID, default: .init()].count = snapshot.entries.count
		}
		state.syncHistory()

		// The page text keeps only the pages history still has (DEV-1068), and a read still on
		// its way is dropped.
		let generation = state.history.advancePageTextGeneration(profileID)
		let kept = Set(state.history.snapshots[profileID]?.entries.map(\.url) ?? [])
		let prunes: Effect<Action> = state.history.snapshots[profileID] == nil
		? .none
		: .run { [pageText] _ in await pageText.retain(profileID, kept, generation) }

		// The answer is applied first, then the removal stops being pending.
		return .merge(prunes, .concatenate(
			request(profileID, epoch: state.history.epochs[profileID, default: 0]) { [client] in
				try await client.removeEntries(profileID, removal, pending.requestedAt)
			},
			.send(.history(.removalFinished(profileID, pending)))
		))
	}

	/// Has the store take other Macs' mirrored visits and clears into these profiles' history.
	/// The first history a profile loads this launch: its page text keeps only the pages it lists
	/// (DEV-1068), which takes the words of pages a synced clear removed while Arx was closed. At
	/// the current generation, so a read on its way still lands.
	private func reconcilePageText(
		_ id: Profile.ID,
		snapshot: BrowsingHistorySnapshot,
		outcome: BrowserHistoryClient.Outcome,
		state: inout State
	) -> Effect<Action> {
		guard
			outcome.failure == nil,
			pageText.isAvailable,
			!state.history.pendingClear.contains(id),
			state.history.pageTextReconciled.insert(id).inserted
		else { return .none }

		let kept = Set(snapshot.entries.map(\.url))
		let generation = state.history.pageTextGenerations[id, default: 0]
		return .run { [pageText] _ in await pageText.retain(id, kept, generation) }
	}

	private func applySynced(
		_ profiles: Set<Profile.ID>,
		state: State
	) -> Effect<Action> {
		let epochs: [Profile.ID: Int] = Dictionary(
			uniqueKeysWithValues: profiles.map { ($0, state.history.epochs[$0, default: 0]) }
		)
		return .run { [client] send in
			let outcomes: [BrowserHistoryClient.Outcome] = await client.applySynced(profiles)
			guard !outcomes.isEmpty else { return }

			await send(.history(.syncApplied(outcomes, epochs: epochs)))
		}
	}

	private func removePagePreviews(
		_ profileID: Profile.ID,
		since: Date?
	) -> Effect<Action> {
		.run { [pagePreviews] _ in
			await SidebarPageDetails.shared.forget([profileID])
			await pagePreviews.removeSince(profileID, since)
		}
	}

	private func clear(
		_ id: Profile.ID,
		state: State
	) -> Effect<Action> {
		request(id, epoch: state.history.epochs[id, default: 0]) { [client] in try await client.clear(id) }
	}

	private func record(
		_ visit: ProfileHistoryState.Visit,
		profileID: Profile.ID,
		epoch: Int
	) -> Effect<Action> {
		request(profileID, epoch: epoch) { [client] in
			try await client.record(profileID, visit)
		}
	}

	private func request(
		_ id: Profile.ID,
		epoch: Int,
		operation: @escaping @Sendable () async throws -> BrowserHistoryClient.Outcome
	) -> Effect<Action> {
		.run { send in
			do {
				let result = try await operation()
				try Task.checkCancellation()
				await send(.history(.received(result, epoch: epoch)))
			} catch is CancellationError {
				return
			} catch {
				guard !Task.isCancelled else { return }

				let failure = error as? BrowserHistoryClient.Failure ?? .unavailable
				await send(.history(.failed(id, failure, epoch: epoch)))
			}
		}
		.cancellable(id: HistoryRequestID(id))
	}

	private static func message(_ failure: BrowserHistoryClient.Failure) -> String {
		switch failure {
		case .corrupt, .futureVersion: String.localized(.appUI.history.unreadable)
		case .changedOnDisk: String.localized(.appUI.history.changedOnDisk)
		case .unavailable: String.localized(.appUI.history.unavailable)
		case .writeFailed: String.localized(.appUI.history.writeFailed)
		}
	}
}

/// One page-text read per tab: a newer visit's replaces it.
private struct PageTextReadID: Hashable {
	internal let tabID: BrowserCore.Tab.ID
}

private struct HistoryRequestID: Hashable {
	internal var profileID: Profile.ID

	internal init(_ id: Profile.ID) {
		self.profileID = id
	}
}

extension AppFeature.State {
	fileprivate mutating func syncHistory() {
		let snapshots = history.snapshots

		// A profile whose history couldn't be read has no snapshot; its History page says so.
		let unreadable = Set(history.failures.keys).subtracting(snapshots.keys)
		main.browsingHistory = snapshots
		main.unreadableHistory = unreadable
		for id in windows.ids where windows[id: id]?.isPrivate == false {
			windows[id: id]?.browsingHistory = snapshots
			windows[id: id]?.unreadableHistory = unreadable
		}
	}
}
