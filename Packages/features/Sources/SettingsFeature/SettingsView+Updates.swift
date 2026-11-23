import AppUI
import AppUpdaterClient
import BrowserCore
import DefaultBrowserClient
import SwiftUI

extension SettingsView {
	/// DEV-884: Helium's uBlock Origin, which Arx turns on and off for every profile.
	internal var contentBlockingSection: some View {
		SettingsSection(
			String.localized(.appUI.settings.section.contentBlocking),
			footer: String.localized(.appUI.settings.contentBlockingExplanation)
		) {
			SettingsToggle(
				String.localized(.appUI.settings.contentBlocking),
				isOn: Binding(
					get: { store.general.blocksContent },
					set: { store.send(.ui(.blocksContent($0))) }
				)
			)
			.settingsAnchor(.contentBlocking)
			SettingsToggle(
				String.localized(.appUI.settings.blockCookieBanners),
				detail: String.localized(.appUI.settings.blockCookieBannersExplanation),
				isOn: Binding(
					get: { store.general.blocksCookieBanners },
					set: { store.send(.ui(.blocksCookieBanners($0))) }
				)
			)
			.disabled(!store.general.blocksContent)
			SettingsRow(String.localized(.appUI.settings.contentBlockingDashboard)) {
				Button(String.localized(.appUI.settings.contentBlockingDashboardButton)) {
					store.send(.ui(.openContentBlockingDashboard))
				}
				.disabled(!store.general.blocksContent)
			}
		}
	}

	/// Check Now, the last check, and Sparkle's automatic check and download settings.
	/// In a build that can't update, a single row says why.
	@ViewBuilder
	internal var updatesSection: some View {
		// The row is titled Updates, so the section has no title of its own (DEV-1241).
		SettingsSection(footer: String.localized(.appUI.settings.updatesDescription)) {
			SettingsRow(String.localized(.appUI.settings.updates), detail: updatesStatusText) {
				if store.updates?.isChecking == true {
					ProgressView()
						.controlSize(.small)
						.accessibilityLabel(Text(localized: .appUI.settings.updatesChecking))
				}
				if store.updates?.isReadyToInstall == true {
					Button(String.localized(.appUI.settings.updatesInstallNow)) {
						store.send(.ui(.installUpdate))
					}
				} else if store.updates?.isAvailable == true {
					Button(String.localized(.appUI.settings.updatesCheckNow)) {
						store.send(.ui(.checkForUpdates))
					}
					.disabled(store.updates?.canCheck != true)
				}
			}
			.settingsAnchor(.updates)
			if store.updates?.isAvailable == true {
				SettingsToggle(
					String.localized(.appUI.settings.updatesAutomaticChecks),
					isOn: Binding(
						get: { store.updates?.automaticallyChecks == true },
						set: { store.send(.ui(.automaticallyChecksForUpdates($0))) }
					)
				)
				SettingsToggle(
					String.localized(.appUI.settings.updatesAutomaticDownloads),
					detail: String.localized(.appUI.settings.updatesAutomaticDownloadsDetail),
					isOn: Binding(
						get: { store.updates?.automaticallyDownloads == true },
						set: { store.send(.ui(.automaticallyDownloadsUpdates($0))) }
					)
				)
				.disabled(store.updates?.automaticallyChecks != true)
				if store.updates?.offersBeta == true {
					SettingsRow(
						String.localized(.appUI.settings.updatesChannel),
						detail: String.localized(.appUI.settings.updatesChannelDetail)
					) {
						Picker(
							String.localized(.appUI.settings.updatesChannel),
							selection: Binding(
								get: { store.updates?.channel ?? .stable },
								set: { store.send(.ui(.updateChannel($0))) }
							)
						) {
							Text(localized: .appUI.settings.updatesChannelStable).tag(AppUpdaterClient.Channel.stable)
							Text(localized: .appUI.settings.updatesChannelBeta).tag(AppUpdaterClient.Channel.beta)
						}
						.labelsHidden()
						.fixedSize()
					}
				}
			}
		}
	}

	private var updatesStatusText: String {
		guard let updates = store.updates
		else { return String.localized(.appUI.settings.updatesNotSetUp) }

		switch updates.availability {
		case .unavailable(.debugBuild):
			return String.localized(.appUI.settings.updatesDevelopmentBuild)

		case .unavailable:
			return String.localized(.appUI.settings.updatesNotSetUp)

		case .available:
			if updates.isReadyToInstall {
				return String.localized(.appUI.settings.updatesReadyToInstall)
			}
			if updates.isChecking {
				return String.localized(.appUI.settings.updatesChecking)
			}
			guard let lastCheck = updates.lastCheck
			else { return String.localized(.appUI.settings.updatesNeverChecked) }

			return String.localized(
				.appUI.settings.updatesLastChecked(lastCheck.formatted(date: .abbreviated, time: .shortened))
			)
		}
	}
}
