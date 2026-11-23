import BrowserCore

// MARK: - Hints

/// The homepage's tips, as a game shows them while it loads. A tip that names a command shows
/// the person's own keys for it, and is left out when the command has none.
internal enum EmptyPageHints {
	internal static let duration: Double = 7

	/// Every tip, in the order they roll. Each names what in Arx it describes, so a test fails
	/// when a command, a setting or a feature flag it relies on goes away (DEV-1263).
	internal static let all: [EmptyPageHint] = [
		.keys(.newTab) { .appUI.emptyPage.hintNewTab($0) },
		.keys(.address) { .appUI.emptyPage.hintAddress($0) },
		.keys(.commandBar) { .appUI.emptyPage.hintCommandBar($0) },
		.keys(.toggleSidebar) { .appUI.emptyPage.hintSidebar($0) },
		.keys(.reopenLastClosedTab) { .appUI.emptyPage.hintReopen($0) },
		.text(.appUI.emptyPage.hintSpaces),
		.text(.appUI.emptyPage.hintPinned),
		.keys(.newFolder) { .appUI.emptyPage.hintFolder($0) },
		.text(.appUI.emptyPage.hintRename),
		.text(.appUI.emptyPage.hintSpaceDrop),
		.text(.appUI.emptyPage.hintArrows),
		.keys(.littleArx) { .appUI.emptyPage.hintLittleArx($0) },
		.text(.appUI.emptyPage.hintPeek, needs: [.setting("row/links/peek")]),
		.text(.appUI.emptyPage.hintSplitDrop),
		.keys(.toggleLibrary) { .appUI.emptyPage.hintLibrary($0) },
		.keys(.space1, .space9) { .appUI.emptyPage.hintSpaceKeys($0, $1) },
		.keys(.copyURL) { .appUI.emptyPage.hintCopyURL($0) },
		.text(.appUI.emptyPage.hintChat),
		.keys(.pagePictureInPicture) { .appUI.emptyPage.hintPagePiP($0) },
		.text(.appUI.emptyPage.hintHoverPreview, needs: [.setting("row/general/hoverPreviews")]),
		.keys(.newPrivateWindow) { .appUI.emptyPage.hintPrivate($0) },
		.text(.appUI.emptyPage.hintBlocking, needs: [.setting("row/general/contentBlocking")]),
		.keys(.nextTab, .previousTab) { .appUI.emptyPage.hintNextTab($0, $1) },
		.text(.appUI.emptyPage.hintCalculator),
		.text(.appUI.emptyPage.hintCaptureArea, needs: [.command(.captureRegion)]),
		.text(.appUI.emptyPage.hintProfiles, needs: [.setting("row/profiles/profileList")]),
		.keys(.readingMode, needs: [.featureFlag(.readingMode)]) { .appUI.emptyPage.hintReadingMode($0) },
		.text(.appUI.emptyPage.hintFavorites),
		.keys(.newSplit) { .appUI.emptyPage.hintSplitAdd($0) },
		.text(.appUI.emptyPage.hintRouting, needs: [.setting("page/routing")]),
		.text(.appUI.emptyPage.hintAssistants, needs: [.setting("automation")]),
		.keys(.settings) { .appUI.emptyPage.hintSettings($0) },
		.keys(.findInPage, .findNext) { .appUI.emptyPage.hintFind($0, $1) },
		.text(.appUI.emptyPage.hintNewSpace, needs: [.featureFlag(.swipeToCreateSpace)]),
		.keys(.openFocusedLinkInPeek) { .appUI.emptyPage.hintFocusedLink($0) },
		.text(.appUI.emptyPage.hintCleanLink, needs: [.command(.copyCleanLink)]),
		.text(.appUI.emptyPage.hintAutoPictureInPicture, needs: [.setting("row/general/pictureInPicture")]),
		.text(.appUI.emptyPage.hintBangs),
		.keys(.closeTab) { .appUI.emptyPage.hintCloseResets($0) },
		.keys(.hideElement, needs: [.featureFlag(.hideElement)]) { .appUI.emptyPage.hintHideElement($0) },
		.text(.appUI.emptyPage.hintSpaceIcon),
		.keys(.focusOtherPane) { .appUI.emptyPage.hintFocusPane($0) },
		.text(.appUI.emptyPage.hintWebKit, needs: [.setting("page/webKitSites")]),
		.text(.appUI.emptyPage.hintChatPin, needs: [.command(.pinChatToTab)]),
		.keys(.tab1, .lastTab) { .appUI.emptyPage.hintFirstLastTab($0, $1) },
		.text(.appUI.emptyPage.hintMatchSite, needs: [.setting("row/appearance/matchSite"), .featureFlag(.matchSiteBackground)]),
		.text(.appUI.emptyPage.hintGlobalLittleArx, needs: [.setting("row/links/globalLittleArx")]),
		.text(.appUI.emptyPage.hintArchive, needs: [.command(.openArchive), .setting("row/profiles/profileList")]),
		.keys(.zoomIn, .zoomOut) { .appUI.emptyPage.hintZoom($0, $1) },
		.text(.appUI.emptyPage.hintSearchShortcut, needs: [.setting("page/searchShortcuts")]),
		.text(.appUI.emptyPage.hintMedia, needs: [.command(.media)]),
		.text(.appUI.emptyPage.hintGroupTabs),
		.text(.appUI.emptyPage.hintProxyLinks, needs: [.setting("page/proxyLinks")]),
		.keys(.taskManager) { .appUI.emptyPage.hintTaskManager($0) },
		.keys(.newWindow) { .appUI.emptyPage.hintNewWindow($0) },
		.text(.appUI.emptyPage.hintFavoriteLinks, needs: [.setting("row/links/crossSitePeek")]),
		.keys(.swapPanes, .toggleSplitOrientation) { .appUI.emptyPage.hintArrangePanes($0, $1) },
		.text(.appUI.emptyPage.hintTranslate, needs: [.command(.translatePage), .featureFlag(.translate)]),
		.keys(.commandBar) { .appUI.emptyPage.hintActions($0) },
		.text(.appUI.emptyPage.hintKeepLoaded, needs: [.setting("page/keptLoadedSites")]),
		.text(.appUI.emptyPage.hintAssistantGrants, needs: [.setting("automation")]),
		.text(.appUI.emptyPage.hintSidebarSide, needs: [.setting("row/appearance/sidebarPosition")]),
		.text(.appUI.emptyPage.hintTabVolume),
		.text(.appUI.emptyPage.hintImport, needs: [.setting("row/advanced/browserData")]),
		.text(.appUI.emptyPage.hintTearOff),
		.text(.appUI.emptyPage.hintCast, needs: [.command(.castTab)]),
		.keys(.pinTab) { .appUI.emptyPage.hintPinTab($0) },
		.text(.appUI.emptyPage.hintCreate),
		.text(.appUI.emptyPage.hintSpaceAppearance),
		.text(.appUI.emptyPage.hintLinkStatus, needs: [.setting("row/links/linkStatus"), .featureFlag(.linkStatus)]),
		.text(.appUI.emptyPage.hintBatterySaver, needs: [.setting("row/general/batterySaver")]),
		.keys(.closePane) { .appUI.emptyPage.hintClosePane($0) },
		.text(.appUI.emptyPage.hintChatTab, needs: [.command(.openChatInTab)]),
		.text(.appUI.emptyPage.hintUndo, needs: [.command(.undoOrganization)]),
		.text(.appUI.emptyPage.hintAppLinks, needs: [.setting("page/appLinks")]),
		.keys(.showHistory) { .appUI.emptyPage.hintHistory($0) },
		.text(.appUI.emptyPage.hintPasswords, needs: [.setting("row/general/autofillAuthentication")]),
		.keys(.toggleSidebar) { .appUI.emptyPage.hintFullScreenSidebar($0) },
		.text(.appUI.emptyPage.hintAliases, needs: [.setting("row/shortcuts/commands")]),
		.text(.appUI.emptyPage.hintSidebarKeys),
		.text(.appUI.emptyPage.hintWebStore, needs: [.command(.chromeWebStore)]),
		.text(.appUI.emptyPage.hintUnload, needs: [.setting("row/general/tabUnloading")]),
		.text(.appUI.emptyPage.hintAssistantStop),
		.text(.appUI.emptyPage.hintLinkTabs, needs: [.setting("row/general/linkTabSwitching")]),
		.text(.appUI.emptyPage.hintCaptureChat),
		.text(.appUI.emptyPage.hintPlayer),
		.text(.appUI.emptyPage.hintSiteMenu),
		.keys(.developerTools, needs: [.setting("row/developer/developerMode")]) { .appUI.emptyPage.hintDevTools($0) },
		.text(.appUI.emptyPage.hintAskForProfile, needs: [.setting("page/routing")]),
		.text(.appUI.emptyPage.hintNewTabPlacement, needs: [.setting("row/general/openedTabPlacement"), .featureFlag(.newTabsAtTop)]),
		.text(.appUI.emptyPage.hintUnreadBadges, needs: [.setting("row/general/unreadBadges")]),
		.text(.appUI.emptyPage.hintPageWords),
		.text(.appUI.emptyPage.hintFolderPreview, needs: [.setting("panel/previews/previews")]),
		.text(.appUI.emptyPage.hintGmail, needs: [.setting("panel/previews/previews")]),
		.text(.appUI.emptyPage.hintRecentPages, needs: [.setting("panel/previews/previews")]),
		.keys(.quit, needs: [.setting("row/general/warnBeforeQuitting")]) { .appUI.emptyPage.hintQuit($0) },
		.text(.appUI.emptyPage.hintAssistantSignIn),
		.text(.appUI.emptyPage.hintSwipeBack),
		.text(.appUI.emptyPage.hintDownloads, needs: [.command(.downloads)]),
		.text(.appUI.emptyPage.hintDefaultBrowser, needs: [.setting("row/arx/defaultBrowser")]),
	]

