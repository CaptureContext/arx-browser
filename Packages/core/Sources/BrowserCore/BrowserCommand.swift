import Foundation

/// Stable identities and availability rules shared by every browser command surface.
public enum BrowserCommand: String, Codable, CaseIterable, Sendable {
	case downloads

	/// Opens the Library's Media page. The raw value predates the rename and keeps saved shortcuts (DEV-783).
	case media = "mediaControls"
	case captureViewport
	case captureRegion
	case newFolder
	case newSpace
	case nextSpace
	case previousSpace

	/// Switch to the Nth space in the switcher's and the Library's order (DEV-725).
	case space1
	case space2
	case space3
	case space4
	case space5
	case space6
	case space7
	case space8
	case space9
	case toggleLibrary
	case chats

	/// Pins the window's chat to the current tab, or unpins the tab's chat (DEV-761).
	case pinChatToTab

	/// Opens the window's chat as a chat tab (DEV-761).
	case openChatInTab
	case moveItems
	case toggleSidebar
	case undoOrganization
	case settings

	/// The current profile's extensions in Settings (DEV-633), also `arx://extensions`.
	case extensions

	/// Opens the Chrome Web Store in the window's profile, to add extensions from it (DEV-801).
	case chromeWebStore

	/// Window ▸ Task Manager: memory, CPU and process of every tab and extension (DEV-898).
	case taskManager

	/// Help ▸ Send Feedback: the in-app feedback card, sent privately through Arx's backend
	/// (DEV-1284).
	case sendFeedback
	case onboarding
	case newWindow
	case newPrivateWindow
	case littleArx
	case newTab
	case address
	case commandBar
	case closeTab
	case closeWindow
	case openArchive
	case reopenLastClosedTab

	/// Archive ▸ Recently Closed ▸ Reopen Closed Window (DEV-908).
	case reopenClosedWindow
	case archiveSelectedTabs
	case archiveAllInSpace
	case copyURL
	case copyCleanLink
	case copyMarkdownOriginal
	case copyProxyLink
	case copyMarkdownProxy
	case routeCurrentURL
	case openFocusedLinkInPeek
	case shareProxyLink

	/// Share… with the page's plain address and title (DEV-818).
	case sharePage

	/// Cast… the tab, or the site's own video, to a Chromecast or TV on the network (DEV-927).
	case castTab

	/// Hide Element… (DEV-1019): uBlock Origin's element picker on the page; what's picked stays
	/// hidden on the site, in the profile's My filters. ⇧⌘H by default.
	case hideElement

	/// Floats the tab's live page in Page PiP, a window that behaves like Picture in Picture,
	/// or brings it back (DEV-950). ⌥⌘P by default. It starts only when asked: automatic
	/// Picture in Picture never falls back to it, and returning to the tab never ends it.
	case pagePictureInPicture

	/// Present Media in Picture in Picture (DEV-1106): the tab's video in Media PiP, when the
	/// site lets it float there.
	case mediaPictureInPicture
	case duplicateTab
	case pinTab
	case newSplit
	case focusOtherPane
	case closePane
	case swapPanes
	case toggleSplitOrientation
	case findInPage
	case findNext
	case findPrevious
	case goBack
	case goForward
	case reload
	case clearCacheAndReload
	case reloadBypassingCache

	/// Page zoom, stepping through Chrome's levels and kept per site (DEV-726).
	case zoomIn
	case zoomOut
	case actualSize
	case developerTools

	/// View ▸ Developer ▸ Inspect Element (DEV-921), in developer mode.
	case inspectElement

	/// View ▸ Developer ▸ JavaScript Console (DEV-921), in developer mode.
	case javaScriptConsole

	/// Prints the page, or the PDF document it shows (DEV-795).
	case printPage

	/// AppKit's Page Setup for the paper size and orientation Print uses (DEV-795).
	case pageSetup

	/// Saves the page as PDF, or with the engine's Save Page as HTML or a web archive (DEV-795).
	case savePageAs

	/// Opens a local file in a new tab (DEV-795).
	case openFile

	/// The command bar listing the profile's history (DEV-795).
	case showHistory

