import Foundation

/// Every `ARX_*` feature flag Arx reads (DEV-1115), in one registry: Settings › Advanced ›
/// Feature Flags lists them from here, so a new flag shows there once it's a case.
///
/// Each reads the environment first, then user defaults under its name: `1`, `true`, `yes` or
/// `on` turns it on, `0`, `false`, `no` or `off` turns it off, and anything else, or nothing,
/// leaves it at its default. Every flag is on by default except those in `offByDefault`
/// (DEV-1143), so a saved `0` or `off` still keeps one off. Settings writes `on` or `off` to
/// user defaults, the words the engine's own reader (`FeatureFlag` in `engine_bridge.mm`) takes;
/// an environment variable still wins over it.
///
/// `FeatureFlagRegistryTests` scans the sources for flags declared or read elsewhere and fails
/// for one that isn't a case here.
public enum FeatureFlag: String, CaseIterable, Hashable, Sendable {
	/// Agents' own tabs (DEV-1022).
	case agentTabs = "ARX_AGENT_TABS"

	/// Reading mode (DEV-1028).
	case readingMode = "ARX_READING_MODE"

	/// Live Calendar hover cards (DEV-804).
	case liveCalendar = "ARX_LIVE_CALENDAR"

	/// Arx's own permission prompts on the page's window (DEV-963).
	case pagePrompts = "ARX_PAGE_PROMPTS"

	/// The developer header's device capture popover (DEV-757).
	case deviceCapture = "ARX_DEVICE_CAPTURE"

	/// The workspace in SQLite (DEV-560).
	case sqliteWorkspace = "ARX_SQLITE_WORKSPACE"

	/// iCloud sync (DEV-560, phase 2). Needs `sqliteWorkspace`.
	case iCloudSync = "ARX_ICLOUD_SYNC"

	/// Turning iCloud sync on for a Mac that has its own workspace merges matching profiles, spaces,
	/// folders, pins and Favorites into iCloud's, after a preview, and Settings › iCloud Sync merges
	/// two synced profiles of the same name (DEV-1216). Off, everything is copied, and only an
	/// untouched starter profile is folded into iCloud's.
	case iCloudSyncMerge = "ARX_ICLOUD_SYNC_MERGE"

	/// Sidebar rows select as the mouse goes down (DEV-914, DEV-994).
	case sidebarPressSelects = "ARX_SIDEBAR_PRESS_SELECTS"

	/// The scroll pocket hides AppKit's separator under a bar (DEV-790).
	case scrollPocketHider = "ARX_SCROLL_POCKET_HIDER"

	/// The scroll pocket follows the content's light or dark (DEV-790).
	case scrollPocketAdaptive = "ARX_SCROLL_POCKET_ADAPTIVE"

	/// Translation Available in the address bar, private windows and Google (DEV-996).
	case translate = "ARX_TRANSLATE"

	/// View › Hide Element… with uBlock Origin's element picker (DEV-1019).
	case hideElement = "ARX_HIDE_ELEMENT"

	/// Hide Element opens Arx's own element picker instead of uBlock Origin's (DEV-1201).
	case elementPicker = "ARX_ELEMENT_PICKER"

	/// A collapsed folder keeps showing its selected tab (DEV-1110).
	case collapsedFolderShowsSelection = "ARX_COLLAPSED_FOLDER_SHOWS_SELECTION"

	/// A swipe past the last space offers Create a Space (DEV-1109).
	case swipeToCreateSpace = "ARX_SWIPE_TO_CREATE_SPACE"

	/// Little Arx windows left unused for the chosen time are archived (DEV-1138).
	case littleArxAutoArchive = "ARX_LITTLE_ARX_AUTO_ARCHIVE"

	/// Settings › General › Previews' choice for pages that aren't loaded, and site pictures
	/// requested with the profile's cookies for the page's own host (DEV-1142).
	case sitePreviewImages = "ARX_SITE_PREVIEW_IMAGES"

	/// Dark pages, on engines that have them (DEV-1020).
	case darkPages = "ARX_DARK_PAGES"

	/// Hovering a page link shows where it goes (DEV-1111).
	case linkStatus = "ARX_LINK_STATUS"

	/// A space can choose Match site, and its chrome takes the shown page's color (DEV-1101).
	case matchSiteBackground = "ARX_MATCH_SITE_BACKGROUND"

	/// A browser accent color, with profile and space overrides (DEV-1117).
	case accentColor = "ARX_ACCENT_COLOR"

	/// Debug builds list the Settings options that don't work yet (DEV-871).
	case pendingSettings = "ARX_PENDING_SETTINGS"

	/// Each browser window keeps its own open tabs, while spaces, Favorites and pinned tabs stay
	/// shared (DEV-822).
	case independentWindows = "ARX_INDEPENDENT_WINDOWS"

