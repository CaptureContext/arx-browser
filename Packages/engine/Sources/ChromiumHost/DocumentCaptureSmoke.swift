import AppKit
import ChromiumEngine

/// The host guard and native run option each require freshly owned storage.
/// The native controller owns fixed loopback routes and actual pixel assertions.
@MainActor
internal final class DocumentCaptureSmoke {
	internal static let argument: String = "--document-capture-fixture"
	private let runtime: ChromiumRuntime
	private let url: URL
	private var window: NSWindow?
	private var page: ChromiumPage?
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
		Task { [self] in
			do {
				let page = try runtime.makePage()
				self.page = page
				let window = NSWindow(
					contentRect: .init(x: 0, y: 0, width: 900, height: 400),
					styleMask: [.titled],
					backing: .buffered,
					defer: false
				)
				self.window = window
				window.contentView = page.view
				window.makeKeyAndOrderFront(nil)
				NSApplication.shared.activate(ignoringOtherApps: true)
				let origin = url.deletingLastPathComponent()
				verified = try await runtime.runDocumentCaptureFixture(on: page, origin: origin)
			} catch {
				fputs("ARX_DOCUMENT_CAPTURE_SMOKE_HOST_FAILED\n", stderr)
			}
			page?.close()
			window?.orderOut(nil)
			runtime.requestQuit()
		}
	}
}
