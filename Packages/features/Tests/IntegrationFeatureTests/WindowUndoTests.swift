import AppKit
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// One ⌘Z for the whole window (DEV-1030).
extension IntegrationFeatureTests {
	@Test
	internal func aTabMovedToAnotherWindowComesBackWithUndoThere() async throws {
		let organization = fixture()
		let personal = organization.spaces[1].id
		let moved = organization.spaces[0].unpinnedTabs[1]
		let other = UUID(900)
		let state = appState(organization, windowUndo: true, windows: [(other, personal)])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], other))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.spaces[1].unpinnedTabs, [moved])
		expectNoDifference(store.state.focusedWindowID, other)

		// ⌘Z in the window the tab went to, which has focus now.
		await store.send(.windows(.element(id: other, action: .sidebar(.ui(.undo)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, organization.spaces[0].unpinnedTabs)
		expectNoDifference(store.state.workspace.spaces[1].unpinnedTabs, [])
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, moved)
		expectNoDifference(store.state.focusedWindowID, state.main.id)

		// Taken back in one window, the step is gone from both.
		#expect(!store.state.main.sidebar.undo.contains { $0.windowMove != nil })
		#expect(store.state.windows[id: other]?.sidebar.undo.contains { $0.windowMove != nil } == false)
	}

	/// A tab moved on to a third window since, by Move to Window or Open in New Window, stays
	/// there when the first move is undone. The tab moved first is the selected one.
	@Test(arguments: [false, true])
	internal func undoLeavesATabMovedOnToAThirdWindow(inANewWindow: Bool) async throws {
		let organization = fixture()
		let moved = organization.spaces[0].unpinnedTabs[0]
		let second = UUID(900)
		let third = UUID(901)
		let state = appState(
			organization,
			windowUndo: true,
			windows: [(second, organization.spaces[1].id), (third, organization.spaces[1].id)]
		)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], second))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		await store.send(.windows(.element(
			id: second,
			action: .sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], inANewWindow ? nil : third))))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.spaces[1].unpinnedTabs, [moved])
		#expect(store.state.focusedWindowID != state.main.id)
	}

	/// Without `ARX_WINDOW_UNDO`, another window's change clears this window's history, as before.
	@Test(arguments: [true, false])
	internal func aStepStaysAfterAnotherWindowsChange(windowUndo: Bool) async throws {
		let organization = fixture()
		let other = UUID(900)
		let state = appState(organization, windowUndo: windowUndo, windows: [(other, organization.spaces[1].id)])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.sidebar(.ui(.sidebar(.newFolder(nil))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		await store.send(.windows(.element(id: other, action: .sidebar(.ui(.sidebar(.newFolder(nil)))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.folders.count == 2)

		// ⌘Z here takes back this window's folder; the other window's stays.
		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		if windowUndo {
			expectNoDifference(store.state.workspace.folders.map(\.spaceID), [organization.spaces[1].id])
		} else {
			#expect(store.state.workspace.folders.count == 2)
		}
	}

	/// A tab moved to another space comes back after another window's change, which stays; without
	/// `ARX_WINDOW_UNDO` that change cleared the history, so the tab stays where it went.
	@Test(arguments: [true, false])
	internal func aTabMovedToAnotherSpaceComesBackAfterAnotherWindowsChange(windowUndo: Bool) async throws {
		let organization = fixture()
		let work = organization.spaces[0].id
		let personal = organization.spaces[1].id
		let moved = organization.spaces[0].unpinnedTabs[1]
		let other = UUID(900)
		let state = appState(organization, windowUndo: windowUndo, windows: [(other, personal)])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.sidebar(.ui(.tabsDroppedOnSpace([.tab(moved.rawValue)], personal)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.spaces[1].unpinnedTabs, [moved])
		await store.send(.windows(.element(id: other, action: .sidebar(.ui(.sidebar(.newFolder(nil)))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.folders.map(\.spaceID), [personal])
		if windowUndo {
			expectNoDifference(store.state.workspace.spaces[id: work]?.unpinnedTabs, organization.spaces[0].unpinnedTabs)
			expectNoDifference(store.state.workspace.spaces[id: personal]?.unpinnedTabs, [])

			// The window shows again the space the tab left.
			expectNoDifference(store.state.main.sidebar.spaceID, work)
		} else {
			expectNoDifference(store.state.workspace.spaces[id: personal]?.unpinnedTabs, [moved])
		}
	}

	/// Without `ARX_WINDOW_UNDO`, only the window the tab left can take Move to Window back, and
	/// the window it went to has no step for it, as before.
	@Test
	internal func withoutWindowUndoOnlyTheWindowTheTabLeftTakesTheMoveBack() async throws {
		let organization = fixture()
		let work = organization.spaces[0].id
		let personal = organization.spaces[1].id
		let moved = organization.spaces[0].unpinnedTabs[1]
		let other = UUID(900)
		let state = appState(organization, windowUndo: false, windows: [(other, personal)])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], other))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.spaces[id: personal]?.unpinnedTabs, [moved])
		#expect(store.state.windows[id: other]?.sidebar.undo.isEmpty == true)

		await store.send(.windows(.element(id: other, action: .sidebar(.ui(.undo)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.spaces[id: personal]?.unpinnedTabs, [moved])

		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.spaces[id: work]?.unpinnedTabs, organization.spaces[0].unpinnedTabs)
		#expect(store.state.main.sidebar.undo.isEmpty)
	}

	/// Without `ARX_WINDOW_UNDO`, deleting a space isn't a step: it stays deleted, as before.
	@Test
	internal func withoutWindowUndoADeletedSpaceStaysDeleted() async throws {
		let organization = fixture()
		let work = organization.spaces[0].id
		let state = appState(organization, windowUndo: false)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.permitsClosing = { _ in true }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.delegate(.changeOrganization(.removeSpace(work)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.main.sidebar.undo.isEmpty)

		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.spaces[id: work] == nil)
	}

	@Test(arguments: [59.0, 61.0])
	internal func aDeletedSpaceComesBackForAMinute(after seconds: TimeInterval) async throws {
		let organization = fixture()
		let work = organization.spaces[0].id
		let clock = LockIsolated(Date(timeIntervalSince1970: 100))
		let state = appState(organization, windowUndo: true)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date = .init { clock.value }
			$0.browserEngine.permitsClosing = { _ in true }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.delegate(.changeOrganization(.removeSpace(work)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.spaces[id: work] == nil)
		#expect(store.state.workspace.tabs.isEmpty)

		clock.setValue(Date(timeIntervalSince1970: 100 + seconds))
		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		if seconds < OrganizationUndo.deletedSpaceGracePeriod {
			expectNoDifference(store.state.workspace.spaces.ids.elements, organization.spaces.ids.elements)
			expectNoDifference(store.state.workspace.tabs.ids.elements, organization.tabs.ids.elements)
			expectNoDifference(store.state.workspace.spaces[0].unpinnedTabs, organization.spaces[0].unpinnedTabs)
			expectNoDifference(store.state.main.sidebar.spaceID, work)
		} else {
			#expect(store.state.workspace.spaces[id: work] == nil)
		}
	}

	/// ⌘Z passes over tabs ⇧⌘T already reopened, to the step before them.
	@Test
	internal func undoPassesOverTabsReopenedWithReopenLastClosedTab() async throws {
		let organization = fixture()
		let kept = organization.spaces[0].unpinnedTabs[0]
		let closed = organization.spaces[0].unpinnedTabs[1]
		let identities = LockIsolated(100)
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.sidebar.windowUndo = true
		let store = TestStore(initialState: state) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .init {
				identities.withValue { $0 += 1 }
				return UUID(identities.value)
			}
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.sidebar(.newFolder(nil)))))
		await store.send(.sidebar(.ui(.sidebar(.closeOtherTabs(.tab(kept.rawValue))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.organization.archive.map(\.tab.id), [closed])

		await store.send(.ui(.reopenLastClosedTab))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		let reopened = try #require(store.state.sidebar.space.unpinnedTabs.last)
		#expect(reopened != kept)
		#expect(store.state.sidebar.organization.archive.isEmpty)

		await store.send(.sidebar(.ui(.undo)))
		expectNoDifference(store.state.sidebar.space.unpinnedTabs, [kept, reopened])
		expectNoDifference(store.state.sidebar.organization.folders, [])
		#expect(store.state.sidebar.organization.tabs[id: closed] == nil)
	}

	/// A close is a step of its own: what pages load and which tab is shown since aren't part of
	/// it, so ⌘Z brings the tab back and leaves them.
	@Test
	internal func undoingACloseKeepsWhatLoadedAndWasShownSince() async throws {
		let organization = fixture()
		let kept = organization.spaces[0].unpinnedTabs[0]
		let closed = organization.spaces[0].unpinnedTabs[1]
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.sidebar.windowUndo = true
		state.sidebar.select(closed)
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.event(.closeApproved(closed, reset: false, expectedLocation: nil))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.organization.tabs[id: closed] == nil)
		let loaded = URL(string: "https://loaded.example")!
		await store.send(.takePageNavigation(kept, BrowserNavigation(url: loaded, title: "Loaded")))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.organization.tabs[id: kept]?.restoration.url, loaded)

		await store.send(.sidebar(.ui(.undo)))
		#expect(store.state.sidebar.space.unpinnedTabs.contains(closed))
		expectNoDifference(store.state.sidebar.organization.tabs[id: kept]?.restoration.url, loaded)
	}

	/// A profile move reached past a step with nothing left still goes back by its own reverse,
	/// which asks each page first, not by taking back the workspace.
	@Test
	internal func aProfileMovePastAnEmptyStepGoesBackByItsOwnReverse() async throws {
		let organization = fixture()
		var moved = organization
		moved.spaces[0].name = "Moved"
		let move = OrganizationMove(
			previous: organization,
			updated: moved,
			roots: [],
			destination: organization.spaces[1].id,
			replacements: [],
			movedTabIDs: []
		)
		var state = SidebarFeature.State(organization: moved, spaceID: organization.spaces[0].id)
		state.windowUndo = true
		state.undo = [
			.init(before: organization, after: moved),
			// A reset the pin's later load took back already: nothing left.
			.init(before: moved, after: moved),
		]
		state.transferUndos = [move]
		let store = TestStore(initialState: state) { SidebarFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.undo))
		await store.receive(\.delegate.reverseTransfer)
		expectNoDifference(store.state.organization, moved)
		expectNoDifference(store.state.undo.map(\.before), [organization])
	}

	/// Taken back in one window, a step goes from the others, but another step with the same
	/// workspaces, such as an agent renaming a space back and forth, stays.
	@Test
	internal func takingAStepBackDropsOnlyItsCopies() async throws {
		let organization = fixture()
		var renamed = organization
		renamed.spaces[0].name = "Renamed"
		let first = OrganizationUndo(before: organization, after: renamed, author: .agent("Codex"))
		let again = OrganizationUndo(before: organization, after: renamed, author: .agent("Codex"))
		var state = MainFeature.State(organization: renamed, spaceID: organization.spaces[0].id)
		state.sidebar.windowUndo = true
		state.sidebar.undo = [first, again]
		let store = TestStore(initialState: state) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.dropUndo(again))
		#expect(store.state.sidebar.undo.count == 1)
		#expect(store.state.sidebar.undo.first?.isSameChange(as: first) == true)
	}

	/// Moving one of a bulk Move to Window's tabs on drops the whole earlier step: its workspaces
	/// hold that tab's move too.
	@Test
	internal func aTabMovedOnDropsItsWholeEarlierMove() async throws {
		let organization = fixture()
		let tabs = organization.spaces[0].unpinnedTabs
		let bulk = OrganizationUndo(
			before: organization,
			after: organization,
			windowMove: .init(tabs: tabs, source: UUID(1), target: UUID(2))
		)
		let onward = OrganizationUndo(
			before: organization,
			after: organization,
			windowMove: .init(tabs: [tabs[0]], source: UUID(2), target: UUID(3))
		)
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.sidebar.windowUndo = true
		state.sidebar.undo = [bulk, onward]
		let store = TestStore(initialState: state) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.dropWindowMoves([tabs[0]], keeping: onward))
		expectNoDifference(store.state.sidebar.undo.map { $0.windowMove?.tabs }, [[tabs[0]]])
	}

	/// Taking a step back gives back their windows only to tabs it reopens: one open already, moved
	/// on since, stays with the window that has it.
	@Test
	internal func undoGivesBackOnlyTheWindowsOfTabsItReopens() async throws {
		let organization = fixture()
		let open = organization.spaces[0].unpinnedTabs[0]
		var renamed = organization
		renamed.spaces[0].name = "Renamed"
		let step = OrganizationUndo(
			before: organization,
			after: renamed,
			author: .agent("Codex"),
			openTabOwners: [open: UUID(900)],
			restoresSelection: false
		)
		var state = SidebarFeature.State(organization: renamed, spaceID: organization.spaces[0].id)
		state.windowUndo = true
		state.undo = [step]
		let store = TestStore(initialState: state) { SidebarFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.undo))
		var undone = step
		undone.openTabOwners = [:]
		await store.receive(\.delegate.undid, undone)
	}

	/// A step that left only its selection to take back, such as closing a pin already at its saved
	/// page, still selects its tab again rather than being passed over.
	@Test
	internal func aStepWithOnlyItsSelectionLeftSelectsAgain() async throws {
		let organization = fixture()
		let spaceID = organization.spaces[0].id
		let tabs = organization.spaces[0].unpinnedTabs
		var before = organization
		before.spaces[0].selectedTabID = tabs[0]
		var after = organization
		after.spaces[0].selectedTabID = tabs[1]
		var state = SidebarFeature.State(organization: after, spaceID: spaceID)
		state.windowUndo = true
		state.undo = [.init(before: before, after: after, spaceID: spaceID)]
		let store = TestStore(initialState: state) { SidebarFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.undo))
		expectNoDifference(store.state.organization.spaces[0].selectedTabID, tabs[0])
		#expect(store.state.undo.isEmpty)
	}

	/// Taking a window move back gives back only the tabs still where it put them: one moved on
	/// since, back to its first space even, stays with the window that has it.
	@Test
	internal func undoGivesBackOnlyTabsStillWhereAWindowMovePutThem() async throws {
		let organization = fixture()
		let moved = organization.spaces[0].unpinnedTabs[1]
		var after = organization
		after.spaces[0].unpinnedTabs.removeAll { $0 == moved }
		after.spaces[1].unpinnedTabs.append(moved)
		var renamed = organization
		renamed.spaces[0].name = "Renamed"
		let step = OrganizationUndo(
			before: organization,
			after: after,
			spaceID: organization.spaces[0].id,
			windowMove: .init(tabs: [moved], source: UUID(1), target: UUID(2))
		)

		// The tab is back in its first space since, moved there in the other window.
		var state = SidebarFeature.State(organization: renamed, spaceID: organization.spaces[0].id)
		state.windowUndo = true
		state.undo = [step]
		let store = TestStore(initialState: state) { SidebarFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.undo))
		var undone = step
		undone.windowMove?.tabs = []
		await store.receive(\.delegate.undid, undone)
	}

	/// Closing a pin or Favorite is a step done as it's made: a tab selected afterwards stays
	/// selected when ⌘Z takes the close back (DEV-1198).
	@Test(arguments: [false, true])
	internal func aSelectionAfterClosingAPinOrFavoriteStays(favorite: Bool) async throws {
		var organization = fixture()
		let work = organization.spaces[0].id
		let other = organization.spaces[0].unpinnedTabs[1]
		let saved: BrowserCore.Tab.ID
		if favorite {
			saved = .init(rawValue: UUID(5))
			organization.tabs.append(.init(
				id: saved,
				profileID: organization.profiles[0].id,
				savedDestination: .init(title: "Mail", url: URL(string: "https://mail.example")!),
				restoration: .init(title: "Inbox", url: URL(string: "https://mail.example/inbox")!)
			))
			organization.profiles[0].favorites = [saved]
		} else {
			saved = organization.spaces[0].unpinnedTabs[0]
			try organization.move(.tab(saved.rawValue), to: .savedRoot, in: work)
			organization.tabs[id: saved]?.restoration.url = URL(string: "https://capturecontext.dev/elsewhere")!
		}
		let loaded = try #require(organization.tabs[id: saved]?.restoration)
		var state = MainFeature.State(organization: organization, spaceID: work)
		state.sidebar.windowUndo = true
		state.sidebar.select(saved)
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.close = { _ in }
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.event(.closeApproved(saved, reset: true, expectedLocation: nil))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.organization.tabs[id: saved]?.restoration != loaded)
		await store.send(.sidebar(.ui(.sidebar(.select(.tab(other.rawValue))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		await store.send(.sidebar(.ui(.undo)))
		expectNoDifference(store.state.sidebar.organization.tabs[id: saved]?.restoration, loaded)
		expectNoDifference(store.state.sidebar.selectedTab?.id, other)
	}

	/// A bulk close is a step done as it's made: a tab selected afterwards stays selected when ⌘Z
	/// brings the closed tabs back (DEV-1198).
	@Test
	internal func aSelectionAfterABulkCloseStays() async throws {
		var organization = fixture()
		let work = organization.spaces[0].id
		let kept = organization.spaces[0].unpinnedTabs[0]
		let closed = organization.spaces[0].unpinnedTabs[1]
		let pinned = BrowserCore.Tab.ID(rawValue: UUID(6))
		organization.tabs.append(.init(
			id: pinned,
			profileID: organization.profiles[0].id,
			savedDestination: .init(title: "Pinned", url: URL(string: "https://pinned.example")!),
			restoration: .init(title: "Pinned", url: URL(string: "https://pinned.example")!)
		))
		organization.spaces[0].savedItems.append(.tab(pinned))
		var state = MainFeature.State(organization: organization, spaceID: work)
		state.sidebar.windowUndo = true
		state.sidebar.select(closed)
		let identities = LockIsolated(100)
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .init {
				identities.withValue { $0 += 1 }
				return UUID(identities.value)
			}
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { _ in }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.sidebar(.closeOtherTabs(.tab(kept.rawValue))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.organization.tabs[id: closed] == nil)
		await store.send(.sidebar(.ui(.sidebar(.select(.tab(pinned.rawValue))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		await store.send(.sidebar(.ui(.undo)))
		#expect(store.state.sidebar.space.unpinnedTabs.contains(closed))
		expectNoDifference(store.state.sidebar.selectedTab?.id, pinned)
	}

	@Test
	internal func undoingAnAgentsChangeSaysWhose() async throws {
		let organization = fixture()
		var changed = organization
		changed.spaces[0].name = "Renamed by an agent"
		var state = MainFeature.State(organization: changed, spaceID: organization.spaces[0].id)
		state.sidebar.windowUndo = true
		state.sidebar.undo = [.init(before: organization, after: changed, author: .agent("Codex"), restoresSelection: false)]
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.undo)))
		expectNoDifference(store.state.sidebar.space.name, "Work")
		expectNoDifference(store.state.sidebar.message, String.localized(.appUI.sidebar.undidAgentChange("Codex")))
	}

	// MARK: - ⌘Z routing

	@Test
	internal func undoInAPageTextFieldUndoesTyping() {
		let field = PageView(isEditing: true)
		#expect(UndoRoute.route(firstResponder: field, isSecureInput: false, windowCanUndo: true) == .responder)

		let page = PageView(isEditing: false)
		#expect(UndoRoute.route(firstResponder: page, isSecureInput: false, windowCanUndo: true) == .window)
		// A page's password field keeps it too.
		#expect(UndoRoute.route(firstResponder: page, isSecureInput: true, windowCanUndo: true) == .responder)
		// With nothing to take back, the page has it as before.
		#expect(UndoRoute.route(firstResponder: page, isSecureInput: false, windowCanUndo: false) == .responder)
	}

	/// With `ARX_WINDOW_UNDO`, Edit › Undo (⌘Z) asks `UndoRoute` where to go, so a focused page
	/// field gets it first; without it, it's AppKit's `undo:` down the responder chain, as before.
	@Test(arguments: [true, false])
	internal func editUndoGoesThroughTheWindowOnlyWithWindowUndo(windowUndo: Bool) throws {
		let store = Store(initialState: appState(fixture(), windowUndo: windowUndo)) { AppFeature() }
		let commands = BrowserCommands(store: store, windowUndo: windowUndo)
		let menu = commands.makeMainMenu()
		let edit = try #require(menu.root.items.first { $0.title == String.localized(.appUI.menu.edit) }?.submenu)
		let undo = try #require(edit.items.first)

		expectNoDifference(undo.action.map(NSStringFromSelector), "undo:")
		expectNoDifference(undo.keyEquivalent, "z")
		#expect((undo.target === commands) == windowUndo)
	}

	@Test
	internal func undoInAnEmptyFieldTakesBackTheWindowsStep() {
		let typed = NSTextView()
		typed.string = "arx"
		#expect(UndoRoute.route(firstResponder: typed, isSecureInput: false, windowCanUndo: true) == .responder)

		let empty = NSTextView()
		#expect(UndoRoute.route(firstResponder: empty, isSecureInput: false, windowCanUndo: true) == .window)
		#expect(UndoRoute.route(firstResponder: nil, isSecureInput: false, windowCanUndo: true) == .window)
	}
}

extension IntegrationFeatureTests {
	/// The app on the fixture's first space with `ARX_WINDOW_UNDO` as `windowUndo` says, and more
	/// windows on the spaces given.
	fileprivate func appState(
		_ organization: BrowserOrganization,
		windowUndo: Bool,
		windows: [(UUID, Space.ID)] = []
	) -> AppFeature.State {
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.sidebar.windowUndo = windowUndo
		for (id, spaceID) in windows {
			var window = MainFeature.State(organization: organization, spaceID: spaceID, id: id)
			window.sidebar.windowUndo = windowUndo
			state.windows.append(window)
		}
		return state
	}
}

/// A page's view: it has an input context only while an editable element has focus, as
/// Chromium's does.
private final class PageView: NSView, @preconcurrency NSTextInputClient {
	private let isEditing: Bool
	private lazy var context = NSTextInputContext(client: self)

	init(isEditing: Bool) {
		self.isEditing = isEditing
		super.init(frame: .zero)
	}

	required init?(coder: NSCoder) { nil }

	override var inputContext: NSTextInputContext? { isEditing ? context : nil }

	func insertText(_ string: Any, replacementRange: NSRange) {}
	func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
	func unmarkText() {}
	func selectedRange() -> NSRange { .init(location: NSNotFound, length: 0) }
	func markedRange() -> NSRange { .init(location: NSNotFound, length: 0) }
	func hasMarkedText() -> Bool { false }
	func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
	func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
	func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
	func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
