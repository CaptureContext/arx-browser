import Foundation

/// A read or change of Arx Settings through automation. Only the sections and preference
/// keys listed here exist: security settings and automation access itself are never part
/// of them. Extensions, site permissions and page zoom belong to one profile, which a
/// whole-profile grant must cover.
public struct AutomationSettingsRequest: Codable, Equatable, Sendable {
	public enum Section: String, Codable, CaseIterable, Sendable {
		/// The allowlisted preferences, each with its schema.
		case preferences

		/// Air Traffic Control rules and the fallback whose destinations the grant covers.
		case routing

		/// Search shortcuts (the user's own bangs).
		case searchShortcuts

		/// Every command's keyboard shortcut.
		case keyboardShortcuts

		/// One granted profile's extensions.
		case extensions

		/// One granted profile's permission defaults and each site's own permissions.
		case sitePermissions

		/// One granted profile's default and per-site page zoom.
		case zoom

		/// Sections that belong to one profile, named by `profileID`.
		public var isProfileScoped: Bool {
			switch self {
			case .extensions, .sitePermissions, .zoom: true
			case .preferences, .routing, .searchShortcuts, .keyboardShortcuts: false
			}
		}
	}

	public enum Kind: Codable, Equatable, Sendable {
		/// `profileID` names the profile for profile-scoped sections and is absent otherwise.
		case read(Section, profileID: UUID?)

		/// Where Air Traffic Control would send `url`. `sourceSpaceID` is the space
		/// current-space rules resolve to.
		case testRoute(URL, sourceSpaceID: UUID?)
		case change(AutomationSettingsChange)
	}

	public var kind: Kind

	public init(_ kind: Kind) {
		self.kind = kind
	}

	public var section: Section {
		switch kind {
		case let .read(section, _): section
		case .testRoute: .routing
		case let .change(change): change.edit.section
		}
	}

	public var change: AutomationSettingsChange? {
		guard case let .change(change) = kind else { return nil }
		return change
	}

	public func validate() throws {
		switch kind {
		case let .read(section, profileID):
			guard section.isProfileScoped == (profileID != nil)
			else { throw AutomationFailure.invalidRequest }

		case let .testRoute(url, _):
			guard
				url.absoluteString.utf8.count <= 4096,
				url.hasWebScheme,
				url.host() != nil
			else { throw AutomationFailure.invalidRequest }

		case let .change(change):
			try change.validate()
		}
	}
}

public struct AutomationSettingsChange: Codable, Equatable, Sendable {
	public var operationID: UUID

	/// The section's revision from the last read; a changed section reports `staleTarget`.
	public var expectedRevision: String
	public var edit: AutomationSettingsEdit

	public init(
		operationID: UUID,
		expectedRevision: String,
		edit: AutomationSettingsEdit
	) {
		self.operationID = operationID
		self.expectedRevision = expectedRevision
		self.edit = edit
	}

	public func validate() throws {
		guard
			expectedRevision.count == 64,
			expectedRevision.allSatisfy(\.isHexDigit)
		else { throw AutomationFailure.invalidRequest }

		try edit.validate()
	}
}

public enum AutomationSettingsEdit: Codable, Equatable, Sendable {
	/// One or more allowlisted preferences, each checked against its schema.
	case setPreferences([AutomationPreferenceSetting])

	/// Creates the rule, or replaces the rule with the same ID. An edited rule keeps
	/// whether it is enabled, as in Settings.
	case saveRoutingRule(AutomationRoutingRule)
	case deleteRoutingRule(UUID)

	/// Swaps the rule with its neighbour: `-1` earlier, `1` later.
	case moveRoutingRule(UUID, offset: Int)
	case setRoutingRuleEnabled(UUID, Bool)

	/// Creates the shortcut, or replaces the one whose keyword is `replacing`.
	case saveSearchShortcut(SearchShortcut, replacing: String?)
	case deleteSearchShortcut(String)
	case setSearchShortcutEnabled(String, Bool)

	/// Nil removes the command's shortcut. A shortcut another command uses is refused
	/// unless `replacesConflicts`, which removes it from those commands, as Settings'
	/// Replace button does.
	case setKeyboardShortcut(BrowserCommand, KeyboardShortcut?, replacesConflicts: Bool)

	/// Returns the command to its default shortcut, under the same conflict rule.
	case resetKeyboardShortcut(BrowserCommand, replacesConflicts: Bool)

	/// Who gets the command's keys when the page would handle them too (DEV-1332): Settings ›
	/// Shortcuts' Conflict resolution. Refused for a command that always keeps its keys or has
	/// no ⌘ shortcut.
	case setShortcutConflictResolution(BrowserCommand, ShortcutConflictResolution)
	case setExtensionEnabled(profileID: UUID, extensionID: String, Bool)

	/// Installs a Chrome Web Store item in the profile. The person always approves it in the
	/// Extensions sheet's review, which shows its name, permissions and verified package,
	/// whatever the client's approval policy (DEV-951).
	case installExtension(profileID: UUID, extensionID: String)

	/// A site's own setting for one permission (nil removes it, so the default applies),
	/// or with no origin the profile's default.
	case setSitePermission(profileID: UUID, origin: String?, SitePermission, SitePermissionSetting?)

	/// A host's page zoom factor (nil removes it), or with no host the profile's default.
	case setSiteZoom(profileID: UUID, host: String?, factor: Double?)

	/// Puts back the preferences an earlier `setPreferences` of the same client changed, by its
	/// operation ID, while they still hold what it set (DEV-1023).
	case undoPreferences(operationID: String)

	public var section: AutomationSettingsRequest.Section {
		switch self {
		case .setPreferences, .undoPreferences: .preferences
		case .saveRoutingRule, .deleteRoutingRule, .moveRoutingRule, .setRoutingRuleEnabled: .routing
		case .saveSearchShortcut, .deleteSearchShortcut, .setSearchShortcutEnabled: .searchShortcuts
		case .setKeyboardShortcut, .resetKeyboardShortcut, .setShortcutConflictResolution: .keyboardShortcuts
		case .setExtensionEnabled, .installExtension: .extensions
		case .setSitePermission: .sitePermissions
		case .setSiteZoom: .zoom
		}
	}

	/// The profile a profile-scoped edit changes.
	public var profileID: UUID? {
		switch self {
		case let .setExtensionEnabled(profileID, _, _), let .installExtension(profileID, _),
			let .setSitePermission(profileID, _, _, _), let .setSiteZoom(profileID, _, _):
			profileID
		default:
			nil
		}
	}

