import AppKit
import Foundation

/// `void* make_window(void* context, void* content_view, const char* title,
/// const uint8_t* icon_png, size_t icon_png_size, const char* icon_path, double width,
/// double height)` (DEV-1316): main thread. A window the app made with the borrowed popup view in
/// it, sized so the view is `width` x `height`, not yet shown, returned +1; or nil for the
/// engine's own. The icon is the one the extension's toolbar button shows: PNG bytes, or a file
/// path, never resolved by the engine.
internal typealias ChromiumExtensionPopupMakeWindowFunction = @convention(c) (
	UnsafeMutableRawPointer?,
	UnsafeMutableRawPointer?,
	UnsafePointer<CChar>?,
	UnsafePointer<UInt8>?,
	Int,
	UnsafePointer<CChar>?,
	Double,
	Double
) -> UnsafeMutableRawPointer?

/// `void resize_window(void* context, void* window, double width, double height)` (DEV-1316):
/// main thread. Resizes the app's window so the popup view is that size, keeping its top-left
/// corner.
internal typealias ChromiumExtensionPopupResizeWindowFunction = @convention(c) (
	UnsafeMutableRawPointer?,
	UnsafeMutableRawPointer?,
	Double,
	Double
) -> Void

/// `void ArxEngineSetExtensionPopupPresenter(make_window, resize_window, closing, context)`
/// (DEV-1316): main thread, safe before the engine runs. An extension's action popup opens in
/// the app's window instead of the engine's own, and closes on losing focus as `closing` says.
/// Outside the ABI table: engines built before it show the popup in a popover and lack it.
internal typealias ChromiumSetExtensionPopupPresenterFunction = @convention(c) (
	ChromiumExtensionPopupMakeWindowFunction?,
	ChromiumExtensionPopupResizeWindowFunction?,
	UInt32,
	UnsafeMutableRawPointer?
) -> Void

internal let ChromiumSetExtensionPopupPresenterSymbol: String = "ArxEngineSetExtensionPopupPresenter"

/// How an extension's popup window answers losing focus (DEV-1316). Whatever the rule, its Close,
/// Escape and the extension's own `window.close()` close it, and it closes with the page it was
/// opened for: when that page navigates, closes or stops showing.
public enum ChromiumExtensionPopupClosing: UInt32, CaseIterable, Sendable {
	/// Closes on losing focus, as extensions expect of a popup, unless the person moved it: a
	/// moved popup stays until it's closed.
	case unlessMoved = 0

	/// Closes on losing focus, as Chrome's popup does, even after it was moved.
	case onFocusLoss = 1

	/// Stays open until it's closed.
	case staysOpen = 2
}

/// The app's window for an extension's action popup (DEV-1316).
public struct ChromiumExtensionPopupWindows {
	public var closing: ChromiumExtensionPopupClosing

	/// A window holding `view`, the popup's page, at `size` points, not yet shown. `title` is the
	/// extension's name and `icon` the encoded image its toolbar button shows, nil when it has
	/// none to show. Nil leaves the popup to the engine's own window.
	public var makeWindow: @MainActor (
		_ view: NSView,
		_ title: String,
		_ icon: Data?,
		_ size: CGSize
	) -> NSWindow?

	/// Resizes `window` so the popup's page is `size` points, keeping its top-left corner.
	public var resizeWindow: @MainActor (_ window: NSWindow, _ size: CGSize) -> Void

	public init(
		closing: ChromiumExtensionPopupClosing = .unlessMoved,
		makeWindow: @escaping @MainActor (NSView, String, Data?, CGSize) -> NSWindow?,
		resizeWindow: @escaping @MainActor (NSWindow, CGSize) -> Void
	) {
		self.closing = closing
		self.makeWindow = makeWindow
		self.resizeWindow = resizeWindow
	}
}

/// The windows the app gave, for the engine's callbacks. One engine per process.
@MainActor
private var extensionPopupWindows: ChromiumExtensionPopupWindows?

extension ChromiumRuntime {
	/// Whether this engine shows an extension's popup in a window the app gives (DEV-1316).
	public var supportsExtensionPopupWindows: Bool {
		optionalExports.setExtensionPopupPresenter != nil
	}

