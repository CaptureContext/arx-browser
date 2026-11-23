import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(
	.dependencies {
		$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
	}
)
@MainActor
internal struct LittlePromotionPublicationTests {
	@Test
	internal func promotionPublishesEveryOrdinaryHostBeforeEffects() async throws {
		var (state, tab, destination) = fixture()
		let previous = state.workspace
		let move = OrganizationMove(
			previous: previous,
			updated: previous,
			roots: [],
			destination: destination,
			replacements: [],
			movedTabIDs: []
		)
		state.main.sidebar.undo = [.init(before: previous)]
		state.main.sidebar.transferUndos = [move]
		state.windows[0].sidebar.undo = [.init(before: previous)]
		state.windows[0].sidebar.transferUndos = [move]
		let background = state.windows[0]
		let privateWindow = MainFeature.State(
			organization: previous,
			spaceID: previous.spaces[0].id,
			isPrivate: true,
			id: UUID(41)
		)
		state.windows.append(privateWindow)

		// Inspect the actual commit boundary without running its deferred handoff.
		_ = AppFeature()._reduce(
			into: &state,
			action: .event(.littlePromotionReady(UUID(20), tab, tab, destination))
		)

		#expect(state.littleWindows.isEmpty)
		#expect(state.workspace.tabs.contains(tab))
		expectNoDifference(state.unsavedOrganization, state.workspace)
		expectNoDifference(state.main.sidebar.selectedTab?.id, tab.id)
		expectNoDifference(state.windows[0].sidebar.selectedTab?.id, background.sidebar.selectedTab?.id)
		expectNoDifference(state.windows[0].viewer, background.viewer)
		expectNoDifference(state.windows[1], privateWindow)

		for host in [state.main, state.windows[0]] {
			#expect(host.sidebar.organization.tabs.contains(tab))
			#expect(host.knownTabIDs.contains(tab.id))
			// Publishing ends each window's open step instead of dropping its history (DEV-1030).
			// A move within one profile stays a step, which takes back only what it moved; only
			// its exact reverse goes.
			#expect(host.sidebar.undo.count == 1)
			#expect(host.sidebar.transferUndos.isEmpty)
			try host.sidebar.organization.validate()
		}
	}

	@Test
	internal func undoAfterPromotionCannotRemoveTheTransferredPage() async throws {
		var (state, tab, destination) = fixture()
		state.main.sidebar.edit { $0.spaces[0].name = "Renamed" }
		state.workspace = state.main.sidebar.organization
		var closed: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
		}

		await store.send(.event(.littlePromotionReady(UUID(20), tab, tab, destination))).finish()
		await store.send(.main(.sidebar(.ui(.undo)))).finish()

