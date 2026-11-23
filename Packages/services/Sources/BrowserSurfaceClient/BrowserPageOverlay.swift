import BrowserCore
import SwiftUI

/// Native content a host draws above one page's surface, such as the capture overlay.
/// It lives in the window, never in the page, so pages can't read or style it.
public struct BrowserPageOverlay: Sendable {
	public var content: @MainActor @Sendable (BrowserCore.Tab.ID) -> AnyView?

	public init(content: @escaping @MainActor @Sendable (BrowserCore.Tab.ID) -> AnyView?) {
		self.content = content
	}
}

extension EnvironmentValues {
	@Entry
	public var browserPageOverlay: BrowserPageOverlay? = nil
}

extension EnvironmentValues {
	/// A notice a host draws at one page's top-right corner, such as the link toast in split
	/// view, so it shows which pane it reports on. Unlike ``browserPageOverlay`` it never takes
	/// the keyboard, so coming and going leaves focus where it is.
	@Entry
	public var browserPageNotice: BrowserPageOverlay? = nil

	/// What a host shows in place of a suppressed page that's lent to another window, such as a
	/// page floating in Page PiP (DEV-950). Nil for a tab leaves the place empty, as before.
	@Entry
	public var browserTabPlaceholder: BrowserPageOverlay? = nil
}
