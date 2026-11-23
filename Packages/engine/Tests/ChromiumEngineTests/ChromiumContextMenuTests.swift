import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// ABI48 context menus (DEV-814): items match the header's order, and a choice reaches
/// Swift only with what its item needs.
@Suite
internal struct ChromiumContextMenuTests {
	@Test
	internal func itemsFollowTheHeaderOrder() {
		#expect(ChromiumContextMenuItem.allCases.count == Int(ARX_CONTEXT_MENU_ITEM_COUNT.rawValue))
		let pairs: [(ChromiumContextMenuItem, ArxContextMenuItem)] = [
			(.cut, ARX_CONTEXT_MENU_CUT),
			(.selectAll, ARX_CONTEXT_MENU_SELECT_ALL),
			(.noGuesses, ARX_CONTEXT_MENU_NO_GUESSES),
			(.checkSpellingWhileTyping, ARX_CONTEXT_MENU_CHECK_SPELLING_WHILE_TYPING),
			(.textReplacement, ARX_CONTEXT_MENU_TEXT_REPLACEMENT),
			(.stopSpeaking, ARX_CONTEXT_MENU_STOP_SPEAKING),
			(.lookUp, ARX_CONTEXT_MENU_LOOK_UP),
			(.searchSelection, ARX_CONTEXT_MENU_SEARCH_SELECTION),
			(.shareSelection, ARX_CONTEXT_MENU_SHARE_SELECTION),
			(.openImageInNewTab, ARX_CONTEXT_MENU_OPEN_IMAGE_IN_NEW_TAB),
			(.copyImageAddress, ARX_CONTEXT_MENU_COPY_IMAGE_ADDRESS),
			(.loop, ARX_CONTEXT_MENU_LOOP),
			(.copyVideoFrame, ARX_CONTEXT_MENU_COPY_VIDEO_FRAME),
			(.downloadVideo, ARX_CONTEXT_MENU_DOWNLOAD_VIDEO),
			(.openAudioInNewTab, ARX_CONTEXT_MENU_OPEN_AUDIO_IN_NEW_TAB),
			(.copyAudioAddress, ARX_CONTEXT_MENU_COPY_AUDIO_ADDRESS),
			(.undo, ARX_CONTEXT_MENU_UNDO),
			(.redo, ARX_CONTEXT_MENU_REDO),
		]
		for (item, native) in pairs {
			#expect(item.native == native)
			#expect(ChromiumContextMenuItem(native: native) == item)
		}
		#expect(ChromiumContextMenuItem(native: ARX_CONTEXT_MENU_ITEM_COUNT) == nil)
		#expect(ChromiumContextMenuItem.downloadImage.mask == 1 << 21)
	}

	@Test
	internal func onlyTheSixAppItemsGoToTheApp() {
		let app = ChromiumContextMenuItem.allCases.filter(\.isCarriedOutByApp)
		#expect(app == [
			.searchSelection, .shareSelection, .openImageInNewTab, .pictureInPicture, .openVideoInNewTab,
			.openAudioInNewTab,
		])
	}

	@Test
	internal func pageMenuSharesSinceABI48() {
		#expect(ChromiumPageMenuItem.allCases.count == Int(ARX_PAGE_MENU_ITEM_COUNT.rawValue))
		#expect(ChromiumPageMenuItem.share.mask == 1 << 6)
		#expect(ChromiumPageMenuItem(native: ARX_PAGE_MENU_SHARE) == .share)
	}

	@Test
	internal func choicesCarryWhatTheirItemNeeds() {
		#expect(choice(ARX_CONTEXT_MENU_OPEN_IMAGE_IN_NEW_TAB, url: "https://example.com/a.png")
			== .init(item: .openImageInNewTab, url: URL(string: "https://example.com/a.png"), point: .init(x: 3, y: 4)))
		#expect(choice(ARX_CONTEXT_MENU_PICTURE_IN_PICTURE) == .init(item: .pictureInPicture, point: .init(x: 3, y: 4)))
		#expect(choice(ARX_CONTEXT_MENU_SEARCH_SELECTION, text: "the words")
			== .init(item: .searchSelection, text: "the words", point: .init(x: 3, y: 4)))

		// A native item, a missing or non-web address, or a missing selection never arrives.
		#expect(choice(ARX_CONTEXT_MENU_COPY_IMAGE, url: "https://example.com/a.png") == nil)
		#expect(choice(ARX_CONTEXT_MENU_DOWNLOAD_IMAGE, url: "https://example.com/a.png") == nil)
		#expect(choice(ARX_CONTEXT_MENU_OPEN_IMAGE_IN_NEW_TAB) == nil)
		#expect(choice(ARX_CONTEXT_MENU_OPEN_VIDEO_IN_NEW_TAB, url: "file:///etc/hosts") == nil)
		#expect(choice(ARX_CONTEXT_MENU_SHARE_SELECTION) == nil)
		#expect(choice(ARX_CONTEXT_MENU_SHARE_SELECTION, text: String(repeating: "a", count: 4097)) == nil)
	}

	private func choice(
		_ item: ArxContextMenuItem,
		url: String = "",
		text: String = ""
	) -> ChromiumContextMenuChoice? {
		let url = Array(url.utf8), text = Array(text.utf8)
		return url.withUnsafeBufferPointer { url in
			text.withUnsafeBufferPointer { text in
				ChromiumContextMenuChoice(native: .init(
					item: item,
					url: url.baseAddress,
					text: text.baseAddress,
					url_size: url.count,
					text_size: text.count,
					x: 3,
					y: 4
				))
			}
		}
	}
}
