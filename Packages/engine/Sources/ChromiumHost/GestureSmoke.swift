import AppKit
import ChromiumEngine

/// Uses only the host's validated fresh storage and exact owned native window.
/// Native renderer ACK/CSS and navigation are real; trackpad points are injected.
@MainActor
internal final class GestureSmoke {
	internal static let argument: String = "--gesture-fixture"
	private let runtime: ChromiumRuntime
	private let url: URL
	private var page: ChromiumPage?
	private var window: NSWindow?
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) {
		self.runtime = runtime
		self.url = url
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)

		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_GESTURE_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_GESTURE_SMOKE_FAILED")
			}

			page?.close()
			window?.orderOut(nil)
			window?.close()
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		let page = try runtime.makePage()
		self.page = page
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 800, height: 600),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		let container = NSView(frame: .init(x: 0, y: 0, width: 800, height: 600))
		window.contentView = container
		page.view.frame = container.bounds
		page.view.autoresizingMask = [.width, .height]
		container.addSubview(page.view)
		self.window = window
		window.makeKeyAndOrderFront(nil)
		window.makeFirstResponder(page.view)
		try page.navigate(to: url)

		let deadline = ContinuousClock.now + .seconds(8)
		while page.navigation.isLoading || page.navigation.title != "Arx engine smoke" {
			guard ContinuousClock.now < deadline
			else { throw Failure.notReady }

			try await Task.sleep(for: .milliseconds(20))
		}
		try await Task.sleep(for: .milliseconds(250))

		let origin = url.deletingLastPathComponent()
		guard await runtime.runGestureFixture(on: page, loopbackOrigin: origin)
		else { throw Failure.nativeRefused }
	}

	private func diagnostic(_ message: String) {
		FileHandle.standardError.write(Data((message + "\n").utf8))
	}

	private enum Failure: Error {
		case notReady
		case nativeRefused
	}
}
