import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Settings' lists add from a "+" on the window's top bar (Max, 18 Nov): the bar's raised
/// squircle, as Shortcuts' search draws it, with a hint naming what it adds, instead of a button
/// over the list. On by default, as every flag is for the beta; the `ARX_SETTINGS_TOOLBAR_ADD`
/// feature flag set to `0`, `false`, `no` or `off` brings back the buttons over the lists.
internal enum SettingsToolbarAdd {
	/// Whether the "+" is on the bar. Read once, through the `FeatureFlag` registry: the
	/// environment, then Arx's defaults under the flag's name.
	internal static let isEnabled: Bool = FeatureFlag.settingsToolbarAdd.isOn()
}

extension EnvironmentValues {
	/// Whether Settings' lists add from the bar, as `SettingsToolbarAdd` describes. Snapshots set
	/// it; the app leaves it at the flag.
	@Entry
	internal var settingsToolbarAdd: Bool = SettingsToolbarAdd.isEnabled
}

/// What a pane's or page's "+" adds.
internal enum SettingsAddTarget: CaseIterable, Equatable, Sendable {
	/// Profiles' New Profile.
	case profile

	/// Links › Proxy Links' New Rule.
	case proxyLinkRule

	/// Links › Air Traffic Control's New Route.
	case route

	/// Links › App Links' New Handler.
	case appLink

	/// Advanced › Sites kept loaded's Add Site.
	case keptLoadedSite

	/// Advanced › WebKit sites' Add Site.
	case webKitSite

	/// A pane's own "+": only Profiles lists something on the pane itself.
	internal init?(category: SettingsCategory) {
		switch category {
		case .profiles: self = .profile
		case .arx, .general, .sync, .assistant, .links, .shortcuts, .appearance, .privacy, .developer, .advanced, .experimental:
			return nil
		}
	}

	/// A page's "+".
	internal init?(page: SettingsPage) {
		switch page {
		case .proxyLinks: self = .proxyLinkRule
		case .routing: self = .route
		case .appLinks: self = .appLink
		case .keptLoadedSites: self = .keptLoadedSite
		case .webKitSites: self = .webKitSite
		case .aiCommands, .assistantFeatures, .profile, .searchShortcuts, .featureFlags: return nil
		}
	}

	/// The hint on hover and what VoiceOver reads: what it adds.
	internal var title: String {
		switch self {
		case .profile: String.localized(.appUI.settings.newProfile)
		case .proxyLinkRule: String.localized(.appUI.links.newRule)
		case .route: String.localized(.appUI.routing.newRoute)
		case .appLink: String.localized(.appUI.appLinks.newHandler)
		case .keptLoadedSite, .webKitSite: String.localized(.appUI.settings.siteForm.addTitle)
		}
	}

	/// What it sends: the action the button over the list sent.
	internal func action(organization: BrowserOrganization) -> SettingsFeature.Action {
		switch self {
		case .profile: .ui(.editOrganization(.init()))
		case .proxyLinkRule: .ui(.proxyLinks(.newRule))
		case .route: .ui(.routing(.newDraft))
		case .appLink: .ui(.appLinks(.newHandler))
		case .keptLoadedSite: .ui(.siteDraft(.new(.keptLoaded, profileID: organization.profiles.first?.id)))
		case .webKitSite: .ui(.siteDraft(.new(.webKit, profileID: nil)))
		}
	}

	/// Whether it's greyed, as the button over the list was. It reads the store field by field,
	/// so the button redraws only when one of them changes.
	@MainActor
	internal func isDisabled(
		_ store: StoreOf<SettingsFeature>,
		organization: BrowserOrganization
	) -> Bool {
		switch self {
		case .profile: store.isManagingOrganization
		case .proxyLinkRule: false
		case .route: store.routingDraft != nil
		case .appLink: store.appLinks.draft != nil
		case .keptLoadedSite: organization.profiles.isEmpty || store.isManagingOrganization
		case .webKitSite: !store.webKitPages.isEnabled
		}
	}
}

/// A pane's or page's "+" on the window's top bar: ``ArxHeaderIconButton``, whose title is its
/// hint and what VoiceOver reads. It shows only while `settingsToolbarAdd` is on.
internal struct SettingsToolbarAddButton: View {
	private let target: SettingsAddTarget?
	private let store: StoreOf<SettingsFeature>
	private let organization: BrowserOrganization

	@Environment(\.settingsToolbarAdd)
	private var isEnabled

	internal init(
		_ target: SettingsAddTarget?,
		store: StoreOf<SettingsFeature>,
		organization: BrowserOrganization
	) {
		self.target = target
		self.store = store
		self.organization = organization
	}

	internal var body: some View {
		if isEnabled, let target {
			ArxHeaderIconButton(target.title, systemImage: "plus") {
				store.send(target.action(organization: organization))
			}
			.disabled(target.isDisabled(store, organization: organization))
		}
	}
}
