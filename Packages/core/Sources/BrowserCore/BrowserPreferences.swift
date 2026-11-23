import Foundation

public struct BrowserPreferences: Codable, Equatable, Sendable {
	public var grainEnabled: Bool
	public var grainIntensity: Double
	public var grainSize: Double

	/// The window chrome's color. Profiles and spaces can override it.
	public var chromeTint: ChromeTint

	/// The app-wide accent color (DEV-1117), or nil for Automatic.
	public var chromeAccent: ChromeAccent?

	/// The app-wide Match site (DEV-1101, DEV-1170): whether the chrome takes the shown page's
	/// color. Profiles and spaces can override it.
	public var chromeMatchesSite: Bool
	public var searchShortcuts: [SearchShortcut]
	public var keyboardShortcuts: [ShortcutBinding]

	/// Words that find commands in the command bar. Validated: write it only from a reducer.
	public var commandAliases: [CommandAlias]

	/// Conflict resolution (DEV-1332): who gets a command's keys when the page would handle them
	/// too, where the person chose other than the command's default. Kept on this Mac: it's in no
	/// synced preference domain.
	public var shortcutConflictChoices: [ShortcutConflictOverride]
	public var proxyLinkRules: [ProxyLinkRule]

	/// The default Proxy Links rules this Mac has already offered, sorted, so a default someone
	/// removed doesn't come back (DEV-1003). Stays on this Mac.
	public var offeredProxyLinkDefaults: [UUID]

	/// The default Proxy Links rules the person deleted, sorted, so no Mac offers them again until
	/// Restore Default Links (DEV-1113). Synced with the routing preferences.
	public var removedProxyLinkDefaults: [UUID]
	public var globalLittleArxEnabled: Bool
	public var routing: RoutingPreferences
	public var automation: AutomationPreferences
	public var automaticPictureInPicture: AutomaticPiPPreferences
	public var windowPresentations: [BrowserWindowPresentation]

	/// What new windows start with: the width most recently set in any saved window.
	public var lastSidebarWidth: Double?

	/// App-wide. Gates DevTools and Inspect Element for every profile; reload
	/// variants stay available without it.
	public var developerModeEnabled: Bool

	/// Introduction dismissal and finished setup steps, persisted separately.
	public var onboarding: OnboardingPreferences
	public var migrationLedger: MigrationLedger

	/// Where a Shift-click opens a link: Peek unless the person chose otherwise (DEV-1239).
	public var shiftClickLinkAction: ShiftClickLinkAction
	public var littleArxLinkBinding: LittleArxLinkBinding
	public var forceClickLinkAction: ForceClickLinkAction

	/// Where a plain click on a link to another site in a Favorite opens it: Peek unless the
	/// person chose otherwise (DEV-727, DEV-1239).
	public var crossSiteLinkFromFavorites: CrossSiteLinkAction

	/// Where a plain click on a link to another site in a pinned tab, in a space or one of its
	/// folders, opens it: the tab itself unless the person chose otherwise (DEV-727, DEV-1239).
	public var crossSiteLinkFromPinnedTabs: CrossSiteLinkAction

	/// Hovering a page link shows where it goes, and what a click with the held modifier keys
	/// will do, at the page's bottom corner (DEV-1111).
	public var showsLinkStatus: Bool

	/// ⌘Q asks before closing every window.
	public var warnsBeforeQuitting: Bool
	public var littleArxLauncherPosition: LittleArxLauncherPosition

	/// Archives Little Arx windows left unused this long (DEV-1138), or nil for never.
	public var littleArxArchiveInterval: LittleArxArchiveInterval?

	/// How the Runway, the picker that asks which profile a link opens in, looks.
	public var runwayAppearance: RunwayAppearance

	/// The Settings identity card's look, chosen with its cycle button.
	public var identityCardStyle: IdentityCardStyle

	/// Launch reopens the normal windows, spaces and split layouts open at quit.
	public var restoresWindowsAtStartup: Bool

	/// Haptics on a Force Touch trackpad, such as while reordering tabs.
	public var hapticsEnabled: Bool

	/// Sound feedback for Arx's own interface (DEV-1256): a capture copied or saved, a download
	/// finished, and one that failed or a capture that couldn't be taken. Off by default.
	public var soundsEnabled: Bool

	/// Light, dark, or the system's appearance, for every Arx window.
	public var appTheme: AppTheme