	/// The engine change a site-settings edit makes.
	public var siteSettingsEdit: SiteSettingsEdit? {
		switch self {
		case let .setSitePermission(_, origin, permission, setting): .setPermission(origin: origin, permission, setting)
		case let .setSiteZoom(_, host, factor): .setZoom(host: host, factor: factor)
		default: nil
		}
	}

	/// The action name agents use for this edit.
	public var name: String {
		switch self {
		case .setPreferences: "setPreferences"
		case .saveRoutingRule: "saveRoutingRule"
		case .deleteRoutingRule: "deleteRoutingRule"
		case .moveRoutingRule: "moveRoutingRule"
		case .setRoutingRuleEnabled: "setRoutingRuleEnabled"
		case .saveSearchShortcut: "saveSearchShortcut"
		case .deleteSearchShortcut: "deleteSearchShortcut"
		case .setSearchShortcutEnabled: "setSearchShortcutEnabled"
		case .setKeyboardShortcut: "setKeyboardShortcut"
		case .resetKeyboardShortcut: "resetKeyboardShortcut"
		case .setShortcutConflictResolution: "setShortcutConflictResolution"
		case .setExtensionEnabled: "setExtensionEnabled"
		case .installExtension: "installExtension"
		case .setSitePermission: "setSitePermission"
		case .setSiteZoom: "setSiteZoom"
		case .undoPreferences: "undo"
		}
	}

	public var riskTier: AutomationRiskTier {
		switch self {
		case .deleteRoutingRule, .deleteSearchShortcut: .destructive
		default: .mutate
		}
	}

	public func validate() throws {
		switch self {
		case let .setPreferences(settings):
			guard
				(1...AutomationPreferenceKey.allCases.count).contains(settings.count),
				Set(settings.map(\.key)).count == settings.count
			else { throw AutomationFailure.invalidRequest }

			for setting in settings { try setting.key.validate(setting.value) }

		case let .undoPreferences(operationID):
			guard UUID(uuidString: operationID) != nil else { throw AutomationFailure.invalidRequest }

		case let .saveRoutingRule(rule):
			try rule.validate()

		case let .moveRoutingRule(_, offset):
			guard offset == -1 || offset == 1 else { throw AutomationFailure.invalidRequest }

		case let .saveSearchShortcut(shortcut, replacing):
			guard
				shortcut.name.utf8.count <= 256,
				shortcut.keyword.utf8.count <= 64,
				shortcut.template.utf8.count <= 4096,
				(shortcut.homepage?.absoluteString.utf8.count ?? 0) <= 4096,
				(replacing?.utf8.count ?? 0) <= 64
			else { throw AutomationFailure.invalidRequest }
			do {
				try shortcut.validate()
			} catch {
				throw AutomationFailure.invalidValue
			}

		case let .deleteSearchShortcut(keyword), let .setSearchShortcutEnabled(keyword, _):
			guard (1...64).contains(keyword.utf8.count)
			else { throw AutomationFailure.invalidRequest }

		case let .setKeyboardShortcut(_, shortcut, _):
			guard let shortcut else { return }
			guard shortcut.isValid else { throw AutomationFailure.invalidValue }
			guard !shortcut.isReserved else { throw AutomationFailure.shortcutReserved }

		case let .setExtensionEnabled(_, extensionID, _), let .installExtension(_, extensionID):
			guard BrowserExtension.isValidID(extensionID) else { throw AutomationFailure.invalidRequest }

		case .setSitePermission, .setSiteZoom:
			do throws(SiteSettingsFailure) {
				try siteSettingsEdit?.validate()
			} catch {
				throw AutomationFailure.invalidValue
			}

		case .deleteRoutingRule, .setRoutingRuleEnabled, .resetKeyboardShortcut, .setShortcutConflictResolution:
			break
		}
	}

	/// Allows a site a permission that prompts by default. Arx asks the user every time,
	/// whatever the client's approval policy or a temporary grant.
	public var installsExtension: Bool {
		guard case .installExtension = self else { return false }
		return true
	}

	public var grantsSitePermission: Bool {
		guard case let .setSitePermission(_, origin?, permission, .allow?) = self
		else { return false }
		return !origin.isEmpty && permission != .popups
	}
}

// MARK: - Preferences

/// The preferences automation may read and write. Anything else, including developer
/// mode, onboarding and the MCP grants, stays out of reach.
///
/// Settings' row index decides which these are (DEV-1023): each row is agent-changeable, the
/// person's alone, or only a way around Settings, and a test fails for a key no row reaches.
public enum AutomationPreferenceKey: String, Codable, CaseIterable, Comparable, Sendable {
	/// Settings › Links › Shift-click a link to open (DEV-1239): `peek`, `littleArx`, `newTab` or
	/// `newWindow`.
	case shiftClickLinkAction
	case littleArxLinkBinding
	case forceClickLinkAction
	case warnsBeforeQuitting
	case littleArxLauncherPosition

	/// How the Runway, the picker that asks which profile a link opens in, looks.
	case runwayAppearance
	case globalLittleArxEnabled
	case automaticPictureInPicture
	case closesPictureInPictureOnReturn
	case identityCardStyle

	/// The app-wide chrome tint's hue, `0 ... 360` degrees.
	case tintHue

	/// The app-wide chrome tint's intensity, `0 ... 1`.
	case tintIntensity
	case grainEnabled

	/// `0 ... 1`.
	case grainIntensity

	/// Display pixels per grain, `1 ... 3`.
	case grainSize

	/// The app-wide accent color (DEV-1117): `automatic`, a preset's name, or `#RRGGBB`.
	case accentColor

	/// The app-wide Match site (DEV-1170): the chrome takes the shown page's color unless a profile
	/// or space chooses otherwise.
	case matchesSite

	/// Settings › General › Previews on hover.
	case hoverPreviewsEnabled

	/// Previews › Picture and description from the site, for pages that aren't loaded (DEV-730).
	case hoverPageDetails

	/// Previews › Full previews: load a page off screen for its picture (DEV-730).
	case fullHoverPreviews

	/// Previews › Shift + hover loads the page instantly, for a page that isn't loaded (DEV-1029).
	case shiftHoverLoadsPages

	// DEV-1023: the plain switches and choices Settings' row index classifies as agent-changeable.
	case switchesToLinkTabs
	case fetchesUnloadedSiteIcons

	/// Settings › General › New tabs open, or Tabs from links open while `ARX_NEW_TABS_AT_TOP` is
	/// on (DEV-1174).
	case newTabPlacement

	/// Settings › General › New tabs open while `ARX_NEW_TABS_AT_TOP` is on (DEV-1174): the New
	/// Tab button, ⌘T and ⌘K. Agents see it only then.
	case openedTabPlacement

