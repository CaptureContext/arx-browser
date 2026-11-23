import BrowserCore
import Foundation
import _ComposableArchitecture

// The Settings row index (DEV-1015): what Settings' search finds, given a stable identity and,
// for a row that is one switch, the preference it shows. The command bar lists these rows with
// their state; DEV-1023 classifies every row for agents on the same index.

extension SettingsDestination {
	/// A stable, readable identity: `pane/general`, `row/general/warnBeforeQuitting`,
	/// `page/aiCommands`, `panel/previews/previews`, `automation` or `extensions`. Command bar
	/// results carry it, and `init(id:)` reads it back.
	public var id: String {
		switch self {
		case let .pane(category): "pane/" + category.rawValue
		case let .row(category, anchor): "row/" + category.rawValue + "/" + anchor.rawValue
		case let .page(page): "page/" + page.rawValue
		case let .panel(panel, anchor): "panel/" + panel.rawValue + "/" + anchor.rawValue
		case .automation: "automation"
		case .extensions: "extensions"
		}
	}

	/// The destination `id` names, or nil for text that names none.
	public init?(id: String) {
		let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
		switch parts.first {
		case "pane" where parts.count == 2:
			guard let category = SettingsCategory(rawValue: parts[1]) else { return nil }
			self = .pane(category)

		case "row" where parts.count == 3:
			guard
				let category = SettingsCategory(rawValue: parts[1]),
				let anchor = SettingsAnchor(rawValue: parts[2])
			else { return nil }
			self = .row(category, anchor)

		case "page" where parts.count == 2:
			guard let page = SettingsPage(rawValue: parts[1]) else { return nil }
			self = .page(page)

		case "panel" where parts.count == 3:
			// Search Shortcuts and Air Traffic Control were sheets before they were pages (DEV-1114).
			if let page = Self.formerPanelPages[parts[1]] {
				self = .page(page)
				return
			}
			guard
				let panel = SettingsPanel(rawValue: parts[1]),
				let anchor = SettingsAnchor(rawValue: parts[2])
			else { return nil }
			self = .panel(panel, anchor)

		case "automation" where parts.count == 1:
			self = .automation

		case "extensions" where parts.count == 1:
			self = .extensions

		default:
			return nil
		}
	}

	/// The sheets that became pages, by their old name.
	private static let formerPanelPages: [String: SettingsPage] = [
		"search": .searchShortcuts,
		"routing": .routing,
	]
}

/// A Settings row that is one on/off switch, named by the preference it shows (DEV-1015).
///
/// Only reading lives here. Turning one on or off goes through `SettingsFeature`'s own action
/// for it, which may do more than store the value, such as registering Little Arx's global
/// shortcut.
public enum SettingsSwitch: String, CaseIterable, Hashable, Sendable {
	case warnsBeforeQuitting
	case hoverPreviews
	case switchesToLinkTabs
	case opensEmptyPageAtLaunch
	case showsUnreadBadges
	case fetchesUnloadedSiteIcons
	case asksBeforeFillingPasswords
	case blocksContent
	case globalLittleArx
	case sounds
	case developerMode
	case developerHeader
	case localTabHighlight
	case restoresWindowsAtStartup
	case haptics
	case keepsPinnedTabsLoaded
	case showsLinkStatus

	/// Whether it's on in these preferences.
	public func isOn(
		general: GeneralPreferences,
		linkClicks: LinkClickPreferences
	) -> Bool {
		switch self {
		case .warnsBeforeQuitting: general.warnsBeforeQuitting
		case .hoverPreviews: general.hoverPreviewsEnabled
		case .switchesToLinkTabs: general.switchesToLinkTabs
		case .opensEmptyPageAtLaunch: general.opensEmptyPageAtLaunch
		case .showsUnreadBadges: general.showsUnreadBadges
		case .fetchesUnloadedSiteIcons: general.fetchesUnloadedSiteIcons
		case .asksBeforeFillingPasswords: general.asksBeforeFillingPasswords
		case .blocksContent: general.blocksContent
		case .globalLittleArx: linkClicks.globalLittleArxEnabled
		case .sounds: general.soundsEnabled
		case .developerMode: general.developerModeEnabled
		case .developerHeader: general.developerHeaderEnabled
		case .localTabHighlight: general.localTabHighlightEnabled
		case .restoresWindowsAtStartup: general.restoresWindowsAtStartup
		case .haptics: general.hapticsEnabled
		case .keepsPinnedTabsLoaded: general.keepsPinnedTabsLoaded
		case .showsLinkStatus: linkClicks.showsLinkStatus
		}
	}

