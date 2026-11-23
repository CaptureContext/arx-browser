import ChromiumBridge
import CoreGraphics
import Foundation

/// ABI48 (DEV-814). An item of the menus a right click on a text field, a selection, an
/// image, a video or audio shows. Declared in `ArxContextMenuItem` order.
public enum ChromiumContextMenuItem: CaseIterable, Equatable, Hashable, Sendable {
	case cut
	case copy
	case paste
	case pasteAndMatchStyle
	case selectAll

	/// Shown disabled for a misspelled word with no suggestions.
	case noGuesses
	case learnSpelling

	/// The Spelling and Grammar submenu's title.
	case spelling
	case checkSpellingWhileTyping

	/// The Substitutions submenu's title.
	case substitutions
	case showSubstitutions
	case smartQuotes
	case smartDashes
	case textReplacement

	/// The Speech submenu's title.
	case speech
	case startSpeaking
	case stopSpeaking

	/// "{}" in the title becomes the selection.
	case lookUp

	/// "{}" in the title becomes the selection. Carried out by the app.
	case searchSelection

	/// Carried out by the app.
	case shareSelection

	/// Carried out by the app.
	case openImageInNewTab

	/// Save Image As…, with the frame's referrer and the Save panel.
	case downloadImage
	case copyImage
	case copyImageAddress
	case loop
	case showControls

	/// ArxPiP for the video. Carried out by the app.
	case pictureInPicture
	case copyVideoFrame

	/// Carried out by the app.
	case openVideoInNewTab

	/// Save Video As….
	case downloadVideo
	case copyVideoAddress

	/// Carried out by the app.
	case openAudioInNewTab

	/// Save Audio As….
	case downloadAudio
	case copyAudioAddress
	case undo
	case redo

	/// Whether the app carries the item out, through `onContextMenuChoice`. The engine
	/// carries out the rest itself.
	public var isCarriedOutByApp: Bool {
		switch self {
		case .searchSelection, .shareSelection, .pictureInPicture, .openImageInNewTab, .openVideoInNewTab,
			.openAudioInNewTab:
			true
		default:
			false
		}
	}

	internal var native: ArxContextMenuItem {
		ArxContextMenuItem(rawValue: UInt32(Self.allCases.firstIndex(of: self)!))
	}

	/// The item's bit in `context_menu_items`.
	internal var mask: UInt64 { 1 << UInt64(native.rawValue) }

	internal init?(native: ArxContextMenuItem) {
		let index = Int(native.rawValue)
		guard Self.allCases.indices.contains(index) else { return nil }
		self = Self.allCases[index]
	}
}

/// ABI48 (DEV-814). An app item the person chose in a context menu.
public struct ChromiumContextMenuChoice: Equatable, Sendable {
	public var item: ChromiumContextMenuItem

	/// The image's or media's http(s) address, for the open items.
	public var url: URL?

	/// The selection, for Search and Share.
	public var text: String?

	/// Where the menu opened, in the page view's coordinates with the origin top-left.
	public var point: CGPoint

	public init(
		item: ChromiumContextMenuItem,
		url: URL? = nil,
		text: String? = nil,
		point: CGPoint
	) {
		self.item = item
		self.url = url
		self.text = text
		self.point = point
	}

	/// Nil for an item the app doesn't carry out, or one without what it needs: an
	/// http(s) address for the open items, text for the selection items.
	internal init?(native: ArxContextMenuChoice) {
		guard
			let item = ChromiumContextMenuItem(native: native.item),
			item.isCarriedOutByApp,
			native.url_size <= 8192,
			native.text_size <= 4096
		else { return nil }

		let url = Self.string(native.url, count: native.url_size)
			.flatMap(URL.init(string:))
			.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
		let text = Self.string(native.text, count: native.text_size)
		switch item {
		case .searchSelection, .shareSelection:
			guard let text, !text.isEmpty else { return nil }
		case .pictureInPicture:
			break
		default:
			guard url != nil else { return nil }
		}
		self.init(item: item, url: url, text: text, point: .init(x: native.x, y: native.y))
	}

	private static func string(
		_ bytes: UnsafePointer<UInt8>?,
		count: Int
	) -> String? {
		guard let bytes, count > 0 else { return nil }
		return String(validating: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
	}
}

extension ChromiumRuntime {
	/// Whether the engine shows Arx's context menus (ABI48).
	public var supportsContextMenus: Bool {
		state == .running && api.configure_context_menus != nil
	}

	/// Turns the context menus on with the host's localized titles, one per item in
	/// `ChromiumContextMenuItem.allCases` order. A missing title leaves them off.
	public func configureContextMenus(titles: [ChromiumContextMenuItem: String]) {
		guard state == .running, let configure = api.configure_context_menus else { return }

		let ordered = ChromiumContextMenuItem.allCases.map { titles[$0] ?? "" }
		let copies = ordered.map { strdup($0) }
		defer { copies.forEach { free($0) } }
		var pointers = copies.map { UnsafePointer($0) }
		configure(&pointers, pointers.count)
	}
}
