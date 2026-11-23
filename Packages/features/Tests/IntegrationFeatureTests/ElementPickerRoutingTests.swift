@testable import AppFeature
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1201: Hide Element opens uBlock Origin's picker while Arx's own is off or the engine
/// hasn't got it. Arx's own, now Hide Element's mode, is in `HideElementFeatureTests` (DEV-1298).
@Suite(.dependencies)
@MainActor
internal struct ElementPickerRoutingTests {
	private func state(elementPickerEnabled: Bool) -> AppFeature.State {
		var organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let shown = organization.tabs[0]
		state.main.sidebar.organization.spaces[0].selectedTabID = shown.id
		state.main.viewer.item.tab = shown
		state.main.viewer.item.navigation = .init(url: URL(string: "https://capturecontext.dev/arx")!)
		state.hideElementEnabled = true
		state.elementPickerEnabled = elementPickerEnabled
		return state
	}

	private final class Engine: Sendable {
		let picks = LockIsolated<[BrowserCore.Tab.ID]>([])
		let accents = LockIsolated<[ChromePalette.RGB]>([])
		let uBlockPicks = LockIsolated<[BrowserCore.Tab.ID]>([])
		let available: Bool
		let outcome: BrowserElementPick

		init(
			available: Bool,
			outcome: BrowserElementPick = .hidden(filter: "capturecontext.dev##aside")
		) {
			self.available = available
			self.outcome = outcome
		}

		var client: BrowserEngineClient {
			var client = BrowserEngineClient(status: { .ready })
			client.elementPickerIsAvailable = { [available] in available }
			client.pickElement = { [picks, accents, outcome] (id: BrowserCore.Tab.ID, accent: ChromePalette.RGB) in
				picks.withValue { $0.append(id) }
				accents.withValue { $0.append(accent) }
				return outcome
			}
			client.startElementPicker = { [uBlockPicks] (id: BrowserCore.Tab.ID) in
				uBlockPicks.withValue { $0.append(id) }
				return true
			}
			return client
		}
	}

	@Test(arguments: [(flag: false, available: true), (flag: true, available: false)])
	internal func otherwiseHideElementOpensUBlocksPicker(flag: Bool, available: Bool) async throws {
		let state = state(elementPickerEnabled: flag)
		let engine = Engine(available: available)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine.client
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.command(.hideElement, .window(state.main.id))))
		await store.finish()

		let tab = try #require(state.main.viewer.item.tab)
		expectNoDifference(engine.picks.value, [])
		expectNoDifference(engine.uBlockPicks.value, [tab.id])
	}
}