	/// Settings › Links › Open links to other sites from Favorites (DEV-1239): `peek`,
	/// `littleArx`, `newTab` or `currentTab`.
	case crossSiteLinkFromFavorites

	/// Settings › Links › Open links to other sites from pinned tabs (DEV-1239): the same choices.
	case crossSiteLinkFromPinnedTabs
	case appTheme
	case sidebarPosition
	case soundsEnabled
	case restoresWindowsAtStartup

	/// Settings › General › Tabs › Open to an empty page at launch (DEV-1234).
	case opensEmptyPageAtLaunch

	/// Settings › General › Tabs › Show unread badges: the browser default (DEV-907, DEV-1258).
	case showsUnreadBadges
	case hapticsEnabled
	case keepsPinnedTabsLoaded

	/// Settings › Links › Show where links go (DEV-1111).
	case showsLinkStatus

	/// Settings › Appearance › Dark pages (DEV-1020, DEV-1141): `off`, `withTheme` or `always`.
	/// Agents see it only while the `ARX_DARK_PAGES` feature flag is on.
	case darkPages

	// DEV-1144: protected media, under the WebKit sites list.
	/// `fairPlayInTab` or `webKitPage`.
	case protectedMediaPlayback

	/// The Widevine answer; Arx loads no Widevine. Applies the next time Arx opens.
	case widevineAnswer

	/// Names of settings that exist but are never readable or writable through automation.
	public static let protectedNames: Set<String> = [
		"developerModeEnabled",
		"automation",
		"mcp",
		"onboarding",
		"migrationLedger",
		"windowPresentations",
		"lastSidebarWidth",
		"keyboardShortcuts",
		"searchShortcuts",
		"routing",
		"proxyLinkRules",
		"offeredProxyLinkDefaults",
		"removedProxyLinkDefaults",
	]

	public enum Schema: Equatable, Sendable {
		case boolean
		case choice([String])
		case number(ClosedRange<Double>)

		/// One of the names, or any color as `#RRGGBB`.
		case color([String])
	}

	public static func < (lhs: Self, rhs: Self) -> Bool {
		lhs.rawValue < rhs.rawValue
	}

	public var schema: Schema {
		switch self {
		case .warnsBeforeQuitting, .globalLittleArxEnabled, .automaticPictureInPicture,
			.closesPictureInPictureOnReturn, .grainEnabled, .hoverPreviewsEnabled, .hoverPageDetails, .fullHoverPreviews,
			.shiftHoverLoadsPages, .switchesToLinkTabs, .fetchesUnloadedSiteIcons,
			.soundsEnabled, .restoresWindowsAtStartup, .opensEmptyPageAtLaunch, .showsUnreadBadges, .hapticsEnabled, .keepsPinnedTabsLoaded, .showsLinkStatus, .widevineAnswer,
			.matchesSite:
			.boolean
		case .protectedMediaPlayback: .choice(ProtectedMediaPlayback.allCases.map(\.rawValue))
		case .newTabPlacement, .openedTabPlacement: .choice(NewTabPlacement.allCases.map(\.rawValue))
		case .appTheme: .choice(AppTheme.allCases.map(\.rawValue))
		case .sidebarPosition: .choice(SidebarPosition.allCases.map(\.rawValue))
		case .littleArxLinkBinding: .choice(LittleArxLinkBinding.allCases.map(\.rawValue))
		case .shiftClickLinkAction: .choice(ShiftClickLinkAction.allCases.map(\.rawValue))
		case .forceClickLinkAction: .choice(ForceClickLinkAction.allCases.map(\.rawValue))
		case .crossSiteLinkFromFavorites, .crossSiteLinkFromPinnedTabs: .choice(CrossSiteLinkAction.allCases.map(\.rawValue))
		case .littleArxLauncherPosition: .choice(LittleArxLauncherPosition.allCases.map(\.rawValue))
		case .runwayAppearance: .choice(RunwayAppearance.allCases.map(\.rawValue))
		case .identityCardStyle: .choice(IdentityCardStyle.allCases.map(\.rawValue))
		case .darkPages: .choice(DarkPagesMode.allCases.map(\.rawValue))
		case .tintHue: .number(0 ... 360)
		case .tintIntensity, .grainIntensity: .number(0 ... 1)
		case .grainSize: .number(1 ... 3)
		case .accentColor: .color([ChromeAccent.automaticName] + ChromeAccent.Preset.allCases.map(\.rawValue))
		}
	}

	/// Whether the key belongs to the app-wide chrome appearance.
	public var isAppearance: Bool {
		[.tintHue, .tintIntensity, .grainEnabled, .grainIntensity, .grainSize, .accentColor, .matchesSite].contains(self)
	}

	public func validate(_ value: AutomationPreferenceValue) throws {
		switch (schema, value) {
		case (.boolean, .bool):
			return

		case let (.choice(choices), .string(choice)):
			guard choices.contains(choice) else { throw AutomationFailure.invalidValue }

		case let (.number(range), .number(number)):
			guard number.isFinite, range.contains(number)
			else { throw AutomationFailure.invalidValue }

		case let (.color(names), .string(color)):
			guard names.contains(color) || ChromeAccent(hex: color) != nil
			else { throw AutomationFailure.invalidValue }

		default:
			throw AutomationFailure.invalidValue
		}
	}

