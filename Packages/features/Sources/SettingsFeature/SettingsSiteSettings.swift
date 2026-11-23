import BrowserCore
import _ComposableArchitecture

/// Opens one ordinary profile's site permissions and zoom from its Profiles page
/// (DEV-716). Only profiles Settings lists can open it; private profiles never appear there.
@Reducer
internal struct SettingsSiteSettings {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.showSiteSettings) { state, id in
			guard let profile = state.extensionProfiles.first(where: { $0.id == id })
			else { return .none }

			state.siteSettings = .init(profileID: profile.id, profileName: profile.name)
			return .none
		}

		Pullback(\.ui.siteSettingsPresented) { state, isPresented in
			guard !isPresented else { return .none }

			state.siteSettings = nil
			return .none
		}

		Pullback(\.siteSettings.delegate.dismiss) { state in
			state.siteSettings = nil
			return .none
		}

		// A profile that went away takes its site settings sheet with it.
		Pullback(\.configureExtensions) { state, profiles in
			guard
				let id = state.siteSettings?.profileID,
				!profiles.contains(where: { $0.id == id })
			else { return .none }

			state.siteSettings = nil
			return .none
		}
	}
}