	/// The Dock icon while Arx runs: dark unless chosen otherwise (DEV-839).
	public var appIcon: AppIconStyle

	/// Resting the pointer on a sidebar tab or folder opens its preview.
	public var hoverPreviewsEnabled: Bool

	/// What hover previews show for folders and favorite sites (DEV-802).
	public var hoverPreviewSources: HoverPreviewSources

	/// With developer mode on, local development pages show the developer header (DEV-733).
	public var developerHeaderEnabled: Bool

	/// Sidebar rows of local-network pages get a construction-tape border and their host:port,
	/// with or without developer mode (DEV-786).
	public var localTabHighlightEnabled: Bool

	/// Delete in an already-empty command bar or address field closes it, as Esc does (DEV-750).
	public var closesCommandBarOnEmptyDelete: Bool

	/// Favorites and pinned tabs that haven't loaded get their icon from the site when the
	/// profile has none yet, without cookies (DEV-796). On by default.
	public var fetchesUnloadedSiteIcons: Bool

	/// How long a hidden tab keeps its page loaded before Arx unloads it to free memory
	/// (DEV-873). Critical memory pressure unloads hidden tabs sooner, whatever this says.
	public var tabUnloadDelay: TabUnloadDelay

	/// How long a tab stays hidden before critical memory pressure may unload it (DEV-873).
	public var tabUnloadPressureGrace: TabUnloadPressureGrace

	/// Pinned tabs and Favorites never unload, like sites a profile keeps loaded (DEV-932).
	/// Off by default.
	public var keepsPinnedTabsLoaded: Bool

	/// Filling a saved password into a page asks for Touch ID or the login password first,
	/// as revealing one in Settings does (DEV-875). On by default; cards always ask.
	public var asksBeforeFillingPasswords: Bool

	/// Ordinary profiles fill saved addresses and payment cards into forms (DEV-893).
	/// On by default; private windows never fill them.
	public var fillsAddresses: Bool
	public var fillsPaymentCards: Bool

	/// Arx's content blocking (Helium's uBlock Origin) in every profile (DEV-884). On by default.
	public var blocksContent: Bool

	/// Selects uBlock's cookie notice lists while content blocking is on (DEV-884). Off by default.
	public var blocksCookieBanners: Bool

	/// The window side the sidebar sits on (DEV-913). Left by default.
	public var sidebarPosition: SidebarPosition

	/// Where new tabs open among a space's open tabs (DEV-913). At the bottom by default.
	///
	/// While `ARX_NEW_TABS_AT_TOP` is on (DEV-1174) this places only tabs links open (Settings ›
	/// General › Tabs from links open), and `openedTabPlacement` places tabs from the New Tab
	/// button, ⌘T and ⌘K. It keeps its name and stored value, so links stay where they went and
	/// an older build, or the flag off, reads the same choice as before.
	public var newTabPlacement: NewTabPlacement

	/// Where a tab from the New Tab button, ⌘T or ⌘K opens while `ARX_NEW_TABS_AT_TOP` is on
	/// (DEV-1174): Settings › General › New tabs open. At the top by default.
	public var openedTabPlacement: NewTabPlacement

	/// A tab a link opens comes forward instead of opening behind the page (DEV-952): Open in
	/// New Tab from the link menu, ⌘-click and middle-click. ⇧⌘-click does the opposite. Off by
	/// default, as in Chrome and Safari.
	public var switchesToLinkTabs: Bool

	/// A launch opens to the empty page (DEV-1234): no space has a tab selected, no window shows
	/// one and every folder is collapsed. On by default; a window opened while Arx runs is
	/// unaffected. Stays on this Mac, like the folder and selection state it resets.
	public var opensEmptyPageAtLaunch: Bool

	/// The browser default for unread badges on tabs and Favorites (DEV-907, DEV-1258). On by
	/// default; a profile, a site or a tab may choose otherwise. Stays on this Mac.
	public var showsUnreadBadges: Bool

	/// The site level of unread badges, by host without "www." (DEV-1258). Stays on this Mac.
	/// Replaces the hidden sites of DEV-907, which read back as `.hide`.
	public var unreadBadgeSites: [String: UnreadBadgeVisibility]

	/// The tab level of unread badges, by open tab (DEV-1258). Stays on this Mac.
	public var unreadBadgeTabs: [Tab.ID: UnreadBadgeVisibility]

	/// Offers the front window's page to Handoff on this person's other devices (DEV-922). On by default.
	public var handoffEnabled: Bool

