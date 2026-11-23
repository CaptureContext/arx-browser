import BrowserCore
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

@Suite(.dependencies)
@MainActor
internal struct IdentityCardSettingsTests {
	@Test
	internal func cyclingMovesToTheNextStyleAndSavesIt() async {
		let state = SettingsFeature.State()
		state.$general.withLock { $0.identityCardStyle = .sunsetGrain }
		let store = TestStore(initialState: state) { SettingsFeature() }

		// A shared key: AppFeature saves the change.
		await store.send(.ui(.cycleIdentityCardStyle)) {
			$0.$general.withLock { $0.identityCardStyle = .memberPass }
		}

		// The last style wraps back to the first.
		await store.send(.ui(.cycleIdentityCardStyle)) {
			$0.$general.withLock { $0.identityCardStyle = .holographicFoil }
		}
	}
}
