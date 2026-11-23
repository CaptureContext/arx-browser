import BrowserCore
import BrowserHistoryClient
import Foundation
import _ComposableArchitecture

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	/// Tells the history store which profiles are "this Mac only" (DEV-981), at launch and whenever
	/// that changes, so their history is neither mirrored to iCloud nor taken in from it. The store
	/// keeps the last list, so a visit before this runs is held to it too. Each handoff only asks the
	/// store to record the list: it reads the current one from the workspace document, so an older
	/// handoff arriving late can't put back an older list.
	internal func handingLocalProfilesToHistory() -> some Reducer<State, Action> {
		CombineReducers {
			onChange(of: { ProfileSync($0.workspace) }, reduce: { _, _, profiles in
				Self.setLocalProfiles(profiles)
			})
			Reduce { state, action in
				guard action.is(\.main.ui.task) else { return .none }

				return Self.setLocalProfiles(ProfileSync(state.workspace))
			}
		}
	}

	private static func setLocalProfiles(_ profiles: ProfileSync) -> Effect<Action> {
		@Dependency(\.browserHistory)
		var history

		return .run { _ in
			await history.setLocalProfiles(profiles)
		}
	}
}