	/// Settings › Advanced › WebKit: the sites that open in WebKit pages (DEV-877).
	public var webKitPages: WebKitPagePreferences

	/// Settings › General › Battery Saver (DEV-915).
	public var batterySaver: BatterySaverMode

	/// Each profile's Never translate sites and Always translate languages (DEV-904).
	public var translation: TranslationPreferences

	/// AppleScript's `execute` runs JavaScript in a tab (DEV-909). Off by default; only with
	/// developer mode on, never in private windows or headless runs.
	public var appleScriptJavaScriptEnabled: Bool

	/// A notification click nobody answered opens the site when its tab is closed (DEV-885).
	/// On by default; off does what Chrome does.
	public var notificationsOpenClosedSites: Bool

	/// Dark pages (DEV-1020): when sites without a dark look of their own are darkened. Off by
	/// default, and only offered while the `ARX_DARK_PAGES` feature flag is on.
	public var darkPages: DarkPagesMode

	/// When each unpinned tab of a profile that archives automatically was last on screen.
	/// Only kept while some profile archives; stays on this Mac.
	public var tabsLastViewed: [Tab.ID: Date]

	/// Opt-in experiments from Settings' Experimental pane.
	public var experiments: ExperimentalPreferences
	/// When this Arx was first installed on this Mac, recorded once at launch (DEV-1323): the
	/// identity card's "Member since". `nil` until then. Stays on this Mac, except its day, which
	/// a member number's sign-in sends; see ``InstallDate``.
	public var installedAt: Date?

