import AppFeature
import BrowserCore
import BrowserHistoryClient
import CustomDump
import Foundation
import HistoryFeature
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// The Library's History page through the app (DEV-817).
extension IntegrationFeatureTests {
	@Test
	internal func showHistoryOpensTheLibrarysHistoryPage() async throws {
		var state = historyPageFixture()
		state.main.sidebar.sidebarIsVisible = false
		let store = Store(initialState: state) { AppFeature() }

		await store.send(.ui(.command(.showHistory, .window(store.main.id)))).finish()

		#expect(store.main.isLibraryOpen)
		expectNoDifference(store.main.libraryPanel, .history)
		#expect(store.main.sidebar.sidebarIsVisible)
		#expect(!store.main.commandBar.isPresented)
	}

	@Test
	internal func historyPageShowsTheCurrentProfilesHistoryAsItChanges() throws {
		var state = historyPageFixture().main
		let profile = state.sidebar.space.profileID
		expectNoDifference(state.historyPage.entries.map(\.title), ["Second", "First"])
		#expect(!state.historyPage.isUnavailable)

		state.browsingHistory[profile]?.entries.removeFirst()
		expectNoDifference(state.historyPage.entries.map(\.title), ["First"])

		state.browsingHistory[profile] = nil
		state.unreadableHistory = [profile]
		#expect(state.historyPage.isUnavailable)

		let privateState = MainFeature.State(
			organization: state.sidebar.organization,
			spaceID: state.sidebar.spaceID,
			isPrivate: true,
			browsingHistory: historyPageFixture().main.browsingHistory
		)
		#expect(privateState.historyPage.profileID == nil)
		#expect(privateState.historyPage.entries.isEmpty)
		#expect(!privateState.librarySections.contains(.history))
	}

	@Test
	internal func openingAHistoryEntryOpensANewTab() async throws {
		let state = historyPageFixture()
		let profile = state.main.sidebar.space.profileID
		let entry = try #require(state.main.browsingHistory[profile]?.entries.first)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.historyPage(.ui(.open(entry.id)))))
		await store.receive(\.main.historyPage.delegate.open)
		await store.receive(\.main.ui.openInNewTab)
		await store.skipReceivedActions()

		// A new tab in the current space, right below the tab the history page showed in or at
		// the top without one among the open tabs (DEV-1243), selected, on the entry's address.
		let selected = try #require(store.state.main.sidebar.selectedTab)
		expectNoDifference(selected.restoration.url, entry.url)
		expectNoDifference(selected.profileID, profile)
		var expected = state.main.sidebar.space.unpinnedTabs
		let opener = state.main.sidebar.space.selectedTabID.flatMap(expected.firstIndex(of:))
		expected.insert(selected.id, at: opener.map { $0 + 1 } ?? 0)
		expectNoDifference(store.state.main.sidebar.space.unpinnedTabs, expected)
	}

