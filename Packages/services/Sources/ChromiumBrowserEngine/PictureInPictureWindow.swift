import AppKit
import Foundation

/// Finds ArxPiP's window and checks that it joins every Space, other apps' full-screen ones
/// included (DEV-848, DEV-852, DEV-962).
///
/// The engine creates Chromium's video Picture in Picture window that way: a non-activating
/// panel from creation (macOS decides then whether a window may join another app's
/// full-screen Space, DEV-962), with activation independence, `.canJoinAllSpaces`,
/// `.fullScreenAuxiliary` and `.canJoinAllApplications` before it's first shown, at the
/// floating level. Ordering Chromium's window out again ends Picture in Picture, so Arx doesn't
/// change the window after it's shown; this is only the check the smokes use. Window flags
/// alone don't show whether the window can join; the media smoke checks that it does, over
/// another app's full-screen window.
public enum PictureInPictureWindow {
	/// The collection behaviour the engine gives the window.
	public static let collectionBehavior: NSWindow.CollectionBehavior = [
		.canJoinAllSpaces,
		.fullScreenAuxiliary,
		.canJoinAllApplications,
	]

	/// Whether `window` is Chromium's video Picture in Picture window: Arx's other windows are
	/// AppKit's own, and Chromium shows no other frameless window at the floating level.
	@MainActor
	public static func isPictureInPictureWindow(_ window: NSWindow) -> Bool {
		NSStringFromClass(type(of: window)) == "NativeWidgetMacFramelessNSWindow"
		&& window.level == .floating
	}

	/// Whether `window` has the behaviour that puts it on every Space and over full-screen apps.
	@MainActor
	public static func joinsEverySpace(_ window: NSWindow) -> Bool {
		window.collectionBehavior.isSuperset(of: collectionBehavior)
		&& !window.hidesOnDeactivate
	}

	/// The one visible Picture in Picture window, if exactly one is showing.
	@MainActor
	public static func visible() -> NSWindow? {
		let windows = NSApp.windows.filter { $0.isVisible && isPictureInPictureWindow($0) }
		return windows.count == 1 ? windows.first : nil
	}
}