	/// Opens the page's source in a new tab (DEV-795).
	case viewSource

	/// Translates the page on this Mac, or shows the original when it's translated (DEV-904).
	case translatePage

	/// Shows the page's article in reading mode, laid over the page, or closes it (DEV-1028).
	case readingMode

	/// Turns dark pages off for the page's site, or back on (DEV-1020).
	case darkPage

	/// Stops loading the page (DEV-795).
	case stopLoading

	/// The next or previous tab in the sidebar's order, wrapping (DEV-795).
	case nextTab
	case previousTab

	/// Select the Nth tab in the sidebar's order; Tab 9 is always the last one (DEV-795).
	case tab1
	case tab2
	case tab3
	case tab4
	case tab5
	case tab6
	case tab7
	case tab8
	case lastTab
	case quit

	public var shortcut: KeyboardShortcut? {
		switch self {
		case .settings: .init(key: ",")

		case .newWindow: .init(key: "n")

		case .newPrivateWindow: .init(key: "n", modifiers: [.command, .shift])

		case .littleArx: .init(key: "a", modifiers: [.command, .option])

		case .newTab: .init(key: "t")

		case .address: .init(key: "l")

		case .commandBar: .init(key: "k")

		case .closeTab: .init(key: "w")

		case .closeWindow: .init(key: "w", modifiers: [.command, .shift])

		case .reopenLastClosedTab: .init(key: "t", modifiers: [.command, .shift])

		case .copyURL: .init(key: "c", modifiers: [.command, .shift])

		case .hideElement: .init(key: "h", modifiers: [.command, .shift])

		case .openFocusedLinkInPeek: .init(key: "p", modifiers: [.command, .shift])

		// Page PiP (DEV-950).
		case .pagePictureInPicture: .init(key: "p", modifiers: [.command, .option])

		// ⇧⌘D, not Dark Reader's ⌥⇧D: a menu's key equivalent without ⌘ would take Î from
		// every text field (DEV-1020).
		case .darkPage: .init(key: "d", modifiers: [.command, .shift])

		case .toggleSidebar: .init(key: "s")

		case .toggleLibrary: .init(key: "l", modifiers: [.command, .shift])

		case .duplicateTab: .init(key: "d")

		case .pinTab: .init(key: "b")

		case .findInPage: .init(key: "f")

		case .findNext: .init(key: "g")

		case .findPrevious: .init(key: "g", modifiers: [.command, .shift])

		case .goBack: .init(key: "[")

		case .goForward: .init(key: "]")

		case .reload: .init(key: "r")

		case .clearCacheAndReload: .init(key: "r", modifiers: [.command, .shift])

		case .reloadBypassingCache: .init(key: "r", modifiers: [.command, .option])

		case .zoomIn: .init(key: "=")

		case .zoomOut: .init(key: "-")

		case .actualSize: .init(key: "0")

		case .developerTools: .init(key: "i", modifiers: [.command, .option])

		case .inspectElement: .init(key: "c", modifiers: [.command, .option])

		case .javaScriptConsole: .init(key: "j", modifiers: [.command, .option])

		// Chrome has none on macOS; ⌥⎋ can't be a binding, since every shortcut needs ⌘ or ⌃.
		case .taskManager: .init(key: "t", modifiers: [.command, .option])

		case .sendFeedback: .init(key: "i", modifiers: [.command, .option, .shift])

		case .printPage: .init(key: "p")

		case .openFile: .init(key: "o")

		case .showHistory: .init(key: "y")

		case .viewSource: .init(key: "u", modifiers: [.command, .option])

		// Safari's ⇧⌘R and ⌥⌘R are Clear Cache and Reload and Reload Bypassing Cache here.
		case .readingMode: .init(key: "r", modifiers: [.command, .control])

		case .stopLoading: .init(key: ".")

		case .nextTab: .init(key: "]", modifiers: [.command, .shift])

		case .previousTab: .init(key: "[", modifiers: [.command, .shift])

		// The keys for the space beside the one shown (DEV-1310).
		case .nextSpace: .init(key: "right", modifiers: [.command, .option])

		case .previousSpace: .init(key: "left", modifiers: [.command, .option])

		case .quit: .init(key: "q")

		// Split View (DEV-920): ⌃⇧ with punctuation, which web apps leave alone.
		case .newSplit: .init(key: "=", modifiers: [.control, .shift])

		case .focusOtherPane: .init(key: "]", modifiers: [.control, .shift])

		case .closePane: .init(key: "-", modifiers: [.control, .shift])

		case .swapPanes: .init(key: "\\", modifiers: [.control, .shift])

		case .toggleSplitOrientation: .init(key: "/", modifiers: [.control, .shift])

		default:
			spaceNumber.map { .init(key: String($0), modifiers: .control) }
			?? tabNumber.map { .init(key: String($0)) }
		}
	}

