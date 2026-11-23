import AppUI
import AppUpdaterClient
import BrowserCore
import DefaultBrowserClient
import SwiftUI

extension SettingsView {
	internal static var developerSearchIndex: [SettingsSearchEntry] {
		[
			.init(
				String.localized(.appUI.developer.mode),
				keywords: [String.localized(.appUI.developer.shortcut)],
				in: .developer,
				destination: .row(.developer, .developerMode)
			),
			.init(
				String.localized(.appUI.developer.headerSetting),
				in: .developer,
				destination: .row(.developer, .developerHeader)
			),
			.init(
				String.localized(.appUI.developer.localTabsSetting),
				keywords: [String.localized(.appUI.developer.localTabsSettingExplanation)],
				in: .developer,
				destination: .row(.developer, .localTabHighlight)
			),
		]
	}

	internal var developerPane: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			SettingsSection(footer: String.localized(.appUI.developer.safety)) {
				SettingsToggle(
					String.localized(.appUI.developer.mode),
					detail: String.localized(.appUI.developer.modeExplanation),
					isOn: Binding(
						get: { store.general.developerModeEnabled },
						set: { store.send(.ui(.developerModeEnabled($0))) }
					)
				)
				.settingsAnchor(.developerMode)
				SettingsToggle(
					String.localized(.appUI.developer.headerSetting),
					detail: String.localized(.appUI.developer.headerSettingExplanation),
					isOn: Binding(
						get: { store.general.developerHeaderEnabled },
						set: { store.send(.ui(.developerHeaderEnabled($0))) }
					)
				)
				.disabled(!store.general.developerModeEnabled)
				.settingsAnchor(.developerHeader)

				// DEV-909: off by default, and only in developer mode.
				SettingsToggle(
					String.localized(.appUI.developer.appleScriptJavaScript),
					detail: String.localized(.appUI.developer.appleScriptJavaScriptExplanation),
					isOn: Binding(
						get: { store.general.developerModeEnabled && store.general.appleScriptJavaScriptEnabled },
						set: { store.send(.ui(.appleScriptJavaScriptEnabled($0))) }
					)
				)
				.disabled(!store.general.developerModeEnabled)
				SettingsToggle(
					String.localized(.appUI.developer.localTabsSetting),
					detail: String.localized(.appUI.developer.localTabsSettingExplanation),
					isOn: Binding(
						get: { store.general.localTabHighlightEnabled },
						set: { store.send(.ui(.localTabHighlightEnabled($0))) }
					)
				)
				.settingsAnchor(.localTabHighlight)
				if let shortcut = shortcuts.first(where: { $0.id == "developerTools" }) {
					SettingsRow(String.localized(.appUI.developer.shortcut)) {
						Text(shortcut.keys).font(.body.monospaced())
					}
				}
			}
			SettingsSection {
				SettingsRow(
					String.localized(.appUI.developer.reloadTitle),
					detail: String.localized(.appUI.developer.reloadExplanation)
				) {}
				SettingsRow(
					String.localized(.appUI.developer.localTitle),
					detail: String.localized(.appUI.developer.localExplanation)
				) {}
			}
			if store.general.developerModeEnabled {
				securityDataSection
			}
		}
	}

	/// The security components the engine keeps updating and their versions (DEV-874).
	private var securityDataSection: some View {
		SettingsSection(
			String.localized(.appUI.developer.securityDataTitle),
			caption: String.localized(.appUI.developer.securityDataCaption)
		) {
			ForEach(store.securityComponents ?? []) { component in
				SettingsRow(
					component.kind.title,
					detail: component.versionText
				) {}
			}
		}
		.task { store.send(.ui(.loadSecurityComponents)) }
	}
}