	public init(
		grainEnabled: Bool = true,
		grainIntensity: Double = 0.18,
		grainSize: Double = 1,
		chromeTint: ChromeTint = .default,
		chromeAccent: ChromeAccent? = nil,
		chromeMatchesSite: Bool = false,
		searchShortcuts: [SearchShortcut] = [],
		keyboardShortcuts: [ShortcutBinding] = [],
		commandAliases: [CommandAlias] = [],
		shortcutConflictChoices: [ShortcutConflictOverride] = [],
		proxyLinkRules: [ProxyLinkRule] = [],
		offeredProxyLinkDefaults: [UUID] = [],
		removedProxyLinkDefaults: [UUID] = [],
		globalLittleArxEnabled: Bool = false,
		routing: RoutingPreferences = .init(),
		automation: AutomationPreferences = .init(),
		automaticPictureInPicture: AutomaticPiPPreferences = .init(),
		windowPresentations: [BrowserWindowPresentation] = [],
		lastSidebarWidth: Double? = nil,
		developerModeEnabled: Bool = false,
		onboarding: OnboardingPreferences = .init(),
		migrationLedger: MigrationLedger = .init(),
		shiftClickLinkAction: ShiftClickLinkAction = .peek,
		littleArxLinkBinding: LittleArxLinkBinding = .optionCommand,
		forceClickLinkAction: ForceClickLinkAction = .peek,
		crossSiteLinkFromFavorites: CrossSiteLinkAction = .peek,
		crossSiteLinkFromPinnedTabs: CrossSiteLinkAction = .currentTab,
		showsLinkStatus: Bool = true,
		warnsBeforeQuitting: Bool = true,
		littleArxLauncherPosition: LittleArxLauncherPosition = .topRight,
		littleArxArchiveInterval: LittleArxArchiveInterval? = nil,
		runwayAppearance: RunwayAppearance = .regular,
		identityCardStyle: IdentityCardStyle = .holographicFoil,
		restoresWindowsAtStartup: Bool = true,
		hapticsEnabled: Bool = true,
		soundsEnabled: Bool = false,
		appTheme: AppTheme = .system,
		appIcon: AppIconStyle = .dark,
		hoverPreviewsEnabled: Bool = true,
		hoverPreviewSources: HoverPreviewSources = .init(),
		developerHeaderEnabled: Bool = true,
		localTabHighlightEnabled: Bool = true,
		closesCommandBarOnEmptyDelete: Bool = true,
		fetchesUnloadedSiteIcons: Bool = true,
		tabUnloadDelay: TabUnloadDelay = .provisionalDefault,
		tabUnloadPressureGrace: TabUnloadPressureGrace = .provisionalDefault,
		keepsPinnedTabsLoaded: Bool = false,
		asksBeforeFillingPasswords: Bool = true,
		fillsAddresses: Bool = true,
		fillsPaymentCards: Bool = true,
		blocksContent: Bool = true,
		blocksCookieBanners: Bool = false,
		sidebarPosition: SidebarPosition = .left,
		newTabPlacement: NewTabPlacement = .bottom,
		openedTabPlacement: NewTabPlacement = .top,
		switchesToLinkTabs: Bool = false,
		opensEmptyPageAtLaunch: Bool = true,
		showsUnreadBadges: Bool = true,
		unreadBadgeSites: [String: UnreadBadgeVisibility] = [:],
		unreadBadgeTabs: [Tab.ID: UnreadBadgeVisibility] = [:],
		handoffEnabled: Bool = true,
		webKitPages: WebKitPagePreferences = .init(),
		batterySaver: BatterySaverMode = .whenBatteryLow,
		translation: TranslationPreferences = .init(),
		appleScriptJavaScriptEnabled: Bool = false,
		notificationsOpenClosedSites: Bool = true,
		darkPages: DarkPagesMode = .off,
		tabsLastViewed: [Tab.ID: Date] = [:],
		experiments: ExperimentalPreferences = .init(),
		installedAt: Date? = nil
	) {
		self.grainEnabled = grainEnabled
		self.grainIntensity = grainIntensity
		self.grainSize = grainSize
		self.chromeTint = chromeTint
		self.chromeAccent = chromeAccent
		self.chromeMatchesSite = chromeMatchesSite
		self.searchShortcuts = searchShortcuts
		self.keyboardShortcuts = keyboardShortcuts
		self.commandAliases = commandAliases
		self.shortcutConflictChoices = shortcutConflictChoices
		self.proxyLinkRules = proxyLinkRules
		self.offeredProxyLinkDefaults = offeredProxyLinkDefaults
		self.removedProxyLinkDefaults = removedProxyLinkDefaults
		self.globalLittleArxEnabled = globalLittleArxEnabled
		self.routing = routing
		self.automation = automation
		self.automaticPictureInPicture = automaticPictureInPicture
		self.windowPresentations = windowPresentations
		self.lastSidebarWidth = lastSidebarWidth
		self.developerModeEnabled = developerModeEnabled
		self.onboarding = onboarding
		self.migrationLedger = migrationLedger
		self.shiftClickLinkAction = shiftClickLinkAction
		self.littleArxLinkBinding = littleArxLinkBinding
		self.forceClickLinkAction = forceClickLinkAction
		self.crossSiteLinkFromFavorites = crossSiteLinkFromFavorites
		self.crossSiteLinkFromPinnedTabs = crossSiteLinkFromPinnedTabs
		self.showsLinkStatus = showsLinkStatus
		self.warnsBeforeQuitting = warnsBeforeQuitting
		self.littleArxLauncherPosition = littleArxLauncherPosition
		self.littleArxArchiveInterval = littleArxArchiveInterval
		self.runwayAppearance = runwayAppearance
		self.identityCardStyle = identityCardStyle
		self.restoresWindowsAtStartup = restoresWindowsAtStartup
		self.hapticsEnabled = hapticsEnabled
		self.soundsEnabled = soundsEnabled
		self.appTheme = appTheme
		self.appIcon = appIcon
		self.hoverPreviewsEnabled = hoverPreviewsEnabled
		self.hoverPreviewSources = hoverPreviewSources
		self.developerHeaderEnabled = developerHeaderEnabled
		self.localTabHighlightEnabled = localTabHighlightEnabled
		self.closesCommandBarOnEmptyDelete = closesCommandBarOnEmptyDelete
		self.fetchesUnloadedSiteIcons = fetchesUnloadedSiteIcons
		self.tabUnloadDelay = tabUnloadDelay
		self.tabUnloadPressureGrace = tabUnloadPressureGrace
		self.keepsPinnedTabsLoaded = keepsPinnedTabsLoaded
		self.asksBeforeFillingPasswords = asksBeforeFillingPasswords
		self.fillsAddresses = fillsAddresses
		self.fillsPaymentCards = fillsPaymentCards
		self.blocksContent = blocksContent
		self.blocksCookieBanners = blocksCookieBanners
		self.sidebarPosition = sidebarPosition
		self.newTabPlacement = newTabPlacement
		self.openedTabPlacement = openedTabPlacement
		self.switchesToLinkTabs = switchesToLinkTabs
		self.opensEmptyPageAtLaunch = opensEmptyPageAtLaunch
		self.showsUnreadBadges = showsUnreadBadges
		self.unreadBadgeSites = unreadBadgeSites
		self.unreadBadgeTabs = unreadBadgeTabs
		self.handoffEnabled = handoffEnabled
		self.webKitPages = webKitPages
		self.batterySaver = batterySaver
		self.translation = translation
		self.appleScriptJavaScriptEnabled = appleScriptJavaScriptEnabled
		self.notificationsOpenClosedSites = notificationsOpenClosedSites
		self.darkPages = darkPages
		self.tabsLastViewed = tabsLastViewed
		self.experiments = experiments
		self.installedAt = installedAt
	}