	public func value(in preferences: BrowserPreferences) -> AutomationPreferenceValue {
		switch self {
		case .shiftClickLinkAction: .string(preferences.shiftClickLinkAction.rawValue)
		case .littleArxLinkBinding: .string(preferences.littleArxLinkBinding.rawValue)
		case .forceClickLinkAction: .string(preferences.forceClickLinkAction.rawValue)
		case .warnsBeforeQuitting: .bool(preferences.warnsBeforeQuitting)
		case .littleArxLauncherPosition: .string(preferences.littleArxLauncherPosition.rawValue)
		case .runwayAppearance: .string(preferences.runwayAppearance.rawValue)
		case .globalLittleArxEnabled: .bool(preferences.globalLittleArxEnabled)
		case .automaticPictureInPicture: .bool(preferences.automaticPictureInPicture.isEnabled)
		case .closesPictureInPictureOnReturn: .bool(preferences.automaticPictureInPicture.closesOnReturn)
		case .identityCardStyle: .string(preferences.identityCardStyle.rawValue)
		case .tintHue: .number(preferences.chromeTint.hue)
		case .tintIntensity: .number(preferences.chromeTint.intensity)
		case .grainEnabled: .bool(preferences.grainEnabled)
		case .grainIntensity: .number(preferences.grainIntensity)
		case .grainSize: .number(preferences.grainSize)
		case .accentColor: .string(ChromeAccent.automationName(of: preferences.chromeAccent))
		case .matchesSite: .bool(preferences.chromeMatchesSite)
		case .hoverPreviewsEnabled: .bool(preferences.hoverPreviewsEnabled)
		case .hoverPageDetails: .bool(preferences.hoverPreviewSources.pageDetails)
		case .fullHoverPreviews: .bool(preferences.hoverPreviewSources.fullPages)
		case .shiftHoverLoadsPages: .bool(preferences.hoverPreviewSources.shiftLoadsPages)
		case .switchesToLinkTabs: .bool(preferences.switchesToLinkTabs)
		case .fetchesUnloadedSiteIcons: .bool(preferences.fetchesUnloadedSiteIcons)
		case .newTabPlacement: .string(preferences.newTabPlacement.rawValue)
		case .openedTabPlacement: .string(preferences.openedTabPlacement.rawValue)
		case .crossSiteLinkFromFavorites: .string(preferences.crossSiteLinkFromFavorites.rawValue)
		case .crossSiteLinkFromPinnedTabs: .string(preferences.crossSiteLinkFromPinnedTabs.rawValue)
		case .showsLinkStatus: .bool(preferences.showsLinkStatus)
		case .darkPages: .string(preferences.darkPages.rawValue)
		case .appTheme: .string(preferences.appTheme.rawValue)
		case .sidebarPosition: .string(preferences.sidebarPosition.rawValue)
		case .soundsEnabled: .bool(preferences.soundsEnabled)
		case .restoresWindowsAtStartup: .bool(preferences.restoresWindowsAtStartup)
		case .opensEmptyPageAtLaunch: .bool(preferences.opensEmptyPageAtLaunch)
		case .showsUnreadBadges: .bool(preferences.showsUnreadBadges)
		case .hapticsEnabled: .bool(preferences.hapticsEnabled)
		case .keepsPinnedTabsLoaded: .bool(preferences.keepsPinnedTabsLoaded)
		case .protectedMediaPlayback: .string(preferences.webKitPages.protectedMedia.rawValue)
		case .widevineAnswer: .bool(preferences.webKitPages.answersWidevine)
		}
	}
}

public enum AutomationPreferenceValue: Codable, Equatable, Hashable, Sendable {
	case bool(Bool)
	case string(String)
	case number(Double)

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Double.self) {
			self = .number(value)
		} else {
			self = .string(try container.decode(String.self))
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case let .bool(value): try container.encode(value)
		case let .string(value): try container.encode(value)
		case let .number(value): try container.encode(value)
		}
	}
}

public struct AutomationPreferenceSetting: Codable, Equatable, Hashable, Sendable {
	public var key: AutomationPreferenceKey
	public var value: AutomationPreferenceValue

	public init(
		key: AutomationPreferenceKey,
		value: AutomationPreferenceValue
	) {
		self.key = key
		self.value = value
	}
}

extension BrowserPreferences {
	/// These preferences with allowlisted settings applied, as Settings stores them.
	/// Appearance values are normalized the way the Settings appearance editor commits them.
	public func applying(_ settings: [AutomationPreferenceSetting]) throws -> Self {
		var preferences = self
		var appearance = chromeAppearance
		for setting in settings {
			try setting.key.validate(setting.value)
			switch (setting.key, setting.value) {
			case let (.shiftClickLinkAction, .string(value)):
				preferences.shiftClickLinkAction = try Self.choice(value)
			case let (.warnsBeforeQuitting, .bool(value)): preferences.warnsBeforeQuitting = value
			case let (.globalLittleArxEnabled, .bool(value)): preferences.globalLittleArxEnabled = value
			case let (.automaticPictureInPicture, .bool(value)): preferences.automaticPictureInPicture.isEnabled = value
			case let (.closesPictureInPictureOnReturn, .bool(value)):
				preferences.automaticPictureInPicture.closesOnReturn = value
			case let (.littleArxLinkBinding, .string(value)):
				preferences.littleArxLinkBinding = try Self.choice(value)
			case let (.forceClickLinkAction, .string(value)):
				preferences.forceClickLinkAction = try Self.choice(value)
			case let (.littleArxLauncherPosition, .string(value)):
				preferences.littleArxLauncherPosition = try Self.choice(value)
			case let (.runwayAppearance, .string(value)):
				preferences.runwayAppearance = try Self.choice(value)
			case let (.identityCardStyle, .string(value)):
				preferences.identityCardStyle = try Self.choice(value)
			case let (.tintHue, .number(value)): appearance.tint.hue = value
			case let (.tintIntensity, .number(value)): appearance.tint.intensity = value
			case let (.grainEnabled, .bool(value)): appearance.grain.isEnabled = value
			case let (.grainIntensity, .number(value)): appearance.grain.intensity = value
			case let (.grainSize, .number(value)): appearance.grain.size = value
			case let (.accentColor, .string(value)):
				if value == ChromeAccent.automaticName {
					appearance.accent = nil
				} else if let preset = ChromeAccent.Preset(rawValue: value) {
					appearance.accent = preset.accent
				} else if let custom = ChromeAccent(hex: value) {
					appearance.accent = custom
				} else {
					throw AutomationFailure.invalidValue
				}
			case let (.matchesSite, .bool(value)): appearance.matchesSite = value
			case let (.hoverPreviewsEnabled, .bool(value)): preferences.hoverPreviewsEnabled = value
			case let (.hoverPageDetails, .bool(value)): preferences.hoverPreviewSources.pageDetails = value
			case let (.fullHoverPreviews, .bool(value)): preferences.hoverPreviewSources.fullPages = value
			case let (.shiftHoverLoadsPages, .bool(value)): preferences.hoverPreviewSources.shiftLoadsPages = value
			case let (.switchesToLinkTabs, .bool(value)): preferences.switchesToLinkTabs = value
			case let (.fetchesUnloadedSiteIcons, .bool(value)): preferences.fetchesUnloadedSiteIcons = value
			case let (.newTabPlacement, .string(value)): preferences.newTabPlacement = try Self.choice(value)
			case let (.openedTabPlacement, .string(value)): preferences.openedTabPlacement = try Self.choice(value)
			case let (.crossSiteLinkFromFavorites, .string(value)):
				preferences.crossSiteLinkFromFavorites = try Self.choice(value)
			case let (.crossSiteLinkFromPinnedTabs, .string(value)):
				preferences.crossSiteLinkFromPinnedTabs = try Self.choice(value)
			case let (.showsLinkStatus, .bool(value)): preferences.showsLinkStatus = value
			case let (.darkPages, .string(value)): preferences.darkPages = try Self.choice(value)
			case let (.appTheme, .string(value)): preferences.appTheme = try Self.choice(value)
			case let (.sidebarPosition, .string(value)): preferences.sidebarPosition = try Self.choice(value)
			case let (.soundsEnabled, .bool(value)): preferences.soundsEnabled = value
			case let (.restoresWindowsAtStartup, .bool(value)): preferences.restoresWindowsAtStartup = value
			case let (.opensEmptyPageAtLaunch, .bool(value)): preferences.opensEmptyPageAtLaunch = value
			case let (.showsUnreadBadges, .bool(value)): preferences.showsUnreadBadges = value
			case let (.hapticsEnabled, .bool(value)): preferences.hapticsEnabled = value
			case let (.keepsPinnedTabsLoaded, .bool(value)): preferences.keepsPinnedTabsLoaded = value
			case let (.protectedMediaPlayback, .string(value)): preferences.webKitPages.protectedMedia = try Self.choice(value)
			case let (.widevineAnswer, .bool(value)): preferences.webKitPages.answersWidevine = value
			default: throw AutomationFailure.invalidValue
			}
		}
		if settings.contains(where: \.key.isAppearance) {
			var resolved = AppearanceOverride(appearance).applied(to: chromeAppearance)

			// Automatic is no accent at all at this level, so the current one isn't kept for it.
			resolved.accent = appearance.accent?.normalized
			preferences.chromeAppearance = resolved
		}
		return preferences
	}

