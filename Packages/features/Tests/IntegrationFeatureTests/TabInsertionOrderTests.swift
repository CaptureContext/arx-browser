import BrowserCore
import CustomDump
import Foundation
import MainFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// A tab made from another tab goes next to it, not to the bottom of the list (DEV-1325), by Max's
/// rules: directly after a regular tab, every time, and first among the regular tabs from a
/// bookmark (a favorite tab, or a pinned tab in a folder or not) or from no tab.
@Suite(
	.dependencies {
		$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
		$0.browserEngine.open = { _ in }
		$0.browserEngine.cloneNavigation = { _, _ in }
		$0.uuid = .incrementing
	}
)
@MainActor
internal struct TabInsertionOrderTests {
	// MARK: - Peek

	@Test
	internal func aPeekBecomesATabRightAfterTheTabItWasOver() async throws {
		var state = appState(showing: regular[0])
		let peek = try promote(peekID: 80, tabID: 81, in: &state)

		expectNoDifference(state.workspace.spaces[0].unpinnedTabs, [regular[0], peek, regular[1], regular[2]])
		expectNoDifference(state.main.sidebar.organization.spaces[0].unpinnedTabs, state.workspace.spaces[0].unpinnedTabs)
	}

	@Test
	internal func eachPeekFromOneTabGoesDirectlyAfterIt() async throws {
		var state = appState(showing: regular[1])
		let first = try promote(peekID: 80, tabID: 81, in: &state)
		let second = try promote(peekID: 82, tabID: 83, in: &state)

		expectNoDifference(
			state.workspace.spaces[0].unpinnedTabs,
			[regular[0], regular[1], second, first, regular[2]]
		)
	}

	@Test(arguments: [Source.favorite, .pinned, .folder])
	internal func aPeekOverABookmarkBecomesTheFirstRegularTab(_ source: Source) async throws {
		var state = appState(showing: source.tabID)
		let first = try promote(peekID: 80, tabID: 81, in: &state)
		let second = try promote(peekID: 82, tabID: 83, in: &state)

		expectNoDifference(state.workspace.spaces[0].unpinnedTabs, [second, first] + regular)
		expectNoDifference(state.workspace.profiles[0].favorites, [Source.favorite.tabID])
		expectNoDifference(state.workspace.spaces[0].savedItems, [.tab(Source.pinned.tabID), .folder(folderID)])
		expectNoDifference(state.workspace.folders[0].children, [.tab(Source.folder.tabID)])
	}

	// MARK: - Duplicate

	@Test
	internal func eachDuplicateGoesDirectlyAfterItsTab() async throws {
		let store = mainStore(selecting: regular[0])
		await store.send(.ui(.duplicateTab))
		let first = try #require(store.state.sidebar.selectedTab?.id)
		await store.send(.sidebar(.ui(.sidebar(.select(.tab(regular[0].rawValue))))))
		await store.send(.ui(.duplicateTab))
		let second = try #require(store.state.sidebar.selectedTab?.id)
		await store.finish()

		expectNoDifference(
			store.state.sidebar.space.unpinnedTabs,
			[regular[0], second, first, regular[1], regular[2]]
		)
	}