	/// Keys older files have that no field reads directly any more.
	private enum LegacyCodingKeys: String, CodingKey {
		/// DEV-907's hidden sites, before DEV-1258 made them the site level.
		case hiddenUnreadBadgeSites
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.grainEnabled = try values.decode(Bool.self, forKey: .grainEnabled)
		self.grainIntensity = try values.decode(Double.self, forKey: .grainIntensity)
		self.grainSize = try values.decode(Double.self, forKey: .grainSize)

		// Saved before tints were configurable: keep the colors Arx shipped with.
		self.chromeTint = (try? values.decodeIfPresent(ChromeTint.self, forKey: .chromeTint))?.normalized ?? .default

		// Saved before accents were configurable: Automatic.
		self.chromeAccent = (try? values.decodeIfPresent(ChromeAccent.self, forKey: .chromeAccent))?.normalized

		// Saved before Match site had a browser default: off, as every space without its own was.
		self.chromeMatchesSite = (try? values.decodeIfPresent(Bool.self, forKey: .chromeMatchesSite)) ?? false
		self.searchShortcuts = try values.decode([SearchShortcut].self, forKey: .searchShortcuts)
		self.keyboardShortcuts = try values.decodeIfPresent([ShortcutBinding].self, forKey: .keyboardShortcuts) ?? []
		self.commandAliases = try values.decodeIfPresent([CommandAlias].self, forKey: .commandAliases) ?? []

		// Saved before Conflict resolution (DEV-1332), or naming a command this version doesn't
		// have: every command keeps its default.
		self.shortcutConflictChoices = (try? values.decodeIfPresent(
			[ShortcutConflictOverride].self,
			forKey: .shortcutConflictChoices
		)) ?? []
		self.proxyLinkRules = try values.decodeIfPresent([ProxyLinkRule].self, forKey: .proxyLinkRules) ?? []

		// Saved before the defaults existed: none offered yet.
		self.offeredProxyLinkDefaults = (try? values.decodeIfPresent([UUID].self, forKey: .offeredProxyLinkDefaults)) ?? []

		// Saved before defaults could be deleted: none deleted.
		self.removedProxyLinkDefaults = (try? values.decodeIfPresent([UUID].self, forKey: .removedProxyLinkDefaults)) ?? []
		self.globalLittleArxEnabled = try values.decodeIfPresent(Bool.self, forKey: .globalLittleArxEnabled) ?? false
		self.routing = try values.decodeIfPresent(RoutingPreferences.self, forKey: .routing) ?? .init()
		self.automation = try values.decodeIfPresent(AutomationPreferences.self, forKey: .automation) ?? .init()
		self.automaticPictureInPicture = try values.decodeIfPresent(
			AutomaticPiPPreferences.self,
			forKey: .automaticPictureInPicture
		) ?? .init()
		self.windowPresentations = try values.decodeIfPresent(
			[BrowserWindowPresentation].self,
			forKey: .windowPresentations
		) ?? []
		self.lastSidebarWidth = try values.decodeIfPresent(Double.self, forKey: .lastSidebarWidth)
		self.developerModeEnabled = try values.decodeIfPresent(Bool.self, forKey: .developerModeEnabled) ?? false
		self.onboarding = try values.decodeIfPresent(OnboardingPreferences.self, forKey: .onboarding) ?? .init()
		self.migrationLedger = try values.decodeIfPresent(MigrationLedger.self, forKey: .migrationLedger) ?? .init()

