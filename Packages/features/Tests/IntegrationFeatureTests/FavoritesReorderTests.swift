@testable import AppUI
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-736: dropping a favorite elsewhere in the grid moves it there.
@Suite(.dependencies)
@MainActor
internal struct FavoritesReorderTests {
	private static let ids = (10..<14).map { BrowserCore.Tab.ID(rawValue: UUID($0)) }

	@Test(arguments: [
		// Third to the end, as in Maxim's recording.
		(2, 3, [0, 1, 3, 2]),
		// Last to the start.
		(3, 0, [3, 0, 1, 2]),
		// One to the right and one to the left.
		(1, 2, [0, 2, 1, 3]),
		(2, 1, [0, 2, 1, 3]),
		// First to the end, and dropped back where it was.
		(0, 3, [1, 2, 3, 0]),
		(1, 1, [0, 1, 2, 3]),
	])
	internal func droppingAFavoriteInTheGridMovesIt(
		from source: Int,
		to cell: Int,
		expected: [Int]
	) async {
		let store = Store(initialState: MainFeature.State(organization: Self.organization(), spaceID: Self.space)) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .incrementing
		}

		// What the grid sends: the cell among the favorites that stay, as a target.
		let staying = Self.ids.enumerated().filter { $0.offset != source }.map { SidebarItem.ID.tab($0.element.rawValue) }
		let target = FavoritesDrop.target(inserting: cell, among: staying)
		#expect(target == Self.resolve(dropping: source, at: cell).target)
		await store.send(.sidebar(.ui(.sidebar(.moveItems([.tab(Self.ids[source].rawValue)], target))))).finish()

		expectNoDifference(store.sidebar.organization.profiles[0].favorites, expected.map { Self.ids[$0] })
		expectNoDifference(store.sidebar.message, nil)

		// What the grid holds from the drop until the store's order arrives is that same order,
		// so letting go of it moves nothing: no flash back to the old order and no replay.
		let favorites = Self.ids.map { SidebarItem.ID.tab($0.rawValue) }
		let held = FavoritesArrangement(order: FavoritesDrop.order(dropping: [favorites[source]], at: cell, among: favorites))
		let stored = store.sidebar.organization.profiles[0].favorites.map { SidebarItem.ID.tab($0.rawValue) }
		expectNoDifference(held, FavoritesArrangement(staying: stored, insertion: nil))
	}

	@Test
	internal func aTabDroppedInTakesTheCellItWasShownIn() async {
		var organization = Self.organization()
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(20)),
			profileID: Self.profile,
			restoration: .init(title: "New", url: URL(string: "https://new.example")!)
		)
		organization.tabs.append(tab)
		organization.spaces[0].unpinnedTabs = [tab.id]
		let store = Store(initialState: MainFeature.State(organization: organization, spaceID: Self.space)) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .incrementing
		}
		let favorites = Self.ids.map { SidebarItem.ID.tab($0.rawValue) }
		let dropped = SidebarItem.ID.tab(tab.id.rawValue)
		let drop = FavoritesDrop.resolve(
			dropping: [dropped],
			at: .zero,
			among: favorites,
			width: 264,
			availableHeight: 600
		)
		let held = FavoritesArrangement(order: FavoritesDrop.order(dropping: [dropped], at: drop.insertion, among: favorites))

		// Until the store adds it, its cell stays open and the others stay put.
		#expect(held.cellCount == 5)
		#expect(held.cells[dropped] == 0)

		await store.send(.sidebar(.ui(.sidebar(.moveItems([dropped], drop.target))))).finish()
		let stored = store.sidebar.organization.profiles[0].favorites.map { SidebarItem.ID.tab($0.rawValue) }
		expectNoDifference(held, FavoritesArrangement(staying: stored, insertion: nil))
	}

	@Test
	internal func aFavoriteDraggedOutLeavesTheGapItShowedClosed() async {
		let store = Store(initialState: MainFeature.State(organization: Self.organization(), spaceID: Self.space)) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .incrementing
		}
		let favorites = Self.ids.map { SidebarItem.ID.tab($0.rawValue) }

		// The drag ended over the tab list: the grid holds the others, closed up without it.
		let held = FavoritesArrangement(staying: favorites.filter { $0 != favorites[1] }, insertion: nil)
		await store.send(.sidebar(.ui(.sidebar(.moveItems([favorites[1]], .unpinnedRoot))))).finish()
		let stored = store.sidebar.organization.profiles[0].favorites.map { SidebarItem.ID.tab($0.rawValue) }
		expectNoDifference(held, FavoritesArrangement(staying: stored, insertion: nil))
	}

	/// The drop as the grid resolves it from the pointer, in a 4-wide row of 264 points.
	private static func resolve(dropping source: Int, at cell: Int) -> FavoritesDrop.Resolution {
		let favorites = ids.map { SidebarItem.ID.tab($0.rawValue) }
		let layout = FavoritesGridLayout(itemCount: favorites.count, width: 264, availableHeight: 600)
		let frame = layout.frame(at: cell)
		return FavoritesDrop.resolve(
			dropping: [favorites[source]],
			at: CGPoint(x: frame.midX, y: frame.midY),
			among: favorites,
			width: 264,
			availableHeight: 600
		)
	}

	private static let profile = Profile.ID(rawValue: UUID(0))
	private static let space = Space.ID(rawValue: UUID(1))

	private static func organization() -> BrowserOrganization {
		let tabs = ids.enumerated().map { index, id in
			BrowserCore.Tab(
				id: id,
				profileID: profile,
				savedDestination: .init(title: "Site \(index)", url: URL(string: "https://site\(index).example")!),
				restoration: .init(title: "Site \(index)", url: URL(string: "https://site\(index).example")!)
			)
		}
		return .init(
			profiles: [.init(id: profile, name: "Default", favorites: ids)],
			spaces: [.init(id: space, profileID: profile, name: "Work")],
			tabs: tabs
		)
	}
}