	@Test
	internal func aPanesDuplicateGoesRightAfterItsTab() async throws {
		var shown = MainFeature.State(organization: organization(), spaceID: spaceID)
		shown.sidebar.select(regular[1])
		shown.viewer.item.tab = shown.sidebar.organization.tabs[id: regular[1]]
		let paneID = shown.viewer.activePaneID
		let store = TestStore(initialState: shown) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.paneCommand(.duplicateTab, paneID)))
		await store.finish()

		let open = store.state.sidebar.space.unpinnedTabs
		let copy = try #require(open.first { !regular.contains($0) })
		expectNoDifference(open, [regular[0], regular[1], copy, regular[2]])
	}

	@Test(arguments: [Source.favorite, .pinned, .folder])
	internal func aPanesDuplicateOfABookmarkIsTheFirstRegularTab(_ source: Source) async throws {
		var shown = MainFeature.State(organization: organization(), spaceID: spaceID)
		shown.sidebar.select(source.tabID)
		shown.viewer.item.tab = shown.sidebar.organization.tabs[id: source.tabID]
		let paneID = shown.viewer.activePaneID
		let store = TestStore(initialState: shown) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.paneCommand(.duplicateTab, paneID)))
		await store.finish()

		let open = store.state.sidebar.space.unpinnedTabs
		let copy = try #require(open.first { !regular.contains($0) })
		expectNoDifference(open, [copy] + regular)
		expectNoDifference(store.state.sidebar.organization.profiles[0].favorites, [Source.favorite.tabID])
		expectNoDifference(store.state.sidebar.organization.folders[0].children, [.tab(Source.folder.tabID)])
	}

	// MARK: - Open in a split

	@Test
	internal func aLinkOpenedInASplitGoesRightAfterTheCurrentTab() async throws {
		var shown = MainFeature.State(organization: organization(), spaceID: spaceID)
		shown.sidebar.select(regular[0])
		shown.viewer.item.tab = shown.sidebar.organization.tabs[id: regular[0]]
		let store = TestStore(initialState: shown) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.splitURL(URL(string: "https://example.com/split")!)))
		await store.finish()

		let open = store.state.sidebar.space.unpinnedTabs
		let opened = try #require(open.first { !regular.contains($0) })
		expectNoDifference(open, [regular[0], opened, regular[1], regular[2]])
	}

	// MARK: - Little Arx

	@Test
	internal func littleArxOpenedInASpaceIsTheFirstRegularTab() async throws {
		var state = appState(showing: regular[1])
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(21)),
			profileID: profileID,
			restoration: .init(title: "Little", url: URL(string: "https://example.com/little")!)
		)
		state.littleWindows.append(.init(id: UUID(20), spaceID: spaceID, tab: tab))

		_ = AppFeature()._reduce(into: &state, action: .event(.littlePromotionReady(UUID(20), tab, tab, spaceID)))

		expectNoDifference(state.workspace.spaces[0].unpinnedTabs, [tab.id] + regular)
	}

	// MARK: - The organization's insertion

	@Test
	internal func theOrganizationPlacesByTheThreeRules() throws {
		var organization = organization()
		let made: [BrowserCore.Tab.ID] = [60, 61, 62, 63].map { .init(rawValue: UUID($0)) }

		// From a regular tab: directly after it, every time.
		organization.placeOpenedTab(made[0], inSpaceAt: 0, opener: regular[1])
		organization.placeOpenedTab(made[1], inSpaceAt: 0, opener: regular[1])
		expectNoDifference(organization.spaces[0].unpinnedTabs, [regular[0], regular[1], made[1], made[0], regular[2]])

		// From a bookmark, or from no tab, as ⌘T and Little Arx: first.
		organization.placeOpenedTab(made[2], inSpaceAt: 0, opener: Source.folder.tabID)
		organization.placeOpenedTab(made[3], inSpaceAt: 0, opener: nil)
		expectNoDifference(Array(organization.spaces[0].unpinnedTabs.prefix(2)), [made[3], made[2]])
		expectNoDifference(organization.folders[0].children, [.tab(Source.folder.tabID)])
	}

	// MARK: - Fixture

	internal enum Source: CaseIterable, Sendable, CustomTestStringConvertible {
		case favorite
		case pinned
		case folder

		internal var tabID: BrowserCore.Tab.ID {
			switch self {
			case .favorite: .init(rawValue: UUID(6))
			case .pinned: .init(rawValue: UUID(7))
			case .folder: .init(rawValue: UUID(9))
			}
		}

		internal var testDescription: String { "\(self)" }
	}

	private let profileID = Profile.ID(rawValue: UUID(0))
	private let spaceID = Space.ID(rawValue: UUID(1))
	private let folderID = Folder.ID(rawValue: UUID(8))
	private let regular: [BrowserCore.Tab.ID] = [3, 4, 5].map { .init(rawValue: UUID($0)) }

	/// Regular tabs 3, 4 and 5; favorite tab 6; pinned tab 7; tab 9 in folder 8.
	private func organization() -> BrowserOrganization {
		func tab(_ id: Int, saved: Bool = false) -> BrowserCore.Tab {
			let url = URL(string: "https://example.com/\(id)")!
			return .init(
				id: .init(rawValue: UUID(id)),
				profileID: profileID,
				savedDestination: saved ? .init(title: "Saved \(id)", url: url) : nil,
				restoration: .init(title: "Page \(id)", url: url)
			)
		}

		return .init(
			profiles: [.init(id: profileID, name: "Default", favorites: [Source.favorite.tabID])],
			spaces: [
				.init(
					id: spaceID,
					profileID: profileID,
					name: "Work",
					savedItems: [.tab(Source.pinned.tabID), .folder(folderID)],
					unpinnedTabs: regular,
					selectedTabID: regular[0]
				),
			],
			folders: [.init(id: folderID, spaceID: spaceID, name: "Folder", children: [.tab(Source.folder.tabID)])],
			tabs: [tab(3), tab(4), tab(5), tab(6, saved: true), tab(7, saved: true), tab(9, saved: true)]
		)
	}

	private func appState(showing tabID: BrowserCore.Tab.ID) -> AppFeature.State {
		let organization = organization()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: spaceID))
		state.main.sidebar.select(tabID)
		state.main.viewer.item = .init(tab: organization.tabs[id: tabID])
		return state
	}

	private func mainStore(selecting tabID: BrowserCore.Tab.ID) -> TestStoreOf<MainFeature> {
		var state = MainFeature.State(organization: organization(), spaceID: spaceID)
		state.sidebar.select(tabID)
		let store = TestStore(initialState: state) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	/// Opens a Peek over the main window's pane and keeps it as a tab.
	private func promote(
		peekID: Int,
		tabID: Int,
		in state: inout AppFeature.State
	) throws -> BrowserCore.Tab.ID {
		let source = try #require(state.peekSource(windowID: state.main.id, paneID: state.main.viewer.activePaneID))
		var peek = PeekFeature.State(
			id: UUID(peekID),
			source: source,
			tab: .init(
				id: .init(rawValue: UUID(tabID)),
				profileID: profileID,
				restoration: .init(title: "Peek", url: URL(string: "https://example.com/peek/\(tabID)")!)
			),
			isTemporary: true
		)
		peek.phase = .releasing
		state.peeks.append(peek)
		state.peekTransitions[peek.id] = .promote(.tab)

		_ = AppFeature()._reduce(into: &state, action: .event(.peekReleased(peek.id)))
		#expect(state.peeks.isEmpty)

		// The source pane keeps showing the tab it was over, as the next Peek's source.
		state.main.viewer.item = .init(tab: state.workspace.tabs[id: source.tabID ?? peek.tab.id])
		return peek.tab.id
	}
}