		// Saved before each link gesture chose where it opens (DEV-1239), these were switches:
		// Peek, or what Chromium does with the click.
		let legacy = try decoder.container(keyedBy: LegacyLinkClickKeys.self)
		self.shiftClickLinkAction = try values.decodeIfPresent(
			ShiftClickLinkAction.self,
			forKey: .shiftClickLinkAction
		) ?? legacy.decodeIfPresent(Bool.self, forKey: .shiftClickPeekEnabled).map { $0 ? .peek : .newWindow } ?? .peek
		self.littleArxLinkBinding = try values.decodeIfPresent(
			LittleArxLinkBinding.self,
			forKey: .littleArxLinkBinding
		) ?? .optionCommand
		self.forceClickLinkAction = try values.decodeIfPresent(
			ForceClickLinkAction.self,
			forKey: .forceClickLinkAction
		) ?? .peek
		self.crossSiteLinkFromFavorites = try values.decodeIfPresent(
			CrossSiteLinkAction.self,
			forKey: .crossSiteLinkFromFavorites
		) ?? legacy.decodeIfPresent(Bool.self, forKey: .crossSitePeekFromFavorites).map { $0 ? .peek : .currentTab } ?? .peek
		self.crossSiteLinkFromPinnedTabs = try values.decodeIfPresent(
			CrossSiteLinkAction.self,
			forKey: .crossSiteLinkFromPinnedTabs
		) ?? legacy.decodeIfPresent(Bool.self, forKey: .crossSitePeekFromPinnedTabs).map { $0 ? .peek : .currentTab }
		?? .currentTab
		self.showsLinkStatus = try values.decodeIfPresent(Bool.self, forKey: .showsLinkStatus) ?? true
		self.warnsBeforeQuitting = try values.decodeIfPresent(Bool.self, forKey: .warnsBeforeQuitting) ?? true
		self.littleArxLauncherPosition = try values.decodeIfPresent(
			LittleArxLauncherPosition.self,
			forKey: .littleArxLauncherPosition
		) ?? .topRight

		// Saved before Little Arx windows were archived (DEV-1138), or a choice this build
		// doesn't know: never.
		self.littleArxArchiveInterval = try? values.decodeIfPresent(
			LittleArxArchiveInterval.self,
			forKey: .littleArxArchiveInterval
		)

		// Saved before the Runway had a choice of looks, or a look this build doesn't know.
		self.runwayAppearance = (try? values.decodeIfPresent(
			RunwayAppearance.self,
			forKey: .runwayAppearance
		)) ?? .regular

		// A style this build doesn't know (from a newer one) falls back instead of
		// failing every other preference.
		let identityCardStyle: String? = (try? values.decodeIfPresent(String.self, forKey: .identityCardStyle)) ?? nil
		self.identityCardStyle = identityCardStyle.flatMap(IdentityCardStyle.init(rawValue:)) ?? .holographicFoil

		// Saved before these were settings: windows were always restored, and the one haptic played.
		self.restoresWindowsAtStartup = try values.decodeIfPresent(Bool.self, forKey: .restoresWindowsAtStartup) ?? true
		self.hapticsEnabled = try values.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
		self.soundsEnabled = try values.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? false

		// A theme this build doesn't know (from a newer one) follows the system.
		let appTheme: String? = (try? values.decodeIfPresent(String.self, forKey: .appTheme)) ?? nil
		self.appTheme = appTheme.flatMap(AppTheme.init(rawValue:)) ?? .system

		// An icon this build doesn't know (from a newer one) falls back to the default.
		let appIcon: String? = (try? values.decodeIfPresent(String.self, forKey: .appIcon)) ?? nil
		self.appIcon = appIcon.flatMap(AppIconStyle.init(rawValue:)) ?? .dark
		self.hoverPreviewsEnabled = try values.decodeIfPresent(Bool.self, forKey: .hoverPreviewsEnabled) ?? true
		self.hoverPreviewSources = (try? values.decodeIfPresent(
			HoverPreviewSources.self,
			forKey: .hoverPreviewSources
		)) ?? .init()
		self.developerHeaderEnabled = try values.decodeIfPresent(Bool.self, forKey: .developerHeaderEnabled) ?? true
		self.localTabHighlightEnabled = try values.decodeIfPresent(
			Bool.self,
			forKey: .localTabHighlightEnabled
		) ?? true
		self.closesCommandBarOnEmptyDelete = try values.decodeIfPresent(
			Bool.self,
			forKey: .closesCommandBarOnEmptyDelete
		) ?? true
		self.fetchesUnloadedSiteIcons = try values.decodeIfPresent(
			Bool.self,
			forKey: .fetchesUnloadedSiteIcons
		) ?? true

