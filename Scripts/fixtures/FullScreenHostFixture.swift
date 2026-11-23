import AppKit
import Foundation

/// Stands in for another app's full-screen Space, such as Safari's or Xcode's, in the media
/// smoke's Picture in Picture check (DEV-962). PiP has to float over other apps' full-screen
/// windows, which a full-screen window of Arx's own doesn't show.
///
/// Usage: FullScreenHostFixture [lifetime in seconds, 120 by default]
///
/// It prints `ARX_FULL_SCREEN_HOST_READY window=<number>` once its window is in full screen, and
/// quits when its standard input closes (the smoke finished or died) or its lifetime ends.
@main
private enum FullScreenHostFixture {
	@MainActor
	static func main() {
		let lifetime = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 120
		Thread.detachNewThread {
			while !FileHandle.standardInput.availableData.isEmpty {}
			exit(0)
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { exit(0) }
		let application = NSApplication.shared
		let delegate = Delegate()
		application.delegate = delegate
		application.setActivationPolicy(.regular)
		application.run()
	}
}

@MainActor
private final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
	private var window: NSWindow?

	func applicationDidFinishLaunching(_ notification: Notification) {
		let window = NSWindow(
			contentRect: NSRect(x: 120, y: 120, width: 640, height: 420),
			styleMask: [.titled, .resizable, .closable],
			backing: .buffered,
			defer: false
		)
		window.title = "Arx smoke full-screen host"
		window.collectionBehavior = [.fullScreenPrimary]
		window.backgroundColor = .darkGray
		window.delegate = self
		window.makeKeyAndOrderFront(nil)
		self.window = window
		NSApp.activate(ignoringOtherApps: true)
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(500))
			window.toggleFullScreen(nil)
		}
	}

	func windowDidEnterFullScreen(_ notification: Notification) {
		guard let window else { return }

		print("ARX_FULL_SCREEN_HOST_READY window=\(window.windowNumber)")
		fflush(stdout)
	}
}
