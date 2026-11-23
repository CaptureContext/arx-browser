import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// The Battery Saver picker, under tab unloading.
internal struct SettingsBatterySaverRow: View {
	private let store: StoreOf<SettingsFeature>

	internal init(store: StoreOf<SettingsFeature>) {
		self.store = store
	}

	internal var body: some View {
		SettingsRow(
			String.localized(.appUI.settings.batterySaver),
			detail: String.localized(.appUI.settings.batterySaverExplanation)
		) {
			Picker(
				String.localized(.appUI.settings.batterySaver),
				selection: Binding(
					get: { store.batterySaver },
					set: { store.send(.ui(.batterySaverMode($0))) }
				)
			) {
				ForEach(BatterySaverMode.allCases, id: \.self) { mode in
					Text(mode.title).tag(mode)
				}
			}
			.labelsHidden()
			.fixedSize()
		}
		.settingsAnchor(.batterySaver)
	}
}

extension BatterySaverMode {
	fileprivate var title: String {
		switch self {
		case .whenBatteryLow: String.localized(.appUI.settings.batterySaverWhenBatteryLow)
		case .whenUnplugged: String.localized(.appUI.settings.batterySaverWhenUnplugged)
		case .never: String.localized(.appUI.settings.batterySaverNever)
		}
	}
}