		// A delay this build doesn't know (from a newer one) falls back to the default.
		let tabUnloadDelay: String? = (try? values.decodeIfPresent(String.self, forKey: .tabUnloadDelay)) ?? nil
		self.tabUnloadDelay = tabUnloadDelay.flatMap(TabUnloadDelay.init(rawValue:)) ?? .provisionalDefault
		let tabUnloadPressureGrace: String? = (try? values.decodeIfPresent(
			String.self,
			forKey: .tabUnloadPressureGrace
		)) ?? nil
		self.tabUnloadPressureGrace = tabUnloadPressureGrace.flatMap(TabUnloadPressureGrace.init(rawValue:))
		?? .provisionalDefault
		self.keepsPinnedTabsLoaded = (try? values.decodeIfPresent(Bool.self, forKey: .keepsPinnedTabsLoaded)) ?? false
		self.asksBeforeFillingPasswords = try values.decodeIfPresent(
			Bool.self,
			forKey: .asksBeforeFillingPasswords
		) ?? true
		self.fillsAddresses = try values.decodeIfPresent(Bool.self, forKey: .fillsAddresses) ?? true
		self.fillsPaymentCards = try values.decodeIfPresent(Bool.self, forKey: .fillsPaymentCards) ?? true
		self.blocksContent = try values.decodeIfPresent(Bool.self, forKey: .blocksContent) ?? true
		self.blocksCookieBanners = try values.decodeIfPresent(Bool.self, forKey: .blocksCookieBanners) ?? false

		// Saved before these were settings, or by a newer build with more choices: the defaults.
		let sidebarPosition: String? = (try? values.decodeIfPresent(String.self, forKey: .sidebarPosition)) ?? nil
		self.sidebarPosition = sidebarPosition.flatMap(SidebarPosition.init(rawValue:)) ?? .left
		let newTabPlacement: String? = (try? values.decodeIfPresent(String.self, forKey: .newTabPlacement)) ?? nil
		self.newTabPlacement = newTabPlacement.flatMap(NewTabPlacement.init(rawValue:)) ?? .bottom

		// Saved before DEV-1174 split the setting: the New Tab button, ⌘T and ⌘K open at the top,
		// while the choice saved above goes on placing tabs links open.
		let openedTabPlacement: String? = (try? values.decodeIfPresent(String.self, forKey: .openedTabPlacement)) ?? nil
		self.openedTabPlacement = openedTabPlacement.flatMap(NewTabPlacement.init(rawValue:)) ?? .top
		self.switchesToLinkTabs = (try? values.decodeIfPresent(Bool.self, forKey: .switchesToLinkTabs)) ?? false

		// Saved before DEV-1234: on, the default.
		self.opensEmptyPageAtLaunch = (try? values.decodeIfPresent(Bool.self, forKey: .opensEmptyPageAtLaunch)) ?? true

		// Saved before DEV-1258: on, the default.
		self.showsUnreadBadges = (try? values.decodeIfPresent(Bool.self, forKey: .showsUnreadBadges)) ?? true
		if let sites = try? values.decodeIfPresent([String: UnreadBadgeVisibility].self, forKey: .unreadBadgeSites) {
			self.unreadBadgeSites = sites
		} else {
			// Saved before DEV-1258: the sites DEV-907 hid are hidden at the site level.
			let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
			let hidden: [String] = (try? legacy.decodeIfPresent([String].self, forKey: .hiddenUnreadBadgeSites)) ?? []
			self.unreadBadgeSites = Dictionary(hidden.map { ($0, .hide) }) { first, _ in first }
		}
		self.unreadBadgeTabs = (try? values.decodeIfPresent([Tab.ID: UnreadBadgeVisibility].self, forKey: .unreadBadgeTabs)) ?? [:]
		self.handoffEnabled = try values.decodeIfPresent(Bool.self, forKey: .handoffEnabled) ?? true
		self.webKitPages = (try? values.decodeIfPresent(WebKitPagePreferences.self, forKey: .webKitPages)) ?? .init()

		// A choice this build doesn't know (from a newer one) falls back to the default.
		let batterySaver: String? = (try? values.decodeIfPresent(String.self, forKey: .batterySaver)) ?? nil
		self.batterySaver = batterySaver.flatMap(BatterySaverMode.init(rawValue:)) ?? .whenBatteryLow
		self.translation = (try? values.decodeIfPresent(TranslationPreferences.self, forKey: .translation)) ?? .init()
		self.appleScriptJavaScriptEnabled = try values.decodeIfPresent(Bool.self, forKey: .appleScriptJavaScriptEnabled) ?? false
		self.notificationsOpenClosedSites = try values.decodeIfPresent(Bool.self, forKey: .notificationsOpenClosedSites) ?? true

