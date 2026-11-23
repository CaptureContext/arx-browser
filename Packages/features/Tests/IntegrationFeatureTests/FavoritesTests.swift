import AppFeature
@testable import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import PeekFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct FavoritesTests {
	@Test
	internal func sameProfileSpaceSwitchRetainsFavoriteIdentityAndCurrentDestination() async throws {
		let organization = fixture()
		let tab = organization.tabs[0]
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = tab
		var opened: [BrowserCore.Tab] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.close = { closed.append($0) }
		}
		for space in [organization.spaces[1], organization.spaces[0]] {
			await store.send(.main(.sidebar(.ui(.spaceSelected(space.id))))).finish()
			expectNoDifference(store.main.sidebar.selectedTab?.id, tab.id)
			expectNoDifference(store.main.viewer.item.tab?.id, tab.id)
			expectNoDifference(store.main.sidebar.favorites.map(\.id), [.tab(tab.id.rawValue)])
		}
		#expect(!opened.isEmpty)
		#expect(opened.allSatisfy { $0.id == tab.id && $0.restoration.url == tab.restoration.url })
		expectNoDifference(closed, [])
		expectNoDifference(store.workspace.tabs, organization.tabs)
		#expect(store.main.commandCandidates.contains { $0.intent == .selectTab(tab.id) })
	}

	@Test
	internal func selectingFavoriteAlreadyVisibleElsewhereFocusesItsOwningPane() async throws {
		let organization = fixture()
		let tab = organization.tabs[0]
		let other = organization.tabs[1]
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.sidebar.select(other.id)
		main.viewer.item.tab = other
		var owner = MainFeature.State(organization: organization, spaceID: organization.spaces[1].id, id: UUID(40))
		owner.sidebar.select(tab.id)
		owner.viewer.item.tab = nil
		let paneID = UUID(41)
		owner.viewer.panes.append(.init(id: paneID, item: .init(tab: tab)))
		var initial = AppFeature.State(main: main)
		initial.windows.append(owner)
		var opened: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.open = { opened.append($0.id) }
		}
		await store.send(.main(.sidebar(.ui(.sidebar(.select(.tab(tab.id.rawValue))))))).finish()
		expectNoDifference(store.focusedWindowID, owner.id)
		expectNoDifference(store.windows[id: owner.id]?.viewer.activePaneID, paneID)
		expectNoDifference(store.main.viewer.item.tab?.id, other.id)
		expectNoDifference(store.main.sidebar.selectedTab?.id, other.id)
		expectNoDifference(opened, [])
	}

	@Test(arguments: [true, false])
	internal func closingFavoriteFromAnotherWindowClearsTheOwningPresentation(_ reset: Bool) async throws {
		let organization = fixture()
		let tab = organization.tabs[0]
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.sidebar.select(organization.tabs[1].id)
		main.viewer.item.tab = organization.tabs[1]
		var owner = MainFeature.State(organization: organization, spaceID: organization.spaces[1].id, id: UUID(40))
		owner.sidebar.select(tab.id)
		owner.viewer.item.tab = tab
		var initial = AppFeature.State(main: main)
		initial.windows.append(owner)
		var closed: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { closed.append($0) }
		}
		let id = SidebarItem.ID.tab(tab.id.rawValue)
		await store.send(.main(.sidebar(.ui(.sidebar(reset ? .reset(id) : .removePin(id)))))).finish()
		expectNoDifference(closed, [tab.id])
		expectNoDifference(store.windows[id: owner.id]?.viewer.item.tab, nil)
		expectNoDifference(store.windows[id: owner.id]?.sidebar.selectedTab, nil)
		expectNoDifference(store.main.viewer.item.tab?.id, organization.tabs[1].id)
	}


	@Test(arguments: [true, false])
	internal func resetRetainsSavedEntryWhileRemovalCanBeUndone(_ reset: Bool) async throws {
		let organization = fixture()
		let tab = organization.tabs[0]
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		initial.viewer.item.tab = tab
		var closed: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial) { MainFeature() } withDependencies: {
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.permitsClosing = { _ in true }
		}
		let id = SidebarItem.ID.tab(tab.id.rawValue)
		await store.send(.sidebar(.ui(.sidebar(reset ? .reset(id) : .removePin(id))))).finish()
		expectNoDifference(closed, [tab.id])
		expectNoDifference(store.sidebar.organization.archive, [])
		expectNoDifference(store.sidebar.undo.map(\.before), [organization])
		expectNoDifference(store.viewer.item.tab, nil)
		if reset {
			let retained = try #require(store.sidebar.organization.tabs[id: tab.id])
			expectNoDifference(retained.savedDestination, tab.savedDestination)
			expectNoDifference(retained.restoration.url, tab.savedDestination?.url)
			expectNoDifference(store.sidebar.organization.profiles[0].favorites, [tab.id])
		} else {
			#expect(!store.sidebar.organization.tabs.ids.contains(tab.id))
			expectNoDifference(store.sidebar.organization.profiles[0].favorites, [])
		}
		await store.send(.sidebar(.ui(.undo))).finish()
		expectNoDifference(store.sidebar.organization, organization)
		expectNoDifference(store.viewer.item.tab?.id, tab.id)
	}

	@Test
	internal func resetClearsInactiveSplitAndSavedSpacePlacementsWithoutClosingTheOtherPane() async throws {
		let organization = fixture()
		let tab = organization.tabs[0]
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.sidebar.select(organization.tabs[1].id)
		main.viewer.item.tab = organization.tabs[1]
		main.viewer.preservesPresentation = true
		let favoritePane = UUID(44)
		main.viewer.panes.append(.init(id: favoritePane, item: .init(tab: tab, generation: 5)))
		main.viewer.presentations = [.init(
			id: organization.spaces[1].id,
			panes: [.init(id: UUID(45), tabID: tab.id)],
			activePaneID: UUID(45)
		)]
		let initial = AppFeature.State(main: main)
		initial.$windowLayout.withLock {
			$0.windowPresentations = [
				.init(id: main.id, activeSpaceID: main.sidebar.spaceID, spaces: main.viewer.allPresentations),
			]
		}
		var closed: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.permitsClosing = { _ in true }
		}
		await store.send(.main(.sidebar(.ui(.sidebar(.reset(.tab(tab.id.rawValue))))))).finish()
		expectNoDifference(closed, [tab.id])
		expectNoDifference(store.main.viewer.activePaneID, main.viewer.activePaneID)
		expectNoDifference(store.main.viewer.item.tab?.id, organization.tabs[1].id)
		expectNoDifference(store.main.viewer.panes[id: favoritePane]?.item.tab, nil)
		#expect(store.main.viewer.allPresentations.allSatisfy { $0.panes.allSatisfy { $0.tabID != tab.id } })
		#expect(store.windowLayout.windowPresentations.allSatisfy { presentation in
			presentation.spaces.allSatisfy { $0.panes.allSatisfy { $0.tabID != tab.id } }
		})
		expectNoDifference(store.workspace.profiles[0].favorites, [tab.id])
	}

	@Test
	internal func resetReleasesBorrowedPeekAfterOneNativeCloseApproval() async throws {
		let initial = borrowedPeekFixture()
		let tab = initial.workspace.tabs[0]
		var approvals = 0
		var closed: [BrowserCore.Tab.ID] = []
		var released: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.browserSurface.release = { released.append($0) }
			$0.browserEngine.permitsClosing = { _ in
				approvals += 1
				return true
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		await store.send(.main(.sidebar(.ui(.sidebar(.reset(.tab(tab.id.rawValue))))))).finish()
		expectNoDifference(approvals, 1)
		expectNoDifference(closed, [tab.id])
		expectNoDifference(released, [tab.id])
		expectNoDifference(store.peeks.count, 0)
		expectNoDifference(store.workspace.profiles[0].favorites, [tab.id])
		expectNoDifference(store.main.viewer.item.tab?.id, initial.main.viewer.item.tab?.id)
	}

	@Test(arguments: [false, true])
	internal func lateResetCompletionPreservesReopenedFavorite(_ nativeSnapshot: Bool) async throws {
		let organization = fixture()
		let tab = organization.tabs[0]
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.sidebar.select(organization.tabs[1].id)
		main.viewer.item.tab = organization.tabs[1]
		var owner = MainFeature.State(organization: organization, spaceID: organization.spaces[1].id, id: UUID(40))
		owner.sidebar.select(tab.id)
		owner.viewer.item.tab = tab
		var initial = AppFeature.State(main: main)
		initial.windows.append(owner)
		var live = false
		var reopen: (@MainActor () -> Void)?
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.snapshot = { _ in live ? .init(navigation: .init(), revision: 2) : nil }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { _ in
				if nativeSnapshot { live = true } else { reopen?() }
			}
		}
		reopen = { store.send(.windows(.element(id: owner.id, action: .viewer(.item(.show(tab)))))) }
		await store.send(.main(.sidebar(.ui(.sidebar(.reset(.tab(tab.id.rawValue))))))).finish()
		reopen = nil
		expectNoDifference(store.windows[id: owner.id]?.viewer.item.tab?.id, tab.id)
		expectNoDifference(store.windows[id: owner.id]?.sidebar.selectedTab?.id, tab.id)
	}

	@Test
	internal func queuedCleanupCannotClearFreshPaneOrPromotingPeek() async throws {
		var initial = borrowedPeekFixture()
		let peek = try #require(initial.peeks.first)
		initial.peeks[id: peek.id]?.phase = .promoting
		let store = TestStore(initialState: initial) { AppFeature() }
		await store.send(.resetPeekPresentation(peek.id, tabID: peek.tab.id, generation: peek.viewer.generation))
		await store.finish()
		expectNoDifference(store.state.peeks[id: peek.id]?.phase, .promoting)

		var window = MainFeature.State(organization: fixture(), spaceID: fixture().spaces[0].id)
		let tab = window.sidebar.organization.tabs[0]
		window.viewer.item.tab = tab
		let reset = TabPresentationReset(tabID: tab.id, window: window)
		window.viewer.item.generation += 1
		window.viewer.observationGeneration = window.viewer.item.generation
		let reopened = TestStore(initialState: window) { MainFeature() }
		await reopened.send(.unloadResetTab(reset))
		await reopened.send(.viewer(.unload(tab.id, in: window.viewer.activePaneID, generation: window.viewer.item.generation - 1)))
		await reopened.finish()
		expectNoDifference(reopened.state.viewer.item.tab?.id, tab.id)
	}

	@Test(arguments: [true, false])
	internal func declinedCloseKeepsFavoriteMetadataAndSession(_ reset: Bool) async throws {
		let organization = fixture()
		let tab = organization.tabs[0]
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		initial.viewer.item.tab = tab
		var closed: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial) { MainFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in false }
			$0.browserEngine.close = { closed.append($0) }
		}
		let id = SidebarItem.ID.tab(tab.id.rawValue)
		await store.send(.sidebar(.ui(.sidebar(reset ? .reset(id) : .removePin(id))))).finish()
		expectNoDifference(store.sidebar.organization, organization)
		expectNoDifference(store.sidebar.undo.map(\.before), [])
		expectNoDifference(store.viewer.item.tab?.id, tab.id)
		expectNoDifference(store.pendingTabCloses, [])
		expectNoDifference(closed, [])
	}

	@Test
	internal func unfavoriteMovesCurrentSessionToActiveSpaceAndFolderMoveMakesPin() async throws {
		var organization = fixture()
		let tab = organization.tabs[0]
		let space = organization.spaces[1].id
		let folder = Folder.ID(rawValue: UUID(60))
		organization.folders.append(.init(id: folder, spaceID: space, name: "Reference"))
		organization.spaces[1].savedItems = [.folder(folder)]
		var initial = MainFeature.State(organization: organization, spaceID: space)
		initial.sidebar.select(tab.id)
		initial.viewer.item.tab = tab
		var closed: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial) { MainFeature() } withDependencies: {
			$0.browserEngine.close = { closed.append($0) }
		}
		let id = SidebarItem.ID.tab(tab.id.rawValue)
		await store.send(.sidebar(.ui(.sidebar(.move(id, .unpinnedRoot))))).finish()
		expectNoDifference(store.sidebar.organization.location(of: tab.id), .unpinned(space))
		expectNoDifference(store.sidebar.organization.tabs[0].savedDestination, nil)
		expectNoDifference(store.sidebar.organization.tabs[0].restoration, tab.restoration)
		expectNoDifference(store.viewer.item.tab?.id, tab.id)
		await store.send(.sidebar(.ui(.sidebar(.move(id, .inside(.folder(folder.rawValue))))))).finish()
		expectNoDifference(store.sidebar.organization.location(of: tab.id), .pinned(space, folder: folder))
		expectNoDifference(store.sidebar.organization.tabs[0].savedDestination?.url, tab.restoration.url)
		expectNoDifference(store.sidebar.organization.profiles[0].favorites, [])
		expectNoDifference(closed, [])
	}

	@Test
	internal func renameReorderAndUpdateSavedURLRoundTripWithoutChangingCurrentURL() async throws {
		let organization = fixture()
		let first = organization.tabs[0]
		let second = organization.tabs[1]
		let initialState = SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = Store(initialState: initialState) { SidebarFeature() }
		await store.send(.ui(.sidebar(.move(.tab(second.id.rawValue), .favoritesRoot)))).finish()
		await store.send(.ui(.sidebar(.move(.tab(second.id.rawValue), .before(.tab(first.id.rawValue)))))).finish()
		await store.send(.ui(.sidebar(.rename(.tab(first.id.rawValue), "Reference")))).finish()
		expectNoDifference(store.organization.tabs[0].savedDestination?.url, first.savedDestination?.url)
		await store.send(.ui(.sidebar(.updateSavedURL(.tab(first.id.rawValue))))).finish()
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserWorkspaceClient(file: directory.appendingPathComponent("workspace.json"))
		try client.save(store.organization)
		let restored = try #require(try client.load())
		expectNoDifference(restored.profiles[0].favorites, [second.id, first.id])
		expectNoDifference(restored.tabs[0].customTitle, "Reference")
		expectNoDifference(restored.tabs[0].savedDestination?.title, "Reference")
		expectNoDifference(restored.tabs[0].savedDestination?.url, first.restoration.url)
		expectNoDifference(restored.tabs[0].restoration, first.restoration)
		expectNoDifference(restored.tabs[0].savedDestination?.iconURL, first.savedDestination?.iconURL)
		try restored.validate()
	}

	@Test
	internal func spaceDeletionRetainsProfileFavoritesAndOtherProfilesCannotSeeThem() throws {
		var organization = fixture()
		let tab = organization.tabs[0]
		let profile = Profile.ID(rawValue: UUID(70))
		let space = Space.ID(rawValue: UUID(71))
		organization.profiles.append(.init(id: profile, name: "Other"))
		organization.spaces.append(.init(id: space, profileID: profile, name: "Other"))
		organization = try organization.applying(.removeSpace(organization.spaces[0].id), uuid: UUID.init)
		expectNoDifference(organization.profiles[0].favorites, [tab.id])
		expectNoDifference(organization.tabs, [tab])
		expectNoDifference(SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id).favorites.count, 1)
		let other = MainFeature.State(organization: organization, spaceID: space)
		expectNoDifference(other.sidebar.favorites, [])
		#expect(!other.commandCandidates.contains { $0.intent == .selectTab(tab.id) })
		try organization.validate()
	}

	@Test(arguments: [160.0, 320, 600, 1000])
	internal func aLongListKeepsEveryFavoriteReachableByKeyboard(_ availableHeight: Double) {
		let layout = FavoritesGridLayout(itemCount: 201, availableHeight: availableHeight)

		// Favorites never scroll: every row counts toward the grid's height.
		expectNoDifference(layout.contentHeight, 51 * (FavoritesGridLayout.tileHeight + FavoritesGridLayout.spacing) - FavoritesGridLayout.spacing)
		var visited = [0]
		while let next = layout.neighbor(of: visited.last!, direction: .right) { visited.append(next) }
		expectNoDifference(visited, Array(0..<201))
		expectNoDifference(layout.neighbor(of: 197, direction: .down), 200)
		expectNoDifference(layout.neighbor(of: 200, direction: .down), nil)
		expectNoDifference(layout.neighbor(of: 200, direction: .up), 196)
	}

	@Test
	internal func shortAndEmptyFavoritesAvoidUnusedScrollArea() {
		let empty = FavoritesGridLayout(itemCount: 0, availableHeight: 600)
		expectNoDifference(empty.contentHeight, 0)
		expectNoDifference(empty.neighbor(of: 0, direction: .down), nil)
		let short = FavoritesGridLayout(itemCount: 4, availableHeight: 600)
		expectNoDifference(short.contentHeight, FavoritesGridLayout.tileHeight)
		expectNoDifference(short.neighbor(of: 0, direction: .left), nil)
		expectNoDifference(
			FavoritesGridLayout(itemCount: 20, availableHeight: 600).contentHeight,
			5 * (FavoritesGridLayout.tileHeight + FavoritesGridLayout.spacing) - FavoritesGridLayout.spacing
		)
	}

	private func fixture() -> BrowserOrganization {
		var organization = IntegrationFeatureTests().fixture()
		var tab = organization.tabs[0]
		tab.savedDestination = .init(title: "Saved", url: URL(string: "https://saved.example")!)
		tab.restoration = .init(title: "Current page", url: URL(string: "https://current.example/article")!)
		tab.savedDestination?.iconURL = URL(string: "https://saved.example/favicon.ico")!
		organization.tabs[0] = tab
		organization.spaces[0].unpinnedTabs.removeFirst()
		organization.profiles[0].favorites = [tab.id]
		return organization
	}

	private func borrowedPeekFixture() -> AppFeature.State {
		let organization = fixture()
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.sidebar.select(organization.tabs[1].id)
		main.viewer.item.tab = organization.tabs[1]
		var initial = AppFeature.State(main: main)
		var peek = PeekFeature.State(
			id: UUID(80),
			source: .init(
				windowID: main.id,
				paneID: main.viewer.activePaneID,
				tabID: organization.tabs[1].id,
				spaceID: main.sidebar.spaceID,
				profileID: organization.profiles[0].id,
				identity: "Default"
			), tab: organization.tabs[0], isTemporary: false
		)
		peek.viewer = .init(tab: peek.tab, generation: 5)
		initial.peeks.append(peek)
		return initial
	}
}
