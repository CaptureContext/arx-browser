import Foundation

/// What decides whether a browser or Little Arx window is on the display for automatic Picture
/// in Picture (DEV-1246, DEV-1322), as BrowserWindow reads it from AppKit.
///
/// Switching OS workspaces floats a video only when its window is full screen: a full-screen
/// window is an OS workspace of its own (tiled beside another app's in Split View too), so
/// leaving it takes the window off the display. A window that isn't full screen stays on the
/// display whichever OS workspace the person is on, so its video keeps playing in place.
/// Minimising the window or hiding Arx takes any window off the display.
internal struct WindowDisplay: Equatable, Sendable {
	/// Visible, not minimised, and Arx isn't hidden.
	internal var isShown: Bool

	/// In macOS full screen, alone or tiled.
	internal var isFullScreen: Bool

	/// On the OS workspace the display shows.
	internal var isOnActiveSpace: Bool

	internal init(
		isShown: Bool,
		isFullScreen: Bool,
		isOnActiveSpace: Bool
	) {
		self.isShown = isShown
		self.isFullScreen = isFullScreen
		self.isOnActiveSpace = isOnActiveSpace
	}

	internal var isOnDisplay: Bool {
		isShown && (isOnActiveSpace || !isFullScreen)
	}
}
