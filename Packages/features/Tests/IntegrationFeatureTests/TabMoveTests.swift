import AppUI
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import Testing
import ViewerFeature
import _ComposableArchitecture
import _TestSupport

/// DEV-992: tabs move anywhere. Each test is a move that was refused before: a pinned tab, at the
/// top of Pinned or in a folder, joins an open split by drag or by menu and becomes an open tab,
/// and an open tab of another space joins too. Since DEV-1006 Favorites join from the grid, and
/// a split takes the list of the tab it forms on (`PinnedSplitTests`).
@Suite(.dependencies)
@MainActor
internal struct TabMoveTests {
	// MARK: - Sidebar drops

	/// A pinned tab dropped on an open tab's row makes a split of the two and is unpinned.
	@Test
	internal func aPinnedTabDroppedOnAnOpenTabSplitsWithIt() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(6)], .split(item(1)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(6)]])
		try expectOpen(tab(6), in: store)
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(6)])
		await store.finish()
	}

	/// A pinned tab in a folder dropped on a group's row joins the group and leaves the folder.
	@Test
	internal func aPinnedTabInAFolderJoinsAGroup() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.move(item(7), .split(item(1)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(2), tab(7)]])
		try expectOpen(tab(7), in: store)
		#expect(store.state.sidebar.organization.folders[id: folder]?.children.isEmpty == true)
		await store.finish()
	}

	/// A selection of pinned and open tabs dropped together joins as one move.
	@Test
	internal func pinnedAndOpenTabsJoinTogether() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(6), item(3)], .split(item(1)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(6), tab(3)]])
		try expectOpen(tab(6), in: store)
		await store.finish()
	}

	/// In the Spaces overview, an open tab of another space joins a split in this one and moves
	/// to this space with it.
	@Test
	internal func anOpenTabOfAnotherSpaceJoinsASplit() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(9)], .split(item(1)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(9)]])
		try expectOpen(tab(9), in: store)
		#expect(store.state.sidebar.organization.spaces[id: otherSpace]?.unpinnedTabs.isEmpty == true)
		await store.finish()
	}

	/// Undo puts the pinned tab back where it was, out of the split.
	@Test
	internal func undoingAPinnedJoinPinsTheTabAgain() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.move(item(7), .split(item(1)), space))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.undo)))
		await store.skipReceivedActions()
		#expect(store.state.sidebar.organization.splits.isEmpty)
		expectNoDifference(store.state.sidebar.organization.folders[id: folder]?.children, [.tab(tab(7))])
		#expect(store.state.sidebar.organization.tabs[id: tab(7)]?.savedDestination != nil)
		await store.finish()
	}

	/// A Favorite joins a split too now, and stays in the grid (DEV-1006).
	@Test
	internal func aFavoriteJoinsASplitFromTheGrid() async throws {
		let store = makeStore()
		expectNoDifference(store.state.viewerDropRefusal(tab(8), edge: .trailing), nil)
		await store.send(.sidebar(.ui(.moveItems([item(8)], .split(item(1)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(8)]])
		expectNoDifference(store.state.sidebar.organization.location(of: tab(8)), .favorite(.init(rawValue: UUID(0))))
		await store.finish()
	}

	// MARK: - The page

	/// A pinned tab dragged onto the page's edge adds a pane there and joins as an open tab.
	@Test
	internal func aPinnedTabDroppedOnThePageJoinsAsAnOpenTab() async throws {
		let store = makeStore()
		expectNoDifference(store.state.viewerDropRefusal(tab(7), edge: .leading), nil)
		await store.send(.ui(.dropTabInViewer(tab(7), .leading)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(7), tab(1)])
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(7), tab(1)]])
		try expectOpen(tab(7), in: store)
		await store.finish()
	}

	/// A pinned tab a press selected and then dragged onto the page splits with the tab shown
	/// before the press (DEV-994) and is unpinned.
	@Test
	internal func aPressedPinnedTabSplitsWithTheTabBefore() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.sidebar(.selectOnPress(item(6))))))
		await store.skipReceivedActions()
		await store.send(.ui(.dropTabInViewer(tab(6), .trailing)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(6)])
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(6)]])
		try expectOpen(tab(6), in: store)
		await store.finish()
	}

	// MARK: - Menus

	/// Add to Split View on a pinned tab puts it in a pane beside the page, as a member.
	@Test
	internal func addingAPinnedTabToASplitFromTheMenuJoinsIt() async throws {
		let store = makeStore()
		try await addToSplit(tab(6), in: store)
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(6)])
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(6)]])
		try expectOpen(tab(6), in: store)
		await store.finish()
	}

	/// Beside a pinned tab, a tab from a folder moves into Pinned beside it, and the window
	/// publishes that at once so the app and other windows keep it; the two make a pinned split
	/// (DEV-1006).
	@Test
	internal func aFolderTabAddedBesideAPinnedOneJoinsItInPinned() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.sidebar(.select(item(6))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(6)])
		await store.send(.ui(.splitTab(tab(7))))
		await store.receive(\.delegate.requestSplit)
		await store.send(.addPane(tab(7)))
		await store.receive(\.delegate.organizationChanged)
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(6), tab(7)])
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(6), tab(7)]])
		expectNoDifference(store.state.sidebar.organization.location(of: tab(7)), .pinned(space, folder: nil))
		await store.finish()
	}

	/// Undo after Add to Split View pins the tab again and brings back the group's own pane
	/// shares, not the equal ones the new pane made.
	@Test
	internal func undoingAMenuJoinRestoresTheGroupAsItWas() async throws {
		let group = SplitGroup(
			id: .init(rawValue: UUID(50)),
			spaceID: space,
			tabIDs: [tab(1), tab(2)],
			orientation: .horizontal,
			fractions: [0.7, 0.3]
		)
		let store = makeStore { state in
			state.sidebar.organization.splits = [group]
			let tabs = [tab(1), tab(2)].compactMap { state.sidebar.organization.tabs[id: $0] }
			state.viewer.panes = [
				.init(id: UUID(999), item: .init(tab: tabs[0])),
				.init(id: UUID(998), item: .init(tab: tabs[1])),
			]
			state.viewer.fractions = [0.7, 0.3]
		}
		try await addToSplit(tab(6), in: store)
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(2), tab(6)]])

		await store.send(.sidebar(.ui(.undo)))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.organization.splits.elements, [group])
		expectNoDifference(store.state.sidebar.organization.location(of: tab(6)), .pinned(space, folder: nil))
		await store.finish()
	}

	/// A pinned tab chosen for a split's empty pane fills it as a member.
	@Test
	internal func aPinnedTabFillsAnEmptyPane() async throws {
		let store = makeStore()
		await store.send(.viewer(.split(nil)))
		await store.skipReceivedActions()
		let empty = try #require(store.state.viewer.panes.first { $0.item.tab == nil })
		await store.send(.present(tab(7), in: empty.id))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(7)])
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(7)]])
		try expectOpen(tab(7), in: store)
		await store.finish()
	}

	/// A split opened with an open tab first, as automation's open_split asks, takes a pinned tab
	/// as an open one; opened with a pinned tab first, it pins the others beside it (DEV-1006).
	@Test
	internal func openingASplitTakesTheFirstTabsList() async throws {
		let store = makeStore()
		await store.send(.ui(.openSplit([tab(2), tab(6)], .horizontal)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(2), tab(6)]])
		try expectOpen(tab(6), in: store)

		await store.send(.ui(.openSplit([tab(7), tab(3)], .horizontal)))
		await store.skipReceivedActions()
		let group = try #require(store.state.sidebar.organization.split(containing: tab(7)))
		expectNoDifference(group.tabIDs, [tab(7), tab(3)])
		expectNoDifference(store.state.sidebar.organization.location(of: tab(3)), .pinned(space, folder: folder))
		await store.finish()
	}

	// MARK: - Fixture

	private var space: Space.ID { .init(rawValue: UUID(1)) }

	private var otherSpace: Space.ID { .init(rawValue: UUID(2)) }

	private var folder: Folder.ID { .init(rawValue: UUID(3)) }

	private func tab(_ index: Int) -> BrowserCore.Tab.ID { .init(rawValue: UUID(100 + index)) }

	private func item(_ index: Int) -> SidebarItem.ID { .tab(tab(index).rawValue) }

	/// Add to Split View: the window asks the app, which answers `addPane` when the tab enters a
	/// new pane here; the pane then loads the tab as an open one.
	private func addToSplit(
		_ id: BrowserCore.Tab.ID,
		in store: TestStoreOf<MainFeature>
	) async throws {
		await store.send(.ui(.splitTab(id)))
		await store.receive(\.delegate.requestSplit)

		// Asking changes nothing: another window may show the tab, and the app only focuses it.
		#expect(store.state.sidebar.organization.tabs[id: id]?.savedDestination != nil)
		await store.send(.addPane(id))
		await store.skipReceivedActions(strict: false)
		let shown = try #require(store.state.viewer.panes.first { $0.item.tab?.id == id }?.item.tab)
		#expect(shown.savedDestination == nil)
	}

	/// An open tab of the space, no longer pinned anywhere.
	private func expectOpen(
		_ id: BrowserCore.Tab.ID,
		in store: TestStoreOf<MainFeature>,
		sourceLocation: SourceLocation = #_sourceLocation
	) throws {
		let organization = store.state.sidebar.organization
		#expect(organization.location(of: id) == .unpinned(space), sourceLocation: sourceLocation)
		#expect(organization.tabs[id: id]?.savedDestination == nil, sourceLocation: sourceLocation)
	}

	/// Open tabs 1 to 5 in Work, tab 1 shown; tab 6 pinned at the top of Pinned, tab 7 pinned in a
	/// folder, tab 8 a Favorite, and tab 9 open in another space of the profile.
	private func makeStore(_ configure: (inout MainFeature.State) -> Void = { _ in }) -> TestStoreOf<MainFeature> {
		let profile = Profile.ID(rawValue: UUID(0))
		let tabs: [BrowserCore.Tab] = (1 ... 9).map { index in
			let url = URL(string: "https://capturecontext.dev/\(index)")!
			return .init(
				id: tab(index),
				profileID: profile,
				savedDestination: (6 ... 8).contains(index) ? .init(title: "Tab \(index)", url: url) : nil,
				restoration: .init(title: "Tab \(index)", url: url)
			)
		}
		let organization = BrowserOrganization(
			profiles: [.init(id: profile, name: "Default", favorites: [tab(8)])],
			spaces: [
				.init(
					id: space,
					profileID: profile,
					name: "Work",
					savedItems: [.tab(tab(6)), .folder(folder)],
					unpinnedTabs: (1 ... 5).map(tab),
					selectedTabID: tab(1)
				),
				.init(
					id: otherSpace,
					profileID: profile,
					name: "Home",
					unpinnedTabs: [tab(9)],
					selectedTabID: tab(9)
				),
			],
			folders: [.init(id: folder, spaceID: space, name: "Reading", children: [.tab(tab(7))])],
			tabs: tabs
		)
		var state = MainFeature.State(organization: organization, spaceID: space)
		state.viewer.panes = [.init(id: UUID(999), item: .init(tab: tabs[0]))]
		state.viewer.activePaneID = UUID(999)
		configure(&state)
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			let next = LockIsolated(0)
			$0.uuid = .init {
				next.withValue { value in
					defer { value += 1 }
					return UUID(value)
				}
			}
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.close = { _ in }
			$0.date = .constant(Date(timeIntervalSince1970: 0))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
