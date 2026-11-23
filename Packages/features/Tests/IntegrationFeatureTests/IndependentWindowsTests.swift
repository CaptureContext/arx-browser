import BrowserCore
import BrowserSurfaceClient
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import ViewerFeature
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-822: ⌘N opens an independent window. Windows share spaces, Favorites and pinned tabs;
/// each keeps its own open tabs.
@Suite(.dependencies)
@MainActor
internal struct IndependentWindowsTests {
	private let url: URL = URL(string: "https://window.example")!

	@Test
	internal func aNewWindowStartsWithNoOpenTabsOfItsOwn() async throws {
		let store = makeStore(fixture())
		let mainTabs = store.state.workspace.spaces[0].unpinnedTabs

		await store.send(.ui(.newWindow))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		let window = try #require(store.state.windows.first)
		expectNoDifference(window.sidebar.spaceID, store.state.workspace.spaces[0].id)
		expectNoDifference(window.sidebar.windowOpenTabs, [])
		expectNoDifference(window.sidebar.windowTabOrder, [store.state.workspace.profiles[0].favorites[0]])
		#expect(window.sidebar.selectedTab == nil)
		// The main window keeps every open tab it had, and every window still holds them all.
		expectNoDifference(store.state.main.sidebar.windowOpenTabs, mainTabs)
		expectNoDifference(window.sidebar.organization.spaces[0].unpinnedTabs, mainTabs)
	}

