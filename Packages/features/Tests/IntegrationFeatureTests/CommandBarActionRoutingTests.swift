import AppFeature
import BrowserCore
import BrowserEngineClient
import CommandBarFeature
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// How windows carry out the command bar's actions (DEV-810).
extension IntegrationFeatureTests {
	@Test
	internal func commandBarListsAnOpenTabAndItsHistorySoReturnSwitchesOrOpensAgain() async throws {
		let organization = fixture()
		let profile = organization.profiles[0].id
		let tab = organization.tabs[0]
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.item.tab = tab
		state.browsingHistory[profile] = .init(
			profileID: profile,
			entries: [actionHistoryEntry(10, url: tab.restoration.url)]
		)
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.command = { _, _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openCommand(.newTab)))
		await store.receive(\.commandBar.present)
		let ids = store.state.commandBar.entries.map(\.presentation.id)
		let tabRow = tab.id.rawValue.uuidString
		let historyRow = "history-\(profile.rawValue)-\(UUID(10))"
		let tabIndex = try #require(ids.firstIndex(of: tabRow))
		expectNoDifference(ids[tabIndex + 1], historyRow)

		// The history row opens a new tab and leaves the open one as it is.
		let tabCount = store.state.sidebar.organization.tabs.count
		await store.send(.commandBar(.ui(.selected(historyRow))))
		await store.receive(\.commandBar.delegate.execute)
		#expect(store.state.sidebar.organization.tabs.count == tabCount + 1)
		#expect(store.state.sidebar.organization.tabs[id: tab.id] == tab)
	}

	@Test
	internal func anActionOnAHistoryEntryRemovedSinceDoesNothing() async throws {
		let organization = fixture()
		let profile = organization.profiles[0].id
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.history.knownProfiles = Set(organization.profiles.map(\.id))
		state.history.snapshots[profile] = .init(
			profileID: profile,
			entries: [actionHistoryEntry(10, url: URL(string: "https://removed.example")!)],
			revision: 1
		)
		state.main.browsingHistory = state.history.snapshots
		let delegated = LockIsolated<Int>(0)
		let store = TestStore(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if case .main(.delegate(.openInLittleArx)) = action { delegated.withValue { $0 += 1 } }
				return AppFeature()._reduce(into: &state, action: action)
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.ui(.openCommand(.newTab))))
		await store.receive(\.main.commandBar.present)

		// Another window clears the history while this bar's list stays as it was.
		await store.send(.history(.received(.init(snapshot: .init(profileID: profile, revision: 2)), epoch: 0)))
		let row = "history-\(profile.rawValue)-\(UUID(10))"
		#expect(store.state.main.commandBar.entries.contains { $0.presentation.id == row })
		await store.send(.main(.commandBar(.ui(.highlighted(row)))))
		await store.send(.main(.commandBar(.ui(.actionsToggled))))
		await store.send(.main(.commandBar(.ui(.actionSelected("open-little-arx")))))
		await store.receive(\.main.commandBar.delegate.execute)
		await store.finish()
		#expect(delegated.value == 0)
	}

	@Test
	internal func copyingFromANewSplitsEmptyPaneClosesThatPaneAndOffersNoPeek() async throws {
		let organization = fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.item.tab = organization.tabs[0]
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .constant(UUID(20))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.splitTab(nil))).finish()
		await store.skipReceivedActions()
		#expect(store.state.viewer.isSplit)
		#expect(!store.state.commandBar.actionAvailability.opensPeek)
		await store.send(.commandBar(.ui(.highlighted(organization.tabs[0].id.rawValue.uuidString))))
		await store.send(.commandBar(.ui(.actionsToggled)))
		await store.send(.commandBar(.ui(.actionSelected("copy-url")))).finish()
		await store.skipReceivedActions()
		#expect(!store.state.viewer.isSplit)
		expectNoDifference(store.state.viewer.item.tab?.id, organization.tabs[0].id)
	}

	@Test
	internal func copyingInTheLittleArxLauncherClosesIt() async throws {
		let organization = fixture()
		var initial = LittleArxFeature.State(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: organization.tabs[0],
			isCommandOnly: true
		)
		initial.commandBar.isPresented = false
		let store = TestStore(initialState: initial) { LittleArxFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openCommand(.newTab)))
		await store.receive(\.commandBar.present)
		await store.send(.commandBar(.ui(.queryChanged("example.org"))))
		await store.send(.commandBar(.ui(.highlighted("destination"))))
		await store.send(.commandBar(.ui(.actionsToggled)))
		expectNoDifference(
			store.state.commandBar.actionPanelActions.map(\.id),
			// The typed address opens as is with ⌘↩ too (DEV-1319).
			["primary", "open-url", "copy-url"]
		)
		await store.send(.commandBar(.ui(.actionSelected("copy-url"))))
		await store.receive(\.commandBar.delegate.execute)
		await store.receive(\.delegate.copyURL, URL(string: "https://example.org")!)
		await store.receive(\.delegate.close)
		await store.finish()
	}

	@Test
	internal func anActionOnATabClosedSinceDoesNothing() async throws {
		let organization = fixture()
		let closed = organization.tabs[1]
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.item.tab = organization.tabs[0]
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openCommand(.newTab)))
		await store.receive(\.commandBar.present)
		let row = closed.id.rawValue.uuidString
		await store.send(.commandBar(.ui(.highlighted(row))))
		await store.send(.commandBar(.ui(.actionsToggled)))

		// The tab closes while the bar's list stays as it was.
		await store.send(.sidebar(.ui(.sidebar(.close(.tab(closed.id.rawValue)))))).finish()
		await store.skipReceivedActions()
		#expect(store.state.sidebar.organization.tabs[id: closed.id] == nil)
		let count = store.state.sidebar.organization.tabs.count
		await store.send(.commandBar(.ui(.actionSelected("open-new-tab"))))
		await store.receive(\.commandBar.delegate.execute)
		await store.finish()
		#expect(store.state.sidebar.organization.tabs.count == count)
	}

	@Test
	internal func copyURLOverAnOpenBarCopiesTheHighlightedResult() async throws {
		let organization = fixture()
		let other = organization.tabs[1]
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.item.tab = organization.tabs[0]
		let paneID = state.viewer.activePaneID
		let store = TestStore(initialState: state) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openCommand(.newTab)))
		await store.receive(\.commandBar.present)
		await store.send(.commandBar(.ui(.highlighted(other.id.rawValue.uuidString))))
		await store.send(.ui(.paneCommand(.copyURL, paneID)))
		await store.receive(\.commandBar.ui.actionRequested)
		await store.receive(\.commandBar.delegate.execute)
		await store.receive(\.delegate.copyURL, other.restoration.url)
		await store.finish()
	}

	@Test
	internal func theCopyURLKeyOverAnOpenBarCopiesTheResultThroughTheApp() async throws {
		let organization = fixture()
		let other = organization.tabs[1]
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		let paneID = state.main.viewer.activePaneID
		let copied = LockIsolated<[String]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.copy = { text in
				copied.withValue { $0.append(text) }
				return true
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.ui(.openCommand(.newTab))))
		await store.receive(\.main.commandBar.present)
		await store.send(.main(.commandBar(.ui(.highlighted(other.id.rawValue.uuidString)))))
		await store.send(.ui(.command(.copyURL, .window(state.main.id, paneID: paneID))))
		await store.receive(\.main.commandBar.ui.actionRequested)
		await store.receive(\.main.delegate.copyURL, other.restoration.url)
		await store.skipReceivedActions()
		await store.finish()
		expectNoDifference(copied.value, [other.restoration.url.absoluteString])
	}

	@Test
	internal func commandKOverAnOpenBarShowsAndHidesTheActions() async throws {
		let organization = fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.item.tab = organization.tabs[0]
		let paneID = state.viewer.activePaneID
		let store = TestStore(initialState: state) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.paneCommand(.newTab, paneID)))
		await store.receive(\.commandBar.present)
		let selected = try #require(store.state.commandBar.selectedID)
		await store.send(.ui(.paneCommand(.commandBar, paneID)))
		await store.receive(\.commandBar.ui.actionsToggled)
		expectNoDifference(store.state.commandBar.actionPanel?.entryID, selected)
		#expect(store.state.commandBar.mode == .newTab)

		await store.send(.ui(.paneCommand(.commandBar, paneID)))
		await store.receive(\.commandBar.ui.actionsToggled)
		#expect(store.state.commandBar.actionPanel == nil)
		#expect(store.state.commandBar.isPresented)
	}

	@Test(arguments: ["open-peek", "open-little-arx", "copy-url", "open-new-tab"])
	internal func anOpenTabsActionReachesTheApp(_ actionID: String) async throws {
		let organization = fixture()
		let tab = organization.tabs[0]
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.item.tab = tab
		let paneID = state.viewer.activePaneID
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openCommand(.newTab)))
		await store.receive(\.commandBar.present)
		await store.send(.commandBar(.ui(.highlighted(tab.id.rawValue.uuidString))))
		await store.send(.commandBar(.ui(.actionsToggled)))
		let tabCount = store.state.sidebar.organization.tabs.count
		await store.send(.commandBar(.ui(.actionSelected(actionID))))
		await store.receive(\.commandBar.delegate.execute)

		let url = tab.restoration.url
		switch actionID {
		case "open-peek":
			await store.receive(\.delegate.openInPeek)
			_ = paneID
		case "open-little-arx":
			await store.receive(\.delegate.openInLittleArx)
		case "copy-url":
			await store.receive(\.delegate.copyURL, url)
		default:
			#expect(store.state.sidebar.organization.tabs.count == tabCount + 1)
		}
		await store.finish()
	}

	@Test
	internal func aPrivateWindowOffersNoPeekLittleArxOrHistoryDeletion() async throws {
		let organization = fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, isPrivate: true)
		state.viewer.item.tab = organization.tabs[0]
		let store = TestStore(initialState: state) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openCommand(.newTab)))
		await store.receive(\.commandBar.present)
		expectNoDifference(
			store.state.commandBar.actionAvailability,
			.init(opensNewTabs: true, opensPeek: false, opensLittleArx: false, removesHistory: false)
		)
	}

	@Test
	internal func deleteFromHistoryInTheCommandBarRemovesTheEntryEverywhere() async throws {
		let organization = fixture()
		let profile = organization.profiles[0].id
		let kept = actionHistoryEntry(10, url: URL(string: "https://kept.example")!)
		let removed = actionHistoryEntry(11, url: URL(string: "https://removed.example")!)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.history.knownProfiles = Set(organization.profiles.map(\.id))
		state.history.snapshots[profile] = .init(profileID: profile, entries: [removed, kept], revision: 1)
		state.main.browsingHistory = state.history.snapshots
		let removals = LockIsolated<[BrowsingHistoryRemoval]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(removeEntries: { id, removal, _ in
				removals.withValue { $0.append(removal) }
				return .init(snapshot: .init(profileID: id, entries: [kept], revision: 2))
			})
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.ui(.openCommand(.newTab))))
		await store.receive(\.main.commandBar.present)
		let row = "history-\(profile.rawValue)-\(removed.id)"
		await store.send(.main(.commandBar(.ui(.highlighted(row)))))
		await store.send(.main(.commandBar(.ui(.actionsToggled))))
		await store.send(.main(.commandBar(.ui(.actionSelected("delete-history")))))
		await store.receive(\.main.commandBar.delegate.removeHistory)
		await store.receive(\.main.delegate.removeHistory)

		// The bar and every window's list drop it before the store answers.
		#expect(!store.state.main.commandBar.entries.contains { $0.presentation.id == row })
		#expect(store.state.main.commandBar.isPresented)
		expectNoDifference(store.state.main.browsingHistory[profile]?.entries, [kept])
		await store.receive(\.history.received)
		await store.finish()
		expectNoDifference(removals.value, [.entries([removed.id])])
		#expect(store.state.history.snapshots[profile]?.revision == 2)
	}

	@Test
	internal func anOlderAnswerArrivingDuringARemovalDoesNotBringTheEntryBack() async throws {
		let organization = fixture()
		let profile = organization.profiles[0].id
		let kept = actionHistoryEntry(10, url: URL(string: "https://kept.example")!)
		let removed = actionHistoryEntry(11, url: URL(string: "https://removed.example")!)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.history.knownProfiles = Set(organization.profiles.map(\.id))
		state.history.snapshots[profile] = .init(profileID: profile, entries: [removed, kept], revision: 1)
		state.main.browsingHistory = state.history.snapshots
		let answer = AsyncStream.makeStream(of: Void.self)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init(removeEntries: { id, _, _ in
				for await _ in answer.stream { break }
				return .init(snapshot: .init(profileID: id, entries: [kept], revision: 3))
			})
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.delegate(.removeHistory(profile, .entries([removed.id])))))
		expectNoDifference(store.state.main.browsingHistory[profile]?.entries, [kept])

		// A visit recorded before the removal answers with the entry still in it.
		await store.send(.history(.received(
			.init(snapshot: .init(profileID: profile, entries: [removed, kept], revision: 2)),
			epoch: 0
		)))
		expectNoDifference(store.state.main.browsingHistory[profile]?.entries, [kept])

		// A visit made after the removal was asked for stays.
		let revisit = BrowsingHistoryEntry(
			id: removed.id,
			url: removed.url,
			title: removed.title,
			lastVisited: Date(timeIntervalSince1970: 200)
		)
		await store.send(.history(.received(
			.init(snapshot: .init(profileID: profile, entries: [revisit, kept], revision: 4)),
			epoch: 0
		)))
		expectNoDifference(store.state.main.browsingHistory[profile]?.entries, [revisit, kept])

		answer.continuation.yield()
		answer.continuation.finish()
		await store.receive(\.history.received)
		await store.receive(\.history.removalFinished)
		await store.finish()
		expectNoDifference(store.state.history.pendingRemovals, [:])

		// The removal's answer is older than the revisit's, so the revisit's list stays.
		expectNoDifference(store.state.history.snapshots[profile]?.revision, 4)
		expectNoDifference(store.state.main.browsingHistory[profile]?.entries, [revisit, kept])
	}

	@Test
	internal func openInPeekAndLittleArxFromTheMainWindowGoToTheirPresenters() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		let paneID = state.main.viewer.activePaneID
		let url = URL(string: "https://peek.example")!
		let opened = LockIsolated<[String]>([])

		// The presenters themselves are covered elsewhere; this checks where the actions go.
		let store = TestStore(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				switch action {
				case let .ui(.openLittleArx(spaceID, target)):
					opened.withValue { $0.append("little \(spaceID == organization.spaces[0].id) \(target == url)") }
					return .none

				case let .ui(.peekURLFromSource(target, source, _)):
					opened.withValue { $0.append("peek \(source.paneID == paneID) \(target == url)") }
					return .none

				default:
					return AppFeature()._reduce(into: &state, action: action)
				}
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.delegate(.openInLittleArx(url, organization.spaces[0].id))))
		await store.receive(\.ui.openLittleArx)
		await store.send(.main(.delegate(.openInPeek(url, paneID: paneID))))
		await store.receive(\.ui.peekURLFromSource)
		await store.finish()
		expectNoDifference(opened.value, ["little true true", "peek true true"])
	}

	private func actionHistoryEntry(
		_ id: Int,
		url: URL
	) -> BrowsingHistoryEntry {
		.init(
			id: UUID(id),
			url: url,
			title: "History \(id)",
			lastVisited: Date(timeIntervalSince1970: Double(id))
		)
	}
}