	internal static func texts(bindings: [ShortcutBinding]) -> [String] {
		all.compactMap { $0.text(bindings: bindings) }
	}
}

/// One tip: its words, the commands whose keys it shows, and what else in Arx it names.
internal struct EmptyPageHint: Sendable {
	/// Something in Arx a tip names, which has to exist for the tip to stay true.
	internal enum Need: Hashable, Sendable {
		/// A command the tip names by its title, such as Copy Clean Link.
		case command(BrowserCommand)

		/// A Settings row, page or pane, by its `SettingsDestination` id, such as
		/// `row/general/batterySaver`. AppUI can't see Settings; IntegrationFeatureTests checks it.
		case setting(String)

		/// A feature flag that's on by default.
		case featureFlag(FeatureFlag)
	}

	/// The commands whose keys the tip shows, in the order its text takes them.
	internal let shortcuts: [BrowserCommand]
	internal let needs: [Need]
	private let resource: @Sendable ([String]) -> _XCStringResource

	private init(
		shortcuts: [BrowserCommand],
		needs: [Need],
		resource: @escaping @Sendable ([String]) -> _XCStringResource
	) {
		self.shortcuts = shortcuts
		self.needs = needs
		self.resource = resource
	}

	/// A tip without keys.
	internal static func text(
		_ resource: _XCStringResource,
		needs: [Need] = []
	) -> Self {
		.init(shortcuts: [], needs: needs) { _ in resource }
	}