	/// The Select Tab commands, ⌘1 to ⌘9 by default. The ninth selects the last tab, as in Safari and Chrome.
	public static let selectTab: [Self] = [
		.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .lastTab,
	]

	/// For a Select Tab command, which tab it selects, counting from 1; 9 means the last tab.
	public var tabNumber: Int? {
		Self.selectTab.firstIndex(of: self).map { $0 + 1 }
	}

	/// The Switch to Space commands, ⌃1 to ⌃9 by default.
	public static let switchToSpace: [Self] = [
		.space1, .space2, .space3, .space4, .space5, .space6, .space7, .space8, .space9,
	]

	/// The command that switches to the space at `number`, counting from 1.
	public static func switchToSpace(_ number: Int) -> Self? {
		switchToSpace.indices.contains(number - 1) ? switchToSpace[number - 1] : nil
	}

	/// For a Switch to Space command, which space it switches to, counting from 1.
	public var spaceNumber: Int? {
		Self.switchToSpace.firstIndex(of: self).map { $0 + 1 }
	}

	/// Defaults added after shortcuts became bindable (DEV-713, DEV-726, DEV-753). Someone may already have
	/// given these keys to another command; their binding wins and this default is off.
	public var defaultShortcutYieldsToUserBindings: Bool {
		[
			.closeWindow, .openFocusedLinkInPeek, .pagePictureInPicture, .zoomIn, .zoomOut, .actualSize, .toggleLibrary,
			.printPage, .openFile, .showHistory, .viewSource, .readingMode, .stopLoading, .nextTab, .previousTab,
			.taskManager, .inspectElement, .javaScriptConsole, .newSplit, .focusOtherPane, .closePane, .swapPanes, .toggleSplitOrientation,
			.darkPage, .sendFeedback, .nextSpace, .previousSpace,
		].contains(self) || spaceNumber != nil || tabNumber != nil
	}

	/// Every default key, the first being `shortcut` (DEV-920). Focus Other Pane also takes
	/// ⌃⇧[, so either bracket moves between panes.
	public var defaultShortcuts: [KeyboardShortcut] {
		let extra: [KeyboardShortcut] = switch self {
		case .focusOtherPane: [.init(key: "[", modifiers: [.control, .shift])]
		default: []
		}
		return (shortcut.map { [$0] } ?? []) + extra
	}

	/// Commands that open the main window or another browser window from outside one,
	/// disabled while launch onboarding holds the main window back.
	public static let opensBrowserWindow: Set<Self> = [
		.newTab, .address, .commandBar, .media, .newWindow, .newPrivateWindow, .reopenClosedWindow,
	]

	/// Copy Proxy Link, its Markdown form and Share Proxy Link, which need a proxy link rule
	/// that matches the page's site (DEV-1262).
	public static let proxyLinkCommands: Set<Self> = [.copyProxyLink, .copyMarkdownProxy, .shareProxyLink]

	/// Whether the command bar lists the command disabled in `context`, rather than leaving it
	/// out: a proxy link command on a page no proxy link rule matches, which the command bar
	/// shows so the command can still be found (DEV-1262). Context menus leave it out.
	public func isListedDisabled(in context: BrowserCommandContext) -> Bool {
		guard Self.proxyLinkCommands.contains(self), !isEnabled(in: context) else { return false }

		var matching = context
		matching.canProxyLink = true
		return isEnabled(in: matching)
	}

