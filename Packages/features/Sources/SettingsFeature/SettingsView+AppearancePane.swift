import AppUI
import AppUpdaterClient
import BrowserCore
import DefaultBrowserClient
import SwiftUI

extension SettingsView {
	internal static var appearanceSearchIndex: [SettingsSearchEntry] {
		[
			.init(
				String.localized(.appUI.appearance.theme),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.theme)),
				in: .appearance,
				destination: .row(.appearance, .theme)
			),
			.init(
				String.localized(.appUI.darkPages.setting),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.darkPages))
					+ [
						String.localized(.appUI.darkPages.withTheme),
						String.localized(.appUI.darkPages.always),
					],
				in: .appearance,
				destination: .row(.appearance, .darkPages)
			),
			.init(
				String.localized(.appUI.appearance.windowBackground),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.windowBackground)),
				in: .appearance,
				destination: .row(.appearance, .windowBackground)
			),
			.init(
				String.localized(.appUI.appearance.matchSite),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.matchSite)),
				in: .appearance,
				trail: [String.localized(.appUI.appearance.windowBackground)],
				destination: .row(.appearance, .matchSite)
			),
			.init(
				String.localized(.appUI.settings.sidebarPosition),
				keywords: [
					String.localized(.appUI.settings.section.sidebar),
					String.localized(.appUI.settings.sidebarLeft),
					String.localized(.appUI.settings.sidebarRight),
				],
				in: .appearance,
				trail: [String.localized(.appUI.settings.section.sidebar)],
				destination: .row(.appearance, .sidebarPosition)
			),
			.init(
				String.localized(.appUI.settings.section.sound),
				keywords: [String.localized(.appUI.settings.sound)],
				in: .appearance,
				destination: .row(.appearance, .sound)
			),
			.init(
				String.localized(.appUI.settings.icon),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.appIcon)),
				in: .appearance,
				destination: .row(.appearance, .appIcon)
			),
		]
	}

	/// Dark pages (DEV-1020), while their feature flag is on and the engine has them.
	private var darkPagesSection: some View {
		SettingsSection(
			String.localized(.appUI.darkPages.setting),
			footer: String.localized(.appUI.darkPages.explanation)
		) {
			SettingsRow(String.localized(.appUI.darkPages.setting)) {
				Picker(
					String.localized(.appUI.darkPages.setting),
					selection: Binding(
						get: { store.general.darkPages },
						set: { store.send(.ui(.darkPages($0))) }
					)
				) {
					Text(localized: .appUI.darkPages.off).tag(DarkPagesMode.off)
					Text(localized: .appUI.darkPages.withTheme).tag(DarkPagesMode.withTheme)
					Text(localized: .appUI.darkPages.always).tag(DarkPagesMode.always)
				}
				.pickerStyle(.menu)
				.labelsHidden()
				.fixedSize()
			}
		}
	}

	internal var appearancePane: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			AppThemePicker(
				selection: store.general.appTheme,
				chromeAppearance: store.chromeAppearance,
				select: { store.send(.ui(.appTheme($0))) }
			)
			.settingsAnchor(.theme)
			if store.darkPagesAvailable {
				darkPagesSection
					.settingsAnchor(.darkPages)
			}
			AppearanceSettingsSection(store: store)
				.settingsAnchor(.windowBackground)
			SettingsSection(String.localized(.appUI.settings.section.sidebar)) {
				SettingsRow(String.localized(.appUI.settings.sidebarPosition)) {
					Picker(
						String.localized(.appUI.settings.sidebarPosition),
						selection: Binding(
							get: { store.general.sidebarPosition },
							set: { store.send(.ui(.sidebarPosition($0))) }
						)
					) {
						Text(localized: .appUI.settings.sidebarLeft).tag(SidebarPosition.left)
						Text(localized: .appUI.settings.sidebarRight).tag(SidebarPosition.right)
					}
					.pickerStyle(.segmented)
					.labelsHidden()
					.fixedSize()
				}
			}
			.settingsAnchor(.sidebarPosition)
			SettingsSection(
				String.localized(.appUI.settings.section.sound),
				footer: String.localized(.appUI.settings.soundsExplanation)
			) {
				SettingsToggle(
					String.localized(.appUI.settings.sound),
					isOn: Binding(
						get: { store.general.soundsEnabled },
						set: { store.send(.ui(.soundsEnabled($0))) }
					)
				)
			}
			.settingsAnchor(.sound)
			ApplicationIconSection(
				selection: store.general.appIcon,
				select: { store.send(.ui(.appIcon($0))) }
			)
				.settingsAnchor(.appIcon)
		}
	}
}