		// ⌘Z takes back the rename, showing its space again, and keeps the promoted page where
		// it went (DEV-1030).
		#expect(store.workspace.tabs.contains(tab))
		#expect(store.workspace.tabOrder(in: destination).contains(tab.id))
		expectNoDifference(store.workspace.spaces[0].name, "Work")
		expectNoDifference(store.main.sidebar.spaceID, store.workspace.spaces[0].id)
		expectNoDifference(closed, [])
	}

	@Test(arguments: [false, true])
	internal func promotionSelectsTheTransferredPageOverFavoriteAndStoredLayout(
		favoriteSelected: Bool
	) async throws {
		var (state, tab, destination) = fixture()
		if favoriteSelected {
			try state.workspace.move(
				.tab(state.workspace.tabs[0].id.rawValue),
				to: .favoritesRoot,
				in: state.main.sidebar.spaceID
			)
			state.main.sidebar.organization = state.workspace
		}

		let oldDestinationTab = state.workspace.tabs[2]
		state.main.viewer.presentations = [.init(
			id: destination,
			panes: [.init(id: UUID(50), tabID: oldDestinationTab.id)],
			activePaneID: UUID(50)
		)]
		var operations: [String] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface.release = { _ in operations.append("release") }
			$0.browserEngine.open = { opened in
				if opened.id == tab.id { operations.append("present") }
			}
		}

		await store.send(.event(.littlePromotionReady(UUID(20), tab, tab, destination))).finish()

		expectNoDifference(store.main.sidebar.spaceID, destination)
		expectNoDifference(store.main.sidebar.selectedTab?.id, tab.id)
		expectNoDifference(store.main.viewer.item.tab?.id, tab.id)
		expectNoDifference(store.main.viewer.activePaneID, UUID(50))
		expectNoDifference(operations, ["release", "present"])
	}

	@Test
	internal func backgroundNavigationDuringHandoffCannotErasePromotion() async throws {
		let (state, tab, destination) = fixture()
		let background = state.windows[0]
		let backgroundTab = try #require(background.viewer.item.tab)
		var completion: AppFeature.Action?
		var holdsCompletion = true
		let store = Store(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if case .event(.littlePromotionReleased) = action, holdsCompletion {
					completion = action
					return .none
				}
				return AppFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.browserEngine.open = { _ in }
		}

		await store.send(.event(.littlePromotionReady(UUID(20), tab, tab, destination))).finish()
		let released = try #require(completion)
		await store.send(.windows(.element(
			id: background.id,
			action: .viewer(.item(.delegate(.navigation(backgroundTab.id, .init(
				url: backgroundTab.restoration.url,
				title: "New background title"
			)))))
		))).finish()

		#expect(store.workspace.tabs.contains(tab))
		expectNoDifference(
			store.workspace.tabs[id: backgroundTab.id]?.restoration.title,
			"New background title"
		)
		expectNoDifference(store.windows[0].sidebar.selectedTab?.id, backgroundTab.id)
		expectNoDifference(store.windows[0].viewer.item.tab?.id, backgroundTab.id)

		holdsCompletion = false
		await store.send(released).finish()
		#expect(store.workspace.tabs.contains(tab))
		expectNoDifference(store.main.sidebar.selectedTab?.id, tab.id)
	}

	/// A background page that starts or stops loading during the handoff, as a subframe does,
	/// leaves the promoted page to be shown; one that goes to another address doesn't (DEV-1078).
	@Test(arguments: [false, true])
	internal func backgroundLoadingDuringHandoffStillPresentsThePromotion(
		changesAddress: Bool
	) async throws {
		let (state, tab, destination) = fixture()
		let background = state.windows[0]
		let backgroundTab = try #require(background.viewer.item.tab)
		var completion: AppFeature.Action?
		var holdsCompletion = true
		let store = Store(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if case .event(.littlePromotionReleased) = action, holdsCompletion {
					completion = action
					return .none
				}
				return AppFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.browserEngine.open = { _ in }
		}

		await store.send(.event(.littlePromotionReady(UUID(20), tab, tab, destination))).finish()
		let released = try #require(completion)
		var navigation = store.windows[0].viewer.item.navigation
		navigation.isLoading.toggle()
		navigation.errorCode = -3
		if changesAddress {
			navigation.url = URL(string: "https://capturecontext.dev/elsewhere")!
		}
		await store.send(.windows(.element(
			id: background.id,
			action: .viewer(.item(.event(.navigation(
				backgroundTab.id,
				store.windows[0].viewer.item.generation,
				navigation
			))))
		))).finish()
		#expect(store.windows[0].viewer.item.navigation == navigation)

		let viewer = store.main.viewer
		holdsCompletion = false
		await store.send(released).finish()

		#expect(store.workspace.tabs.contains(tab))
		expectNoDifference(store.main.sidebar.selectedTab?.id, tab.id)
		if changesAddress {
			expectNoDifference(store.main.viewer, viewer)
		} else {
			expectNoDifference(store.main.viewer.item.tab?.id, tab.id)
		}
	}

	@Test(arguments: [false, true])
	internal func delayedPromotionPresentationPreservesNewerSelectionOrWindowClosure(
		closesWindow: Bool
	) async throws {
		let (state, tab, destination) = fixture()
		var completion: AppFeature.Action?
		var holdsCompletion = true
		var opened: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if case .event(.littlePromotionReleased) = action, holdsCompletion {
					completion = action
					return .none
				}
				return AppFeature()._reduce(into: &state, action: action)
			}
		} withDependencies: {
			$0.browserEngine.open = { opened.append($0.id) }
		}

		await store.send(.event(.littlePromotionReady(UUID(20), tab, tab, destination))).finish()
		let released = try #require(completion)
		if closesWindow {
			await store.send(.ui(.closeWindow)).finish()

		} else {
			await store.send(.main(.present(
				state.workspace.tabs[2].id,
				in: store.main.viewer.activePaneID
			))).finish()
		}

		let viewer = store.main.viewer
		let selected = store.main.sidebar.selectedTab?.id
		let isOpen = store.windowIsOpen
		let previousOpened = opened
		holdsCompletion = false
		await store.send(released).finish()

		expectNoDifference(store.main.viewer, viewer)
		expectNoDifference(store.main.sidebar.selectedTab?.id, selected)
		expectNoDifference(store.windowIsOpen, isOpen)
		expectNoDifference(opened, previousOpened)
		#expect(store.workspace.tabs.contains(tab))
	}

	private func fixture() -> (AppFeature.State, BrowserCore.Tab, Space.ID) {
		var organization = IntegrationFeatureTests().fixture()
		let destination = organization.spaces[1].id
		let existing = BrowserCore.Tab(
			id: .init(rawValue: UUID(10)),
			profileID: organization.profiles[0].id,
			restoration: organization.tabs[0].restoration
		)
		organization.tabs.append(existing)
		organization.spaces[1].unpinnedTabs = [existing.id]
		organization.spaces[1].selectedTabID = existing.id
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(21)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Promoted", url: URL(string: "https://capturecontext.dev/promoted")!)
		)
		var state = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))
		state.main.viewer.item = .init(tab: organization.tabs[0])
		state.littleWindows.append(.init(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: tab
		))
		var background = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			id: UUID(40)
		)
		background.sidebar.select(organization.tabs[1].id)
		background.viewer.item = .init(tab: organization.tabs[1])
		state.windows.append(background)
		return (state, tab, destination)
	}
}
