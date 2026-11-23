import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-927: a tab's Cast picker opens on the window showing it, or the one that asked, and the
/// person's choices reach the engine for that tab only.
@Suite(.dependencies)
@MainActor
internal struct CastPickerTests {
	@Test
	internal func aSitesCastButtonOpensThePickerOnItsWindow() async throws {
		let state = fixture()
		let tab = state.workspace.tabs[0].id
		let calls = CastCalls(.init())
		let store = makeStore(state, calls: calls)

		await store.send(.cast(.changed(.init(tabID: tab, picker: Self.picker)))) {
			$0.castPicker = .init(windowID: state.main.id, tabID: tab, picker: Self.picker)
		}
		var updated = Self.picker
		updated.devices[0].state = .connecting
		await store.send(.cast(.changed(.init(tabID: tab, picker: updated)))) {
			$0.castPicker?.picker = updated
		}

		// Casting started: the engine closes it.
		await store.send(.cast(.changed(.init(tabID: tab, picker: nil)))) {
			$0.castPicker = nil
		}
		expectNoDifference(calls.value.closed, [])
	}

	@Test
	internal func aPickerNoWindowShowsIsClosedAtOnce() async throws {
		let state = fixture()
		let hidden = state.workspace.tabs[1].id
		let calls = CastCalls(.init())
		let store = makeStore(state, calls: calls)

		await store.send(.cast(.changed(.init(tabID: hidden, picker: Self.picker))))
		#expect(store.state.castPicker == nil)
		expectNoDifference(calls.value.closed, [hidden])
	}

	@Test
	internal func theMediaControlsOpenItOnTheirWindowForAHiddenTab() async throws {
		let state = fixture()
		let hidden = state.workspace.tabs[1].id
		let calls = CastCalls(.init())
		let store = makeStore(state, calls: calls)

		await store.send(.cast(.open(hidden, windowID: state.main.id))) {
			$0.castPickerRequest = .init(tabID: hidden, windowID: state.main.id)
		}
		expectNoDifference(calls.value.shown, [hidden])
		await store.send(.cast(.changed(.init(tabID: hidden, picker: Self.picker)))) {
			$0.castPickerRequest = nil
			$0.castPicker = .init(windowID: state.main.id, tabID: hidden, picker: Self.picker)
		}
	}

	@Test
	internal func aTabThatCantCastLeavesNoRequest() async throws {
		let state = fixture()
		let tab = state.workspace.tabs[0].id
		let calls = CastCalls(.init())
		let store = makeStore(state, calls: calls, shows: false)

		await store.send(.cast(.open(tab, windowID: state.main.id)))
		#expect(store.state.castPickerRequest == nil)
	}

	@Test
	internal func choicesReachTheEngineForThatTab() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		state.castPicker = .init(windowID: state.main.id, tabID: tab, picker: Self.picker)
		let calls = CastCalls(.init())
		let store = makeStore(state, calls: calls)

		await store.send(.castPicker(.ui(.deviceChosen("living-room", nil))))
		await store.send(.castPicker(.ui(.deviceChosen("living-room", .tab))))

		// A device it can't cast to, or one it doesn't list, isn't sent.
		await store.send(.castPicker(.ui(.deviceChosen("kitchen", nil))))
		await store.send(.castPicker(.ui(.deviceChosen("elsewhere", nil))))
		await store.send(.castPicker(.ui(.stopButtonTapped(route: "route-1"))))
		await store.send(.castPicker(.ui(.stopButtonTapped(route: "other"))))
		await store.send(.castPicker(.ui(.doneButtonTapped)))
		await store.receive(\.castPicker.delegate.closed) {
			$0.castPicker = nil
		}

		expectNoDifference(calls.value.chosen.map(\.device), ["living-room", "living-room"])
		expectNoDifference(calls.value.chosen.map(\.mode), [nil, .tab])
		expectNoDifference(calls.value.stopped, ["route-1"])
		expectNoDifference(calls.value.closed, [tab])
	}

	@Test
	internal func anotherTabsPickerWaitsItsTurn() async throws {
		var state = fixture()
		let first = state.workspace.tabs[0].id
		let second = state.workspace.tabs[1].id
		var window = MainFeature.State(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			id: UUID(90)
		)
		window.viewer.item.tab = state.workspace.tabs[1]
		state.windows.append(window)
		state.castPicker = .init(windowID: state.main.id, tabID: first, picker: Self.picker)
		let calls = CastCalls(.init())
		let store = makeStore(state, calls: calls)

		await store.send(.cast(.changed(.init(tabID: second, picker: Self.picker))))
		#expect(store.state.castPicker?.tabID == first)
		expectNoDifference(calls.value.closed, [second])
	}

	@Test
	internal func aClosedWindowTakesItsPickerWithIt() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[1].id

		// The picker's window is gone, as when a Little Arx closes under its sheet.
		state.castPicker = .init(windowID: UUID(91), tabID: tab, picker: Self.picker)
		let calls = CastCalls(.init())
		let store = makeStore(state, calls: calls)

		await store.send(.cast(.changed(.init(tabID: state.workspace.tabs[0].id, picker: nil))))
		await store.finish()
		#expect(store.state.castPicker == nil)
		expectNoDifference(calls.value.closed, [tab])
	}

	@Test
	internal func observingNeedsAnEngineThatCasts() async throws {
		let calls = CastCalls(.init())
		let store = makeStore(fixture(), calls: calls, available: false)

		await store.send(.cast(.observe(menuTitle: "Cast…")))
		#expect(!store.state.castIsAvailable)
		expectNoDifference(calls.value.menuTitles, [])
	}

	@Test
	internal func castIsAWebPageCommand() {
		var context = BrowserCommandContext(host: .main, hasTab: true, canSavePage: true)
		#expect(BrowserCommand.castTab.isEnabled(in: context))
		context.canSavePage = false
		#expect(!BrowserCommand.castTab.isEnabled(in: context))
		context = BrowserCommandContext(host: .peek, hasTab: true, canSavePage: true)
		#expect(!BrowserCommand.castTab.isEnabled(in: context))
	}

	// MARK: - Fixture

	private static let picker = BrowserCastPicker(
		source: "Cast youtube.com",
		isSiteRequest: true,
		devices: [
			.init(id: "living-room", name: "Living Room", modes: [.presentation, .tab], route: "route-1"),
			.init(id: "kitchen", name: "Kitchen", state: .unavailable, kind: .audio, modes: []),
		]
	)

	/// The main window showing the first of two tabs in its space.
	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		state.main.viewer.item.tab = organization.tabs[0]
		return state
	}

	private func makeStore(
		_ state: AppFeature.State,
		calls: CastCalls,
		shows: Bool = true,
		available: Bool = true
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)
			$0.cast = .init(
				isAvailable: { available },
				events: { title in
					calls.withValue { $0.menuTitles.append(title) }
					return .finished
				},
				show: { id in
					calls.withValue { $0.shown.append(id) }
					return shows
				},
				choose: { id, device, mode in
					calls.withValue { $0.chosen.append((device, mode)) }
					return true
				},
				stop: { _, route in
					calls.withValue { $0.stopped.append(route) }
					return true
				},
				close: { id in calls.withValue { $0.closed.append(id) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}

private struct CastCallLog: Sendable {
	var menuTitles: [String] = []
	var shown: [BrowserCore.Tab.ID] = []
	var chosen: [(device: String, mode: BrowserCastPicker.Device.Mode?)] = []
	var stopped: [String] = []
	var closed: [BrowserCore.Tab.ID] = []
}

private typealias CastCalls = LockIsolated<CastCallLog>
