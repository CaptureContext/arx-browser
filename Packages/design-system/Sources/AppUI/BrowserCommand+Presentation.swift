import BrowserCore
import Foundation

extension BrowserCommand {
	public var symbol: String {
		switch self {
		// DEV-1333: the camera captures part of the page; the page itself has the lines of text.
		case .captureViewport: "text.viewfinder"
		case .captureRegion: "camera.viewfinder"
		case .media: "play.circle"
		case .downloads: "arrow.down.circle"
		case .newFolder: "folder.badge.plus"
		case .newSpace: "plus.rectangle.on.rectangle"
		case .nextSpace: "chevron.right"
		case .previousSpace: "chevron.left"
		case .space1, .space2, .space3, .space4, .space5, .space6, .space7, .space8, .space9:
			"\(spaceNumber ?? 1).square"
		case .toggleLibrary: "archivebox"
		case .chats: "bubble.left.and.text.bubble.right"
		case .pinChatToTab: "pin"
		case .openChatInTab: "macwindow"
		case .moveItems: "arrow.right.square"
		case .archiveAllInSpace: "archivebox.circle"
		case .undoOrganization: "arrow.uturn.backward"
		case .commandBar: "command"
		case .copyCleanLink, .copyURL: "link"
		case .copyMarkdownOriginal, .copyMarkdownProxy: "text.badge.checkmark"
		case .copyProxyLink: "link.badge.plus"
		case .routeCurrentURL: "arrow.triangle.branch"
		case .openFocusedLinkInPeek: "rectangle.portrait.on.rectangle.portrait"
		case .darkPage: "moon"
		case .shareProxyLink, .sharePage: "square.and.arrow.up"
		case .castTab: "tv.badge.wifi"
		case .hideElement: "eye.slash"
		case .pagePictureInPicture: "pip.enter"
		case .mediaPictureInPicture: "pip"
		case .settings: "gearshape"
		case .extensions: "puzzlepiece.extension"
		case .chromeWebStore: "storefront"
		case .taskManager: "gauge.with.dots.needle.50percent"
		case .sendFeedback: "envelope"
		case .onboarding: "hand.wave"
		case .newWindow: "macwindow.badge.plus"
		case .newPrivateWindow: "eyeglasses"
		case .littleArx: "macwindow"
		case .newTab: "plus"
		case .address: "magnifyingglass"
		case .openArchive: "archivebox"
		case .reopenLastClosedTab: "arrow.uturn.left.circle"
		case .reopenClosedWindow: "macwindow.badge.plus"
		case .archiveSelectedTabs: "archivebox.fill"
		case .closeTab: "xmark"
		case .closeWindow: "xmark.rectangle"
		case .toggleSidebar: "sidebar.left"
		case .duplicateTab: "plus.square.on.square"
		case .pinTab: "pin"
		case .newSplit: "rectangle.split.2x1"
		case .focusOtherPane: "rectangle.righthalf.inset.filled"
		case .closePane: "xmark.rectangle"
		case .swapPanes: "arrow.left.arrow.right"
		case .toggleSplitOrientation: "rectangle.split.1x2"
		case .findInPage: "text.magnifyingglass"
		case .findNext: "chevron.down"
		case .findPrevious: "chevron.up"
		case .goBack: "arrow.left"
		case .goForward: "arrow.right"
		case .reload: "arrow.clockwise"
		case .clearCacheAndReload: "trash"
		case .reloadBypassingCache: "arrow.clockwise.circle"
		case .zoomIn: "plus.magnifyingglass"
		case .zoomOut: "minus.magnifyingglass"
		case .actualSize: "1.magnifyingglass"
		case .developerTools: "hammer"
		case .inspectElement: "cursorarrow.rays"
		case .javaScriptConsole: "terminal"
		case .printPage: "printer"
		case .pageSetup: "doc.richtext"
		case .savePageAs: "square.and.arrow.down"
		case .openFile: "doc"
		case .showHistory: "clock.arrow.circlepath"
		case .viewSource: "chevron.left.forwardslash.chevron.right"
		case .translatePage: "translate"
		case .readingMode: "doc.plaintext"
		case .stopLoading: "xmark.circle"
		case .nextTab: "arrow.down.to.line"
		case .previousTab: "arrow.up.to.line"
		case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8: "\(tabNumber ?? 1).circle"
		case .lastTab: "arrow.down.to.line.compact"
		case .quit: "power"
		}
	}