	/// Shows extensions' action popups in `windows`, closing as its rule says; nil goes back to
	/// the engine's own window, which closes on losing focus unless moved. False with an engine
	/// built before it, which keeps its popover. Safe before the engine starts.
	@discardableResult
	public func setExtensionPopupWindows(_ windows: ChromiumExtensionPopupWindows?) -> Bool {
		guard let setPresenter = optionalExports.setExtensionPopupPresenter
		else { return false }

		extensionPopupWindows = windows
		guard let windows else {
			setPresenter(nil, nil, ChromiumExtensionPopupClosing.unlessMoved.rawValue, nil)
			return true
		}

		// The engine calls on the main thread. Pointers cross into the main actor as addresses.
		setPresenter(
			{ _, view, title, png, pngSize, path, width, height in
				let view = view.map { UInt(bitPattern: $0) }
				let name = title.map { String(cString: $0) } ?? ""
				let icon = ChromiumRuntime.extensionPopupIcon(
					png: png,
					size: pngSize,
					path: path.map { String(cString: $0) }
				)
				let window = MainActor.assumeIsolated {
					ChromiumRuntime.makeExtensionPopupWindow(view, name, icon, width, height)
				}
				return window.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
			},
			{ _, window, width, height in
				let window = window.map { UInt(bitPattern: $0) }
				MainActor.assumeIsolated {
					ChromiumRuntime.resizeExtensionPopupWindow(window, width, height)
				}
			},
			windows.closing.rawValue,
			nil
		)
		return true
	}

	/// The engine asks for a window holding the view at `view`: the app's, handed over +1, as an
	/// address.
	private static func makeExtensionPopupWindow(
		_ view: UInt?,
		_ title: String,
		_ icon: Data?,
		_ width: Double,
		_ height: Double
	) -> UInt? {
		guard
			let windows = extensionPopupWindows,
			let view = view.flatMap({ UnsafeMutableRawPointer(bitPattern: $0) }),
			width.isFinite, height.isFinite, width > 0, height > 0
		else { return nil }

		let content = Unmanaged<NSView>.fromOpaque(view).takeUnretainedValue()
		guard let window = windows.makeWindow(content, title, icon, CGSize(width: width, height: height))
		else { return nil }

		focusPage(content, in: window)
		return UInt(bitPattern: Unmanaged.passRetained(window).toOpaque())
	}

	/// Gives the popup's page the keyboard before its window shows. A window shown with no first
	/// responder of its own has AppKit pick a key view as Tab would, and the engine answers a
	/// page view focused that way by focusing the page's first control: a field the page had
	/// focused itself before the window showed, a search field say, then lost the keyboard.
	internal static func focusPage(
		_ page: NSView,
		in window: NSWindow
	) {
		guard
			window.firstResponder === window,
			page.window === window,
			let responder = firstResponder(in: page)
		else { return }

		window.makeFirstResponder(responder)
	}

	/// The first view, `view` or below it, that takes the keyboard.
	private static func firstResponder(in view: NSView) -> NSView? {
		if view.acceptsFirstResponder { return view }

		return view.subviews.lazy.compactMap(firstResponder(in:)).first
	}

	/// The icon's bytes: the engine's PNG when it gave one, else the file at `path`, read only
	/// when it's a regular file of at most ``maximumExtensionPopupIconBytes``. Nil otherwise; the
	/// header then draws the extension's letter.
	nonisolated internal static func extensionPopupIcon(
		png: UnsafePointer<UInt8>?,
		size: Int,
		path: String?
	) -> Data? {
		if let png, (1...maximumExtensionPopupIconBytes).contains(size) {
			return Data(bytes: png, count: size)
		}
		guard
			let path, !path.isEmpty, path.hasPrefix("/"),
			let attributes = try? FileManager.default.attributesOfItem(atPath: path),
			attributes[.type] as? FileAttributeType == .typeRegular,
			let length = attributes[.size] as? Int,
			(1...maximumExtensionPopupIconBytes).contains(length)
		else { return nil }

		return FileManager.default.contents(atPath: path)
	}

	/// Manifest icons are small PNGs; anything larger isn't drawn.
	nonisolated internal static let maximumExtensionPopupIconBytes: Int = 512 * 1024

	/// The engine resizes a window the app made.
	private static func resizeExtensionPopupWindow(
		_ window: UInt?,
		_ width: Double,
		_ height: Double
	) {
		guard
			let windows = extensionPopupWindows,
			let window = window.flatMap({ UnsafeMutableRawPointer(bitPattern: $0) }),
			width.isFinite, height.isFinite, width > 0, height > 0
		else { return }

		let target = Unmanaged<NSWindow>.fromOpaque(window).takeUnretainedValue()
		windows.resizeWindow(target, CGSize(width: width, height: height))
	}
}