	@Test
	internal func aNewWindowOpensOnTheFrontWindowsSpace() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[1].id)
		state.focusedWindowID = windowID
		let store = makeStore(state)

		await store.send(.ui(.newWindow))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.windows.last?.sidebar.spaceID, state.workspace.spaces[1].id)
	}

	@Test
	internal func aTabOpenedInAWindowIsOnlyThere() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let store = makeStore(state)

		let opened = try await openTab(in: windowID, store)
		let window = try #require(store.state.windows[id: windowID])
		expectNoDifference(store.state.windowTabOwners, [opened: windowID])
		expectNoDifference(window.sidebar.windowOpenTabs, [opened])
		#expect(!store.state.main.sidebar.windowOpenTabs.contains(opened))
		// The organization stays whole in every window.
		#expect(store.state.main.sidebar.organization.spaces[0].unpinnedTabs.contains(opened))
		// Next Tab and ⌘1–9 go through the window's own tabs, after the shared Favorite.
		expectNoDifference(window.sidebar.windowTabOrder, [store.state.workspace.profiles[0].favorites[0], opened])
	}

	@Test
	internal func aTabOpenedInTheMainWindowStaysOutOfTheOthers() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let store = makeStore(state)

		let opened = try await openTab(in: state.main.id, store)
		#expect(store.state.windowTabOwners.isEmpty)
		#expect(store.state.main.sidebar.windowOpenTabs.contains(opened))
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.windowOpenTabs, [])
	}

	@Test
	internal func pinningATabSharesItAndUnpinningGivesItToThatWindow() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let store = makeStore(state)
		let spaceID = state.workspace.spaces[0].id

		let opened = try await openTab(in: windowID, store)

		await store.send(.windows(.element(
			id: windowID,
			action: .sidebar(.ui(.move(.tab(opened.rawValue), .savedRoot, spaceID)))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.spaces[0].savedItems.contains(.tab(opened)))
		#expect(store.state.windowTabOwners.isEmpty)
		#expect(store.state.main.sidebar.windowTabOrder.contains(opened))

		// Unpinned in the window, it's that window's again.
		await store.send(.windows(.element(
			id: windowID,
			action: .sidebar(.ui(.move(.tab(opened.rawValue), .unpinnedRoot, spaceID)))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.windowTabOwners, [opened: windowID])
		#expect(!store.state.main.sidebar.windowOpenTabs.contains(opened))
		#expect(store.state.windows[id: windowID]?.sidebar.windowOpenTabs.contains(opened) == true)
	}

	@Test
	internal func moveToWindowHandsTheTabsOver() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let store = makeStore(state)
		let moved = state.workspace.spaces[0].unpinnedTabs[1]

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], windowID))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.windowTabOwners, [moved: windowID])
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.windowOpenTabs, [moved])
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.selectedTab?.id, moved)
		#expect(!store.state.main.sidebar.windowOpenTabs.contains(moved))

		// And back: the main window takes it again, and no window keeps it.
		await store.send(.windows(.element(
			id: windowID,
			action: .sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], state.main.id))))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.windowTabOwners.isEmpty)
		#expect(store.state.main.sidebar.windowOpenTabs.contains(moved))
	}

	@Test
	internal func aPinnedTabAnotherWindowUnpinsLeavesThisWindowsMultiSelection() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let store = makeStore(state)
		let spaceID = state.workspace.spaces[0].id
		let opened = try await openTab(in: windowID, store)
		await store.send(.windows(.element(
			id: windowID,
			action: .sidebar(.ui(.move(.tab(opened.rawValue), .savedRoot, spaceID)))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		// The main window multi-selects the pinned tab and an open tab of its own.
		let own = state.workspace.spaces[0].unpinnedTabs[1]
		await store.send(.main(.sidebar(.ui(.sidebar(.toggleMoveSelection(.tab(opened.rawValue)))))))
		await store.send(.main(.sidebar(.ui(.sidebar(.toggleMoveSelection(.tab(own.rawValue)))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.main.sidebar.moveSelection.contains(.tab(opened.rawValue)))

		// The other window unpins it: it's that window's, and the main window's bulk actions
		// can't reach it.
		await store.send(.windows(.element(
			id: windowID,
			action: .sidebar(.ui(.move(.tab(opened.rawValue), .unpinnedRoot, spaceID)))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.windowTabOwners, [opened: windowID])
		#expect(!store.state.main.sidebar.moveSelection.contains(.tab(opened.rawValue)))
		#expect(store.state.main.sidebar.moveSelection.contains(.tab(own.rawValue)))
	}

	@Test
	internal func aTabDroppedFromAnotherWindowsSidebarComesToThisWindow() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let dropped = state.workspace.spaces[0].unpinnedTabs[1]
		state.main.sidebar.select(dropped)
		let store = makeStore(state)

		// The main window's row dropped among the new window's open tabs.
		await store.send(.windows(.element(
			id: windowID,
			action: .sidebar(.ui(.sidebar(.moveItems([.tab(dropped.rawValue)], .unpinnedRoot))))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.windowTabOwners, [dropped: windowID])
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.windowOpenTabs, [dropped])
		#expect(!store.state.main.sidebar.windowOpenTabs.contains(dropped))
		// The main window lets it go, as Move to Window does.
		#expect(store.state.main.sidebar.selectedTab?.id != dropped)
	}

	/// With one ⌘Z per window, a tab this window opened and another window took by a drop stays
	/// there: ⌘Z here no longer takes back its opening (DEV-1030).
	@Test
	internal func undoLeavesATabThisWindowOpenedThatAnotherTookByADrop() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let store = makeStore(state)
		let opened = try await openTab(in: store.state.main.id, store)
		#expect(!store.state.main.sidebar.undo.isEmpty)

		await store.send(.windows(.element(
			id: windowID,
			action: .sidebar(.ui(.sidebar(.moveItems([.tab(opened.rawValue)], .unpinnedRoot))))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.windowTabOwners[opened], windowID)

		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.tabs[id: opened] != nil)
		expectNoDifference(store.state.windowTabOwners[opened], windowID)
	}

	/// With one ⌘Z per window, a tab sent with Move to Window and dropped on into a third window
	/// stays there: ⌘Z in the first window no longer pulls it back (DEV-1030).
	@Test
	internal func undoOfMoveToWindowLeavesATabDroppedOnIntoAThirdWindow() async throws {
		var state = fixture()
		let second = UUID(50)
		let third = UUID(51)
		state.appendBrowserWindow(second, spaceID: state.workspace.spaces[0].id)
		state.appendBrowserWindow(third, spaceID: state.workspace.spaces[0].id)
		let moved = state.workspace.spaces[0].unpinnedTabs[1]
		let store = makeStore(state)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], second))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		await store.send(.windows(.element(
			id: third,
			action: .sidebar(.ui(.sidebar(.moveItems([.tab(moved.rawValue)], .unpinnedRoot))))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.windowTabOwners[moved], third)

		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.windowTabOwners[moved], third)
	}

	/// With one ⌘Z per window, a deleted space taken back gives each window its open tabs again,
	/// not all of them to the window that took it back (DEV-1030).
	@Test
	internal func undoingASpacesDeletionGivesEachWindowItsTabsBack() async throws {
		var state = fixture()
		let work = state.workspace.spaces[0].id
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: work)
		let open = state.workspace.spaces[0].unpinnedTabs
		state.giveOpenTabs([open[1]], to: windowID)
		let next = LockIsolated(1_000)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = UUIDGenerator { next.withValue { value in
				value += 1
				return UUID(value)
			} }
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserEngine.permitsClosing = { _ in true }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.delegate(.changeOrganization(.removeSpace(work)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.spaces[id: work] == nil)

		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.spaces[id: work]?.unpinnedTabs, open)
		expectNoDifference(store.state.windowTabOwners, [open[1]: windowID])
	}

	/// A step records the window of every open tab it removes, closed by an agent as well as in a
	/// deleted space, so taking it back from any window gives each its tabs again (DEV-1030).
	@Test
	internal func aStepRecordsTheWindowOfEveryOpenTabItRemoves() throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let open = state.workspace.spaces[0].unpinnedTabs
		state.giveOpenTabs([open[1]], to: windowID)
		var closed = state.workspace
		closed.spaces[0].unpinnedTabs.removeAll { $0 == open[1] }
		closed.tabs.remove(id: open[1])

		expectNoDifference(state.openTabOwners(removedFrom: state.workspace, in: closed), [open[1]: windowID])
		state.setIndependentWindows(false)
		expectNoDifference(state.openTabOwners(removedFrom: state.workspace, in: closed), [:])
	}

	/// A tab one window made and another window opened since, unpinning it there, is that
	/// window's: the step that made it goes from the first window, so ⌘Z there can't close it
	/// (DEV-1030).
	@Test
	internal func aTabUnpinnedInAnotherWindowDropsTheStepThatMadeItHere() throws {
		var state = fixture()
		let windowID = UUID(50)
		let spaceID = state.workspace.spaces[0].id
		state.appendBrowserWindow(windowID, spaceID: spaceID)
		let made = state.workspace.spaces[0].unpinnedTabs[1]
		var withoutTab = state.workspace
		withoutTab.spaces[0].unpinnedTabs.removeAll { $0 == made }
		withoutTab.tabs.remove(id: made)
		var pinned = state.workspace
		try pinned.move(.tab(made.rawValue), to: .savedRoot, in: spaceID)
		state.main.sidebar.undo = [.init(before: withoutTab, after: state.workspace)]

		state.claimOpenedTabs(from: windowID, previous: pinned, current: state.workspace)
		expectNoDifference(state.windowTabOwners[made], windowID)
		#expect(state.main.sidebar.undo.isEmpty)
	}

	@Test
	internal func aTabDroppedIntoATabGroupFromAnotherWindowComesToThisWindow() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let dropped = state.workspace.spaces[0].unpinnedTabs[1]
		let store = makeStore(state)
		let own = try await openTab(in: windowID, store)
		await store.send(.windows(.element(id: windowID, action: .sidebar(.ui(.sidebar(.groupTabs([.tab(own.rawValue)])))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		let group = try #require(store.state.workspace.tabGroups.first { $0.tabIDs == [own] })

		await store.send(.windows(.element(
			id: windowID,
			action: .sidebar(.ui(.sidebar(.moveItems([.tab(dropped.rawValue)], .inside(.folder(group.id.rawValue))))))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.tabGroups[id: group.id]?.tabIDs.contains(dropped) == true)
		expectNoDifference(store.state.windowTabOwners[dropped], windowID)
		#expect(store.state.windows[id: windowID]?.sidebar.windowOpenTabs.contains(dropped) == true)
		#expect(!store.state.main.sidebar.windowOpenTabs.contains(dropped))
	}

	@Test
	internal func pinGroupPinsOnlyTheTabsThisWindowShows() async throws {
		let (store, windowID, group, mainTab, windowTab) = try await groupSplitAcrossWindows()

		await store.send(.main(.sidebar(.ui(.sidebar(.pinTabGroup(.folder(group.rawValue)))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		let space = store.state.workspace.spaces[0]
		#expect(!space.unpinnedTabs.contains(mainTab))
		#expect(store.state.workspace.folders.contains { $0.children == [.tab(mainTab)] })
		// The other window keeps its tab, open and grouped.
		#expect(space.unpinnedTabs.contains(windowTab))
		expectNoDifference(store.state.workspace.tabGroups[id: group]?.tabIDs, [windowTab])
		expectNoDifference(store.state.windowTabOwners[windowTab], windowID)
		#expect(store.state.windows[id: windowID]?.sidebar.windowOpenTabs.contains(windowTab) == true)
	}

	@Test
	internal func ungroupTakesOnlyTheTabsThisWindowShowsOutOfTheGroup() async throws {
		let (store, windowID, group, mainTab, windowTab) = try await groupSplitAcrossWindows()

		await store.send(.windows(.element(id: windowID, action: .sidebar(.ui(.sidebar(.ungroupTabGroup(.folder(group.rawValue))))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.tabGroup(containing: windowTab) == nil)
		expectNoDifference(store.state.workspace.tabGroups[id: group]?.tabIDs, [mainTab])
		expectNoDifference(store.state.windowTabOwners[windowTab], windowID)
	}

	@Test
	internal func aRefusedTabGroupDropLeavesTheTabWithItsWindow() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let grouped = state.workspace.spaces[0].unpinnedTabs[1]
		let store = makeStore(state)
		await store.send(.main(.sidebar(.ui(.sidebar(.groupTabs([.tab(grouped.rawValue)]))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.tabGroups.contains { $0.tabIDs == [grouped] })

		// Dropped beside a row that's gone by the time the drop arrives: the move fails.
		await store.send(.windows(.element(
			id: windowID,
			action: .sidebar(.ui(.sidebar(.moveItems([.tab(grouped.rawValue)], .before(.tab(UUID(999)))))))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.windowTabOwners.isEmpty)
		#expect(store.state.main.sidebar.windowOpenTabs.contains(grouped))
	}

	@Test
	internal func anotherWindowsOpenTabStaysOutOfThisWindowsSplitView() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let mainTab = state.workspace.spaces[0].unpinnedTabs[1]
		let store = makeStore(state)
		_ = try await openTab(in: windowID, store)

		await store.send(.windows(.element(id: windowID, action: .ui(.splitTab(mainTab)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.windows[id: windowID]?.viewer.isSplit == false)
		#expect(store.state.windowTabOwners[mainTab] == nil)

		// A Favorite still joins.
		await store.send(.windows(.element(id: windowID, action: .ui(.splitTab(.init(rawValue: UUID(5)))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.windows[id: windowID]?.viewer.isSplit == true)
	}

	/// With one ⌘Z per window and without it, as before (DEV-1030).
	@Test(arguments: [true, false])
	internal func undoOfMoveToWindowBringsTheTabBackToThisWindow(windowUndo: Bool) async throws {
		var state = fixture(windowUndo: windowUndo)
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let moved = state.workspace.spaces[0].unpinnedTabs[1]
		state.main.sidebar.select(moved)
		let store = makeStore(state)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], windowID))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.windowTabOwners, [moved: windowID])

		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.windowTabOwners.isEmpty)
		#expect(store.state.main.sidebar.windowOpenTabs.contains(moved))
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, moved)
		#expect(store.state.windows[id: windowID]?.sidebar.windowOpenTabs.contains(moved) == false)
		#expect(store.state.windows[id: windowID]?.sidebar.selectedTab?.id != moved)
		#expect(store.state.main.sidebar.undo.isEmpty)
	}

	/// With one ⌘Z per window and without it, as before (DEV-1030).
	@Test(arguments: [true, false])
	internal func undoOfAnEditAfterMoveToWindowLeavesTheMovedTabThere(windowUndo: Bool) async throws {
		var state = fixture(windowUndo: windowUndo)
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let moved = state.workspace.spaces[0].unpinnedTabs[1]
		state.main.sidebar.select(state.workspace.spaces[0].unpinnedTabs[0])
		let store = makeStore(state)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], windowID))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		await store.send(.main(.sidebar(.ui(.sidebar(.newFolder(nil))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(!store.state.workspace.folders.isEmpty)

		// The first undo takes the folder away and nothing else.
		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.folders.isEmpty)
		expectNoDifference(store.state.windowTabOwners, [moved: windowID])

		// The next one brings the tab back.
		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.windowTabOwners.isEmpty)
		#expect(store.state.main.sidebar.windowOpenTabs.contains(moved))
	}

	/// With one ⌘Z per window and without it, as before (DEV-1030).
	@Test(arguments: [true, false])
	internal func undoOfMovingAPinnedTabToAWindowLetsThatWindowShowAnotherTab(windowUndo: Bool) async throws {
		var state = fixture(windowUndo: windowUndo)
		let spaceID = state.workspace.spaces[0].id
		let open = state.workspace.spaces[0].unpinnedTabs
		var organization = state.workspace
		try organization.move(.tab(open[1].rawValue), to: .savedRoot, in: spaceID)
		let pinned = open[1]
		state.workspace = organization
		state.main.sidebar.organization = organization
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: spaceID)

		// The pinned tab went to the window, and this window shows another tab.
		var previous = organization
		previous.spaces[0].selectedTabID = pinned
		state.main.sidebar.select(open[0])
		state.main.sidebar.undo = [.init(
			before: previous,
			after: state.main.sidebar.organization,
			spaceID: spaceID,
			windowMove: .init(tabs: [pinned], source: state.main.id, target: windowID)
		)]

		// It moved on from that window to a third one, which shows it now.
		let thirdID = UUID(51)
		state.appendBrowserWindow(thirdID, spaceID: spaceID)
		state.windows[id: thirdID]?.sidebar.select(pinned)
		let pinnedTab = organization.tabs[id: pinned]
		state.windows[id: thirdID]?.viewer.item.tab = pinnedTab
		let store = makeStore(state)

		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.main.sidebar.selectedTab?.id, pinned)
		#expect(store.state.windows[id: thirdID]?.sidebar.selectedTab?.id != pinned)
	}

	/// With one ⌘Z per window and without it, as before (DEV-1030).
	@Test(arguments: [true, false])
	internal func moveToAWindowThatAlreadyShowsThePinnedTabLeavesNothingToUndo(windowUndo: Bool) async throws {
		var state = fixture(windowUndo: windowUndo)
		let spaceID = state.workspace.spaces[0].id
		let open = state.workspace.spaces[0].unpinnedTabs
		var organization = state.workspace
		try organization.move(.tab(open[1].rawValue), to: .savedRoot, in: spaceID)
		let pinned = open[1]
		state.workspace = organization
		state.main.sidebar.organization = organization
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: spaceID)
		state.windows[id: windowID]?.sidebar.select(pinned)
		let pinnedTab = organization.tabs[id: pinned]
		state.windows[id: windowID]?.viewer.item.tab = pinnedTab
		let store = makeStore(state)

		// The window already shows it, so the move only brings that window forward.
		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(pinned.rawValue)], windowID))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.focusedWindowID, windowID)
		#expect(store.state.main.sidebar.undo.isEmpty)
		#expect(store.state.windows[id: windowID]?.sidebar.undo.isEmpty == true)
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.selectedTab?.id, pinned)
	}

	/// With one ⌘Z per window and without it, as before (DEV-1030).
	@Test(arguments: [true, false])
	internal func undoOfOpenInNewWindowBringsTheTabBackToThisWindow(windowUndo: Bool) async throws {
		let state = fixture(windowUndo: windowUndo)
		let store = makeStore(state, uuid: .constant(UUID(900)))
		let moved = state.workspace.spaces[0].unpinnedTabs[0]

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], nil))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.windowTabOwners, [moved: UUID(900)])

		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.windowTabOwners.isEmpty)
		#expect(store.state.main.sidebar.windowOpenTabs.contains(moved))
		#expect(store.state.windows[id: UUID(900)]?.sidebar.windowOpenTabs.isEmpty == true)
	}

	/// With one ⌘Z per window and without it, as before (DEV-1030).
	@Test(arguments: [true, false])
	internal func undoOfMoveToAWindowOnAnotherSpaceBringsTheTabBackInOneStep(windowUndo: Bool) async throws {
		var state = fixture(windowUndo: windowUndo)
		let windowID = UUID(50)
		let work = state.workspace.spaces[0].id
		let personal = state.workspace.spaces[1].id
		state.appendBrowserWindow(windowID, spaceID: personal)
		let moved = state.workspace.spaces[0].unpinnedTabs[1]
		let store = makeStore(state)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], windowID))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.spaces[id: personal]?.unpinnedTabs.contains(moved) == true)
		expectNoDifference(store.state.main.sidebar.undo.count, 1)

		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.spaces[id: work]?.unpinnedTabs.contains(moved) == true)
		#expect(store.state.workspace.spaces[id: personal]?.unpinnedTabs.contains(moved) == false)
		#expect(store.state.windowTabOwners.isEmpty)
		#expect(store.state.main.sidebar.windowOpenTabs.contains(moved))
		#expect(store.state.main.sidebar.undo.isEmpty)
	}

	@Test
	internal func openInArxGoesToTheOrdinaryWindowUsedLast() async throws {
		var state = fixture()
		let windowID = UUID(50)
		let spaceID = state.workspace.spaces[0].id
		state.appendBrowserWindow(windowID, spaceID: spaceID)
		let (store, littleID, tab) = littleArxStore(state)

		// The window has the keyboard, then Little Arx does.
		await store.send(.ui(.focusWindow(windowID)))
		await store.send(.ui(.focusWindow(littleID)))
		await store.send(.event(.littlePromotionReady(littleID, tab, tab, spaceID)))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.littleWindows.isEmpty)
		expectNoDifference(store.state.windowTabOwners[tab.id], windowID)
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.selectedTab?.id, tab.id)
		expectNoDifference(store.state.focusedWindowID, windowID)
		#expect(!store.state.main.sidebar.windowOpenTabs.contains(tab.id))
	}

	@Test
	internal func openInArxGoesToTheMainWindowWhenItWasUsedLastOrNoOtherIsOpen() async throws {
		var state = fixture()
		let windowID = UUID(50)
		let spaceID = state.workspace.spaces[0].id
		state.appendBrowserWindow(windowID, spaceID: spaceID)
		let (store, littleID, tab) = littleArxStore(state)

		await store.send(.ui(.focusWindow(windowID)))
		await store.send(.ui(.focusWindow(state.main.id)))
		await store.send(.ui(.focusWindow(littleID)))
		await store.send(.event(.littlePromotionReady(littleID, tab, tab, spaceID)))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.windowTabOwners[tab.id] == nil)
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, tab.id)
		expectNoDifference(store.state.focusedWindowID, state.main.id)

		// The window used last closed before Open in Arx: the main window takes the tab.
		var closed = fixture()
		closed.appendBrowserWindow(windowID, spaceID: spaceID)
		let (other, otherLittleID, otherTab) = littleArxStore(closed)
		await other.send(.ui(.focusWindow(windowID)))
		await other.send(.ui(.focusWindow(otherLittleID)))
		await other.send(.ui(.closeAdditionalWindow(windowID)))
		await other.finish()
		await other.skipReceivedActions(strict: false)
		await other.send(.event(.littlePromotionReady(otherLittleID, otherTab, otherTab, spaceID)))
		await other.finish()
		await other.skipReceivedActions(strict: false)

		#expect(other.state.windowTabOwners[otherTab.id] == nil)
		expectNoDifference(other.state.main.sidebar.selectedTab?.id, otherTab.id)
	}

	@Test
	internal func openInNewWindowGivesTheNewWindowTheTab() async throws {
		let state = fixture()
		let store = makeStore(state, uuid: .constant(UUID(900)))
		let moved = state.workspace.spaces[0].unpinnedTabs[0]

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], nil))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.windowTabOwners, [moved: UUID(900)])
		expectNoDifference(store.state.windows[id: UUID(900)]?.sidebar.windowOpenTabs, [moved])
		expectNoDifference(store.state.windows[id: UUID(900)]?.sidebar.selectedTab?.id, moved)
	}

	@Test
	internal func choosingAnotherWindowsTabBringsThatWindowForward() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		state.focusedWindowID = windowID
		let store = makeStore(state)
		let mainTab = state.workspace.spaces[0].unpinnedTabs[1]

		await store.send(.windows(.element(id: windowID, action: .ui(.selectTab(mainTab)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.focusedWindowID, state.main.id)
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, mainTab)
		#expect(store.state.windows[id: windowID]?.sidebar.selectedTab == nil)
		#expect(store.state.windowTabOwners.isEmpty)
	}

	@Test
	internal func aTabOfTheClosedMainWindowComesToTheWindowThatChoseIt() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		state.focusedWindowID = windowID
		let mainTab = state.workspace.spaces[0].unpinnedTabs[1]
		state.main.sidebar.select(mainTab)
		state.windowIsOpen = false
		let store = makeStore(state)

		await store.send(.windows(.element(id: windowID, action: .ui(.selectTab(mainTab)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.windowTabOwners, [mainTab: windowID])
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.selectedTab?.id, mainTab)
		expectNoDifference(store.state.focusedWindowID, windowID)

		// The reopened main window doesn't show it again.
		await store.send(.main(.ui(.task)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.main.sidebar.selectedTab?.id != mainTab)
		#expect(!store.state.main.viewer.panes.contains { $0.item.tab?.id == mainTab })
	}

	@Test
	internal func closingAWindowGivesItsTabsToTheMainWindowAndReopeningTakesThemBack() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let store = makeStore(state)

		let opened = try await openTab(in: windowID, store)

		await store.send(.ui(.closeAdditionalWindow(windowID)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.windowTabOwners.isEmpty)
		// Nothing is archived: the tab is still open, now in the main window.
		#expect(store.state.workspace.spaces[0].unpinnedTabs.contains(opened))
		#expect(store.state.main.sidebar.windowOpenTabs.contains(opened))
		expectNoDifference(store.state.recentlyClosedWindows.last?.openTabs, [opened])

		await store.send(.ui(.reopenClosedWindow(nil)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		let reopened = try #require(store.state.windows.last)
		expectNoDifference(store.state.windowTabOwners, [opened: reopened.id])
		expectNoDifference(reopened.sidebar.windowOpenTabs, [opened])
		#expect(!store.state.main.sidebar.windowOpenTabs.contains(opened))
	}

	@Test
	internal func aWindowsRecordKeepsItsOpenTabsForTheNextLaunch() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let store = makeStore(state)

		let opened = try await openTab(in: windowID, store)

		let records = store.state.windowLayout.windowPresentations
		expectNoDifference(records.first { $0.id == windowID }?.openTabs, [opened])
		#expect(records.first { $0.id == state.main.id }?.openTabs == nil)

		// The next launch gives the restored window its tab back.
		var relaunched = AppFeature.State(main: .init(
			organization: store.state.workspace,
			spaceID: store.state.workspace.spaces[0].id,
			id: state.main.id
		))
		relaunched.$windowLayout.withLock { $0.windowPresentations = records }
		relaunched.restoreWindowPresentations()
		relaunched.setIndependentWindows(true)
		expectNoDifference(relaunched.windowTabOwners, [opened: windowID])
		expectNoDifference(relaunched.windows[id: windowID]?.sidebar.windowOpenTabs, [opened])
		#expect(!relaunched.main.sidebar.windowOpenTabs.contains(opened))

		// With the feature flag off, every window shares it again.
		relaunched.setIndependentWindows(false)
		#expect(relaunched.windowTabOwners.isEmpty)
		#expect(relaunched.main.sidebar.windowOpenTabs.contains(opened))
	}

	@Test
	internal func withTheFeatureFlagOffWindowsShareEveryOpenTab() async throws {
		var state = fixture()
		state.setIndependentWindows(false)
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let store = makeStore(state)

		let opened = try await openTab(in: windowID, store)
		#expect(store.state.windowTabOwners.isEmpty)
		#expect(store.state.main.sidebar.windowOpenTabs.contains(opened))
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.openTabFilter, .all)
	}

	@Test
	internal func aLinkOpenedBehindTheWindowsPageStaysInThatWindow() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let opener = state.workspace.spaces[0].unpinnedTabs[1]
		state.giveOpenTabs([opener], to: windowID)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(80))
			$0.browserEngine.open = { _ in }
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.openLinkInBackgroundTab(url, opener: opener, windowID: windowID))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		let id = BrowserCore.Tab.ID(rawValue: UUID(80))
		#expect(store.state.workspace.spaces[0].unpinnedTabs.contains(id))
		expectNoDifference(store.state.windowTabOwners[id], windowID)
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.windowOpenTabs, [opener, id])
		#expect(!store.state.main.sidebar.windowOpenTabs.contains(id))
	}

	@Test
	internal func aClosedMainWindowsTabInAnotherSpaceOpensThere() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		state.focusedWindowID = windowID
		state.windowIsOpen = false

		// A main-window tab in Personal, chosen from the window's command bar while it shows Work.
		let tab = state.workspace.spaces[0].unpinnedTabs[1]
		var organization = state.workspace
		organization.spaces[0].unpinnedTabs.removeAll { $0 == tab }
		organization.spaces[1].unpinnedTabs = [tab]
		organization.spaces[0].selectedTabID = organization.spaces[0].unpinnedTabs.first
		state.workspace = organization
		state.main.sidebar.organization = organization
		var windowOrganization = organization
		for index in windowOrganization.spaces.indices { windowOrganization.spaces[index].selectedTabID = nil }
		state.windows[id: windowID]?.sidebar.organization = windowOrganization
		let store = makeStore(state)

		await store.send(.windows(.element(id: windowID, action: .delegate(.selectTabInOtherWindow(tab)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.windowTabOwners, [tab: windowID])
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.spaceID, state.workspace.spaces[1].id)
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.selectedTab?.id, tab)
	}

	@Test
	internal func aRecordFromBeforeKeepsTheOpenTabsItsPanesShow() throws {
		let state = fixture()
		let windowID = UUID(50)
		let shown = state.workspace.spaces[0].unpinnedTabs[1]
		let record = BrowserWindowPresentation(
			id: windowID,
			activeSpaceID: state.workspace.spaces[0].id,
			spaces: [.init(
				id: state.workspace.spaces[0].id,
				panes: [.init(id: UUID(60), tabID: shown)],
				activePaneID: UUID(60)
			)]
		)
		#expect(record.openTabs == nil)

		var relaunched = AppFeature.State(main: .init(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id
		))
		relaunched.$windowLayout.withLock { $0.windowPresentations = [record] }
		relaunched.restoreWindowPresentations()
		relaunched.setIndependentWindows(true)

		expectNoDifference(relaunched.windowTabOwners, [shown: windowID])
		expectNoDifference(relaunched.windows[id: windowID]?.sidebar.windowOpenTabs, [shown])
		#expect(!relaunched.main.sidebar.windowOpenTabs.contains(shown))
	}

	@Test
	internal func olderRecordsGiveATabToTheWindowThatShowsItBeforeOneThatCachedIt() throws {
		let state = fixture()
		let first = state.workspace.spaces[0].id
		let second = state.workspace.spaces[1].id
		let tab = state.workspace.spaces[0].unpinnedTabs[1]

		// The earlier window shows the Favorite in another space and still holds the first space's
		// layout.
		let earlier = BrowserWindowPresentation(
			id: UUID(50),
			activeSpaceID: second,
			spaces: [
				.init(id: second, panes: [.init(id: UUID(62), tabID: .init(rawValue: UUID(5)))], activePaneID: UUID(62)),
				.init(id: first, panes: [.init(id: UUID(60), tabID: tab)], activePaneID: UUID(60)),
			]
		)

		// The later window shows that tab.
		let later = BrowserWindowPresentation(
			id: UUID(51),
			activeSpaceID: first,
			spaces: [.init(id: first, panes: [.init(id: UUID(61), tabID: tab)], activePaneID: UUID(61))]
		)

		var relaunched = AppFeature.State(main: .init(organization: state.workspace, spaceID: first))
		relaunched.$windowLayout.withLock { $0.windowPresentations = [earlier, later] }
		relaunched.restoreWindowPresentations()
		relaunched.setIndependentWindows(true)

		#expect(relaunched.windows[id: UUID(51)]?.viewer.panes.contains { $0.item.tab?.id == tab } == true)
		expectNoDifference(relaunched.windowTabOwners, [tab: UUID(51)])
		#expect(relaunched.windows[id: UUID(51)]?.sidebar.windowOpenTabs.contains(tab) == true)
		#expect(relaunched.windows[id: UUID(50)]?.sidebar.windowOpenTabs.contains(tab) == false)
	}

	@Test
	internal func aTabTheMainWindowLastShowedRestoresInTheWindowThatKeepsIt() throws {
		let state = fixture()
		let first = state.workspace.spaces[0].id
		let tab = state.workspace.spaces[0].unpinnedTabs[1]

		// Another window took the closed main window's active tab: both records still show it.
		let main = BrowserWindowPresentation(
			id: state.main.id,
			activeSpaceID: first,
			spaces: [.init(id: first, panes: [.init(id: UUID(60), tabID: tab)], activePaneID: UUID(60))]
		)
		let other = BrowserWindowPresentation(
			id: UUID(50),
			activeSpaceID: first,
			spaces: [.init(id: first, panes: [.init(id: UUID(61), tabID: tab)], activePaneID: UUID(61))],
			openTabs: [tab]
		)

		var relaunched = AppFeature.State(main: .init(organization: state.workspace, spaceID: first, id: state.main.id))
		relaunched.$windowLayout.withLock { $0.windowPresentations = [main, other] }
		relaunched.restoreWindowPresentations()
		relaunched.setIndependentWindows(true)

		expectNoDifference(relaunched.windowTabOwners, [tab: UUID(50)])
		#expect(relaunched.windows[id: UUID(50)]?.viewer.panes.contains { $0.item.tab?.id == tab } == true)
		#expect(!relaunched.main.viewer.panes.contains { $0.item.tab?.id == tab })
	}

	@Test
	internal func aReopenedMainWindowWithItsLayoutShowsTheNeighbourOfATabAnotherWindowTook() async throws {
		var state = fixture()
		let first = state.workspace.spaces[0].id
		let neighbour = state.workspace.spaces[0].unpinnedTabs[0]
		let taken = state.workspace.spaces[0].unpinnedTabs[1]
		state.$windowLayout.withLock {
			$0.windowPresentations = [BrowserWindowPresentation(
				id: state.main.id,
				activeSpaceID: first,
				spaces: [.init(id: first, panes: [.init(id: UUID(60), tabID: taken)], activePaneID: UUID(60))]
			)]
		}
		state.restoreWindowPresentations()
		#expect(state.main.viewer.preservesPresentation)
		#expect(state.main.sidebar.selectedTab?.id == taken)
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: first)
		state.focusedWindowID = windowID
		state.windowIsOpen = false
		let store = makeStore(state)

		await store.send(.windows(.element(id: windowID, action: .ui(.selectTab(taken)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.windowTabOwners, [taken: windowID])

		await store.send(.main(.ui(.task)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, neighbour)
		expectNoDifference(store.state.main.viewer.item.tab?.id, neighbour)
		#expect(!store.state.main.viewer.panes.contains { $0.item.tab?.id == taken })
	}

	@Test
	internal func aSplitRowListsOnlyTheWindowsOwnMembers() throws {
		var organization = fixture().workspace
		let open = organization.spaces[0].unpinnedTabs
		try organization.update {
			$0.splits.append(.init(
				id: .init(rawValue: UUID(70)),
				spaceID: $0.spaces[0].id,
				tabIDs: open
			))
		}
		var sidebar = SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		sidebar.openTabFilter = .only([open[0]])

		// With one member in this window, the row is that tab's own (DEV-1006); the other window's
		// member stays out of it.
		expectNoDifference(sidebar.openTabs.map(\.id), [.tab(open[0].rawValue)])
		let row = try #require(sidebar.openTabs.first)
		#expect(row.split == nil)
		expectNoDifference(row.splitPanes?.count, open.count)
	}

	@Test
	internal func aPinnedTabAnotherWindowShowsStaysThereWhenUnpinned() async throws {
		var state = fixture()
		let windowID = UUID(50)
		let spaceID = state.workspace.spaces[0].id
		let pinned = state.workspace.spaces[0].unpinnedTabs[1]
		var organization = state.workspace
		try organization.update {
			$0.spaces[0].unpinnedTabs.removeAll { $0 == pinned }
			$0.spaces[0].savedItems = [.tab(pinned)]
			$0.tabs[id: pinned]?.savedDestination = .init(title: "Pinned", url: URL(string: "https://pinned.example")!)
		}
		state.workspace = organization
		state.main.sidebar.organization = organization
		state.appendBrowserWindow(windowID, spaceID: spaceID)
		state.windows[id: windowID]?.viewer.item.tab = organization.tabs[id: pinned]
		let store = makeStore(state)

		await store.send(.main(.sidebar(.ui(.move(.tab(pinned.rawValue), .unpinnedRoot, spaceID)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.spaces[0].unpinnedTabs.contains(pinned))
		expectNoDifference(store.state.windowTabOwners, [pinned: windowID])
		#expect(!store.state.main.sidebar.windowOpenTabs.contains(pinned))
	}

	@Test
	internal func anotherWindowsSplitMemberStaysOutOfThisWindowsLayout() throws {
		var state = fixture()
		let windowID = UUID(50)
		let open = state.workspace.spaces[0].unpinnedTabs
		try state.workspace.update {
			$0.splits.append(.init(id: .init(rawValue: UUID(70)), spaceID: $0.spaces[0].id, tabIDs: open))
		}
		state.main.sidebar.organization = state.workspace
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		state.giveOpenTabs([open[1]], to: windowID)

		let layout = ViewerFeature.Layout(tabs: open.compactMap { state.workspace.tabs[id: $0] }, activeTabID: open[0])
		state.prepareGroupLayout(for: .main(.viewer(.layout(layout))))
		#expect(state.main.viewer.tabsShownElsewhere.contains(open[1]))
		#expect(!state.main.viewer.tabsShownElsewhere.contains(open[0]))
	}

	@Test
	internal func movingATabAwaySelectsTheOneAfterIt() async throws {
		var state = fixture()
		let windowID = UUID(50)
		let third = BrowserCore.Tab(
			id: .init(rawValue: UUID(6)),
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "Third", url: URL(string: "https://third.example")!)
		)
		try state.workspace.update {
			$0.tabs.append(third)
			$0.spaces[0].unpinnedTabs.append(third.id)
		}
		state.main.sidebar.organization = state.workspace
		let open = state.workspace.spaces[0].unpinnedTabs
		state.main.sidebar.select(open[1])
		state.main.viewer.item.tab = state.workspace.tabs[id: open[1]]
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		state.focusedWindowID = state.main.id
		let store = makeStore(state)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(open[1].rawValue)], windowID))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.main.sidebar.selectedTab?.id, third.id)
	}

	@Test
	internal func aSpaceMovedToAnotherProfileKeepsItsWindowsTabs() throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let open = state.workspace.spaces[0].unpinnedTabs
		state.giveOpenTabs([open[1]], to: windowID)

		var moved = state.workspace
		let profile = Profile.ID(rawValue: UUID(90))
		moved.profiles.append(.init(id: profile, name: "Other"))

		// The space's open tabs get new IDs in their places.
		moved.spaces[0] = .init(
			id: moved.spaces[0].id,
			profileID: profile,
			name: moved.spaces[0].name,
			unpinnedTabs: [.init(rawValue: UUID(201)), .init(rawValue: UUID(202))]
		)

		state.remapOpenTabOwners(from: state.workspace, to: moved)
		expectNoDifference(state.windowTabOwners, [.init(rawValue: UUID(202)): windowID])
	}

	@Test
	internal func aRestoredSpaceLeavesOtherWindowsTabsOut() {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let open = state.workspace.spaces[0].unpinnedTabs
		state.giveOpenTabs([open[1]], to: windowID)

		expectNoDifference(state.otherWindowsOpenTabs(for: state.main.id), [open[1]])
		expectNoDifference(state.otherWindowsOpenTabs(for: windowID), [open[0]])
		state.setIndependentWindows(false)
		#expect(state.otherWindowsOpenTabs(for: windowID).isEmpty)
	}

	@Test
	internal func reopeningAWindowLeavesATabTheMainWindowShows() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let store = makeStore(state)
		let opened = try await openTab(in: windowID, store)

		await store.send(.ui(.closeAdditionalWindow(windowID)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		await store.send(.main(.ui(.selectTab(opened))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, opened)

		await store.send(.ui(.reopenClosedWindow(nil)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.windowTabOwners.isEmpty)
		#expect(store.state.main.sidebar.windowOpenTabs.contains(opened))
	}

	@Test
	internal func openTabsWithNewIDsFromAnotherMacStayInTheirWindow() {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let open = state.workspace.spaces[0].unpinnedTabs
		state.giveOpenTabs([open[1]], to: windowID)

		let replacement = BrowserCore.Tab.ID(rawValue: UUID(300))
		state.replaceOwnedTabs([open[1]: replacement, open[0]: .init(rawValue: UUID(301))])
		expectNoDifference(state.windowTabOwners, [replacement: windowID])
	}

	@Test
	internal func movedTabsLeaveTheSourceWindowsSelection() async throws {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		state.focusedWindowID = state.main.id
		let moved = state.workspace.spaces[0].unpinnedTabs[1]
		state.main.sidebar.moveSelection = [.tab(moved.rawValue)]
		let store = makeStore(state)

		await store.send(.main(.sidebar(.ui(.sidebar(.moveToWindow([.tab(moved.rawValue)], windowID))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(store.state.windowTabOwners, [moved: windowID])
		#expect(!store.state.main.sidebar.moveSelection.contains(.tab(moved.rawValue)))
	}

	@Test
	internal func aSpaceMovedToAnotherProfileFromASidebarKeepsItsWindowsTabs() {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let open = state.workspace.spaces[0].unpinnedTabs
		state.giveOpenTabs([open[1]], to: windowID)

		var moved = state.workspace
		let profile = Profile.ID(rawValue: UUID(90))
		moved.profiles.append(.init(id: profile, name: "Other"))
		moved.spaces[0] = .init(
			id: moved.spaces[0].id,
			profileID: profile,
			name: moved.spaces[0].name,
			unpinnedTabs: [.init(rawValue: UUID(201)), .init(rawValue: UUID(202))]
		)
		state.main.sidebar.organization = moved

		_ = state.publishOrganization(from: state.main.id)

		// The main window moved the space; the tab the other window kept is still that window's.
		expectNoDifference(state.windowTabOwners, [.init(rawValue: UUID(202)): windowID])
	}

	@Test
	internal func theFilterShowsRowsOrderAndNeighboursOfTheWindowsOwnTabs() {
		let organization = fixture().workspace
		let open = organization.spaces[0].unpinnedTabs
		var sidebar = SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		sidebar.openTabFilter = .only([open[1]])

		expectNoDifference(sidebar.openTabs.map(\.id), [.tab(open[1].rawValue)])
		#expect(sidebar.windowShows(open[1]))
		#expect(!sidebar.windowShows(open[0]))
		// Favorites show in every window.
		#expect(sidebar.windowShows(organization.profiles[0].favorites[0]))

		sidebar.openTabFilter = .excluding([open[1]])
		expectNoDifference(sidebar.openTabs.map(\.id), [.tab(open[0].rawValue)])
	}

	/// The main window groups its two open tabs, then another window on the space takes the second
	/// by dropping it into the group, so the group is split across the windows.
	private func groupSplitAcrossWindows() async throws -> (
		store: TestStoreOf<AppFeature>,
		windowID: UUID,
		group: TabGroup.ID,
		mainTab: BrowserCore.Tab.ID,
		windowTab: BrowserCore.Tab.ID
	) {
		var state = fixture()
		let windowID = UUID(50)
		state.appendBrowserWindow(windowID, spaceID: state.workspace.spaces[0].id)
		let open = state.workspace.spaces[0].unpinnedTabs
		let store = makeStore(state)
		await store.send(.main(.sidebar(.ui(.sidebar(.groupTabs(open.map { .tab($0.rawValue) }))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		let group = try #require(store.state.workspace.tabGroups.first).id

		await store.send(.windows(.element(
			id: windowID,
			action: .sidebar(.ui(.sidebar(.moveItems([.tab(open[1].rawValue)], .inside(.folder(group.rawValue))))))
		)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(Set(store.state.workspace.tabGroups[id: group]?.tabIDs ?? []), Set(open))
		expectNoDifference(store.state.windowTabOwners[open[1]], windowID)
		return (store, windowID, group, open[0], open[1])
	}

	/// A store with a Little Arx showing a page of the fixture's profile, ready for Open in Arx.
	private func littleArxStore(
		_ state: AppFeature.State
	) -> (store: TestStoreOf<AppFeature>, littleID: UUID, tab: BrowserCore.Tab) {
		var state = state
		let littleID = UUID(20)
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(21)),
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "Little", url: URL(string: "https://little.example")!)
		)
		state.littleWindows.append(.init(id: littleID, spaceID: state.workspace.spaces[0].id, tab: tab))
		let store = makeStore(state)
		store.dependencies.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
		store.dependencies.browserEngine.open = { _ in }
		store.dependencies.browserEngine.close = { _ in }
		return (store, littleID, tab)
	}

	/// Opens a page in a new tab of the window, as ⌘T does, and returns the tab.
	private func openTab(
		in windowID: UUID,
		_ store: TestStoreOf<AppFeature>
	) async throws -> BrowserCore.Tab.ID {
		let before = Set(store.state.workspace.tabs.ids)
		let action = MainFeature.Action.ui(.openInNewTab(url))
		await store.send(windowID == store.state.main.id ? .main(action) : .windows(.element(id: windowID, action: action)))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		return try #require(store.state.workspace.tabs.ids.first { !before.contains($0) })
	}

	private func makeStore(
		_ state: AppFeature.State,
		uuid: UUIDGenerator? = nil
	) -> TestStoreOf<AppFeature> {
		// New tabs need IDs no profile, space or tab of the fixture has.
		let next = LockIsolated(1_000)
		let uuid = uuid ?? UUIDGenerator { next.withValue { value in
			value += 1
			return UUID(value)
		} }
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = uuid
			$0.browserEngine.snapshot = { _ in nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	/// Two spaces of one profile: Work has a Favorite and two open tabs; Personal has none.
	private func fixture(windowUndo: Bool = true) -> AppFeature.State {
		var organization = IntegrationFeatureTests().fixture()
		let favorite = BrowserCore.Tab(
			id: .init(rawValue: UUID(5)),
			profileID: organization.profiles[0].id,
			savedDestination: .init(title: "Mail", url: URL(string: "https://mail.example")!),
			restoration: .init(title: "Mail", url: URL(string: "https://mail.example")!)
		)
		organization.tabs.append(favorite)
		organization.profiles[0].favorites = [favorite.id]
		var state = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.sidebar.windowUndo = windowUndo
		state.focusedWindowID = state.main.id
		state.setIndependentWindows(true)
		return state
	}
}