	public var title: String {
		switch self {
		case .captureViewport: String.localized(.appUI.capture.viewportCommand)
		case .captureRegion: String.localized(.appUI.capture.regionCommand)
		case .media: String.localized(.appUI.media.title)
		case .downloads: String.localized(.appUI.downloads.title)
		case .newFolder: String.localized(.appUI.sidebar.newFolder)
		case .newSpace: String.localized(.appUI.sidebar.newSpace)
		case .nextSpace: String.localized(.appUI.command.nextSpace)
		case .previousSpace: String.localized(.appUI.command.previousSpace)
		case .space1, .space2, .space3, .space4, .space5, .space6, .space7, .space8, .space9:
			String.localized(.appUI.command.switchToSpaceNumber(spaceNumber ?? 1))
		case .toggleLibrary: String.localized(.appUI.sidebar.library)
		case .chats: String.localized(.appUI.command.chats)
		case .pinChatToTab: String.localized(.appUI.command.pinChatToTab)
		case .openChatInTab: String.localized(.appUI.command.openChatInTab)
		case .moveItems: String.localized(.appUI.move.choose)
		case .archiveAllInSpace: String.localized(.appUI.archive.allInSpace)
		case .undoOrganization: String.localized(.appUI.command.undoOrganization)
		case .commandBar: String.localized(.appUI.command.openCommands)
		case .copyCleanLink: String.localized(.appUI.menu.copyCleanLink)
		case .copyMarkdownOriginal: String.localized(.appUI.menu.copyMarkdownOriginal)
		case .copyProxyLink: String.localized(.appUI.menu.copyProxyLink)
		case .copyMarkdownProxy: String.localized(.appUI.menu.copyMarkdownProxy)
		case .routeCurrentURL: String.localized(.appUI.routing.routeCurrent)
		case .openFocusedLinkInPeek: String.localized(.appUI.command.openFocusedLinkInPeek)
		case .darkPage: String.localized(.appUI.darkPages.command)
		case .shareProxyLink: String.localized(.appUI.menu.shareProxyLink)
		case .sharePage: String.localized(.appUI.menu.sharePage)
		case .castTab: String.localized(.appUI.cast.command)
		case .hideElement: String.localized(.appUI.hideElement.command)
		case .pagePictureInPicture: String.localized(.appUI.pagePicture.command)
		case .mediaPictureInPicture: String.localized(.appUI.media.presentInTabPicture)
		case .settings: String.localized(.appUI.settings.title)
		case .extensions: String.localized(.appUI.command.extensions)
		case .chromeWebStore: String.localized(.appUI.extensions.chromeWebStore)
		case .taskManager: String.localized(.appUI.taskManager.title)
		case .sendFeedback: String.localized(.appUI.sendFeedback.commandTitle)
		case .onboarding: String.localized(.appUI.onboarding.command)
		case .newWindow: String.localized(.appUI.menu.openWindow)
		case .newPrivateWindow: String.localized(.appUI.menu.incognito)
		case .littleArx: String.localized(.appUI.littleArx.open)
		case .newTab: String.localized(.appUI.sidebar.newTab)
		case .address: String.localized(.appUI.url.search)
		case .openArchive: String.localized(.appUI.archive.title)
		case .reopenLastClosedTab: String.localized(.appUI.archive.reopenLast)
		case .reopenClosedWindow: String.localized(.appUI.menu.reopenClosedWindow)
		case .archiveSelectedTabs: String.localized(.appUI.archive.selected)
		case .closeTab: String.localized(.appUI.menu.closeTab)
		case .closeWindow: String.localized(.appUI.menu.closeWindow)
		case .copyURL: String.localized(.appUI.menu.copyURL)
		case .toggleSidebar: String.localized(.appUI.sidebar.toggle)
		case .duplicateTab: String.localized(.appUI.menu.duplicateTab)
		case .pinTab: String.localized(.appUI.menu.pinTab)
		case .newSplit: String.localized(.appUI.split.newPane)
		case .focusOtherPane: String.localized(.appUI.split.focusOther)
		case .closePane: String.localized(.appUI.split.closePane)
		case .swapPanes: String.localized(.appUI.split.swap)
		case .toggleSplitOrientation: String.localized(.appUI.split.orientation)
		case .findInPage: String.localized(.appUI.find.command)
		case .findNext: String.localized(.appUI.find.next)
		case .findPrevious: String.localized(.appUI.find.previous)
		case .goBack: String.localized(.appUI.navigation.back)
		case .goForward: String.localized(.appUI.navigation.forward)
		case .reload: String.localized(.appUI.menu.reload)
		case .clearCacheAndReload: String.localized(.appUI.menu.clearCacheReload)
		case .reloadBypassingCache: String.localized(.appUI.menu.reloadBypassingCache)
		case .zoomIn: String.localized(.appUI.menu.zoomIn)
		case .zoomOut: String.localized(.appUI.menu.zoomOut)
		case .actualSize: String.localized(.appUI.menu.actualSize)
		case .developerTools: String.localized(.appUI.menu.developerTools)
		case .inspectElement: String.localized(.appUI.menu.inspectElement)
		case .javaScriptConsole: String.localized(.appUI.menu.javaScriptConsole)
		case .printPage: String.localized(.appUI.menu.print)
		case .pageSetup: String.localized(.appUI.menu.pageSetup)
		case .savePageAs: String.localized(.appUI.menu.savePageAs)
		case .openFile: String.localized(.appUI.menu.openFile)
		case .showHistory: String.localized(.appUI.menu.showHistory)
		case .viewSource: String.localized(.appUI.menu.viewSource)
		case .translatePage: String.localized(.appUI.translation.translatePage)
		case .readingMode: String.localized(.appUI.reader.command)
		case .stopLoading: String.localized(.appUI.menu.stopLoading)
		case .nextTab: String.localized(.appUI.menu.nextTab)
		case .previousTab: String.localized(.appUI.menu.previousTab)
		case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8:
			String.localized(.appUI.command.selectTabNumber(tabNumber ?? 1))
		case .lastTab: String.localized(.appUI.command.selectLastTab)
		case .quit: String.localized(.appUI.menu.quit)
		}
	}

	/// A second line the command bar shows and matches, so a command is found by what it's for.
	public var subtitle: String {
		switch self {
		case .chromeWebStore: String.localized(.appUI.command.getExtensions)
		case .taskManager: String.localized(.appUI.taskManager.subtitle)
		case .sendFeedback: String.localized(.appUI.sendFeedback.commandSubtitle)
		case .darkPage: String.localized(.appUI.darkPages.subtitle)
		case .pagePictureInPicture: String.localized(.appUI.pagePicture.subtitle)
		case .mediaPictureInPicture: String.localized(.appUI.media.presentInTabPictureSubtitle)
		case .castTab: String.localized(.appUI.cast.subtitle)
		case .readingMode: String.localized(.appUI.reader.subtitle)
		case .hideElement: String.localized(.appUI.hideElement.subtitle)
		default: ""
		}
	}
}
