import ChromiumBridge
import Foundation

/// ABI45 (DEV-795). An item of the menu a right click on the page itself shows.
public enum ChromiumPageMenuItem: CaseIterable, Equatable, Sendable {
	case back
	case forward
	case reload
	case saveAs
	case print
	case viewSource

	/// ABI48 (DEV-818): Share… with the page's address and title.
	case share

	/// The item's bit in `page_menu_items`.
	internal var mask: UInt32 {
		let native: ArxPageMenuItem = switch self {
		case .back: ARX_PAGE_MENU_BACK
		case .forward: ARX_PAGE_MENU_FORWARD
		case .reload: ARX_PAGE_MENU_RELOAD
		case .saveAs: ARX_PAGE_MENU_SAVE_AS
		case .print: ARX_PAGE_MENU_PRINT
		case .viewSource: ARX_PAGE_MENU_VIEW_SOURCE
		case .share: ARX_PAGE_MENU_SHARE
		}
		return 1 << native.rawValue
	}

	internal init?(native: ArxPageMenuItem) {
		switch native {
		case ARX_PAGE_MENU_BACK: self = .back
		case ARX_PAGE_MENU_FORWARD: self = .forward
		case ARX_PAGE_MENU_RELOAD: self = .reload
		case ARX_PAGE_MENU_SAVE_AS: self = .saveAs
		case ARX_PAGE_MENU_PRINT: self = .print
		case ARX_PAGE_MENU_VIEW_SOURCE: self = .viewSource
		case ARX_PAGE_MENU_SHARE: self = .share
		default: return nil
		}
	}
}

/// ABI45 (DEV-795). How Save Page As writes the page, as Chrome's formats.
public enum ChromiumSavePageKind: Equatable, Sendable {
	/// The page's HTML alone.
	case htmlOnly

	/// The HTML and its resources in a "<name>_files" folder beside it.
	case complete

	/// One MHTML web archive.
	case webArchive

	internal var native: ArxSavePageKind {
		switch self {
		case .htmlOnly: ARX_SAVE_PAGE_HTML_ONLY
		case .complete: ARX_SAVE_PAGE_COMPLETE
		case .webArchive: ARX_SAVE_PAGE_MHTML
		}
	}
}

extension ChromiumRuntime {
	/// Whether the engine shows Arx's page menu and saves pages (ABI45).
	public var supportsPageMenu: Bool {
		state == .running && api.configure_page_menu != nil && api.save_page != nil
	}

	/// Turns the page menu on with the host's localized titles, one per item in
	/// `ChromiumPageMenuItem.allCases` order. Choices arrive at `onPageMenuChoice`.
	public func configurePageMenu(titles: [ChromiumPageMenuItem: String]) {
		guard state == .running, let configure = api.configure_page_menu else { return }

		let ordered = ChromiumPageMenuItem.allCases.map { titles[$0] ?? "" }
		let copies = ordered.map { strdup($0) }
		defer { copies.forEach { free($0) } }
		var pointers = copies.map { UnsafePointer($0) }
		configure(&pointers, pointers.count)
	}

	/// Saves the page's current http(s) document to `url`, a file URL. The save
	/// runs as a download in the page's profile.
	public func savePage(
		_ page: ChromiumPage,
		to url: URL,
		kind: ChromiumSavePageKind
	) throws {
		guard url.isFileURL else { throw ChromiumError.invalidFileURL }
		try perform(on: page) { api, id in
			guard
				let save = api.save_page,
				save(id, url.path(percentEncoded: false), kind.native)
			else { throw ChromiumError.invalidURL }
		}
	}
}
