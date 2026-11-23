import Foundation

/// How link clicks and the Little Arx launcher behave. A view over fields `BrowserPreferences`
/// stores separately, so the workspace file keeps its format.
public struct LinkClickPreferences: Equatable, Sendable {
	public var shiftClickLinkAction: ShiftClickLinkAction
	public var littleArxLinkBinding: LittleArxLinkBinding
	public var forceClickLinkAction: ForceClickLinkAction
	public var littleArxLauncherPosition: LittleArxLauncherPosition

	/// Archives Little Arx windows left unused this long (DEV-1138), or nil for never.
	public var littleArxArchiveInterval: LittleArxArchiveInterval?
	public var globalLittleArxEnabled: Bool
	public var crossSiteLinkFromFavorites: CrossSiteLinkAction
	public var crossSiteLinkFromPinnedTabs: CrossSiteLinkAction

	/// DEV-1111.
	public var showsLinkStatus: Bool

	/// How the Runway looks.
	public var runwayAppearance: RunwayAppearance

	public init(
		shiftClickLinkAction: ShiftClickLinkAction,
		littleArxLinkBinding: LittleArxLinkBinding,
		forceClickLinkAction: ForceClickLinkAction,
		littleArxLauncherPosition: LittleArxLauncherPosition,
		globalLittleArxEnabled: Bool,
		crossSiteLinkFromFavorites: CrossSiteLinkAction = .peek,
		crossSiteLinkFromPinnedTabs: CrossSiteLinkAction = .currentTab,
		showsLinkStatus: Bool = true,
		littleArxArchiveInterval: LittleArxArchiveInterval? = nil,
		runwayAppearance: RunwayAppearance = .regular
	) {
		self.shiftClickLinkAction = shiftClickLinkAction
		self.littleArxArchiveInterval = littleArxArchiveInterval
		self.littleArxLinkBinding = littleArxLinkBinding
		self.forceClickLinkAction = forceClickLinkAction
		self.littleArxLauncherPosition = littleArxLauncherPosition
		self.globalLittleArxEnabled = globalLittleArxEnabled
		self.crossSiteLinkFromFavorites = crossSiteLinkFromFavorites
		self.crossSiteLinkFromPinnedTabs = crossSiteLinkFromPinnedTabs
		self.showsLinkStatus = showsLinkStatus
		self.runwayAppearance = runwayAppearance
	}
}

/// App-wide behaviour from Settings' General pane. A view over fields `BrowserPreferences`
/// stores separately, so the workspace file keeps its format.
public struct GeneralPreferences: Equatable, Sendable {
	public var warnsBeforeQuitting: Bool
	public var developerModeEnabled: Bool
	public var identityCardStyle: IdentityCardStyle
	public var restoresWindowsAtStartup: Bool
	public var hapticsEnabled: Bool
	public var soundsEnabled: Bool
	public var appTheme: AppTheme

	/// DEV-1020.
	public var darkPages: DarkPagesMode
	public var appIcon: AppIconStyle
	public var hoverPreviewsEnabled: Bool
	public var hoverPreviewSources: HoverPreviewSources
	public var developerHeaderEnabled: Bool
	public var localTabHighlightEnabled: Bool
	public var closesCommandBarOnEmptyDelete: Bool
	public var fetchesUnloadedSiteIcons: Bool
	public var tabUnloadDelay: TabUnloadDelay

	/// DEV-873.
	public var tabUnloadPressureGrace: TabUnloadPressureGrace

	/// DEV-932.
	public var keepsPinnedTabsLoaded: Bool
	public var asksBeforeFillingPasswords: Bool
	public var fillsAddresses: Bool
	public var fillsPaymentCards: Bool

	/// DEV-884.
	public var blocksContent: Bool
	public var blocksCookieBanners: Bool

	/// The window side the sidebar sits on (DEV-913).
	public var sidebarPosition: SidebarPosition

	/// Where new tabs open among a space's open tabs (DEV-913); only tabs links open while
	/// `ARX_NEW_TABS_AT_TOP` is on (DEV-1174).
	public var newTabPlacement: NewTabPlacement