	private static func choice<Value: RawRepresentable<String>>(_ raw: String) throws -> Value {
		guard let value = Value(rawValue: raw) else { throw AutomationFailure.invalidValue }
		return value
	}
}

// MARK: - Routing

/// An Air Traffic Control rule as automation sees and edits it.
public struct AutomationRoutingRule: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var name: String
	public var host: String
	public var includesSubdomains: Bool
	public var scheme: String?
	public var port: Int?
	public var pathPrefix: String?
	public var destination: AutomationRoutingDestination
	public var isEnabled: Bool

	public init(
		id: UUID,
		name: String,
		host: String,
		includesSubdomains: Bool = false,
		scheme: String? = nil,
		port: Int? = nil,
		pathPrefix: String? = nil,
		destination: AutomationRoutingDestination,
		isEnabled: Bool = true
	) {
		self.id = id
		self.name = name
		self.host = host
		self.includesSubdomains = includesSubdomains
		self.scheme = scheme
		self.port = port
		self.pathPrefix = pathPrefix
		self.destination = destination
		self.isEnabled = isEnabled
	}

	public init(_ rule: RoutingRule) {
		self.init(
			id: rule.id,
			name: rule.name,
			host: rule.host,
			includesSubdomains: rule.includesSubdomains,
			scheme: rule.scheme,
			port: rule.port,
			pathPrefix: rule.pathPrefix,
			destination: .init(rule.destination),
			isEnabled: rule.isEnabled
		)
	}

	public var rule: RoutingRule {
		.init(
			id: id,
			name: name,
			host: host,
			includesSubdomains: includesSubdomains,
			scheme: scheme,
			port: port,
			pathPrefix: pathPrefix,
			destination: destination.destination,
			isEnabled: isEnabled
		)
	}

	public func validate() throws {
		guard
			name.utf8.count <= 256,
			host.utf8.count <= 256,
			(pathPrefix?.utf8.count ?? 0) <= 1024
		else { throw AutomationFailure.invalidRequest }
		do {
			try rule.validate()
		} catch {
			throw AutomationFailure.invalidValue
		}
		try destination.validate()
	}
}

public struct AutomationRoutingDestination: Codable, Equatable, Sendable {
	public enum Scope: String, Codable, CaseIterable, Sendable {
		/// The space the link was opened from.
		case currentSpace

		/// The profile's most recently used space.
		case profile
		case space

		/// Nothing opens until the person picks a destination.
		case ask
	}

	public var scope: Scope

	/// The profile or space, for those scopes.
	public var id: UUID?
	public var mode: RoutingWindowMode

	public init(
		scope: Scope,
		id: UUID? = nil,
		mode: RoutingWindowMode
	) {
		self.scope = scope
		self.id = id
		self.mode = mode
	}

	public init(_ destination: RoutingDestination) {
		switch destination.scope {
		case .currentSpace: self.init(scope: .currentSpace, mode: destination.mode)
		case .ask: self.init(scope: .ask, mode: destination.mode)
		case let .profile(id): self.init(scope: .profile, id: id.rawValue, mode: destination.mode)
		case let .space(id): self.init(scope: .space, id: id.rawValue, mode: destination.mode)
		}
	}

	public var destination: RoutingDestination {
		switch (scope, id) {
		case let (.profile, id?): .init(scope: .profile(.init(rawValue: id)), mode: mode)
		case let (.space, id?): .init(scope: .space(.init(rawValue: id)), mode: mode)
		case (.ask, _): .init(scope: .ask, mode: mode)
		default: .init(scope: .currentSpace, mode: mode)
		}
	}

	public func validate() throws {
		let takesID = scope == .profile || scope == .space
		guard takesID == (id != nil) else { throw AutomationFailure.invalidRequest }
	}
}

extension AutomationAccess {
	/// Whether a routing destination stays within the grant: the current space always
	/// does, a profile needs a whole-profile grant and a space needs its own grant.
	public static func permitsRoutingDestination(
		_ destination: RoutingDestination,
		client: AutomationClient,
		organization: BrowserOrganization
	) -> Bool {
		switch destination.scope {
		case .currentSpace, .ask: true
		case let .profile(id): permitsProfile(id, client: client)
		case let .space(id): permitsSpace(id, client: client, organization: organization)
		}
	}
}

// MARK: - Results

public struct AutomationSettingsResult: Codable, Equatable, Sendable {
	public var section: AutomationSettingsRequest.Section

	/// Pass it as `expectedRevision` with the next change of this section.
	public var revision: String
	public var preferences: [AutomationPreferenceEntry]?

	/// With the preferences section: every Settings row and who may change it (DEV-1023).
	public var rows: [AutomationSettingsRow]?
	public var routing: AutomationRoutingSettings?
	public var searchShortcuts: [AutomationSearchShortcut]?
	public var keyboardShortcuts: [AutomationKeyboardBinding]?
	public var extensions: AutomationExtensionSettings?