	@Test(arguments: [false, true])
	internal func deletingFromTheHistoryPageTakesTheCommandBarsPathAndUpdatesEveryWindow(
		_ fromChildWindow: Bool
	) async throws {
		var state = historyPageFixture()
		let profile = state.main.sidebar.space.profileID
		let windowID = UUID(70)
		state.windows.append(.init(
			organization: state.workspace,
			spaceID: state.main.sidebar.spaceID,
			id: windowID,
			browsingHistory: state.history.snapshots
		))
		let snapshot = try #require(state.history.snapshots[profile])
		let deleted = snapshot.entries[0]
		let kept = snapshot.entries[1]
		let requests = LockIsolated<[BrowsingHistoryRemoval]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 2_000_000)
			$0.browserHistory = .init(
				removeEntries: { id, removal, _ in
					requests.withValue { $0.append(removal) }
					return .init(snapshot: .init(profileID: id, entries: [kept], revision: snapshot.revision + 1))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let action = MainFeature.Action.historyPage(.ui(.delete(deleted.id)))
		let removal: (inout AppFeature.State) -> Void = {
			// Every window shows the deletion at once, before the store answers.
			$0.history.snapshots[profile]?.entries = [kept]
			$0.main.browsingHistory[profile]?.entries = [kept]
			$0.windows[id: windowID]?.browsingHistory[profile]?.entries = [kept]
		}
		if fromChildWindow {
			await store.send(.windows(.element(id: windowID, action: action)))
			await store.receive(\.windows) // The page's delegate.
			await store.receive(\.windows, assert: removal)
		} else {
			await store.send(.main(action))
			await store.receive(\.main.historyPage.delegate.remove)
			await store.receive(\.main.delegate.removeHistory, assert: removal)
		}
		await store.receive(\.history.received)
		await store.finish()

		expectNoDifference(requests.value, [.entries([deleted.id])])
		expectNoDifference(store.state.main.historyPage.entries, [kept])
		expectNoDifference(store.state.windows[id: windowID]?.historyPage.entries, [kept])
		expectNoDifference(store.state.history.snapshots[profile]?.revision, snapshot.revision + 1)
		expectNoDifference(store.state.settings.historyStatus[profile]?.count, 1)
	}

	@Test
	internal func deletingADayFromTheHistoryPageDeletesItsPagesInOneCall() async throws {
		let state = historyPageFixture()
		let profile = state.main.sidebar.space.profileID
		let entries = try #require(state.history.snapshots[profile]?.entries)
		let requests = LockIsolated<[BrowsingHistoryRemoval]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.calendar = Calendar(identifier: .gregorian)
			$0.date.now = Date(timeIntervalSince1970: 2_000_000)
			$0.browserHistory = .init(
				removeEntries: { id, removal, _ in
					requests.withValue { $0.append(removal) }
					return .init(snapshot: .init(profileID: id, revision: 10))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.historyPage(.ui(.deleteDay(entries[0].lastVisited)))))
		await store.send(.main(.historyPage(.ui(.deletionConfirmed))))
		await store.receive(\.main.delegate.removeHistory)
		await store.receive(\.history.received)
		await store.finish()

		expectNoDifference(requests.value, [.entries(Set(entries.map(\.id)))])
		#expect(store.state.main.historyPage.entries.isEmpty)
		#expect(store.state.main.historyDeletion == nil)
	}

	/// A confirmation asked for in one profile never deletes from another when the window's
	/// space changes meanwhile, for example through an assistant.
	@Test
	internal func aPendingDeletionStaysWithItsProfile() async throws {
		var organization = fixture()
		let other = Space(id: .init(rawValue: UUID(90)), profileID: .init(rawValue: UUID(91)), name: "Other")
		organization.profiles.append(.init(id: other.profileID, name: "Other"))
		organization.spaces.append(other)
		var state = historyPageFixture(organization)
		let profile = state.main.sidebar.space.profileID
		state.history.snapshots[other.profileID] = state.history.snapshots[profile].map { snapshot in
			var copy = snapshot
			copy.profileID = other.profileID
			return copy
		}
		state.main.browsingHistory = state.history.snapshots
		let day = try #require(state.history.snapshots[profile]?.entries.first?.lastVisited)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.calendar = Calendar(identifier: .gregorian)
			$0.date.now = Date(timeIntervalSince1970: 2_000_000)
			$0.browserHistory = .init(
				removeEntries: { id, _, _ in
					Issue.record("Deleted history after the profile changed")
					return .init(snapshot: .init(profileID: id))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.historyPage(.ui(.deleteDay(day)))))
		#expect(store.state.main.historyPage.pendingDeletion != nil)
		await store.send(.main(.sidebar(.ui(.spaceSelected(other.id)))))
		await store.skipReceivedActions()
		#expect(store.state.main.sidebar.space.profileID == other.profileID)
		#expect(store.state.main.historyPage.pendingDeletion == nil)
		await store.send(.main(.historyPage(.ui(.deletionConfirmed))))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.history.snapshots[other.profileID]?.entries.count, 2)
		expectNoDifference(store.state.history.snapshots[profile]?.entries.count, 2)
	}

	@Test
	internal func privateWindowsCantDeleteHistory() async throws {
		var state = historyPageFixture()
		let profile = state.main.sidebar.space.profileID
		let privateID = UUID(71)
		state.windows.append(.init(
			organization: state.workspace,
			spaceID: state.main.sidebar.spaceID,
			isPrivate: true,
			id: privateID
		))
		let id = try #require(state.history.snapshots[profile]?.entries.first?.id)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 2_000_000)
			$0.browserHistory = .init(
				removeEntries: { id, _, _ in
					Issue.record("A private window deleted history")
					return .init(snapshot: .init(profileID: id))
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.windows(.element(id: privateID, action: .delegate(.removeHistory(profile, .entries([id]))))))
		await store.finish()
		expectNoDifference(store.state.history.snapshots[profile]?.entries.count, 2)
	}

	private func historyPageFixture(_ organization: BrowserOrganization? = nil) -> AppFeature.State {
		let organization = organization ?? fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let profile = organization.spaces[0].profileID
		let snapshot = BrowsingHistorySnapshot(
			profileID: profile,
			entries: [
				.init(
					id: UUID(11),
					url: URL(string: "https://capturecontext.dev/second")!,
					title: "Second",
					lastVisited: Date(timeIntervalSince1970: 1_000_020)
				),
				.init(
					id: UUID(10),
					url: URL(string: "https://capturecontext.dev/first")!,
					title: "First",
					lastVisited: Date(timeIntervalSince1970: 1_000_010)
				),
			],
			revision: 3
		)
		state.history.snapshots[profile] = snapshot
		state.history.knownProfiles = Set(organization.profiles.map(\.id))
		state.main.browsingHistory = state.history.snapshots
		return state
	}
}
