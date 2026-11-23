import AppKit

/// The app's window for an extension's action popup (DEV-1316): the engine places, shows,
/// focuses and closes it, and keeps it the size the popup's page asks for.
public struct BrowserExtensionPopupWindows {
	/// How a popup's window answers losing focus. Whatever the rule, its Close, Escape and the
	/// extension's own `window.close()` close it, and it closes with the page it was opened for.
	public enum Closing: Equatable, Sendable {
		/// Closes on losing focus, as extensions expect of a popup, unless the person moved it: a
		/// moved popup stays until it's closed.
		case unlessMoved

		/// Closes on losing focus, as Chrome's popup does, even after it was moved.
		case onFocusLoss

		/// Stays open until it's closed.
		case staysOpen
	}

	public var closing: Closing

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
		closing: Closing,
		makeWindow: @escaping @MainActor (NSView, String, Data?, CGSize) -> NSWindow?,
		resizeWindow: @escaping @MainActor (NSWindow, CGSize) -> Void
	) {
		self.closing = closing
		self.makeWindow = makeWindow
		self.resizeWindow = resizeWindow
	}
}
