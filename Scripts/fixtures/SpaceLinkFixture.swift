import AppKit
import Foundation

/// Stands in for an app such as Slack (DEV-931): it sends links to a running Arx through
/// LaunchServices, which activates Arx as a click would. The first link comes from the desktop
/// Space with Arx's main window, the second from this app's own full-screen Space. Each must
/// open a Little Arx on the Space it came from, and the second must not switch Spaces.
///
/// Usage: SpaceLinkFixture <Arx.app> <Arx pid> <first url> <second url> <done file>
///
/// It creates the done file once it has checked the second Little Arx, so Arx keeps its windows
/// until then.
@main
private enum SpaceLinkFixture {
	@MainActor
	static func main() {
		let application = NSApplication.shared
		let delegate = Delegate()
		application.delegate = delegate
		application.setActivationPolicy(.regular)
		application.run()
	}
}

private enum Failure: Error {
	case usage, notActive, arxNotOnDesktop, noFullScreen, littleArxFollowed, spaceSwitched
	case noLittleArx, mainWindowShown, leftFullScreen, timedOut, foreignInstance
}

@MainActor
private final class Delegate: NSObject, NSApplicationDelegate {
	private var window: NSWindow?
	private var spaceChanges: Int = 0
	private var observer: (any NSObjectProtocol)?

	func applicationDidFinishLaunching(_ notification: Notification) {
		Task { @MainActor in
			do {
				try await run()
				print("ARX_SPACE_LINK_FIXTURE_SUCCESS")
				exit(0)
			} catch {
				FileHandle.standardError.write(Data("Space link fixture failed: \(error)\n".utf8))
				exit(1)
			}
		}
	}

	private func run() async throws {
		let arguments = CommandLine.arguments
		guard
			arguments.count == 6,
			let pid = pid_t(arguments[2]),
			let first = URL(string: arguments[3]),
			let second = URL(string: arguments[4])
		else { throw Failure.usage }

		let arx = URL(fileURLWithPath: arguments[1])
		observer = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.activeSpaceDidChangeNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.spaceChanges += 1 }
		}

		let window = NSWindow(
			contentRect: .init(x: 200, y: 200, width: 640, height: 400),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.title = "Space link fixture"
		window.collectionBehavior = [.fullScreenPrimary]
		window.isReleasedWhenClosed = false
		self.window = window
		try await bringForward()

		// The desktop Space with Arx's main window: Little Arx opens here.
		guard windows(of: pid).contains(where: \.isMain) else { throw Failure.arxNotOnDesktop }
		try await open(first, in: arx, pid: pid)
		try await waitFor(.noLittleArx) { self.windows(of: pid).contains(where: \.isFloating) }
		guard spaceChanges == 0 else { throw Failure.spaceSwitched }
		try await bringForward()

		// This app's own full-screen Space, with no Arx window at all.
		window.toggleFullScreen(nil)
		try await waitFor(.noFullScreen) {
			window.styleMask.contains(.fullScreen) && window.isOnActiveSpace && self.spaceChanges > 0
		}
		try await Task.sleep(for: .seconds(1))
		guard !windows(of: pid).contains(where: \.isFloating) else { throw Failure.littleArxFollowed }
		guard !windows(of: pid).contains(where: \.isMain) else { throw Failure.mainWindowShown }

		let changes = spaceChanges
		try await open(second, in: arx, pid: pid)
		try await waitFor(.noLittleArx) { self.windows(of: pid).contains(where: \.isFloating) }
		try await Task.sleep(for: .milliseconds(1500))
		guard spaceChanges == changes, window.isOnActiveSpace else { throw Failure.spaceSwitched }
		guard window.styleMask.contains(.fullScreen) else { throw Failure.leftFullScreen }
		guard windows(of: pid).filter(\.isFloating).count == 1 else { throw Failure.littleArxFollowed }
		guard !windows(of: pid).contains(where: \.isMain) else { throw Failure.mainWindowShown }
		guard FileManager.default.createFile(atPath: arguments[5], contents: Data()) else { throw Failure.usage }

		NSApp.activate()
		window.toggleFullScreen(nil)
		try await waitFor(.timedOut) { !window.styleMask.contains(.fullScreen) }
		window.close()
	}

	private func bringForward() async throws {
		guard let window else { throw Failure.usage }

		// Under cooperative activation, a plain activate() from an app the runner started in the
		// background may be declined, so the fixture insists, as a user's click would.
		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
		try await waitFor(.notActive) { NSApp.isActive && window.isKeyWindow && window.isOnActiveSpace }
	}

	/// The way another app opens a link: Arx gets the URL and is activated, as on a click. Only
	/// the smoke's own instance may get it, never another Arx with the person's profile.
	private func open(
		_ url: URL,
		in arx: URL,
		pid: pid_t
	) async throws {
		let instances = NSWorkspace.shared.runningApplications.filter {
			$0.bundleURL?.resolvingSymlinksInPath() == arx.resolvingSymlinksInPath()
		}
		guard instances.map(\.processIdentifier) == [pid] else { throw Failure.foreignInstance }

		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates = true
		configuration.addsToRecentItems = false
		configuration.promptsUserIfNeeded = false
		configuration.allowsRunningApplicationSubstitution = false
		let opened = try await NSWorkspace.shared.open([url], withApplicationAt: arx, configuration: configuration)
		guard opened.processIdentifier == pid else { throw Failure.foreignInstance }
	}

	private struct ArxWindow {
		let layer: Int
		let bounds: CGRect

		/// Little Arx panels float; Arx's browser windows don't.
		var isFloating: Bool { layer == Int(CGWindowLevelForKey(.floatingWindow)) }
		var isMain: Bool { layer == 0 && bounds.width >= 400 && bounds.height >= 300 }
	}

	/// Arx's windows on the active Space: on-screen windows are those of the Spaces shown now.
	private func windows(of pid: pid_t) -> [ArxWindow] {
		let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
		guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
		else { return [] }

		return list.compactMap { info in
			guard
				(info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
				let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
				let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
					.flatMap({ CGRect(dictionaryRepresentation: $0) })
			else { return nil }

			return .init(layer: layer, bounds: bounds)
		}
	}

	private func waitFor(
		_ failure: Failure,
		seconds: Int = 30,
		until condition: @MainActor () -> Bool
	) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(seconds))
		while !condition() {
			guard clock.now < deadline else { throw failure }
			try await Task.sleep(for: .milliseconds(100))
		}
	}
}