	public func isEnabled(in context: BrowserCommandContext) -> Bool {
		guard !context.isClosing else { return false }
		guard !context.mainWindowIsHeld || !Self.opensBrowserWindow.contains(self)
		else { return false }
		switch self {
		case .settings, .onboarding, .newWindow, .newPrivateWindow, .quit, .pageSetup, .taskManager, .sendFeedback: return true

		case .captureViewport, .captureRegion: return context.captureAvailable && context.hasTab && !context.isBusy

		case .downloads: return context.downloadsAvailable && !context.isBusy

		case .media: return context.mediaAvailable && !context.isPrivate && !context.isBusy

		// Extensions belong to an ordinary profile: a main window's, never a private one.
		case .extensions, .chromeWebStore: return context.host == .main && !context.isPrivate && !context.isBusy

		case .littleArx: return !context.isPrivate

		case .newTab, .commandBar: return context.host != .peek && !context.isBusy

		case .address: return !context.isBusy

		case .toggleSidebar: return context.host == .main

		case .newFolder, .newSpace, .toggleLibrary: return context.host == .main && !context.isBusy

		// Chats belong to a profile; private windows have none.
		case .chats: return context.host == .main && !context.isPrivate && !context.isBusy

		case .pinChatToTab: return context.host == .main && !context.isPrivate && !context.isBusy && context.hasTab

		case .openChatInTab: return context.host == .main && !context.isPrivate && !context.isBusy

		case .nextSpace, .previousSpace: return context.host == .main && !context.isBusy && context.canSwitchSpace

		// Space N must exist; otherwise its shortcut does nothing.
		case .space1, .space2, .space3, .space4, .space5, .space6, .space7, .space8, .space9:
			return context.host == .main && !context.isBusy && context.spaceCount >= (spaceNumber ?? .max)

		case .moveItems: return context.host == .main && !context.isBusy && context.hasTab

		case .undoOrganization: return context.host == .main && !context.isBusy && context.canUndo

		case .closeWindow: return context.host != .application && !context.isBusy

		case .closeTab:
			let closesWithoutTab: [BrowserCommandContext.Host] = [
				.settings, .onboarding, .downloads, .little, .taskManager,
			]
			return !context.isBusy && (closesWithoutTab.contains(context.host) || context.hasTab)

		case .newSplit: return context.host == .main && !context.isBusy && context.canAddPane

		case .focusOtherPane, .closePane, .swapPanes, .toggleSplitOrientation:
			return context.host == .main && !context.isBusy && context.isSplit

		case .goBack: return !context.isBusy && context.hasTab && context.canGoBack

		case .goForward: return !context.isBusy && context.hasTab && context.canGoForward

		case .routeCurrentURL: return !context.isPrivate && !context.isBusy && context.hasTab

		// Peek opens over a page in a window or Little Arx; never over Peek or a private window.
		case .openFocusedLinkInPeek:
			return [.main, .little].contains(context.host) && !context.isPrivate && !context.isBusy && context.hasTab

		case .openArchive: return context.host == .main && !context.isPrivate && !context.isBusy

		case .reopenLastClosedTab:
			return context.host == .main && !context.isPrivate && !context.isBusy && context.canReopenArchivedTab

		// From any window, or none: it opens one.
		case .reopenClosedWindow: return !context.isBusy && context.canReopenClosedWindow

		case .archiveSelectedTabs:
			return context.host == .main && !context.isPrivate && !context.isBusy && context.canArchiveSelectedTabs

		case .archiveAllInSpace:
			return context.host == .main && !context.isPrivate && !context.isBusy && context.canArchiveSpace

		case .duplicateTab: return context.host == .main && !context.isBusy && context.hasTab

		case .pinTab: return context.host == .main && !context.isBusy && context.hasTab && !context.isSaved

		case .developerTools, .inspectElement, .javaScriptConsole:
			return context.developerModeEnabled && !context.isBusy && context.hasTab

		// Print reads the page as PDF, which the engine does only for ordinary pages (DEV-816).
		case .printPage: return !context.isBusy && context.hasTab && context.canSavePage

		// Save As also saves a private page, as HTML or a web archive with Chromium's Save Page.
		case .savePageAs: return !context.isBusy && context.hasTab && context.canSavePage

		case .viewSource: return context.host == .main && !context.isBusy && context.hasTab && context.canSavePage

		// A web page in an ordinary window, while dark pages are offered (DEV-1020).
		case .darkPage:
			return context.host == .main && !context.isPrivate && !context.isBusy && context.hasTab
			&& context.canSavePage && context.darkPagesOffered

		// Web pages in a window. Private pages translate only with the `ARX_TRANSLATE` feature
		// flag, whose scripts run in a world of their own (DEV-996, DEV-1122).
		case .translatePage:
			return context.host == .main && (!context.isPrivate || context.pageTranslationEnabled)
			&& !context.isBusy && context.hasTab && context.canSavePage

		// An ordinary web page in a window, Peek or Little Arx, with its feature flag on. Private
		// pages aren't read: the engine runs no script in them.
		case .readingMode:
			return context.readingModeEnabled && !context.isPrivate && !context.isBusy && context.hasTab
			&& ((context.canSavePage && !context.usesWebKit) || context.isReading)

		// The page's own http(s) address, as the site menu shares it; private pages too.
		case .sharePage: return !context.isBusy && context.hasTab && context.canSavePage

		// A web page, as Chrome casts; private windows too.
		case .castTab: return !context.isBusy && context.hasTab && context.canSavePage && context.host != .peek

		// The tab plays a video the site lets float (DEV-1106).
		case .mediaPictureInPicture: return !context.isBusy && context.hasTab && context.canPresentMedia

		// An ordinary web page in a window, a Split View pane, Peek or Little Arx (DEV-1298), while
		// content blocking is on: uBlock keeps what's hidden, so a page WebKit shows has none.
		case .hideElement:
			return [.main, .peek, .little].contains(context.host) && !context.isPrivate && !context.isBusy && context.hasTab
			&& context.canSavePage && !context.usesWebKit && context.canHideElements

		case .openFile: return context.host == .main && !context.isBusy

		// A page whose site a proxy link rule matches (DEV-1262).
		case .copyProxyLink, .copyMarkdownProxy, .shareProxyLink:
			return !context.isBusy && context.hasTab && context.canProxyLink

		case .showHistory: return context.host == .main && !context.isPrivate && !context.isBusy

		case .stopLoading: return !context.isBusy && context.hasTab && context.isLoading

		case .nextTab, .previousTab: return context.host == .main && !context.isBusy && context.tabCount > 1

		case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .lastTab:
			return context.host == .main && !context.isBusy
			&& (self == .lastTab ? context.tabCount > 0 : context.tabCount >= (tabNumber ?? .max))

		default: return !context.isBusy && context.hasTab
		}
	}
}

