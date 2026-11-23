import AppUI
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import ViewerFeature
import _ComposableArchitecture
import _TestSupport

/// DEV-1006: Split View for every kind of tab. A split's tabs share one list of the sidebar (the
/// open tabs, Pinned or a folder), and a tab joins by moving into that list beside them; Favorites
/// join from the grid and stay there.
@Suite(.dependencies)
@MainActor
internal struct PinnedSplitTests {
	// MARK: - Moving into and out of splits

	/// An open tab dropped on a pinned tab is pinned beside it, and the two make a pinned split.
	@Test
	internal func anOpenTabDroppedOnAPinnedTabMakesAPinnedSplit() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(6)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(6), tab(2)]])
		expectNoDifference(store.state.sidebar.space.savedItems, [.tab(tab(6)), .tab(tab(2)), .tab(tab(10)), .folder(folder)])
		#expect(store.state.sidebar.organization.tabs[id: tab(2)]?.savedDestination != nil)
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(6), tab(2)])
		await store.finish()
	}

	/// A pinned tab dropped on another pinned tab, here from a folder, makes a split in Pinned.
	@Test
	internal func aPinnedTabDroppedOnAnotherMakesASplitInPinned() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.move(item(7), .split(item(6)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(6), tab(7)]])
		expectNoDifference(store.state.sidebar.organization.location(of: tab(7)), .pinned(space, folder: nil))
		expectNoDifference(store.state.sidebar.organization.folders[id: folder]?.children, [.tab(tab(11))])
		await store.finish()
	}

	/// An open tab dropped on a tab in a folder joins it in the folder.
	@Test
	internal func aTabDroppedOnATabInAFolderMakesASplitThere() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(3)], .split(item(7)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(7), tab(3)]])
		expectNoDifference(store.state.sidebar.organization.folders[id: folder]?.children, [.tab(tab(7)), .tab(tab(3)), .tab(tab(11))])
		await store.finish()
	}

	/// A pinned tab dropped on an open tab is unpinned, as before (DEV-992).
	@Test
	internal func aPinnedTabDroppedOnAnOpenTabIsUnpinned() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(6)], .split(item(1)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(6)]])
		expectNoDifference(store.state.sidebar.organization.location(of: tab(6)), .unpinned(space))
		#expect(store.state.sidebar.organization.tabs[id: tab(6)]?.savedDestination == nil)
		await store.finish()
	}

	/// A pinned split unpinned from its row's menu unpins every tab and stays a split, and a split
	/// pinned again does the same the other way, each one undo.
	@Test
	internal func aPinnedSplitUnpinnedWholeStaysASplit() async throws {
		let store = makeStore { $0.sidebar.organization.splits = [self.pinnedSplit] }
		await store.send(.sidebar(.ui(.sidebar(.setPinned([item(6), item(10)], false)))))
		await store.skipReceivedActions()
		let group = try #require(store.state.sidebar.organization.splits.first)
		expectNoDifference(group.tabIDs, [tab(6), tab(10)])
		expectNoDifference(store.state.sidebar.organization.splitList(of: group), .open(space))
		#expect(store.state.sidebar.organization.tabs[id: tab(10)]?.savedDestination == nil)

		await store.send(.sidebar(.ui(.sidebar(.setPinned([item(6), item(10)], true)))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(6), tab(10)]])
		expectNoDifference(store.state.sidebar.organization.splitList(of: store.state.sidebar.organization.splits[0]), .pinned(space))

		await store.send(.sidebar(.ui(.undo)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splitList(of: store.state.sidebar.organization.splits[0]), .open(space))
		await store.finish()
	}

	/// A pinned split dragged into the open tabs unpins its tabs and stays a split; dragged into a
	/// folder it stays a split there.
	@Test
	internal func aPinnedSplitDraggedWholeStaysASplit() async throws {
		let store = makeStore { $0.sidebar.organization.splits = [self.pinnedSplit] }
		await store.send(.sidebar(.ui(.sidebar(.moveItems([item(6), item(10)], .inside(.folder(folder.rawValue)))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(6), tab(10)]])
		expectNoDifference(store.state.sidebar.organization.splitList(of: store.state.sidebar.organization.splits[0]), .folder(folder))

		await store.send(.sidebar(.ui(.sidebar(.moveItems([item(6), item(10)], .unpinnedRoot)))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(6), tab(10)]])
		expectNoDifference(store.state.sidebar.organization.splitList(of: store.state.sidebar.organization.splits[0]), .open(space))
		#expect(store.state.sidebar.organization.tabs[id: tab(6)]?.savedDestination == nil)
		await store.finish()
	}

	/// A tab dropped just below a pinned split's row lands after the whole split, which stays one.
	@Test
	internal func aDropBelowAPinnedSplitLandsAfterIt() async throws {
		let store = makeStore { $0.sidebar.organization.splits = [self.pinnedSplit] }
		await store.send(.sidebar(.ui(.move(item(2), .after(item(6)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(6), tab(10)]])
		expectNoDifference(store.state.sidebar.space.savedItems, [.tab(tab(6)), .tab(tab(10)), .tab(tab(2)), .folder(folder)])

		await store.send(.sidebar(.ui(.moveItems([item(3)], .after(item(6)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(6), tab(10)]])
		expectNoDifference(
			store.state.sidebar.space.savedItems,
			[.tab(tab(6)), .tab(tab(10)), .tab(tab(3)), .tab(tab(2)), .folder(folder)]
		)
		await store.finish()
	}

	/// The sidebar shows a pinned split as one row in Pinned, and one in a folder in the folder.
	@Test
	internal func pinnedSplitsShowAsOneRowInTheirList() {
		var organization = makeStore().state.sidebar.organization
		organization.splits = [pinnedSplit]
		var sidebar = SidebarFeature.State(organization: organization, spaceID: space)
		expectNoDifference(sidebar.savedItems.map(\.id), [item(6), .folder(folder.rawValue)])
		expectNoDifference(sidebar.savedItems[0].split?.memberIDs, [item(6), item(10)])

		sidebar.organization.splits = [.init(id: .init(rawValue: UUID(51)), spaceID: space, tabIDs: [tab(7), tab(11)])]
		let children = sidebar.savedItems[2].children
		expectNoDifference(children.map(\.id), [item(7)])
		expectNoDifference(children[0].split?.memberIDs, [item(7), item(11)])
	}

	/// An address typed into the empty pane beside a pinned tab opens a new tab pinned beside it,
	/// and the two make a pinned split.
	@Test
	internal func aNewTabInAPinnedSplitsEmptyPaneIsPinned() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.sidebar(.select(item(6))))))
		await store.skipReceivedActions()
		await store.send(.ui(.splitTab(nil))).finish()
		await store.skipReceivedActions()
		#expect(store.state.commandBarEmptyPaneID != nil)
		await store.send(.commandBar(.ui(.queryChanged("https://new.example")))).finish()
		await store.send(.commandBar(.ui(.selected("destination")))).finish()
		await store.skipReceivedActions(strict: false)

		let group = try #require(store.state.sidebar.organization.split(containing: tab(6)))
		expectNoDifference(group.tabIDs.count, 2)
		let added = try #require(group.tabIDs.last)
		expectNoDifference(store.state.sidebar.organization.location(of: added), .pinned(space, folder: nil))
		expectNoDifference(store.state.sidebar.organization.tabs[id: added]?.restoration.url.host(), "new.example")
		await store.finish()
	}

	/// Duplicate puts a pinned split's copies after it in Pinned, pinned at the page each tab
	/// shows rather than the one it was pinned at.
	@Test
	internal func duplicatingAPinnedSplitPinsCopiesAtTheirPages() async throws {
		let elsewhere = URL(string: "https://capturecontext.dev/elsewhere")!
		let store = makeStore { state in
			state.sidebar.organization.splits = [self.pinnedSplit]
			state.sidebar.organization.tabs[id: self.tab(10)]?.restoration.url = elsewhere
		}
		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.duplicate(pinnedSplit.id.rawValue))))))
		await store.skipReceivedActions()
		let organization = store.state.sidebar.organization
		let copy = try #require(organization.splits.first { $0.id != pinnedSplit.id })
		expectNoDifference(organization.splitList(of: copy), .pinned(space))
		expectNoDifference(
			Array(store.state.sidebar.space.savedItems.prefix(4)),
			[.tab(tab(6)), .tab(tab(10))] + copy.tabIDs.map(SavedItem.tab)
		)
		expectNoDifference(organization.tabs[id: copy.tabIDs[1]]?.savedDestination?.url, elsewhere)
		await store.finish()
	}

	// MARK: - Favorites

	/// A Favorite dropped on an open tab joins it and stays in the grid; the window shows the
	/// split and highlights both, and the list shows the tab's own row.
	@Test
	internal func aFavoriteAndAnOpenTabShareASplit() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(8)], .split(item(1)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(8)]])
		expectNoDifference(store.state.sidebar.organization.profiles[0].favorites, [tab(8)])
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(8)])
		expectNoDifference(store.state.splitTabIDs, [item(1), item(8)])
		let row = try #require(store.state.sidebar.openTabs.first)
		expectNoDifference(row.id, item(1))
		#expect(row.split == nil)
		// The row still knows its split's panes, to judge a drop on it.
		expectNoDifference(row.splitPanes, .init(count: 2, isVertical: false))

		// Selecting the Favorite shows the split again.
		await store.send(.sidebar(.ui(.sidebar(.select(item(2))))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.sidebar(.select(item(8))))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(8)])
		await store.finish()
	}

	/// A Favorite and two open tabs: the list shows one split row with the two open tabs.
	@Test
	internal func aFavoriteAndTwoOpenTabsShowAsOneRowOfTwo() async throws {
		let store = makeStore()
		await store.send(.sidebar(.ui(.moveItems([item(2)], .split(item(1)), space))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.moveItems([item(8)], .split(item(1)), space))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(2), tab(8)]])
		expectNoDifference(store.state.splitTabIDs, [item(1), item(2), item(8)])
		let row = try #require(store.state.sidebar.openTabs.first)
		expectNoDifference(row.split?.memberIDs, [item(1), item(2)])
		await store.finish()
	}

	/// In the Spaces overview, a Favorite dropped on a tab of another space joins it there, and the
	/// window goes to that space to show the split.
	@Test
	internal func aFavoriteDroppedOnAnotherSpacesTabShowsThatSpace() async throws {
		let other = Space.ID(rawValue: UUID(2))
		let store = makeStore { state in
			let url = URL(string: "https://capturecontext.dev/12")!
			state.sidebar.organization.tabs.append(.init(
				id: self.tab(12),
				profileID: .init(rawValue: UUID(0)),
				restoration: .init(title: "Tab 12", url: url)
			))
			state.sidebar.organization.spaces.append(.init(
				id: other,
				profileID: .init(rawValue: UUID(0)),
				name: "Home",
				unpinnedTabs: [self.tab(12)]
			))
		}
		await store.send(.sidebar(.ui(.moveItems([item(8)], .split(item(12)), other))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(12), tab(8)]])
		expectNoDifference(store.state.sidebar.spaceID, other)
		await store.finish()
	}

	/// A Favorite grouped in another space doesn't carry a tab of this space there: dropped beside
	/// the Favorite on this space's page, the tab stays in this space.
	@Test
	internal func aFavoriteGroupedElsewhereKeepsTheTabHere() async throws {
		let other = Space.ID(rawValue: UUID(2))
		let store = makeStore { state in
			let url = URL(string: "https://capturecontext.dev/12")!
			state.sidebar.organization.tabs.append(.init(
				id: self.tab(12),
				profileID: .init(rawValue: UUID(0)),
				restoration: .init(title: "Tab 12", url: url)
			))
			state.sidebar.organization.spaces.append(.init(
				id: other,
				profileID: .init(rawValue: UUID(0)),
				name: "Home",
				unpinnedTabs: [self.tab(12)]
			))
			state.sidebar.organization.splits = [.init(id: .init(rawValue: UUID(52)), spaceID: other, tabIDs: [self.tab(12), self.tab(8)])]
			state.sidebar.organization.spaces[id: self.space]?.selectedTabID = self.tab(8)
			let favorite = state.sidebar.organization.tabs[id: self.tab(8)]
			state.viewer.panes = [.init(id: UUID(999), item: .init(tab: favorite))]
		}
		await store.send(.ui(.dropTabInViewer(tab(2), .trailing)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.sidebar.organization.location(of: tab(2)), .unpinned(space))
		await store.finish()
	}

	/// A Favorite dragged onto the page's edge joins what it shows.
	@Test
	internal func aFavoriteDroppedOnThePageJoins() async throws {
		let store = makeStore()
		expectNoDifference(store.state.viewerDropRefusal(tab(8), edge: .trailing), nil)
		await store.send(.ui(.dropTabInViewer(tab(8), .trailing)))
		await store.skipReceivedActions()
		expectNoDifference(store.state.viewer.panes.map { $0.item.tab?.id }, [tab(1), tab(8)])
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(1), tab(8)]])
		expectNoDifference(store.state.sidebar.organization.profiles[0].favorites, [tab(8)])
		await store.finish()
	}

	// MARK: - Closing

	/// Closing a pane from its header only takes its tab out of the split: a pinned tab keeps its
	/// page and stays pinned.
	@Test
	internal func closingAPinnedTabsPaneOnlySeparatesIt() async throws {
		let navigated = URL(string: "https://capturecontext.dev/elsewhere")!
		let store = makeStore { $0.sidebar.organization.tabs[id: self.tab(10)]?.restoration.url = navigated }
		await store.send(.sidebar(.ui(.move(item(10), .split(item(6)), space))))
		await store.skipReceivedActions()
		await store.send(.sidebar(.ui(.sidebar(.select(item(6))))))
		await store.skipReceivedActions()
		let pane = try #require(store.state.viewer.panes.first { $0.item.tab?.id == tab(10) })

		await store.send(.viewer(.ui(.closePane(pane.id))))
		await store.skipReceivedActions()
		#expect(store.state.sidebar.organization.splits.isEmpty)
		expectNoDifference(store.state.sidebar.organization.location(of: tab(10)), .pinned(space, folder: nil))
		expectNoDifference(store.state.sidebar.organization.tabs[id: tab(10)]?.restoration.url, navigated)
		await store.finish()
	}

	/// The split row's − on a pinned tab at its saved page separates it, leaving it pinned.
	@Test
	internal func separatingAPinnedMemberKeepsItPinned() async throws {
		let store = makeStore { $0.sidebar.organization.splits = [self.pinnedSplit] }
		let group = pinnedSplit.id.rawValue
		await store.send(.sidebar(.ui(.sidebar(.splitGroup(.separate(group: group, tab: tab(10).rawValue))))))
		await store.skipReceivedActions()
		#expect(store.state.sidebar.organization.splits.isEmpty)
		expectNoDifference(store.state.sidebar.organization.location(of: tab(10)), .pinned(space, folder: nil))
		#expect(store.state.sidebar.organization.tabs[id: tab(10)] != nil)
		await store.finish()
	}

	/// The split row's × on a pinned tab away from its saved page resets it and keeps it in the split.
	@Test
	internal func resettingAPinnedMemberKeepsItInTheSplit() async throws {
		let store = makeStore { state in
			state.sidebar.organization.splits = [self.pinnedSplit]
			state.sidebar.organization.tabs[id: self.tab(10)]?.restoration.url = URL(string: "https://capturecontext.dev/elsewhere")!
		}
		await store.send(.sidebar(.ui(.sidebar(.reset(item(10))))))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.organization.splits.map(\.tabIDs), [[tab(6), tab(10)]])
		expectNoDifference(
			store.state.sidebar.organization.tabs[id: tab(10)]?.restoration.url,
			store.state.sidebar.organization.tabs[id: tab(10)]?.savedDestination?.url
		)
		await store.finish()
	}

	// MARK: - Fixture

	private var space: Space.ID { .init(rawValue: UUID(1)) }

	private var folder: Folder.ID { .init(rawValue: UUID(3)) }

	/// Tabs 6 and 10, pinned at the top of Pinned.
	private var pinnedSplit: SplitGroup {
		.init(id: .init(rawValue: UUID(50)), spaceID: space, tabIDs: [tab(6), tab(10)])
	}

	private func tab(_ index: Int) -> BrowserCore.Tab.ID { .init(rawValue: UUID(100 + index)) }

	private func item(_ index: Int) -> SidebarItem.ID { .tab(tab(index).rawValue) }

	/// Open tabs 1 to 5 in Work, tab 1 shown; tabs 6 and 10 pinned at the top of Pinned, tabs 7
	/// and 11 pinned in a folder, and tab 8 a Favorite.
	private func makeStore(_ configure: (inout MainFeature.State) -> Void = { _ in }) -> TestStoreOf<MainFeature> {
		let profile = Profile.ID(rawValue: UUID(0))
		let pinned: Set<Int> = [6, 7, 8, 10, 11]
		let tabs: [BrowserCore.Tab] = [1, 2, 3, 4, 5, 6, 7, 8, 10, 11].map { index in
			let url = URL(string: "https://capturecontext.dev/\(index)")!
			return .init(
				id: tab(index),
				profileID: profile,
				savedDestination: pinned.contains(index) ? .init(title: "Tab \(index)", url: url) : nil,
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
					savedItems: [.tab(tab(6)), .tab(tab(10)), .folder(folder)],
					unpinnedTabs: (1 ... 5).map(tab),
					selectedTabID: tab(1)
				),
			],
			folders: [.init(id: folder, spaceID: space, name: "Reading", children: [.tab(tab(7)), .tab(tab(11))])],
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
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.discardNavigation = { _, _ in }
			$0.date = .constant(Date(timeIntervalSince1970: 0))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
