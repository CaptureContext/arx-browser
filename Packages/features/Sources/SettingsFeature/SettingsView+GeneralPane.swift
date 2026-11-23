import AppUI
import AppUpdaterClient
import BrowserCore
import DefaultBrowserClient
import SwiftUI

extension SettingsView {
	internal static var generalSearchIndex: [SettingsSearchEntry] {
		let windows = String.localized(.appUI.settings.section.windows)
		let tabs = String.localized(.appUI.settings.section.tabs)
		let search = String.localized(.appUI.settings.section.search)
		return [
			.init(
				String.localized(.appUI.settings.updates),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.updates)),
				in: .general,
				destination: .row(.general, .updates)
			),
			.init(
				String.localized(.appUI.settings.warnQuit),
				keywords: [String.localized(.appUI.settings.warnQuitExplanation)],
				in: .general,
				trail: [windows],
				destination: .row(.general, .warnBeforeQuitting)
			),
			.init(
				String.localized(.appUI.settings.hoverPreviews),
				in: .general,
				trail: [tabs],
				destination: .row(.general, .hoverPreviews)
			),
			.init(
				String.localized(.appUI.settings.showsUnreadBadges),
				keywords: [String.localized(.appUI.settings.showsUnreadBadgesDetail)],
				in: .general,
				trail: [tabs],
				destination: .row(.general, .unreadBadges)
			),
			.init(
				String.localized(.appUI.settings.newTabPlacement),
				keywords: [
					String.localized(.appUI.settings.newTabsAtTop),
					String.localized(.appUI.settings.newTabsBelowCurrent),
				],
				in: .general,
				trail: [tabs],
				destination: .row(.general, .newTabPlacement)
			),
			// DEV-1174: the row `ARX_NEW_TABS_AT_TOP` shows instead of the one above.
			.init(
				String.localized(.appUI.settings.newTabPlacement),
				keywords: [
					String.localized(.appUI.settings.newTabsAtTop),
					String.localized(.appUI.settings.newTabsBelowCurrent),
				],
				in: .general,
				trail: [tabs],
				destination: .row(.general, .openedTabPlacement)
			),
			.init(
				String.localized(.appUI.settings.switchesToLinkTabs),
				keywords: [String.localized(.appUI.settings.switchesToLinkTabsExplanation)]
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.linkTabs)),
				in: .general,
				trail: [tabs],
				destination: .row(.general, .linkTabSwitching)
			),
			.init(
				String.localized(.appUI.settings.opensEmptyPageAtLaunch),
				keywords: [String.localized(.appUI.settings.opensEmptyPageAtLaunchExplanation)]
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.emptyPageAtLaunch)),
				in: .general,
				trail: [tabs],
				destination: .row(.general, .emptyPageAtLaunch)
			),
			.init(
				String.localized(.appUI.settings.unloadedSiteIcons),
				keywords: [
					String.localized(.appUI.settings.unloadedSiteIconsExplanation),
					String.localized(.appUI.settingsSearch.keywords.favicons),
				],
				in: .general,
				trail: [tabs],
				destination: .row(.general, .unloadedSiteIcons)
			),
			.init(
				String.localized(.appUI.settings.tabUnloading),
				keywords: [String.localized(.appUI.settings.tabUnloadingExplanation)]
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.tabUnloading)),
				in: .general,
				trail: [tabs],
				destination: .row(.general, .tabUnloading)
			),
			.init(
				String.localized(.appUI.settings.batterySaver),
				keywords: [String.localized(.appUI.settings.batterySaverExplanation)]
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.batterySaver)),
				in: .general,
				trail: [tabs],
				destination: .row(.general, .batterySaver)
			),
			.init(
				String.localized(.appUI.settings.asksBeforeFillingPasswords),
				keywords: [
					String.localized(.appUI.settings.asksBeforeFillingPasswordsExplanation),
					String.localized(.appUI.settings.section.autofill),
					String.localized(.appUI.settings.fillsAddresses),
					String.localized(.appUI.settings.fillsPaymentCards),
				],
				in: .general,
				trail: [String.localized(.appUI.settings.section.autofill)],
				destination: .row(.general, .autofillAuthentication)
			),
			.init(
				String.localized(.appUI.settings.contentBlocking),
				keywords: [
					String.localized(.appUI.settings.section.contentBlocking),
					String.localized(.appUI.settings.blockCookieBanners),
					String.localized(.appUI.settingsSearch.keywords.adBlocking),
				],
				in: .general,
				trail: [String.localized(.appUI.settings.section.contentBlocking)],
				destination: .row(.general, .contentBlocking)
			),
			.init(
				String.localized(.appUI.settings.previews),
				keywords: [
					String.localized(.appUI.settings.folderPreviews),
					String.localized(.appUI.settings.mailPreviews),
					String.localized(.appUI.settings.recentPreviews),
					String.localized(.appUI.settings.pageDetailsPreviews),
					String.localized(.appUI.settings.fullPreviews),
					// DEV-1142's choice, under `ARX_SITE_PREVIEW_IMAGES`.
					String.localized(.appUI.settings.unloadedPreviewSitePicture),
					String.localized(.appUI.settings.unloadedPreviewLoadPage),
					String.localized(.appUI.settings.shiftHoverLoadsPages),
				],
				in: .general,
				trail: [tabs],
				destination: .panel(.previews, .previews)
			),
			.init(
				String.localized(.appUI.settings.section.pictureInPicture),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.pictureInPicture))
					+ [String.localized(.appUI.settings.pipAutomatic), String.localized(.appUI.settings.pipClosesOnReturn)],
				in: .general,
				destination: .row(.general, .pictureInPicture)
			),
			.init(
				String.localized(.appUI.settings.bangs),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.searchShortcuts)),
				in: .general,
				trail: [search],
				destination: .page(.searchShortcuts)
			),
			.init(
				String.localized(.appUI.settings.section.setupGuide),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.setupGuide)),
				in: .general,
				destination: .row(.general, .setupGuide)
			),
		] + (PageTranslationFeatureFlag.isEnabled() ? [
			.init(
				String.localized(.appUI.settings.section.translation),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.translation)),
				in: .general,
				destination: .row(.general, .translation)
			),
		] : [])
	}

	internal var generalPane: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			updatesSection

			// Each explanation sits on its own row, not under the whole card (DEV-1241).
			SettingsSection(String.localized(.appUI.settings.section.windows)) {
				SettingsToggle(
					String.localized(.appUI.settings.warnQuit),
					detail: String.localized(.appUI.settings.warnQuitExplanation),
					isOn: Binding(
						get: { store.general.warnsBeforeQuitting },
						set: { store.send(.ui(.warnsBeforeQuitting($0))) }
					)
				)
				.settingsAnchor(.warnBeforeQuitting)

				// DEV-922: the front window's page on this person's iPhone, iPad and other Macs.
				// DEV-885: off does what Chrome does.
				SettingsToggle(
					String.localized(.appUI.settings.notificationsOpenClosedSites),
					detail: String.localized(.appUI.settings.notificationsOpenClosedSitesExplanation),
					isOn: Binding(
						get: { store.general.notificationsOpenClosedSites },
						set: { store.send(.ui(.notificationsOpenClosedSites($0))) }
					)
				)
				SettingsToggle(
					String.localized(.appUI.settings.handoff),
					detail: String.localized(.appUI.settings.handoffExplanation),
					isOn: Binding(
						get: { store.general.handoffEnabled },
						set: { store.send(.ui(.handoffEnabled($0))) }
					)
				)
			}
			SettingsSection(String.localized(.appUI.settings.section.tabs)) {
				SettingsToggle(
					String.localized(.appUI.settings.hoverPreviews),
					detail: String.localized(.appUI.settings.hoverPreviewsExplanation),
					isOn: Binding(
						get: { store.general.hoverPreviewsEnabled },
						set: { store.send(.ui(.hoverPreviewsEnabled($0))) }
					)
				)
				.settingsAnchor(.hoverPreviews)
				SettingsRow(String.localized(.appUI.settings.previews)) {
					Button(String.localized(.appUI.settings.previewsButton)) {
						store.send(.ui(.panelPresented(.previews)))
					}
				}
				.settingsAnchor(.previews)
				SettingsToggle(
					String.localized(.appUI.settings.unloadedSiteIcons),
					detail: String.localized(.appUI.settings.unloadedSiteIconsExplanation),
					isOn: Binding(
						get: { store.general.fetchesUnloadedSiteIcons },
						set: { store.send(.ui(.fetchesUnloadedSiteIcons($0))) }
					)
				)
				.settingsAnchor(.unloadedSiteIcons)
				tabUnloadDelayRow
					.settingsAnchor(.tabUnloading)

				// DEV-1174: with `ARX_NEW_TABS_AT_TOP` on, the New Tab button, ⌘T and ⌘K have a row of
				// their own. Tabs links open follow their opener either way (DEV-1243).
				if store.newTabsAtTopAvailable {
					SettingsTabPlacementRow(
						String.localized(.appUI.settings.newTabPlacement),
						selection: Binding(
							get: { store.general.openedTabPlacement },
							set: { store.send(.ui(.openedTabPlacement($0))) }
						)
					)
					.settingsAnchor(.openedTabPlacement)
				} else {
					SettingsTabPlacementRow(
						String.localized(.appUI.settings.newTabPlacement),
						selection: Binding(
							get: { store.general.newTabPlacement },
							set: { store.send(.ui(.newTabPlacement($0))) }
						)
					)
					.settingsAnchor(.newTabPlacement)
				}
				SettingsToggle(
					String.localized(.appUI.settings.switchesToLinkTabs),
					detail: String.localized(.appUI.settings.switchesToLinkTabsExplanation),
					isOn: Binding(
						get: { store.general.switchesToLinkTabs },
						set: { store.send(.ui(.switchesToLinkTabs($0))) }
					)
				)
				.settingsAnchor(.linkTabSwitching)

				// DEV-1234: read once, when Arx opens.
				SettingsToggle(
					String.localized(.appUI.settings.opensEmptyPageAtLaunch),
					detail: String.localized(.appUI.settings.opensEmptyPageAtLaunchExplanation),
					isOn: Binding(
						get: { store.general.opensEmptyPageAtLaunch },
						set: { store.send(.ui(.opensEmptyPageAtLaunch($0))) }
					)
				)
				.settingsAnchor(.emptyPageAtLaunch)
				unreadBadgesRow
				SettingsBatterySaverRow(store: store)
			}

			// DEV-996: behind the `ARX_TRANSLATE` feature flag.
			if PageTranslationFeatureFlag.isEnabled() {
				SettingsTranslationSection(store: store)
			}
			SettingsSection(String.localized(.appUI.settings.section.autofill)) {
				SettingsToggle(
					String.localized(.appUI.settings.asksBeforeFillingPasswords),
					detail: String.localized(.appUI.settings.asksBeforeFillingPasswordsExplanation),
					isOn: Binding(
						get: { store.general.asksBeforeFillingPasswords },
						set: { store.send(.ui(.asksBeforeFillingPasswords($0))) }
					)
				)
				.settingsAnchor(.autofillAuthentication)
				SettingsToggle(
					String.localized(.appUI.settings.fillsAddresses),
					isOn: Binding(
						get: { store.general.fillsAddresses },
						set: { store.send(.ui(.fillsAddresses($0))) }
					)
				)
				SettingsToggle(
					String.localized(.appUI.settings.fillsPaymentCards),
					detail: String.localized(.appUI.settings.fillsPaymentCardsExplanation),
					isOn: Binding(
						get: { store.general.fillsPaymentCards },
						set: { store.send(.ui(.fillsPaymentCards($0))) }
					)
				)
			}
			if store.contentBlockingAvailable {
				contentBlockingSection
			}
			SettingsSection(
				String.localized(.appUI.settings.section.pictureInPicture),
				footer: String.localized(.appUI.settings.pipExplanation)
			) {
				SettingsToggle(
					String.localized(.appUI.settings.pipAutomatic),
					isOn: Binding(
						get: { store.automaticPictureInPicture.isEnabled },
						set: { store.send(.ui(.automaticPictureInPicture($0))) }
					)
				)
				SettingsToggle(
					String.localized(.appUI.settings.pipClosesOnReturn),
					isOn: Binding(
						get: { store.automaticPictureInPicture.closesOnReturn },
						set: { store.send(.ui(.closesPictureInPictureOnReturn($0))) }
					)
				)
			}
			.settingsAnchor(.pictureInPicture)
			SettingsSection(
				String.localized(.appUI.settings.section.commandBar),
				footer: String.localized(.appUI.settings.closeOnEmptyDeleteExplanation)
			) {
				SettingsToggle(
					String.localized(.appUI.settings.closeOnEmptyDelete),
					isOn: Binding(
						get: { store.general.closesCommandBarOnEmptyDelete },
						set: { store.send(.ui(.closesCommandBarOnEmptyDelete($0))) }
					)
				)
			}
			SettingsSection(
				String.localized(.appUI.settings.section.search),
				footer: String.localized(.appUI.settings.bangsDescription)
			) {
				pageRow(.searchShortcuts)
			}
			onboardingSection
		}
	}

	/// Reopens onboarding where it left off, or opens one of its steps on its own.
	private var onboardingSection: some View {
		SettingsSection(String.localized(.appUI.settings.section.setupGuide)) {
			SettingsRow(String.localized(.appUI.settings.onboarding)) {
				Menu(String.localized(.appUI.settings.onboardingStep)) {
					ForEach(onboardingSteps, id: \.self) { step in
						Button(step.title) { openOnboarding(step) }
					}
				}
				.fixedSize()
				.disabled(onboardingSteps.isEmpty)
				Button(String.localized(.appUI.settings.onboardingOpen)) {
					openOnboarding(nil)
				}
			}
		}
		.settingsAnchor(.setupGuide)
	}
}
