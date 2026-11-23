import BrowserCore
import CustomDump
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Routes to a profile's most recent space read `recentSpaceIDs`, which follows the space in front.
@Suite(.dependencies)
@MainActor
internal struct RecentSpacesTests {
	@Test
	internal func theSpaceLeftCountsEvenIfItWasOpenSinceLaunch() async {
		let organization = IntegrationFeatureTests().fixture()
		let first = organization.spaces[0].id
		let second = organization.spaces[1].id

		// Restored at launch in the second space: nothing has been recorded yet.
		let state = AppFeature.State(main: .init(organization: organization, spaceID: second))
		let store = TestStore(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, _ in
				state.main.sidebar.selectSpace(first)
				return .none
			}
			.recordingRecentSpaces()
		}
		await store.send(.processRouteQueue) {
			$0.main.sidebar.selectSpace(first)
			$0.recentSpaceIDs = [first, second]
		}
	}
}
