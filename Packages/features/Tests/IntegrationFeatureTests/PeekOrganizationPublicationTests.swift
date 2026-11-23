import BrowserCore
import CustomDump
import Foundation
import MainFeature
import PeekFeature
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
internal struct PeekOrganizationPublicationTests {
	@Test(arguments: [false, true])
	internal func promotionPublishesEveryOrdinaryHostBeforeEffects(
		additionalSource: Bool
	) async throws {
		var (state, peek) = try fixture(additionalSource: additionalSource)
		let main = state.main
		let background = state.windows[0]
		let privateWindow = state.windows[1]

		// No emitted presentation or reconciliation can run before these assertions.
		_ = AppFeature()._reduce(into: &state, action: .event(.peekReleased(peek.id)))

		#expect(state.peeks.isEmpty)
		#expect(state.workspace.tabs.contains(peek.tab))
		expectNoDifference(state.unsavedOrganization, state.workspace)
		expectNoDifference(state.main.viewer, main.viewer)
		expectNoDifference(state.windows[0].viewer, background.viewer)
		expectNoDifference(state.main.sidebar.selectedTab?.id, main.sidebar.selectedTab?.id)
		expectNoDifference(state.windows[0].sidebar.selectedTab?.id, background.sidebar.selectedTab?.id)
		expectNoDifference(state.windows[1], privateWindow)

		for host in [state.main, state.windows[0]] {
			#expect(host.sidebar.organization.tabs.contains(peek.tab))
			#expect(host.knownTabIDs.contains(peek.tab.id))
			// A move within one profile stays a step, which takes back only what it moved; only
			// its exact reverse goes (DEV-1030).
			#expect(host.sidebar.undo.count == 1)
			#expect(host.sidebar.transferUndos.isEmpty)
			try host.sidebar.organization.validate()
		}
	}

	@Test(arguments: [false, true], [false, true])
	internal func delayedOrganizationNotificationCannotErasePromotion(
		additionalSource: Bool,
		additionalOrigin: Bool
	) async throws {
		let (state, peek) = try fixture(additionalSource: additionalSource)
		var queuedDelegate: AppFeature.Action?
		var holdsDelegate = true
		var queuedReconciliations: [AppFeature.Action] = []
		let store = Store(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				switch action {
				case .main(.reconcile), .windows(.element(_, .reconcile)):
					queuedReconciliations.append(action)
					return .none

				case .main(.delegate(.organizationChanged)),
					.windows(.element(_, .delegate(.organizationChanged))):
					if holdsDelegate {
						if queuedDelegate == nil { queuedDelegate = action }
						return .none
					}

				default:
					break
				}

				return AppFeature()._reduce(into: &state, action: action)
			}
		}

		await store.send(hostAction(.synchronize, additional: additionalOrigin)).finish()
		let oldDelegate = try #require(queuedDelegate)
		await store.send(.event(.peekReleased(peek.id))).finish()
		#expect(store.workspace.tabs.contains(peek.tab))

		// Deliver the pre-promotion notification while any old deferred recipient
		// reconciliations remain held, reproducing the actual asynchronous gap.
		holdsDelegate = false
		await store.send(oldDelegate).finish()

		#expect(queuedReconciliations.isEmpty)
		#expect(store.workspace.tabs.contains(peek.tab))
		#expect(store.main.sidebar.organization.tabs.contains(peek.tab))
		#expect(store.windows[0].sidebar.organization.tabs.contains(peek.tab))
		expectNoDifference(store.unsavedOrganization, store.workspace)
		let source = additionalSource ? store.windows[0] : store.main
		expectNoDifference(source.viewer.panes[id: peek.source.paneID]?.item.tab?.id, peek.tab.id)
	}

	private func hostAction(
		_ action: MainFeature.Action,
		additional: Bool
	) -> AppFeature.Action {
		additional ? .windows(.element(id: UUID(40), action: action)) : .main(action)
	}

	private func fixture(
		additionalSource: Bool
	) throws -> (AppFeature.State, PeekFeature.State) {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		state.main.viewer.item = .init(tab: organization.tabs[0])
		var background = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			id: UUID(40)
		)
		background.sidebar.select(organization.tabs[1].id)
		background.viewer.item = .init(tab: organization.tabs[1])

		let move = OrganizationMove(
			previous: organization,
			updated: organization,
			roots: [],
			destination: organization.spaces[0].id,
			replacements: [],
			movedTabIDs: []
		)
		state.main.sidebar.undo = [.init(before: organization)]
		state.main.sidebar.transferUndos = [move]
		background.sidebar.undo = [.init(before: organization)]
		background.sidebar.transferUndos = [move]
		state.windows.append(background)
		state.windows.append(
			.init(
				organization: organization,
				spaceID: organization.spaces[0].id,
				isPrivate: true,
				id: UUID(41)
			)
		)

		let host = additionalSource ? background : state.main
		let source = try #require(state.peekSource(windowID: host.id, paneID: host.viewer.activePaneID))
		var peek = PeekFeature.State(
			id: UUID(80),
			source: source,
			tab: .init(
				id: .init(rawValue: UUID(81)),
				profileID: organization.profiles[0].id,
				restoration: .init(title: "Promoted", url: URL(string: "https://capturecontext.dev/preview")!)
			),
			isTemporary: true
		)
		peek.phase = .releasing
		state.peeks.append(peek)
		state.peekTransitions[peek.id] = .promote(.tab)
		return (state, peek)
	}
}
