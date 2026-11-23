import AppUI
import BrowserCore
import BrowserEngineClient
import SwiftUI
import _ComposableArchitecture

/// Site Settings' Devices (DEV-905): every device a site in the profile may use, with Forget.
internal struct SiteSettingsDevicesSection: View {
	private let store: StoreOf<SiteSettingsFeature>

	internal init(store: StoreOf<SiteSettingsFeature>) {
		self.store = store
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(localized: .appUI.siteSettings.devices)
				.font(SettingsTypography.heading)
			Text(localized: .appUI.siteSettings.devicesCaption)
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
			SettingsCard {
				if store.devices.isEmpty {
					Text(localized: .appUI.siteSettings.noDevices)
						.foregroundStyle(.secondary)
				} else {
					ForEach(store.devices) { device in
						HStack {
							VStack(alignment: .leading, spacing: 2) {
								Text(device.name)
								Text(device.origin)
									.font(SettingsTypography.caption)
									.foregroundStyle(.secondary)
							}
							Spacer(minLength: 16)
							Button(String.localized(.appUI.siteSettings.forgetDevice)) {
								store.send(.ui(.forgetDevice(device.id)))
							}
						}
					}
				}
			}
		}
	}
}