public struct BrowserCommandContext: Equatable, Sendable {
	public enum Host: Equatable, Sendable {
		case application
		case downloads
		case main
		case little
		case peek
		case settings
		case onboarding

		/// Window ▸ Task Manager (DEV-898).
		case taskManager
	}

	public var host: Host
	public var hasTab: Bool
	public var isSaved: Bool
	public var isPrivate: Bool
	public var isBusy: Bool
	public var isClosing: Bool
	public var canUndo: Bool
	public var canReopenArchivedTab: Bool

	/// A browser window closed in this session can open again (DEV-908).
	public var canReopenClosedWindow: Bool
	public var canArchiveSelectedTabs: Bool
	public var canArchiveSpace: Bool
	public var canSwitchSpace: Bool

	/// How many spaces the window's switcher lists.
	public var spaceCount: Int
	public var isSplit: Bool

	/// Whether the split can take another pane: fewer than four, with room for one more.
	public var canAddPane: Bool
	public var canGoBack: Bool
	public var canGoForward: Bool

	/// Whether the page is loading, for Stop.
	public var isLoading: Bool

	/// Whether the page is an ordinary web page (http or https) that Print, Save As and View Source take.
	public var canSavePage: Bool

	/// How many tabs the window's sidebar lists in its space, for Next Tab and Select Tab.
	public var tabCount: Int
	public var captureAvailable: Bool
	public var downloadsAvailable: Bool