	/// Whether it's on now, in the app's shared preferences.
	public var isOn: Bool {
		isOn(
			general: SharedReader(.general).wrappedValue,
			linkClicks: SharedReader(.linkClicks).wrappedValue
		)
	}
}

extension SettingsAnchor {
	/// The switch this anchor marks, when the row it marks is one switch whose label is the
	/// search entry's title. A section with several controls has none.
	public var toggle: SettingsSwitch? {
		switch self {
		case .warnBeforeQuitting: .warnsBeforeQuitting

		case .hoverPreviews: .hoverPreviews

		case .linkTabSwitching: .switchesToLinkTabs

		case .emptyPageAtLaunch: .opensEmptyPageAtLaunch

		case .unreadBadges: .showsUnreadBadges

		case .unloadedSiteIcons: .fetchesUnloadedSiteIcons

		case .autofillAuthentication: .asksBeforeFillingPasswords

		case .contentBlocking: .blocksContent

		case .globalLittleArx: .globalLittleArx

		// The Sound section holds this one switch.
		case .sound: .sounds

		case .developerMode: .developerMode

		case .developerHeader: .developerHeader

		case .localTabHighlight: .localTabHighlight

		case .restoreWindows: .restoresWindowsAtStartup

		case .haptics: .haptics

		case .memoryPinnedTabs: .keepsPinnedTabsLoaded

		case .linkStatus: .showsLinkStatus

		default: nil
		}
	}
}

/// The feature flags that decide whether Settings shows a row, and so whether its search finds
/// it and agents can read and change it.
public struct SettingsFeatureFlags: Equatable, Sendable {
	/// Links › Link Status (`ARX_LINK_STATUS`, DEV-1111).
	public var linkStatus: Bool

	/// Appearance › Dark pages (`ARX_DARK_PAGES`, DEV-1020, DEV-1141).
	public var darkPages: Bool

	/// Appearance › Window background › Match site (`ARX_MATCH_SITE_BACKGROUND`, DEV-1101, DEV-1170).
	public var matchSite: Bool

	/// General › Tabs: New tabs open and Tabs from links open, instead of the one New tabs open
	/// (`ARX_NEW_TABS_AT_TOP`, DEV-1174).
	public var newTabsAtTop: Bool

	public init(
		linkStatus: Bool = false,
		darkPages: Bool = false,
		matchSite: Bool = false,
		newTabsAtTop: Bool = false
	) {
		self.linkStatus = linkStatus
		self.darkPages = darkPages
		self.matchSite = matchSite
		self.newTabsAtTop = newTabsAtTop
	}

	/// Every flagged row shown. The one New tabs open row, which `newTabsAtTop` replaces, isn't.
	public static let all: Self = .init(
		linkStatus: true,
		darkPages: true,
		matchSite: true,
		newTabsAtTop: true
	)
}

extension SettingsFeature.State {
	/// The feature flags this Settings shows its rows with. Dark pages also need an engine that
	/// has them.
	public var featureFlags: SettingsFeatureFlags {
		.init(
			linkStatus: linkStatusAvailable,
			darkPages: darkPagesAvailable,
			matchSite: matchSiteAvailable,
			newTabsAtTop: newTabsAtTopAvailable
		)
	}
}

extension SettingsSearchEntry {
	/// Whether Settings shows the row this entry finds: some rows only with their feature flag.
	public func isAvailable(_ flags: SettingsFeatureFlags) -> Bool {
		switch destination {
		case .row(.links, .linkStatus): flags.linkStatus
		case .row(.appearance, .darkPages): flags.darkPages
		case .row(.appearance, .matchSite): flags.matchSite
		case .row(.general, .newTabPlacement): !flags.newTabsAtTop
		case .row(.general, .openedTabPlacement): flags.newTabsAtTop
		default: true
		}
	}

	/// The switch this entry finds, when it finds a row that is one switch.
	public var toggle: SettingsSwitch? {
		guard case let .row(_, anchor) = destination else { return nil }
		return anchor.toggle
	}
}

// MARK: - Who may change a row (DEV-1023)

