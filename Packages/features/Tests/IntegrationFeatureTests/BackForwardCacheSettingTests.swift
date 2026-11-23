import CustomDump
import Foundation
import Testing
import _ComposableArchitecture

@testable import SettingsFeature

/// DEV-943: Settings › Advanced › Memory › Pages kept for Back and Forward. The engine reads the
/// number at launch from Arx's defaults, under its feature flag's name.
@Suite(.dependencies)
@MainActor
internal struct BackForwardCacheSettingTests {
	private let defaults: UserDefaults = .init(suiteName: "BackForwardCacheSettingTests.\(UUID())")!

	@Test
	internal func theDefaultIsThreePages() async throws {
		let state = state()

		expectNoDifference(state.backForwardCachePages, 3)
		expectNoDifference(state.backForwardCachePagesAtLaunch, 3)

		// Sharing writes the default; the engine's own default is the same.
		#expect([nil, "3"].contains(defaults.string(forKey: "ARX_BACK_FORWARD_CACHE_SIZE")))
	}

	@Test
	internal func choosingANumberSavesItForTheEngineFromTheNextLaunch() async throws {
		let store = store(state())

		await store.send(.ui(.backForwardCachePages(0)))
		expectNoDifference(store.state.backForwardCachePages, 0)

		// The engine reads it as a string (`stringForKey:` turns numbers into strings).
		expectNoDifference(defaults.string(forKey: "ARX_BACK_FORWARD_CACHE_SIZE"), "0")

		// This run keeps the number it started with.
		expectNoDifference(store.state.backForwardCachePagesAtLaunch, 3)

		await store.send(.ui(.backForwardCachePages(6)))
		expectNoDifference(defaults.string(forKey: "ARX_BACK_FORWARD_CACHE_SIZE"), "6")
	}

	@Test(arguments: [-1, 7, 100])
	internal func numbersOutsideTheRangeAreIgnored(_ count: Int) async throws {
		let store = store(state())

		await store.send(.ui(.backForwardCachePages(count)))

		expectNoDifference(store.state.backForwardCachePages, 3)
		#expect([nil, "3"].contains(defaults.string(forKey: "ARX_BACK_FORWARD_CACHE_SIZE")))
	}

	@Test
	internal func aRunStartsWithTheSavedNumber() async throws {
		defaults.set(1, forKey: "ARX_BACK_FORWARD_CACHE_SIZE")

		let state = state()

		expectNoDifference(state.backForwardCachePages, 1)
		expectNoDifference(state.backForwardCachePagesAtLaunch, 1)
	}

	private func state() -> SettingsFeature.State {
		withDependencies {
			$0.defaultAppStorage = defaults
		} operation: {
			SettingsFeature.State()
		}
	}

	private func store(_ state: SettingsFeature.State) -> TestStoreOf<SettingsFeature> {
		let store = TestStore(initialState: state) { SettingsFeature() } withDependencies: {
			$0.defaultAppStorage = defaults
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