	/// Spotify's protected media plays in its Chromium tab through Arx's FairPlay helper, instead
	/// of moving to a WebKit page (DEV-1144).
	case fairPlayInChromium = "ARX_FAIRPLAY_IN_CHROMIUM"

	/// Sidebar row details: the close button on hover, bold folder titles, light folders
	/// (DEV-1161).
	case sidebarRowPolish = "ARX_SIDEBAR_ROW_POLISH"

	/// The URL bar's buttons and other buttons inside a control draw only a darker shape under
	/// the pointer (`ChromeInlineButtonStyle`).
	case inlineButtons = "ARX_INLINE_BUTTONS"

	/// A tab's, a link's and the Tab menu's copy and share items sit in a Copy submenu
	/// (DEV-1162).
	case copySubmenu = "ARX_COPY_SUBMENU"

	/// Back from a Settings page returns its pane to where it was scrolled (Max, 18 Nov).
	case settingsScrollRestore = "ARX_SETTINGS_SCROLL_RESTORE"

	/// Settings' lists add from a "+" on the window's top bar, with a hint naming what it adds,
	/// instead of a button over the list (Max, 18 Nov).
	case settingsToolbarAdd = "ARX_SETTINGS_TOOLBAR_ADD"

	/// Clicking Page PiP's address edits it there, as the main window's URL bar does (DEV-1124).
	case pagePictureInPictureAddress = "ARX_PAGE_PIP_ADDRESS"

	/// ⌃Tab switches among the window's tabs in the order they were last shown
	/// (DEV-544). Off, it goes to the next tab in the sidebar.
	case recentTabSwitcher = "ARX_RECENT_TAB_SWITCHER"

	/// Closing the selected tab, or resetting a selected pin or Favorite, selects the tab the window
	/// showed before it instead of leaving none selected (DEV-1228).
	case returnToPreviousTab = "ARX_RETURN_TO_PREVIOUS_TAB"

	/// Resetting a pin plays a short horizontal shake on its sidebar row, or a brief highlight with
	/// Reduce Motion on (DEV-1225).
	case pinResetShake = "ARX_PIN_RESET_SHAKE"

	/// Shift-hover over a sidebar item opens its preview at once, and Shift + hover loads the
	/// page instantly when its setting is on (DEV-1029).
	case shiftHoverPreview = "ARX_SHIFT_HOVER_PREVIEW"

	/// A tab opened from the New Tab button, ⌘T or the command bar goes to the top of the space's
	/// open tabs (DEV-1174).
	case newTabsAtTop = "ARX_NEW_TABS_AT_TOP"

	/// Sidebar rows and Favorites slide in and collapse out on a short spring as tabs come, go
	/// and move (DEV-1187).
	case sidebarRowAnimations = "ARX_SIDEBAR_ROW_ANIMATIONS"

	/// Page PiP's header picks the floating tab's space instead of its profile, ⌘1–9 moves the
	/// floating tab to that space, and moving a tab to a space of another profile asks first, in
	/// plain words (DEV-1184).
	case pagePictureInPictureSpaces = "ARX_PAGE_PIP_SPACES"

	/// The URL bar and the command bar open typed addresses with any scheme: `arx://settings/…`,
	/// `chrome://settings/…`, `about:blank`, `file:` and apps' own, such as `slack://` (DEV-1189).
	case schemeAddresses = "ARX_SCHEME_ADDRESSES"

	/// ⌘Z takes back the window's last step and keeps what changed since elsewhere: moves
	/// between spaces and windows, a deleted space for a minute, closed tabs and agents' changes,
	/// with a focused page or text field getting ⌘Z first (DEV-1030). Off, Undo Organization
	/// Change restores the window's own last edit and forgets its history on any outside change.
	case windowUndo = "ARX_WINDOW_UNDO"

	/// `chrome://` and `arc://` links from pages and other apps open Arx's place for them, or
	/// Chrome or Arc, and `arx://settings/…` opens Settings from other apps (DEV-1193).
	case browserLinks = "ARX_BROWSER_LINKS"

	/// Capture Page's frame shows the whole page it took, and Capture Area scrolls the page while
	/// an area is drawn toward its edge, taking the area beyond the viewport in one image
	/// (DEV-1208).
	case captureBeyondViewport = "ARX_CAPTURE_BEYOND_VIEWPORT"

	/// A store update the automatic check turned down because it asks for more permissions is
	/// marked "Update needs review" on its Extensions row, the Settings Extensions entry and the
	/// site menu's tile, and opens its review from there (DEV-1210).
	case extensionUpdateReview = "ARX_EXTENSION_UPDATE_REVIEW"

	/// A button in the corner of a pane with no page opens the homepage's controls there: its
	/// logo, pointer, ink trail, guide and background. Off, every pane shows the default
	/// homepage.
	case customizableHomepage = "ARX_CUSTOMIZABLE_HOMEPAGE"