	/// Set for `installExtension`.
	public var installation: AutomationExtensionInstallation?
	public var sitePermissions: AutomationSitePermissionSettings?
	public var zoom: AutomationZoomSettings?
	public var route: AutomationRouteTest?

	/// Set for a change.
	public var operationID: UUID?

	/// The saved routing rule's ID or search shortcut's keyword.
	public var targetID: String?

	public init(
		section: AutomationSettingsRequest.Section,
		revision: String,
		preferences: [AutomationPreferenceEntry]? = nil,
		rows: [AutomationSettingsRow]? = nil,
		routing: AutomationRoutingSettings? = nil,
		searchShortcuts: [AutomationSearchShortcut]? = nil,
		keyboardShortcuts: [AutomationKeyboardBinding]? = nil,
		extensions: AutomationExtensionSettings? = nil,
		installation: AutomationExtensionInstallation? = nil,
		sitePermissions: AutomationSitePermissionSettings? = nil,
		zoom: AutomationZoomSettings? = nil,
		route: AutomationRouteTest? = nil,
		operationID: UUID? = nil,
		targetID: String? = nil
	) {
		self.section = section
		self.revision = revision
		self.preferences = preferences
		self.rows = rows
		self.routing = routing
		self.searchShortcuts = searchShortcuts
		self.keyboardShortcuts = keyboardShortcuts
		self.extensions = extensions
		self.installation = installation
		self.sitePermissions = sitePermissions
		self.zoom = zoom
		self.route = route
		self.operationID = operationID
		self.targetID = targetID
	}
}

/// A row Settings' search finds, as agents see it (DEV-1023).
public struct AutomationSettingsRow: Codable, Equatable, Sendable {
	/// Who may change a row.
	public enum Access: String, Codable, Sendable {
		/// An agent may change it: through `keys` of the preferences section, or through `section`.
		case agent

		/// Only the person changes it, in Arx.
		case user

		/// Nothing to set: a pane, a page, a button or information.
		case ui
	}

	/// The row's stable identity, such as `row/advanced/haptics`.
	public var id: String
	public var title: String

	/// Where it lives, such as `Advanced › Haptics`.
	public var path: String
	public var access: Access

	/// The preferences it changes, for an agent row of the preferences section.
	public var keys: [AutomationPreferenceKey]?

	/// The section whose actions edit it, for an agent row of another section.
	public var section: AutomationSettingsRequest.Section?

	public init(
		id: String,
		title: String,
		path: String,
		access: Access,
		keys: [AutomationPreferenceKey]? = nil,
		section: AutomationSettingsRequest.Section? = nil
	) {
		self.id = id
		self.title = title
		self.path = path
		self.access = access
		self.keys = keys
		self.section = section
	}
}

public struct AutomationPreferenceEntry: Codable, Equatable, Sendable {
	public var key: AutomationPreferenceKey
	public var value: AutomationPreferenceValue

	/// `boolean`, `choice`, `number` or `color` (a choice, or any `#RRGGBB`).
	public var type: String
	public var choices: [String]?
	public var minimum: Double?
	public var maximum: Double?

	public init(
		key: AutomationPreferenceKey,
		value: AutomationPreferenceValue
	) {
		self.key = key
		self.value = value
		switch key.schema {
		case .boolean:
			self.type = "boolean"
		case let .choice(choices):
			self.type = "choice"
			self.choices = choices
		case let .number(range):
			self.type = "number"
			self.minimum = range.lowerBound
			self.maximum = range.upperBound
		case let .color(names):
			self.type = "color"
			self.choices = names
		}
	}
}

public struct AutomationRoutingSettings: Codable, Equatable, Sendable {
	/// Rules in evaluation order, the first enabled match winning. Rules sending links
	/// outside the grant are left out.
	public var rules: [AutomationRoutingRule]

	/// How many rules are left out.
	public var hiddenRules: Int

	/// Where unmatched links go, when the grant covers it.
	public var fallback: AutomationRoutingDestination?

	public init(
		rules: [AutomationRoutingRule],
		hiddenRules: Int,
		fallback: AutomationRoutingDestination?
	) {
		self.rules = rules
		self.hiddenRules = hiddenRules
		self.fallback = fallback
	}
}

public struct AutomationRouteTest: Codable, Equatable, Sendable {
	/// `rule`, `fallback`, `hiddenRule` (a rule outside the grant matched),
	/// `ungrantedDestination` or `unresolved`.
	public var outcome: String
	public var ruleID: UUID?
	public var ruleName: String?
	public var profileID: UUID?
	public var spaceID: UUID?
	public var mode: RoutingWindowMode?

	public init(
		outcome: String,
		ruleID: UUID? = nil,
		ruleName: String? = nil,
		profileID: UUID? = nil,
		spaceID: UUID? = nil,
		mode: RoutingWindowMode? = nil
	) {
		self.outcome = outcome
		self.ruleID = ruleID
		self.ruleName = ruleName
		self.profileID = profileID
		self.spaceID = spaceID
		self.mode = mode
	}
}

public struct AutomationSearchShortcut: Codable, Equatable, Sendable {
	public var keyword: String
	public var name: String
	public var template: String
	public var homepage: String?
	public var isEnabled: Bool

	public init(_ shortcut: SearchShortcut) {
		self.keyword = shortcut.keyword
		self.name = shortcut.name
		self.template = shortcut.template
		self.homepage = shortcut.homepage?.absoluteString
		self.isEnabled = shortcut.isEnabled
	}
}

/// A key and its modifiers, such as `{"key": "k", "modifiers": ["command", "shift"]}`.
public struct AutomationKeyChord: Codable, Equatable, Sendable {
	public static let modifierNames: [(String, KeyboardShortcut.Modifiers)] = [
		("command", .command),
		("option", .option),
		("shift", .shift),
		("control", .control),
	]

	public var key: String
	public var modifiers: [String]

	public init(
		key: String,
		modifiers: [String]
	) {
		self.key = key
		self.modifiers = modifiers
	}

	public init(_ shortcut: KeyboardShortcut) {
		self.init(
			key: shortcut.key,
			modifiers: Self.modifierNames.filter { shortcut.modifiers.contains($0.1) }.map(\.0)
		)
	}

	/// Nil for an unknown modifier name.
	public var shortcut: KeyboardShortcut? {
		var modifiers: KeyboardShortcut.Modifiers = []
		for name in self.modifiers {
			guard let modifier = Self.modifierNames.first(where: { $0.0 == name })?.1
			else { return nil }
			modifiers.insert(modifier)
		}
		return .init(key: key, modifiers: modifiers)
	}
}

public struct AutomationKeyboardBinding: Codable, Equatable, Sendable {
	public var command: BrowserCommand
	public var shortcut: AutomationKeyChord?