/// Who may change a Settings row: an agent through `browser_settings`, only the person, or
/// nobody, because the row sets nothing.
///
/// Every row Settings' search finds has one. The switches below have no default, so a new
/// anchor, page or panel doesn't build until it's classified, and `SettingsRowAccessTests`
/// fails for a preference agents can change that no row reaches.
public struct SettingsRowAccess: Equatable, Sendable {
	public var access: AutomationSettingsRow.Access

	/// The preferences an agent row changes through the preferences section.
	public var keys: [AutomationPreferenceKey]

	/// The `browser_settings` section whose actions edit an agent row that isn't preferences.
	public var section: AutomationSettingsRequest.Section?

	private init(
		access: AutomationSettingsRow.Access,
		keys: [AutomationPreferenceKey] = [],
		section: AutomationSettingsRequest.Section? = nil
	) {
		self.access = access
		self.keys = keys
		self.section = section
	}

	/// An agent may change these preferences.
	public static func agent(_ keys: AutomationPreferenceKey...) -> Self {
		.init(access: .agent, keys: keys)
	}

	/// An agent may change it through this section's actions.
	public static func agent(section: AutomationSettingsRequest.Section) -> Self {
		.init(access: .agent, section: section)
	}

	/// Only the person changes it: privacy, security, passwords, accounts, AI, permissions,
	/// the system's own settings and the Mac's resources.
	public static let user: Self = .init(access: .user)

	/// It sets nothing itself: a pane, a section whose rows have their own entries, or a button
	/// that only shows something.
	public static let ui: Self = .init(access: .ui)
}

extension SettingsDestination {
	/// Who may change what this destination shows.
	public var access: SettingsRowAccess {
		switch self {
		case .pane: .ui

		case let .row(_, anchor): anchor.access

		case let .page(page): page.access

		case let .panel(panel, _): panel.access

		// The MCP grants: never an agent's to change.
		case .automation: .user

		case .extensions: .agent(section: .extensions)
		}
	}
}

extension SettingsPage {
	public var access: SettingsRowAccess {
		switch self {
		// The assistant's actions and its place in Arx are the person's AI decisions.
		case .aiCommands, .assistantFeatures: .user

		// A profile's sign-ins, passwords and data.
		case .profile: .user

		case .searchShortcuts: .agent(section: .searchShortcuts)

		case .routing: .agent(section: .routing)

		// Handing another app a link: the person's choice, like the default browser.
		case .appLinks: .user

		// Rewriting shared links, and which sites stay loaded or open in WebKit.
		case .proxyLinks, .keptLoadedSites, .webKitSites: .user

		// Unfinished features, some with risks: never an agent's to turn on (DEV-1115).
		case .featureFlags: .user
		}
	}
}

extension SettingsPanel {
	public var access: SettingsRowAccess {
		switch self {
		case .previews: .agent(.hoverPageDetails, .fullHoverPreviews, .shiftHoverLoadsPages)
		}
	}
}

