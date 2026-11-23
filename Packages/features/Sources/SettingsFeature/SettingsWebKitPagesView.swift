import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Settings › Advanced › WebKit (DEV-877): the switch and the row that opens the sites' own page
/// (DEV-1114).
internal struct SettingsWebKitPagesSection<SitesRow: View>: View {
	private let store: StoreOf<SettingsFeature>
	private let sitesRow: SitesRow

	internal init(
		store: StoreOf<SettingsFeature>,
		@ViewBuilder sitesRow: () -> SitesRow
	) {
		self.store = store
		self.sitesRow = sitesRow()
	}

	internal var body: some View {
		SettingsSection(
			String.localized(.appUI.settings.section.webKit),
			caption: String.localized(.appUI.settings.webKitPagesExplanation)
		) {
			SettingsToggle(
				String.localized(.appUI.settings.webKitPages),
				isOn: Binding(
					get: { store.webKitPages.isEnabled },
					set: { store.send(.ui(.webKitPagesEnabled($0))) }
				)
			)
			.settingsAnchor(.webKitPages)

			// DEV-1144: how protected media plays, FairPlay either way.
			SettingsRow(
				String.localized(.appUI.settings.protectedMedia),
				detail: String.localized(.appUI.settings.protectedMediaExplanation)
			) {
				Picker(
					String.localized(.appUI.settings.protectedMedia),
					selection: Binding(
						get: { store.webKitPages.protectedMedia },
						set: { store.send(.ui(.protectedMediaPlayback($0))) }
					)
				) {
					Text(localized: .appUI.settings.protectedMediaFairPlayInTab)
						.tag(ProtectedMediaPlayback.fairPlayInTab)
					Text(localized: .appUI.settings.protectedMediaWebKitPage)
						.tag(ProtectedMediaPlayback.webKitPage)
				}
				.labelsHidden()
				.fixedSize()
			}
			.settingsAnchor(.protectedMedia)

			SettingsToggle(
				String.localized(.appUI.settings.widevineAnswer),
				detail: String.localized(.appUI.settings.widevineAnswerExplanation),
				isOn: Binding(
					get: { store.webKitPages.answersWidevine },
					set: { store.send(.ui(.widevineAnswer($0))) }
				)
			)
			.settingsAnchor(.widevineAnswer)

			sitesRow
		}
	}
}

/// Settings › Advanced › WebKit sites (DEV-877, DEV-1114): the sites that open in WebKit pages,
/// Add Site… and Restore Defaults, greyed while WebKit pages are off. Add Site… and a click on a
/// site open the site form (DEV-1001).
internal struct SettingsWebKitSitesView: View {
	private let store: StoreOf<SettingsFeature>

	@Environment(\.settingsToolbarAdd)
	private var addsFromToolbar

	internal init(store: StoreOf<SettingsFeature>) {
		self.store = store
	}

	internal var body: some View {
		SettingsSection {
			ForEach(store.webKitPages.sites, id: \.self) { site in
				SettingsWebKitSiteRow(
					site: site,
					onEdit: { store.send(.ui(.siteDraft(.edit(.webKit, site: site, profileID: nil)))) },
					onRemove: { store.send(.ui(.removeWebKitSite(site))) }
				)
			}
			.disabled(!store.webKitPages.isEnabled)

			HStack(spacing: 8) {
				if !addsFromToolbar {
					Button(String.localized(.appUI.settings.siteForm.addButton), systemImage: "plus") {
						store.send(.ui(.siteDraft(.new(.webKit, profileID: nil))))
					}
				}
				Spacer(minLength: 8)
				Button(String.localized(.appUI.settings.webKitRestoreDefaults)) {
					store.send(.ui(.restoreWebKitSites))
				}
				.disabled(store.webKitPages.hasDefaultSites)
			}
			.settingsRow()
			.disabled(!store.webKitPages.isEnabled)
		} footer: {
			if !store.webKitPages.isEnabled {
				Text(localized: .appUI.settings.webKitSitesOff)
			}
		}
		.settingsSiteFormSheet(.webKit, store: store)
	}
}

/// One listed site: a click opens it in the site form, and Remove.
private struct SettingsWebKitSiteRow: View {
	internal let site: String
	internal let onEdit: () -> Void
	internal let onRemove: () -> Void

	internal var body: some View {
		HStack(spacing: 8) {
			Button(action: onEdit) {
				HStack(spacing: 8) {
					Image(systemName: "safari")
						.foregroundStyle(.secondary)
						.accessibilityHidden(true)
					Text(site)
					Spacer(minLength: 8)
				}
				.settingsRow()
			}

			// The fill reaches the card's leading inset and stops before Remove.
			.buttonStyle(.settingsGroupRow(edges: .leading))
			.accessibilityHint(Text(localized: .appUI.settings.siteForm.editHint))
			Button(action: onRemove) {
				Image(systemName: "minus.circle")
			}
			.buttonStyle(.borderless)
			.help(String.localized(.appUI.settings.webKitSiteRemove(site)))
			.accessibilityLabel(Text(localized: .appUI.settings.webKitSiteRemove(site)))
		}
	}
}