	/// Whether the command still uses its default shortcut.
	public var isDefault: Bool

	/// Who gets its keys when the page would handle them too (DEV-1332).
	public var conflictResolution: ShortcutConflictResolution

	/// Whether `setShortcutConflictResolution` may change it: not for a command that always keeps
	/// its keys, nor while it has no ⌘ shortcut.
	public var conflictResolutionIsFixed: Bool

	public init(
		command: BrowserCommand,
		shortcut: KeyboardShortcut?,
		isDefault: Bool,
		conflictResolution: ShortcutConflictResolution = .arx,
		conflictResolutionIsFixed: Bool = false
	) {
		self.command = command
		self.shortcut = shortcut.map(AutomationKeyChord.init)
		self.isDefault = isDefault
		self.conflictResolution = conflictResolution
		self.conflictResolutionIsFixed = conflictResolutionIsFixed
	}
}

public struct AutomationExtensionSettings: Codable, Equatable, Sendable {
	public var profileID: UUID
	public var items: [AutomationExtensionItem]

	/// Whether `installExtension` is offered: this Arx can install Chrome Web Store items.
	public var canInstall: Bool

	public init(
		profileID: UUID,
		items: [AutomationExtensionItem],
		canInstall: Bool = false
	) {
		self.profileID = profileID
		self.items = items
		self.canInstall = canInstall
	}
}

/// How an `installExtension` ended (DEV-951).
public struct AutomationExtensionInstallation: Codable, Equatable, Sendable {
	public enum Outcome: String, Codable, CaseIterable, Sendable {
		/// The person approved the review and Chromium installed it.
		case installed

		/// The person cancelled the review or closed the Extensions sheet.
		case declined

		/// The profile already has it; there was nothing to review.
		case alreadyInstalled

		/// The store, the package or Chromium refused it; `reason` says why.
		case failed
	}

	public var profileID: UUID
	public var extensionID: String
	public var outcome: Outcome

	/// The verified package's name and version, once Arx has them.
	public var name: String?
	public var version: String?

	/// Why it failed, such as `invalidPackage`, `blockedByPolicy` or `timeout`.
	public var reason: String?

	public init(
		profileID: UUID,
		extensionID: String,
		outcome: Outcome,
		name: String? = nil,
		version: String? = nil,
		reason: String? = nil
	) {
		self.profileID = profileID
		self.extensionID = extensionID
		self.outcome = outcome
		self.name = name.map { String($0.prefix(256)) }
		self.version = version.map { String($0.prefix(64)) }
		self.reason = reason.map { String($0.prefix(256)) }
	}
}

public struct AutomationExtensionItem: Codable, Equatable, Sendable {
	public var id: String
	public var name: String
	public var version: String

	/// `enabled`, `disabled`, `terminated`, `blocklisted` or `blocked`.
	public var state: String
	public var canEnable: Bool
	public var canDisable: Bool
	public var fromWebStore: Bool

	/// New permissions wait for the user's review in Arx Settings before it can be enabled.
	public var permissionsIncreased: Bool
	public var permissions: [String]
	public var hostPermissions: [String]

	public init(_ item: BrowserExtension) {
		self.id = item.id
		self.name = String(item.name.prefix(256))
		self.version = String(item.version.prefix(64))
		self.state = item.state.rawValue
		self.canEnable = item.allows(.enable)
		self.canDisable = item.allows(.disable)
		self.fromWebStore = item.fromWebStore
		self.permissionsIncreased = item.permissionsIncreased
		self.permissions = Array(item.activePermissions.apis.prefix(64))
		self.hostPermissions = Array(item.activePermissions.hosts.prefix(64))
	}
}

public struct AutomationSitePermissionSettings: Codable, Equatable, Sendable {
	public struct Default: Codable, Equatable, Sendable {
		public var permission: SitePermission
		public var setting: SitePermissionSetting

		/// What the default may be set to.
		public var choices: [SitePermissionSetting]

		/// Policy, an extension or supervision decides it.
		public var managed: Bool

		internal init(
			permission: SitePermission,
			setting: SitePermissionSetting,
			choices: [SitePermissionSetting],
			managed: Bool
		) {
			self.permission = permission
			self.setting = setting
			self.choices = choices
			self.managed = managed
		}
	}

	public struct Site: Codable, Equatable, Sendable {
		/// `scheme://host[:port]`, or Chromium's pattern for a wider rule, which can only be removed.
		public var origin: String
		public var permission: SitePermission
		public var setting: SitePermissionSetting
		public var managed: Bool

		internal init(
			origin: String,
			permission: SitePermission,
			setting: SitePermissionSetting,
			managed: Bool
		) {
			self.origin = origin
			self.permission = permission
			self.setting = setting
			self.managed = managed
		}
	}

	public var profileID: UUID
	public var defaults: [Default]
	public var sites: [Site]

	/// Chromium had more sites than a listing carries.
	public var truncated: Bool

	public init(
		profileID: UUID,
		settings: SiteSettings
	) {
		self.profileID = profileID
		self.defaults = settings.defaults.map {
			.init(
				permission: $0.permission,
				setting: $0.setting,
				choices: $0.permission.defaultSettings,
				managed: $0.isManaged
			)
		}
		self.sites = settings.exceptions.map {
			.init(
				origin: $0.origin,
				permission: $0.permission,
				setting: $0.setting,
				managed: $0.isManaged
			)
		}
		self.truncated = settings.isTruncated
	}
}

public struct AutomationZoomSettings: Codable, Equatable, Sendable {
	public var profileID: UUID

	/// The profile's default page zoom, as a factor (1 is 100%).
	public var `default`: Double
	public var sites: [SiteZoom]
	public var minimum: Double
	public var maximum: Double
	public var truncated: Bool

	public init(
		profileID: UUID,
		settings: SiteSettings
	) {
		self.profileID = profileID
		self.default = settings.defaultZoom
		self.sites = settings.zoom
		self.minimum = SiteSettings.zoomRange.lowerBound
		self.maximum = SiteSettings.zoomRange.upperBound
		self.truncated = settings.isTruncated
	}
}

// MARK: - Appearance

/// One field of a profile's or space's appearance override.
public enum AutomationAppearanceField: String, Codable, CaseIterable, Comparable, Sendable {
	case theme
	case tintHue
	case tintIntensity
	case grainEnabled
	case grainIntensity
	case grainSize

	/// A preset's name or `#RRGGBB` (DEV-1134, DEV-1117).
	case accentColor

	/// The chrome takes the shown page's color (DEV-1134, DEV-1101).
	case matchesSite

