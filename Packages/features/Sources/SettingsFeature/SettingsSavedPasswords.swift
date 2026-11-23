import BrowserCore
import _ComposableArchitecture

/// Opens one ordinary profile's saved passwords from its Profiles page (DEV-721).
/// Only profiles Settings lists can open it; private profiles never appear there.
@Reducer
internal struct SettingsSavedPasswords {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.showSavedPasswords) { state, id in
			guard let profile = state.extensionProfiles.first(where: { $0.id == id })
			else { return .none }

			state.savedPasswords = .init(profileID: profile.id, profileName: profile.name)
			return .none
		}

		Pullback(\.ui.savedPasswordsPresented) { state, isPresented in
			guard !isPresented else { return .none }

			state.savedPasswords = nil
			return .none
		}

		Pullback(\.savedPasswords.delegate.dismiss) { state in
			state.savedPasswords = nil
			return .none
		}

		// A profile's addresses and payment cards (DEV-893), the same way.
		Pullback(\.ui.showAutofill) { state, id in
			guard let profile = state.extensionProfiles.first(where: { $0.id == id })
			else { return .none }

			state.autofillData = .init(profileID: profile.id, profileName: profile.name)
			return .none
		}

		Pullback(\.ui.autofillPresented) { state, isPresented in
			guard !isPresented else { return .none }

			state.autofillData = nil
			return .none
		}

		Pullback(\.autofillData.delegate.dismiss) { state in
			state.autofillData = nil
			return .none
		}

		// A profile that went away takes its passwords sheet with it.
		Pullback(\.configureExtensions) { state, profiles in
			if let id = state.autofillData?.profileID, !profiles.contains(where: { $0.id == id }) {
				state.autofillData = nil
			}
			guard
				let id = state.savedPasswords?.profileID,
				!profiles.contains(where: { $0.id == id })
			else { return .none }

			state.savedPasswords = nil
			return .none
		}
	}
}