	/// A first launch's onboarding asks to set Arx up from iCloud before its first profile is
	/// used: it adopts the workspace other Macs synced, or starts iCloud with this Mac's
	/// (DEV-1215). Shown only while iCloud sync is available.
	case onboardingICloud = "ARX_ONBOARDING_ICLOUD"

	/// WebKit pages swipe back and forward with Arx's own gesture, the Chromium pages' arrow and
	/// thresholds, and a swipe back from a WebKit page's first entry reopens the Chromium page the
	/// tab came from (DEV-1203). Off, WebKit pages keep WebKit's own swipe.
	case webKitSwipe = "ARX_WEBKIT_SWIPE"

	/// The engine trims the browser process's free memory once Arx is idle (DEV-916, DEV-682),
	/// read by the engine.
	case idleTrim = "ARX_IDLE_TRIM"

	/// The engine lets extensions' background pages start with the bootstrap profile, as Chrome
	/// does (DEV-944), read by the engine.
	case bootstrapBackgroundPages = "ARX_BOOTSTRAP_BACKGROUND_PAGES"

	/// The engine keeps a spare renderer ready (DEV-916), read by the engine.
	case spareRenderer = "ARX_SPARE_RENDERER"

	/// Pages with a live connection are neither frozen nor unloaded (DEV-879), read by the
	/// engine.
	case spareLiveConnections = "ARX_SPARE_LIVE_CONNECTIONS"

	/// The browser window's sidebar and background let the desktop through, less as the tint's
	/// intensity grows (DEV-1286). Off, they're solid.
	case translucentChrome = "ARX_TRANSLUCENT_CHROME"

	/// Help › Send Feedback opens the in-app feedback sheet, which files reports through Arx's
	/// backend (DEV-1284). Off, Send Feedback opens Report a Problem instead.
	case feedbackForm = "ARX_FEEDBACK_FORM"

	/// The name read from the environment and user defaults.
	public var name: String { rawValue }

	/// The flags that stay off by default (DEV-1143). For the beta every flag is on but the
	/// Customizable homepage (Max, 20 Nov), and which to turn off for 1.0.0 is decided later.
	/// Adding one here turns it off for everyone who hasn't turned it on themselves, and
	/// Settings › Advanced › Feature Flags says so.
	///
	/// An engine flag's default is also the engine's own, in `engine_bridge.mm`, and moves only
	/// with it: `FeatureFlagRegistryTests` checks they agree.
	public static let offByDefault: Set<Self> = [.customizableHomepage]

	/// Whether it's on when nothing sets it.
	public var isOnByDefault: Bool {
		!Self.offByDefault.contains(self)
	}

	/// Whether Arx reads it only at launch, so a change waits for a relaunch. Every flag does
	/// for now: Live Calendar's previews read it as the window draws, which a change in Settings
	/// doesn't redraw.
	public var needsRelaunch: Bool {
		switch self {
		case .feedbackForm: false
		case .agentTabs, .readingMode, .liveCalendar, .pagePrompts, .deviceCapture, .sqliteWorkspace, .iCloudSync, .iCloudSyncMerge,
			.sidebarPressSelects, .scrollPocketHider, .scrollPocketAdaptive, .translate, .hideElement, .elementPicker,
			.collapsedFolderShowsSelection, .swipeToCreateSpace, .idleTrim, .bootstrapBackgroundPages, .spareRenderer,
			.spareLiveConnections,
			.littleArxAutoArchive, .sitePreviewImages, .darkPages, .linkStatus, .matchSiteBackground, .accentColor,
			.pendingSettings,
			.independentWindows, .fairPlayInChromium, .sidebarRowPolish, .inlineButtons, .copySubmenu,
			.settingsScrollRestore, .settingsToolbarAdd, .pagePictureInPictureAddress, .recentTabSwitcher, .returnToPreviousTab, .pinResetShake, .shiftHoverPreview, .newTabsAtTop, .sidebarRowAnimations, .pagePictureInPictureSpaces, .schemeAddresses, .windowUndo, .browserLinks,
			.captureBeyondViewport, .extensionUpdateReview, .onboardingICloud, .customizableHomepage, .webKitSwipe, .translucentChrome: true
		}
	}