	/// A tip that shows one command's keys.
	internal static func keys(
		_ command: BrowserCommand,
		needs: [Need] = [],
		_ resource: @escaping @Sendable (String) -> _XCStringResource
	) -> Self {
		.init(shortcuts: [command], needs: needs) { keys in resource(keys[0]) }
	}

	/// A tip that shows two commands' keys.
	internal static func keys(
		_ first: BrowserCommand,
		_ second: BrowserCommand,
		needs: [Need] = [],
		_ resource: @escaping @Sendable (String, String) -> _XCStringResource
	) -> Self {
		.init(shortcuts: [first, second], needs: needs) { keys in resource(keys[0], keys[1]) }
	}

	/// The string catalog key, such as `emptyPage.hintNewTab`.
	internal var key: String {
		String(describing: blank.key)
	}

	/// The tip's own words, with its keys left out.
	internal var template: String {
		String.localized(blank)
	}

	private var blank: _XCStringResource {
		resource(shortcuts.map { _ in "" })
	}

	/// The tip with the person's keys, or nil when a command it shows has none.
	internal func text(bindings: [ShortcutBinding]) -> String? {
		var keys: [String] = []
		for command in shortcuts {
			guard let shortcut = bindings.shortcut(for: command) else { return nil }

			keys.append(shortcut.display)
		}
		return String.localized(resource(keys))
	}
}
