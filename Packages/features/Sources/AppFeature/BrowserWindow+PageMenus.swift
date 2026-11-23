import AppKit
import AppUI
import BrowserAutomationClient
import BrowserCaptureClient
import BrowserCore
import BrowserEngineClient
import BrowserMediaClient
import BrowserPageInspectionClient
import BrowserPagePreviewClient
import BrowserPageWaitClient
import BrowserDownloadsClient
import BrowserSiteIconClient
import BrowserSurfaceClient
import BrowserHistoryClient
import HistoryDatabase
import PageTextIndexClient
import BrowserWorkspaceClient
import CoreServices.AE
import ChromiumBrowserEngine
import ChromiumEngine
import DownloadsFeature
import FairPlayBridge
import MainFeature
import MigrationAssistant
import MigrationAssistantFeature
import OnboardingFeature
import OSLog
import SettingsFeature
import SwiftUI
import TaskManagerFeature
import WebKitBrowserEngine
import WorkspaceSync
import _ComposableArchitecture

extension BrowserWindow {
	/// The command a page menu item carries out (DEV-795).
	internal static func command(for item: ChromiumPageMenuItem) -> BrowserCommand {
		switch item {
		case .back: .goBack
		case .forward: .goForward
		case .reload: .reload
		case .saveAs: .savePageAs
		case .print: .printPage
		case .viewSource: .viewSource
		case .share: .sharePage
		}
	}

	/// A context menu's app item as the app's action (DEV-814); nil without what it needs.
	internal static func action(for choice: ChromiumContextMenuChoice) -> PageContextAction? {
		switch choice.item {
		case .searchSelection: choice.text.map(PageContextAction.search)
		case .shareSelection: choice.text.map(PageContextAction.shareText)
		case .openImageInNewTab, .openVideoInNewTab, .openAudioInNewTab: choice.url.map(PageContextAction.openInNewTab)
		case .pictureInPicture: .pictureInPicture
		default: nil
		}
	}

	/// The context menu's app items a host can carry out (DEV-814).
	internal static func contextMenuItems(_ kinds: Set<PageContextAction.Kind>) -> Set<ChromiumContextMenuItem> {
		Set(ChromiumContextMenuItem.allCases.filter { item in
			switch item {
			case .searchSelection: kinds.contains(.search)
			case .shareSelection: kinds.contains(.shareText)
			case .openImageInNewTab, .openVideoInNewTab, .openAudioInNewTab: kinds.contains(.openInNewTab)
			case .pictureInPicture: kinds.contains(.pictureInPicture)
			default: false
			}
		})
	}

	/// The context menus' titles, one per item (DEV-814).
	internal static var contextMenuTitles: [ChromiumContextMenuItem: String] {
		Dictionary(uniqueKeysWithValues: ChromiumContextMenuItem.allCases.map { item in
			let title: String = switch item {
			case .cut: String.localized(.appUI.menu.cut)
			case .copy: String.localized(.appUI.menu.copy)
			case .paste: String.localized(.appUI.menu.paste)
			case .pasteAndMatchStyle: String.localized(.appUI.menu.pasteAndMatchStyle)
			case .selectAll: String.localized(.appUI.menu.selectAll)
			case .noGuesses: String.localized(.appUI.contextMenu.noGuesses)
			case .learnSpelling: String.localized(.appUI.contextMenu.learnSpelling)
			case .spelling: String.localized(.appUI.contextMenu.spelling)
			case .checkSpellingWhileTyping: String.localized(.appUI.contextMenu.checkSpellingWhileTyping)
			case .substitutions: String.localized(.appUI.contextMenu.substitutions)
			case .showSubstitutions: String.localized(.appUI.contextMenu.showSubstitutions)
			case .smartQuotes: String.localized(.appUI.contextMenu.smartQuotes)
			case .smartDashes: String.localized(.appUI.contextMenu.smartDashes)
			case .textReplacement: String.localized(.appUI.contextMenu.textReplacement)
			case .speech: String.localized(.appUI.contextMenu.speech)
			case .startSpeaking: String.localized(.appUI.contextMenu.startSpeaking)
			case .stopSpeaking: String.localized(.appUI.contextMenu.stopSpeaking)
			case .lookUp: String.localized(.appUI.contextMenu.lookUp)
			case .searchSelection: String.localized(.appUI.contextMenu.searchSelection)
			case .shareSelection: String.localized(.appUI.contextMenu.shareSelection)
			case .openImageInNewTab: String.localized(.appUI.contextMenu.openImageInNewTab)
			case .downloadImage: String.localized(.appUI.contextMenu.downloadImage)
			case .copyImage: String.localized(.appUI.contextMenu.copyImage)
			case .copyImageAddress: String.localized(.appUI.contextMenu.copyImageAddress)
			case .loop: String.localized(.appUI.contextMenu.loop)
			case .showControls: String.localized(.appUI.contextMenu.showControls)
			case .pictureInPicture: String.localized(.appUI.contextMenu.pictureInPicture)
			case .copyVideoFrame: String.localized(.appUI.contextMenu.copyVideoFrame)
			case .openVideoInNewTab: String.localized(.appUI.contextMenu.openVideoInNewTab)
			case .downloadVideo: String.localized(.appUI.contextMenu.downloadVideo)
			case .copyVideoAddress: String.localized(.appUI.contextMenu.copyVideoAddress)
			case .openAudioInNewTab: String.localized(.appUI.contextMenu.openAudioInNewTab)
			case .downloadAudio: String.localized(.appUI.contextMenu.downloadAudio)
			case .copyAudioAddress: String.localized(.appUI.contextMenu.copyAudioAddress)
			case .undo: String.localized(.appUI.menu.undo)
			case .redo: String.localized(.appUI.menu.redo)
			}
			return (item, title)
		})
	}
}