	/// Dark pages are on: the `ARX_DARK_PAGES` feature flag, an engine that has them, and a mode
	/// other than Off (DEV-1020).
	public var darkPagesOffered: Bool
	public var mediaAvailable: Bool

	/// The tab plays a video it can present in Media PiP (DEV-1106).
	public var canPresentMedia: Bool
	public var developerModeEnabled: Bool

	/// The `ARX_READING_MODE` feature flag (DEV-1028).
	public var readingModeEnabled: Bool

	/// The page shows in reading mode, which closes whatever the page is.
	public var isReading: Bool

	/// The page shows in WebKit (DEV-877), which reading mode can't read.
	public var usesWebKit: Bool

	/// Launch onboarding is holding the main window back (DEV-838): commands that would open it,
	/// or another browser window, wait until onboarding ends.
	public var mainWindowIsHeld: Bool

	/// Content blocking is on, so uBlock Origin's element picker can hide elements (DEV-1019).
	public var canHideElements: Bool

	/// The `ARX_TRANSLATE` feature flag (DEV-996): private windows translate too (DEV-1122).
	public var pageTranslationEnabled: Bool

	/// A proxy link rule matches the page's site, so the proxy link commands have something to
	/// do (DEV-1262): `LinkTransformer.proxies(_:rules:)` for the page's address.
	public var canProxyLink: Bool

	public init(
		host: Host,
		hasTab: Bool = false,
		isSaved: Bool = false,
		isPrivate: Bool = false,
		isBusy: Bool = false,
		isClosing: Bool = false,
		canUndo: Bool = false,
		canReopenArchivedTab: Bool = false,
		canReopenClosedWindow: Bool = false,
		canArchiveSelectedTabs: Bool? = nil,
		canArchiveSpace: Bool = false,
		canSwitchSpace: Bool = false,
		spaceCount: Int = 0,
		isSplit: Bool = false,
		canAddPane: Bool? = nil,
		canGoBack: Bool = false,
		canGoForward: Bool = false,
		isLoading: Bool = false,
		canSavePage: Bool = false,
		tabCount: Int = 0,
		captureAvailable: Bool = false,
		downloadsAvailable: Bool = false,
		darkPagesOffered: Bool = false,
		mediaAvailable: Bool = false,
		canPresentMedia: Bool = false,
		developerModeEnabled: Bool = false,
		readingModeEnabled: Bool = ReadingMode.isOn,
		isReading: Bool = false,
		usesWebKit: Bool = false,
		mainWindowIsHeld: Bool = false,
		canHideElements: Bool = false,
		pageTranslationEnabled: Bool = false,
		canProxyLink: Bool = false
	) {
		self.host = host
		self.hasTab = hasTab
		self.isSaved = isSaved
		self.isPrivate = isPrivate
		self.isBusy = isBusy
		self.isClosing = isClosing
		self.canUndo = canUndo
		self.canReopenArchivedTab = canReopenArchivedTab
		self.canReopenClosedWindow = canReopenClosedWindow
		self.canArchiveSelectedTabs = canArchiveSelectedTabs ?? (hasTab && !isSaved)
		self.canArchiveSpace = canArchiveSpace
		self.canSwitchSpace = canSwitchSpace
		self.spaceCount = spaceCount
		self.isSplit = isSplit
		self.canAddPane = canAddPane ?? !isSplit
		self.canGoBack = canGoBack
		self.canGoForward = canGoForward
		self.isLoading = isLoading
		self.canSavePage = canSavePage
		self.tabCount = tabCount
		self.captureAvailable = captureAvailable
		self.downloadsAvailable = downloadsAvailable
		self.darkPagesOffered = darkPagesOffered
		self.mediaAvailable = mediaAvailable
		self.canPresentMedia = canPresentMedia
		self.developerModeEnabled = developerModeEnabled
		self.readingModeEnabled = readingModeEnabled
		self.isReading = isReading
		self.usesWebKit = usesWebKit
		self.mainWindowIsHeld = mainWindowIsHeld
		self.canHideElements = canHideElements
		self.pageTranslationEnabled = pageTranslationEnabled
		self.canProxyLink = canProxyLink
	}
}
