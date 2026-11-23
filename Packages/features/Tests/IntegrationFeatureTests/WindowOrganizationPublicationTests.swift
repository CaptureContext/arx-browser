import BrowserCore
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
		$0.browserEngine.open = { _ in }
		$0.uuid = .incrementing
	}
)
@MainActor
internal struct WindowOrganizationPublicationTests {
	@Test(arguments: [false, true])
	internal func queuedDelegateCannotEraseAnAlreadyPublishedPromotion(
		additionalOrigin: Bool
	) async throws {
		let (state, tab) = fixture()
		var queued: AppFeature.Action?
		var holdsDelegate = true
		let store = Store(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if holdsDelegate, isOrganizationDelegate(action) {
					queued = action
					return .none
				}
				return AppFeature()._reduce(into: &state, action: action)
			}
		}

		await store.send(hostAction(.synchronize, additional: additionalOrigin)).finish()
		let oldDelegate = try #require(queued)
		await store.send(.event(.littlePromotionReady(
			UUID(20), tab, tab, state.workspace.spaces[0].id
		))).finish()
		#expect(store.workspace.tabs.contains(tab))

		holdsDelegate = false
		await store.send(oldDelegate).finish()

		#expect(store.workspace.tabs.contains(tab))
		#expect(store.main.sidebar.organization.tabs.contains(tab))
		#expect(store.windows[0].sidebar.organization.tabs.contains(tab))
		expectNoDifference(store.unsavedOrganization, store.workspace)
	}

	@Test(arguments: [false, true])
	internal func queuedDelegatePublishesTheOriginsNewerStructuralEdit(
		additionalOrigin: Bool
	) async throws {
		let (state, _) = fixture()
		var queued: AppFeature.Action?
		var holdsDelegate = true
		var saved: [BrowserOrganization] = []
		let store = Store(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if holdsDelegate, isOrganizationDelegate(action) {
					if queued == nil { queued = action }
					return .none
				}
				if case .delegate(.save) = action { saved.append(state.workspace) }
				return AppFeature()._reduce(into: &state, action: action)
			}
		}

		await store.send(hostAction(.synchronize, additional: additionalOrigin)).finish()
		let oldDelegate = try #require(queued)
		await store.send(hostAction(
			.sidebar(.ui(.sidebar(.newFolder(nil)))),
			additional: additionalOrigin
		)).finish()
		let origin = additionalOrigin ? store.windows[0] : store.main
		let created = try #require(origin.sidebar.organization.folders.first)

		// The newer delegate is deliberately held too: delivering only the old
		// notification must still publish the origin's current edit and request a save.
		holdsDelegate = false
		await store.send(oldDelegate).finish()

		expectNoDifference(store.workspace.folders, [created])
		expectNoDifference(store.main.sidebar.organization.folders, [created])
		expectNoDifference(store.windows[0].sidebar.organization.folders, [created])
		expectNoDifference(saved.last, store.workspace)
	}

	@Test
	internal func publicationDoesNotQueueAnOldReconciliationOverTheNextEdit() async throws {
		let (state, _) = fixture()
		var reconciliations: [AppFeature.Action] = []
		let store = Store(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				switch action {
				case .main(.reconcile), .windows(.element(_, .reconcile)):
					reconciliations.append(action)
					return .none

				default:
					return AppFeature()._reduce(into: &state, action: action)
				}
			}
		}

		await store.send(.main(.sidebar(.ui(.sidebar(.newFolder(nil)))))).finish()
		let first = try #require(store.workspace.folders.first)
		await store.send(hostAction(
			.sidebar(.ui(.sidebar(.newFolder(nil)))),
			additional: true
		)).finish()

		#expect(reconciliations.isEmpty)
		#expect(store.workspace.folders.contains(first))
		expectNoDifference(store.workspace.folders.count, 2)
		expectNoDifference(store.main.sidebar.organization.folders, store.workspace.folders)
		expectNoDifference(store.windows[0].sidebar.organization.folders, store.workspace.folders)
	}

	@Test
	internal func privateOrganizationDelegatesNeverPublishOrSave() async throws {
		var (state, _) = fixture()
		var privateOrganization = state.workspace
		privateOrganization.spaces[0].name = "Private only"
		let privateWindow = MainFeature.State(
			organization: privateOrganization,
			spaceID: privateOrganization.spaces[0].id,
			isPrivate: true,
			id: UUID(41)
		)
		state.windows.append(privateWindow)
		var saves = 0
		let store = Store(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				if case .delegate(.save) = action { saves += 1 }
				return AppFeature()._reduce(into: &state, action: action)
			}
		}

		await store.send(.windows(.element(
			id: privateWindow.id,
			action: .delegate(.organizationChanged(privateOrganization))
		))).finish()

		expectNoDifference(store.workspace, state.workspace)
		expectNoDifference(store.main.sidebar.organization, state.main.sidebar.organization)
		expectNoDifference(store.unsavedOrganization, nil)
		expectNoDifference(saves, 0)
	}

	private func isOrganizationDelegate(_ action: AppFeature.Action) -> Bool {
		switch action {
		case .main(.delegate(.organizationChanged)), .windows(.element(_, .delegate(.organizationChanged))): true
		default: false
		}
	}

	private func hostAction(
		_ action: MainFeature.Action,
		additional: Bool
	) -> AppFeature.Action {
		additional ? .windows(.element(id: UUID(40), action: action)) : .main(action)
	}

	private func fixture() -> (AppFeature.State, BrowserCore.Tab) {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))
		state.main.viewer.item = .init(tab: organization.tabs[0])
		var background = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			id: UUID(40)
		)
		background.sidebar.select(organization.tabs[1].id)
		background.viewer.item = .init(tab: organization.tabs[1])
		state.windows.append(background)
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(21)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Promoted", url: URL(string: "https://capturecontext.dev/promoted")!)
		)
		state.littleWindows.append(.init(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: tab
		))
		return (state, tab)
	}
}