	/// Where a tab from the New Tab button, ⌘T or ⌘K opens while `ARX_NEW_TABS_AT_TOP` is on
	/// (DEV-1174).
	public var openedTabPlacement: NewTabPlacement

	/// A tab a link opens comes forward instead of opening behind the page (DEV-952).
	public var switchesToLinkTabs: Bool

	/// A launch opens to the empty page with every folder collapsed (DEV-1234).
	public var opensEmptyPageAtLaunch: Bool

	/// The browser default for unread badges (DEV-907, DEV-1258).
	public var showsUnreadBadges: Bool

	/// DEV-922.
	public var handoffEnabled: Bool

	/// DEV-909.
	public var appleScriptJavaScriptEnabled: Bool

	/// DEV-885.
	public var notificationsOpenClosedSites: Bool

	public init(
		warnsBeforeQuitting: Bool,
		developerModeEnabled: Bool,
		identityCardStyle: IdentityCardStyle,
		restoresWindowsAtStartup: Bool = true,
		hapticsEnabled: Bool = true,
		soundsEnabled: Bool = false,
		appTheme: AppTheme = .system,
		darkPages: DarkPagesMode = .off,
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
		handoffEnabled: Bool = true,
		appleScriptJavaScriptEnabled: Bool = false,
		notificationsOpenClosedSites: Bool = true
	) {
		self.warnsBeforeQuitting = warnsBeforeQuitting
		self.developerModeEnabled = developerModeEnabled
		self.identityCardStyle = identityCardStyle
		self.restoresWindowsAtStartup = restoresWindowsAtStartup
		self.hapticsEnabled = hapticsEnabled
		self.soundsEnabled = soundsEnabled
		self.appTheme = appTheme
		self.darkPages = darkPages
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
		self.handoffEnabled = handoffEnabled
		self.appleScriptJavaScriptEnabled = appleScriptJavaScriptEnabled
		self.notificationsOpenClosedSites = notificationsOpenClosedSites
	}
}

extension BrowserPreferences {
	public var linkClicks: LinkClickPreferences {
		get {
			.init(
				shiftClickLinkAction: shiftClickLinkAction,
				littleArxLinkBinding: littleArxLinkBinding,
				forceClickLinkAction: forceClickLinkAction,
				littleArxLauncherPosition: littleArxLauncherPosition,
				globalLittleArxEnabled: globalLittleArxEnabled,
				crossSiteLinkFromFavorites: crossSiteLinkFromFavorites,
				crossSiteLinkFromPinnedTabs: crossSiteLinkFromPinnedTabs,
				showsLinkStatus: showsLinkStatus,
				littleArxArchiveInterval: littleArxArchiveInterval,
				runwayAppearance: runwayAppearance
			)
		}
		set {
			shiftClickLinkAction = newValue.shiftClickLinkAction
			littleArxArchiveInterval = newValue.littleArxArchiveInterval
			littleArxLinkBinding = newValue.littleArxLinkBinding
			forceClickLinkAction = newValue.forceClickLinkAction
			littleArxLauncherPosition = newValue.littleArxLauncherPosition
			globalLittleArxEnabled = newValue.globalLittleArxEnabled
			crossSiteLinkFromFavorites = newValue.crossSiteLinkFromFavorites
			crossSiteLinkFromPinnedTabs = newValue.crossSiteLinkFromPinnedTabs
			showsLinkStatus = newValue.showsLinkStatus
			runwayAppearance = newValue.runwayAppearance
		}
	}