		// A mode this build doesn't know (from a newer one) is off.
		let darkPages: String? = (try? values.decodeIfPresent(String.self, forKey: .darkPages)) ?? nil
		self.darkPages = darkPages.flatMap(DarkPagesMode.init(rawValue:)) ?? .off
		self.tabsLastViewed = (try? values.decodeIfPresent([Tab.ID: Date].self, forKey: .tabsLastViewed)) ?? [:]

		// Experiments come and go: a missing or unreadable set starts from the defaults.
		self.experiments = (try? values.decodeIfPresent(ExperimentalPreferences.self, forKey: .experiments)) ?? .init()
		// Saved before DEV-1323, or unreadable: recorded again at the next launch.
		self.installedAt = (try? values.decodeIfPresent(Date.self, forKey: .installedAt)) ?? nil
	}

	/// Adds each default Proxy Links rule this Mac hasn't offered yet, after the person's own
	/// rules, then remembers it as offered (DEV-1003). A first launch gets all of them; an
	/// existing install gets them once. A default is skipped when a rule with its ID is there, when
	/// a rule already handles any of the same links, so nothing is duplicated or overridden, or
	/// when the person deleted it on any Mac (``removedProxyLinkDefaults``, DEV-1113).
	///
	/// - Returns: whether anything changed, so the caller saves.
	@discardableResult
	public mutating func offerDefaultProxyLinkRules() -> Bool {
		var offered: Set<UUID> = Set(offeredProxyLinkDefaults)
		let removed: Set<UUID> = Set(removedProxyLinkDefaults)
		var changed: Bool = false
		for rule in ProxyLinkRule.defaults where offered.insert(rule.id).inserted {
			changed = true
			guard !removed.contains(rule.id) else { continue }

			// Either way round: a rule for `vm.tiktok.com` overlaps the default for `tiktok.com`
			// and its subdomains.
			let isHandled = proxyLinkRules.contains { existing in
				existing.id == rule.id
				|| rule.sourceHosts.contains { existing.covers(host: $0) }
				|| existing.sourceHosts.contains { rule.covers(host: $0) }
			}
			if !isHandled { proxyLinkRules.append(rule) }
		}
		if changed { offeredProxyLinkDefaults = offered.sorted { $0.uuidString < $1.uuidString } }
		return changed
	}

	/// The app-wide chrome appearance, kept in the fields earlier builds saved.
	public var chromeAppearance: ChromeAppearance {
		get {
			.init(
				tint: chromeTint,
				grain: .init(isEnabled: grainEnabled, intensity: grainIntensity, size: grainSize),
				accent: chromeAccent,
				matchesSite: chromeMatchesSite
			)
		}
		set {
			chromeTint = newValue.tint
			chromeAccent = newValue.accent
			chromeMatchesSite = newValue.matchesSite
			grainEnabled = newValue.grain.isEnabled
			grainIntensity = newValue.grain.intensity
			grainSize = newValue.grain.size
		}
	}

	public func validate() throws {
		try validateKeyboardShortcuts()
		try commandAliases.validate()
		try routing.validate()
		try automation.validate()
		guard
			grainIntensity.isFinite,
			grainSize.isFinite,
			(0 ... 1).contains(grainIntensity),
			(1 ... 3).contains(grainSize),
			chromeTint.normalized == chromeTint
		else { throw SearchShortcut.Failure.invalidDefinition }
		var ruleIDs: Set<UUID> = []
		for rule in proxyLinkRules {
			try rule.validate()
			guard ruleIDs.insert(rule.id).inserted
			else { throw LinkTransformationError.duplicateRule }
		}
		var keywords: Set<String> = []
		for shortcut in searchShortcuts {
			try shortcut.validate()
			guard keywords.insert(shortcut.keyword.lowercased()).inserted
			else { throw SearchShortcut.Failure.duplicateKeyword }
		}
	}
}

/// The coding keys of link-click switches that became choices (DEV-1239). They are only read, so
/// a workspace saved by an older Arx keeps what its person chose.
private enum LegacyLinkClickKeys: String, CodingKey {
	case shiftClickPeekEnabled
	case crossSitePeekFromFavorites
	case crossSitePeekFromPinnedTabs
}