	/// One or two more colors and an angle, or the tint's own two-tone gradient (DEV-1134, DEV-919).
	case gradient

	public static func < (lhs: Self, rhs: Self) -> Bool {
		lhs.rawValue < rhs.rawValue
	}
}

/// An edit of a profile's or space's appearance override: fields to choose, fields to
/// return to inheriting from the level above, or the whole override cleared first.
public struct AutomationAppearanceChange: Codable, Equatable, Hashable, Sendable {
	public var set: AppearanceOverride
	public var inherit: Set<AutomationAppearanceField>
	public var clearsAll: Bool

	public init(
		set: AppearanceOverride = .init(),
		inherit: Set<AutomationAppearanceField> = [],
		clearsAll: Bool = false
	) {
		self.set = set
		self.inherit = inherit
		self.clearsAll = clearsAll
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			set: try values.decode(AppearanceOverride.self, forKey: .set),
			inherit: Set(try values.decode([AutomationAppearanceField].self, forKey: .inherit)),
			clearsAll: try values.decode(Bool.self, forKey: .clearsAll)
		)
	}

	/// Inherited fields encode sorted, so an equal change always encodes the same.
	public func encode(to encoder: any Encoder) throws {
		var values = encoder.container(keyedBy: CodingKeys.self)
		try values.encode(set, forKey: .set)
		try values.encode(inherit.sorted(), forKey: .inherit)
		try values.encode(clearsAll, forKey: .clearsAll)
	}

	private enum CodingKeys: String, CodingKey {
		case set, inherit, clearsAll
	}

	public var setFields: Set<AutomationAppearanceField> {
		var fields: Set<AutomationAppearanceField> = []
		if set.theme != nil { fields.insert(.theme) }
		if set.tintHue != nil { fields.insert(.tintHue) }
		if set.tintIntensity != nil { fields.insert(.tintIntensity) }
		if set.grainEnabled != nil { fields.insert(.grainEnabled) }
		if set.grainIntensity != nil { fields.insert(.grainIntensity) }
		if set.grainSize != nil { fields.insert(.grainSize) }
		if set.accent != nil { fields.insert(.accentColor) }
		if set.matchesSite != nil { fields.insert(.matchesSite) }
		if set.gradient != nil { fields.insert(.gradient) }
		return fields
	}

	public func validate() throws {
		guard
			clearsAll || !setFields.isEmpty || !inherit.isEmpty,
			setFields.isDisjoint(with: inherit)
		else { throw AutomationFailure.invalidRequest }

		let numbers: [(Double?, ClosedRange<Double>)] = [
			(set.tintHue, 0 ... 360),
			(set.tintIntensity, 0 ... 1),
			(set.grainIntensity, ChromeGrain.intensityRange),
			(set.grainSize, ChromeGrain.sizeRange),
		]
		for (value, range) in numbers {
			guard let value else { continue }
			guard value.isFinite, range.contains(value) else { throw AutomationFailure.invalidValue }
		}
		if let accent = set.accent {
			guard [accent.red, accent.green, accent.blue].allSatisfy({ $0.isFinite && (0 ... 1).contains($0) })
			else { throw AutomationFailure.invalidValue }
		}
		if let gradient = set.gradient {
			// As the editor offers it: one or two more colors, each a tint, at an angle on the circle.
			guard
				gradient.stops.count <= ChromeGradient.maximumStops,
				gradient.angle.isFinite,
				(0 ... 360).contains(gradient.angle),
				gradient.stops.allSatisfy({ stop in
					stop.hue.isFinite && (0 ... 360).contains(stop.hue)
					&& stop.intensity.isFinite && (0 ... 1).contains(stop.intensity)
				})
			else { throw AutomationFailure.invalidValue }
		}
	}

	/// The override after this change. A hue of 360 is stored as 0, as Settings stores it.
	public func applied(to current: AppearanceOverride?) -> AppearanceOverride {
		var result = clearsAll ? AppearanceOverride() : (current ?? .init())
		for field in inherit {
			switch field {
			case .theme: result.theme = nil
			case .tintHue: result.tintHue = nil
			case .tintIntensity: result.tintIntensity = nil
			case .grainEnabled: result.grainEnabled = nil
			case .grainIntensity: result.grainIntensity = nil
			case .grainSize: result.grainSize = nil
			case .accentColor: result.accent = nil
			case .matchesSite: result.matchesSite = nil
			case .gradient: result.gradient = nil
			}
		}
		if let theme = set.theme { result.theme = theme }
		if let hue = set.tintHue { result.tintHue = hue.truncatingRemainder(dividingBy: 360) }
		if let intensity = set.tintIntensity { result.tintIntensity = intensity }
		if let enabled = set.grainEnabled { result.grainEnabled = enabled }
		if let intensity = set.grainIntensity { result.grainIntensity = intensity }
		if let size = set.grainSize { result.grainSize = size }
		if let accent = set.accent?.normalized { result.accent = accent }
		if let matchesSite = set.matchesSite { result.matchesSite = matchesSite }
		if let gradient = set.gradient?.normalized { result.gradient = gradient }
		return result
	}
}

/// What a profile or space looks like once every inherited setting is filled in.
public struct AutomationResolvedAppearance: Codable, Equatable, Sendable {
	/// `light`, `dark` or `system`.
	public var theme: String
	public var tintHue: Double
	public var tintIntensity: Double
	public var grainEnabled: Bool
	public var grainIntensity: Double
	public var grainSize: Double

	/// `automatic`, a preset's name or `#RRGGBB` (DEV-1134).
	public var accentColor: String

	/// Whether the chrome takes the shown page's color, while the Match site feature flag is on: the
	/// space's choice, else its profile's, else Settings' (DEV-1170).
	public var matchesSite: Bool

	/// The colors after the tint's own, or nil for the tint's two-tone gradient.
	public var gradient: ChromeGradient?

	public init(
		global: ChromeAppearance,
		profile: AppearanceOverride?,
		space: AppearanceOverride?
	) {
		let chrome = ChromeAppearance.resolve(global: global, profile: profile, space: space)
		self.theme = (space?.theme ?? profile?.theme)?.rawValue ?? "system"
		self.tintHue = chrome.tint.hue
		self.tintIntensity = chrome.tint.intensity
		self.grainEnabled = chrome.grain.isEnabled
		self.grainIntensity = chrome.grain.intensity
		self.grainSize = chrome.grain.size
		self.accentColor = ChromeAccent.automationName(of: chrome.accent)
		self.matchesSite = chrome.matchesSite
		self.gradient = chrome.gradient
	}
}
