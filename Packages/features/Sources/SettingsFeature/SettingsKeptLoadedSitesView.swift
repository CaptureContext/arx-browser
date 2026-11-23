import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Settings › Advanced › Sites kept loaded, the sites that never unload (DEV-932), on a page of
/// their own (DEV-1114): each profile's own list and Add Site…. Add Site… and a click on a site
/// open the site form, which also chooses the profile when there's more than one (DEV-1001).
/// Keep pinned tabs loaded stays in the pane, beside the row that opens this page.
internal struct SettingsKeptLoadedSitesView: View {
	internal let store: StoreOf<SettingsFeature>
	internal let organization: BrowserOrganization

	@Environment(\.settingsToolbarAdd)
	private var addsFromToolbar

	internal init(
		store: StoreOf<SettingsFeature>,
		organization: BrowserOrganization
	) {
		self.store = store
		self.organization = organization
	}

	internal var body: some View {
		SettingsSection(caption: String.localized(.appUI.settings.keptLoadedSitesExplanation)) {
			ForEach(organization.profiles) { profile in
				ForEach(profile.keptLoadedSites ?? [], id: \.self) { site in
					siteRow(site, in: profile)
				}
			}
			if !addsFromToolbar {
				HStack {
					Button(String.localized(.appUI.settings.siteForm.addButton), systemImage: "plus") {
						store.send(.ui(.siteDraft(.new(.keptLoaded, profileID: organization.profiles.first?.id))))
					}
					.disabled(organization.profiles.isEmpty)
					Spacer()
				}
				.settingsRow()
			}
		} footer: {
			if let error = store.organizationError {
				Text(error)
			}
		}
		.disabled(store.isManagingOrganization)
		.settingsSiteFormSheet(.keptLoaded, store: store, profiles: Array(organization.profiles))
	}

	/// A click opens the site in the form; Remove takes it off the list.
	private func siteRow(
		_ site: String,
		in profile: Profile
	) -> some View {
		HStack(spacing: 8) {
			Button {
				store.send(.ui(.siteDraft(.edit(.keptLoaded, site: site, profileID: profile.id))))
			} label: {
				HStack(spacing: 12) {
					VStack(alignment: .leading, spacing: 2) {
						Text(site)
						if organization.profiles.count > 1 {
							Text(profile.name)
								.font(SettingsTypography.caption)
								.foregroundStyle(.secondary)
						}
					}
					Spacer(minLength: 12)
				}
				.settingsRow()
			}

			// The fill reaches the card's leading inset and stops before Remove.
			.buttonStyle(.settingsGroupRow(edges: .leading))
			.accessibilityHint(Text(localized: .appUI.settings.siteForm.editHint))
			Button(String.localized(.appUI.settings.keptLoadedSiteRemove)) {
				store.send(.ui(.changeOrganization(.setKeptLoadedSite(profile.id, site: site, kept: false))))
			}
		}
	}
}