	public var general: GeneralPreferences {
		get {
			.init(
				warnsBeforeQuitting: warnsBeforeQuitting,
				developerModeEnabled: developerModeEnabled,
				identityCardStyle: identityCardStyle,
				restoresWindowsAtStartup: restoresWindowsAtStartup,
				hapticsEnabled: hapticsEnabled,
				soundsEnabled: soundsEnabled,
				appTheme: appTheme,
				darkPages: darkPages,
				appIcon: appIcon,
				hoverPreviewsEnabled: hoverPreviewsEnabled,
				hoverPreviewSources: hoverPreviewSources,
				developerHeaderEnabled: developerHeaderEnabled,
				localTabHighlightEnabled: localTabHighlightEnabled,
				closesCommandBarOnEmptyDelete: closesCommandBarOnEmptyDelete,
				fetchesUnloadedSiteIcons: fetchesUnloadedSiteIcons,
				tabUnloadDelay: tabUnloadDelay,
				tabUnloadPressureGrace: tabUnloadPressureGrace,
				keepsPinnedTabsLoaded: keepsPinnedTabsLoaded,
				asksBeforeFillingPasswords: asksBeforeFillingPasswords,
				fillsAddresses: fillsAddresses,
				fillsPaymentCards: fillsPaymentCards,
				blocksContent: blocksContent,
				blocksCookieBanners: blocksCookieBanners,
				sidebarPosition: sidebarPosition,
				newTabPlacement: newTabPlacement,
				openedTabPlacement: openedTabPlacement,
				switchesToLinkTabs: switchesToLinkTabs,
				opensEmptyPageAtLaunch: opensEmptyPageAtLaunch,
				showsUnreadBadges: showsUnreadBadges,
				handoffEnabled: handoffEnabled,
				appleScriptJavaScriptEnabled: appleScriptJavaScriptEnabled,
				notificationsOpenClosedSites: notificationsOpenClosedSites
			)
		}
		set {
			warnsBeforeQuitting = newValue.warnsBeforeQuitting
			developerModeEnabled = newValue.developerModeEnabled
			identityCardStyle = newValue.identityCardStyle
			restoresWindowsAtStartup = newValue.restoresWindowsAtStartup
			hapticsEnabled = newValue.hapticsEnabled
			soundsEnabled = newValue.soundsEnabled
			appTheme = newValue.appTheme
			darkPages = newValue.darkPages
			appIcon = newValue.appIcon
			hoverPreviewsEnabled = newValue.hoverPreviewsEnabled
			hoverPreviewSources = newValue.hoverPreviewSources
			developerHeaderEnabled = newValue.developerHeaderEnabled
			localTabHighlightEnabled = newValue.localTabHighlightEnabled
			closesCommandBarOnEmptyDelete = newValue.closesCommandBarOnEmptyDelete
			fetchesUnloadedSiteIcons = newValue.fetchesUnloadedSiteIcons
			tabUnloadDelay = newValue.tabUnloadDelay
			tabUnloadPressureGrace = newValue.tabUnloadPressureGrace
			keepsPinnedTabsLoaded = newValue.keepsPinnedTabsLoaded
			asksBeforeFillingPasswords = newValue.asksBeforeFillingPasswords
			fillsAddresses = newValue.fillsAddresses
			fillsPaymentCards = newValue.fillsPaymentCards
			blocksContent = newValue.blocksContent
			blocksCookieBanners = newValue.blocksCookieBanners
			sidebarPosition = newValue.sidebarPosition
			newTabPlacement = newValue.newTabPlacement
			openedTabPlacement = newValue.openedTabPlacement
			switchesToLinkTabs = newValue.switchesToLinkTabs
			opensEmptyPageAtLaunch = newValue.opensEmptyPageAtLaunch
			showsUnreadBadges = newValue.showsUnreadBadges
			handoffEnabled = newValue.handoffEnabled
			appleScriptJavaScriptEnabled = newValue.appleScriptJavaScriptEnabled
			notificationsOpenClosedSites = newValue.notificationsOpenClosedSites
		}
	}
}

/// Where windows were and how wide their sidebars were. A view over fields `BrowserPreferences`
/// stores separately, so the workspace file keeps its format.
public struct WindowPreferences: Equatable, Sendable {
	public var windowPresentations: [BrowserWindowPresentation]

	/// What new windows start with: the width most recently set in any saved window.
	public var lastSidebarWidth: Double?

	public init(
		windowPresentations: [BrowserWindowPresentation],
		lastSidebarWidth: Double?
	) {
		self.windowPresentations = windowPresentations
		self.lastSidebarWidth = lastSidebarWidth
	}
}

extension BrowserPreferences {
	public var windows: WindowPreferences {
		get {
			.init(
				windowPresentations: windowPresentations,
				lastSidebarWidth: lastSidebarWidth
			)
		}
		set {
			windowPresentations = newValue.windowPresentations
			lastSidebarWidth = newValue.lastSidebarWidth
		}
	}
}