extension SettingsAnchor {
	public var access: SettingsRowAccess {
		switch self {
		// Arx
		case .identityCard: .agent(.identityCardStyle)

		case .defaultBrowser: .user

		// Signing in with Apple and sending the token to Arx's server is the person's
		// own decision about an account (DEV-701).
		case .memberNumber: .user

		// Which iCloud account the person's data goes to, and what of it: theirs to decide.
		case .iCloudSync: .user

		// General
		case .updates: .user

		case .warnBeforeQuitting: .agent(.warnsBeforeQuitting)

		case .hoverPreviews: .agent(.hoverPreviewsEnabled)

		case .previews: .agent(.hoverPageDetails, .fullHoverPreviews, .shiftHoverLoadsPages)

		case .unloadedSiteIcons: .agent(.fetchesUnloadedSiteIcons)

		case .tabUnloading: .user

		case .batterySaver: .user

		// Choosing Google sends page text off the Mac (DEV-996), so it's the person's call.
		case .translation: .user

		case .autofillAuthentication: .user

		case .contentBlocking: .user

		case .newTabPlacement: .agent(.newTabPlacement)

		case .openedTabPlacement: .agent(.openedTabPlacement)

		case .linkTabSwitching: .agent(.switchesToLinkTabs)

		case .emptyPageAtLaunch: .agent(.opensEmptyPageAtLaunch)

		// The browser default (DEV-1258). The sites listed under it chose in their site menu, and
		// Use Default only takes a site's choice back.
		case .unreadBadges: .agent(.showsUnreadBadges)

		case .pictureInPicture: .agent(.automaticPictureInPicture, .closesPictureInPictureOnReturn)

		case .setupGuide: .ui

		// Profiles
		case .profileList: .user

		// Assistant
		case .assistantProviders: .user

		// Links
		case .littleArx: .ui

		case .globalLittleArx: .agent(.globalLittleArxEnabled)

		case .littleArxPosition: .agent(.littleArxLauncherPosition)

		case .runwayAppearance: .agent(.runwayAppearance)

		// Closing the person's windows on its own is theirs to choose, and the row shows only with
		// its feature flag, which agents' preference list can't depend on (DEV-1138).
		case .littleArxArchive: .user

		case .modifiedLinks: .agent(.littleArxLinkBinding)

		case .peek: .agent(.shiftClickLinkAction)

		case .forceClick: .agent(.forceClickLinkAction)

		case .crossSitePeek: .agent(.crossSiteLinkFromFavorites, .crossSiteLinkFromPinnedTabs)

		case .linkStatus: .agent(.showsLinkStatus)

		// Shortcuts
		case .commands: .agent(section: .keyboardShortcuts)

		// Appearance
		case .theme: .agent(.appTheme)

		case .darkPages: .agent(.darkPages)

		case .windowBackground: .agent(.tintHue, .tintIntensity, .grainEnabled, .grainIntensity, .grainSize, .accentColor)

		// The browser default; profiles and spaces choose theirs through their appearance (DEV-1170).
		case .matchSite: .agent(.matchesSite)

		case .sidebarPosition: .agent(.sidebarPosition)

		case .sound: .agent(.soundsEnabled)

		case .appIcon: .user

		// Privacy
		case .crashReports: .user

		case .reportProblem: .user

		// Developer
		case .developerMode: .user

		case .developerHeader: .user

		case .localTabHighlight: .user

		// Advanced
		case .automation: .user

		case .restoreWindows: .agent(.restoresWindowsAtStartup)

		case .haptics: .agent(.hapticsEnabled)

		case .webKitPages: .user

		// DEV-1144: both FairPlay; Arx has no Widevine to turn on.
		case .protectedMedia: .agent(.protectedMediaPlayback)

		case .widevineAnswer: .agent(.widevineAnswer)

		case .memoryTabUnloading: .user

		case .memoryPressureGrace: .user

		case .memoryPinnedTabs: .agent(.keepsPinnedTabsLoaded)

		case .backForwardCache: .user

		case .browserData: .user
		}
	}
}

extension SettingsSearchEntry {
	/// Who may change this row.
	public var access: SettingsRowAccess { destination.access }

	/// The row as `browser_settings` lists it.
	public var automationRow: AutomationSettingsRow {
		let access = access
		return .init(
			id: destination.id,
			title: title,
			path: path ?? category.title,
			access: access.access,
			keys: access.keys.isEmpty ? nil : access.keys,
			section: access.section
		)
	}
}

extension SettingsCategory {
	/// Every row Settings' search finds with these feature flags, as `browser_settings` lists
	/// them, in the sidebar's order.
	@MainActor
	public static func automationRows(_ flags: SettingsFeatureFlags) -> [AutomationSettingsRow] {
		searchIndex.filter { $0.isAvailable(flags) }.map(\.automationRow)
	}

	/// The preferences agents may read and change with these feature flags: those the rows
	/// Settings shows reach, in the order rows list them.
	@MainActor
	public static func agentPreferenceKeys(_ flags: SettingsFeatureFlags) -> [AutomationPreferenceKey] {
		var keys: [AutomationPreferenceKey] = []
		for row in searchIndex where row.isAvailable(flags) {
			for key in row.access.keys where !keys.contains(key) { keys.append(key) }
		}
		return keys
	}
}

extension SettingsDestination {
	/// Where an `arx://settings/<pane>/<item>` address leads (DEV-1189), ignoring case: the page
	/// inside the pane, else the row Settings' search finds there, else the pane itself. Nil for a
	/// pane Settings doesn't list.
	@MainActor
	public init?(
		pane: String,
		item: String
	) {
		guard let category = SettingsCategory.available.first(where: { $0.rawValue.lowercased() == pane.lowercased() })
		else { return nil }

		let item: String = item.lowercased()
		if let page = SettingsPage.available.first(where: { $0.category == category && $0.rawValue.lowercased() == item }) {
			self = .page(page)
			return
		}
		let row = category.searchIndex.first { entry in
			entry.destination.anchor?.rawValue.lowercased() == item
		}
		self = row?.destination ?? .pane(category)
	}
}