	/// Whether turning it on can cost data or reach other Macs, so Settings warns.
	public var isRisky: Bool {
		switch self {
		case .sqliteWorkspace, .iCloudSync, .iCloudSyncMerge: true
		case .agentTabs, .readingMode, .liveCalendar, .pagePrompts, .deviceCapture, .sidebarPressSelects,
			.scrollPocketHider, .scrollPocketAdaptive, .translate, .hideElement, .elementPicker, .collapsedFolderShowsSelection,
			.swipeToCreateSpace, .idleTrim, .bootstrapBackgroundPages, .spareRenderer, .spareLiveConnections,
			.littleArxAutoArchive, .sitePreviewImages, .darkPages, .linkStatus, .matchSiteBackground, .accentColor,
			.pendingSettings,
			.independentWindows, .fairPlayInChromium, .sidebarRowPolish, .inlineButtons, .copySubmenu,
			.settingsScrollRestore, .settingsToolbarAdd, .pagePictureInPictureAddress, .recentTabSwitcher, .returnToPreviousTab, .pinResetShake, .shiftHoverPreview, .newTabsAtTop, .sidebarRowAnimations, .pagePictureInPictureSpaces, .schemeAddresses, .windowUndo, .browserLinks,
			.captureBeyondViewport, .extensionUpdateReview, .onboardingICloud, .customizableHomepage, .webKitSwipe, .translucentChrome, .feedbackForm: false
		}
	}

	/// Whether it's on.
	public func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		state(environment: environment, defaults: defaults).isOn
	}

	/// Whether the engine reads it, in `engine_bridge.mm`: from the environment if it's set at
	/// all, else from user defaults, and only the exact word `on` (or `off`, for one on by
	/// default) changes it.
	public var isReadByEngine: Bool {
		switch self {
		case .idleTrim, .bootstrapBackgroundPages, .spareRenderer, .spareLiveConnections: true
		case .agentTabs, .readingMode, .liveCalendar, .pagePrompts, .deviceCapture, .sqliteWorkspace, .iCloudSync, .iCloudSyncMerge,
			.sidebarPressSelects, .scrollPocketHider, .scrollPocketAdaptive, .translate, .hideElement, .elementPicker,
			.collapsedFolderShowsSelection, .swipeToCreateSpace,
			.littleArxAutoArchive, .sitePreviewImages, .darkPages, .linkStatus, .matchSiteBackground, .accentColor,
			.pendingSettings,
			.independentWindows, .fairPlayInChromium, .sidebarRowPolish, .inlineButtons, .copySubmenu,
			.settingsScrollRestore, .settingsToolbarAdd, .pagePictureInPictureAddress, .recentTabSwitcher, .returnToPreviousTab, .pinResetShake, .shiftHoverPreview, .newTabsAtTop, .sidebarRowAnimations, .pagePictureInPictureSpaces, .schemeAddresses, .windowUndo, .browserLinks,
			.captureBeyondViewport, .extensionUpdateReview, .onboardingICloud, .customizableHomepage, .webKitSwipe, .translucentChrome, .feedbackForm: false
		}
	}

	/// Whether it's on and what set it.
	public func state(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> FeatureFlagState {
		if isReadByEngine {
			return engineState(environment: environment, defaults: defaults)
		}
		if let value = environment[name].flatMap(Self.parse) {
			return .init(isOn: value, source: .environment)
		}
		if let value = defaults.string(forKey: name).flatMap(Self.parse) {
			return .init(isOn: value, source: .defaults)
		}
		return .init(isOn: isOnByDefault, source: .default)
	}

	/// Saves it to user defaults, as Settings does; nil goes back to the default.
	public func set(
		_ isOn: Bool?,
		defaults: UserDefaults = .standard
	) {
		if let isOn {
			defaults.set(isOn ? "on" : "off", forKey: name)
		} else {
			defaults.removeObject(forKey: name)
		}
	}

	/// As the engine reads it, so Settings shows what the engine does.
	private func engineState(
		environment: [String: String],
		defaults: UserDefaults
	) -> FeatureFlagState {
		let changing: String = isOnByDefault ? "off" : "on"
		if let value = environment[name] {
			return .init(isOn: (value == changing) != isOnByDefault, source: .environment)
		}
		if let value = defaults.string(forKey: name) {
			return .init(isOn: (value == changing) != isOnByDefault, source: .defaults)
		}
		return .init(isOn: isOnByDefault, source: .default)
	}

	/// `1`, `true`, `yes` or `on` is on; `0`, `false`, `no` or `off` is off; anything else is
	/// neither.
	public static func parse(_ value: String) -> Bool? {
		switch value.trimmingCharacters(in: .whitespaces).lowercased() {
		case "1", "true", "yes", "on": true
		case "0", "false", "no", "off": false
		default: nil
		}
	}
}

/// A feature flag's value and what set it.
public struct FeatureFlagState: Equatable, Sendable {
	public enum Source: Equatable, Sendable {
		/// An environment variable, which Settings can't change.
		case environment

		/// User defaults, as Settings saves it.
		case defaults

		/// Nothing: the flag's default.
		case `default`
	}

	public var isOn: Bool
	public var source: Source

	public init(
		isOn: Bool,
		source: Source
	) {
		self.isOn = isOn
		self.source = source
	}
}
