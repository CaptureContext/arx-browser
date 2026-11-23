import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

internal struct SettingsHistoryView: View {
	internal let store: StoreOf<SettingsFeature>
	internal let profile: Profile

	internal init(
		store: StoreOf<SettingsFeature>,
		profile: Profile
	) {
		self.store = store
		self.profile = profile
	}

	internal var body: some View {
		let status = store.historyStatus[profile.id]
		SettingsSection(
			String.localized(.appUI.history.title),
			footer: String.localized(.appUI.history.description)
		) {
			SettingsRow(String.localized(.appUI.history.clear), detail: errorText(status)) {
				if status?.isWorking == true { ProgressView().controlSize(.small) }
				if status?.error != nil {
					Button(String.localized(.appUI.history.retry)) {
						store.send(.ui(.retryHistory(profile.id)))
					}
				}
				Button(String.localized(.appUI.history.clear), role: .destructive) {
					store.send(.ui(.requestClearHistory(profile.id)))
				}
				.disabled(status?.isWorking == true)
			}
		}
		.confirmationDialog(
			String.localized(.appUI.history.clear),
			isPresented: Binding(
				get: { store.pendingHistoryClearID == profile.id },
				set: { if !$0 { store.send(.ui(.cancelClearHistory)) } }
			),
			titleVisibility: .visible
		) {
			Button(String.localized(.appUI.history.clear), role: .destructive) {
				store.send(.ui(.confirmClearHistory))
			}
		} message: {
			Text(profile.name + "\n" + String.localized(.appUI.history.clearMessage))
		}
	}

	/// Why loading or clearing history failed, if it did.
	private func errorText(_ status: HistoryStatus?) -> String? {
		[status?.error, store.historyRemovalError].compactMap(\.self).first
	}
}
