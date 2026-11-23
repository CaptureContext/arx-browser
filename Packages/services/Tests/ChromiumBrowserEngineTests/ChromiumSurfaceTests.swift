import AppKit
import BrowserCore
import ChromiumBridge
import CustomDump
import Testing

@testable import BrowserSurfaceClient
@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumSurfaceTests {
	@Test
	internal func unhandledEscapeRequiresCurrentFocusedNativeHost() async throws {
		let fixture = try Fixture()
		defer { fixture.close() }
		let window = FixtureWindow()
		defer { window.close() }
		window.fixtureVisible = true
		window.fixtureKey = true
		let original = fixture.host(in: window)
		defer { original.dismantle() }
		try await fixture.engine.client.open(fixture.tab)
		#expect(window.makeFirstResponder(Fixture.pageView))
		let work = EscapeWork()
		original.coordinator.onUnhandledEscape = { current in
			work.current = current
			return true
		}
		#expect(!fixture.runtime.receiveUnhandledEscape(page: 1, generation: 2))
		#expect(fixture.runtime.receiveUnhandledEscape(page: 1, generation: 1))
		#expect(work.current?() == true)

		Fixture.pageView.isHidden = true
		#expect(!fixture.runtime.receiveUnhandledEscape(page: 1, generation: 1))
		#expect(work.current?() == false)
		Fixture.pageView.isHidden = false
		window.fixtureKey = false
		#expect(!fixture.runtime.receiveUnhandledEscape(page: 1, generation: 1))
		window.fixtureKey = true

		let replacement = fixture.host(in: window)
		defer { replacement.dismantle() }
		#expect(work.current?() == false)
		replacement.coordinator.onUnhandledEscape = { _ in true }
		original.dismantle()
		#expect(window.makeFirstResponder(Fixture.pageView))
		#expect(fixture.runtime.receiveUnhandledEscape(page: 1, generation: 1))
	}

	@Test
	internal func captureVisibilityTracksNativeHostWithoutMakingItKey() async throws {
		let fixture = try Fixture()
		defer { fixture.close() }
		let window = FixtureWindow()
		defer { window.close() }
		window.fixtureVisible = true
		let original = fixture.host(in: window, isFocused: false)
		try await fixture.engine.client.open(fixture.tab)
		#expect(!window.isKeyWindow)
		#expect(fixture.engine.client.snapshot(fixture.tab.id)?.isVisibleForCapture == true)

		original.view.isHidden = true
		#expect(fixture.engine.client.snapshot(fixture.tab.id)?.isVisibleForCapture == false)
		original.view.isHidden = false
		window.fixtureMinimized = true
		#expect(fixture.engine.client.snapshot(fixture.tab.id)?.isVisibleForCapture == false)
		window.fixtureMinimized = false
		window.fixtureVisible = false
		#expect(fixture.engine.client.snapshot(fixture.tab.id)?.isVisibleForCapture == false)

		window.fixtureVisible = true
		let replacement = fixture.host(in: window, isFocused: false)
		original.dismantle()
		#expect(fixture.engine.client.snapshot(fixture.tab.id)?.isVisibleForCapture == true)
		replacement.dismantle()
		#expect(fixture.engine.client.snapshot(fixture.tab.id)?.isVisibleForCapture == false)
		expectNoDifference(window.focusRequests, 0)
	}

	@Test(arguments: [false, true], [false, true])
	internal func replacementKeepsPageMounted(
		oldDismantlesFirst: Bool,
		pageOpensAfterReplacement: Bool
	) async throws {
		let fixture = try Fixture()
		defer { fixture.close() }
		let window = FixtureWindow()
		defer { window.close() }
		let original = fixture.host(in: window)
		if !pageOpensAfterReplacement {
			try await fixture.engine.client.open(fixture.tab)
		}

		let replacement = fixture.host()
		#expect(Fixture.pageView.superview !== replacement.view)
		if oldDismantlesFirst {
			original.dismantle()
			window.contentView?.addSubview(replacement.view)

		} else {
			window.contentView?.addSubview(replacement.view)
			original.dismantle()
		}
		if pageOpensAfterReplacement {
			try await fixture.engine.client.open(fixture.tab)
		}

		#expect(Fixture.pageView.superview === replacement.view)
		#expect(Fixture.pageView.window === window)
		#expect(fixture.engine.isAttached(fixture.tab.id))
		expectNoDifference(Fixture.createdPages, 1)
		replacement.dismantle()
		#expect(Fixture.pageView.superview == nil)
	}

	@Test
	internal func anotherWindowCannotClaimExistingPage() async throws {
		let fixture = try Fixture()
		defer { fixture.close() }
		let originalWindow = FixtureWindow()
		let destinationWindow = FixtureWindow()
		defer {
			originalWindow.close()
			destinationWindow.close()
		}
		let original = fixture.host(in: originalWindow)
		try await fixture.engine.client.open(fixture.tab)
		let destination = fixture.host(in: destinationWindow)

		#expect(Fixture.pageView.superview === original.view)
		#expect(destination.view.subviews.isEmpty)
		#expect(originalWindow.focusRequests > 0)
		expectNoDifference(Fixture.createdPages, 1)
		destination.dismantle()
		#expect(Fixture.pageView.superview === original.view)
		original.dismantle()
	}

	@Test(arguments: [false, true])
	internal func suppressedOrDismantledHostCannotReattach(dismantled: Bool) async throws {
		let fixture = try Fixture()
		defer { fixture.close() }
		let window = FixtureWindow()
		defer { window.close() }
		let host = fixture.host(isSuppressed: !dismantled)
		if dismantled { host.dismantle() }
		window.contentView?.addSubview(host.view)
		try await fixture.engine.client.open(fixture.tab)
		await Task.yield()

		#expect(Fixture.pageView.superview == nil)
		#expect(host.view.subviews.isEmpty)
		#expect(!fixture.engine.isAttached(fixture.tab.id))
		host.dismantle()
	}

	@Test
	internal func noninteractivePageStillMounts() async throws {
		let fixture = try Fixture()
		defer { fixture.close() }
		let window = FixtureWindow()
		defer { window.close() }
		let host = fixture.host(isFocused: false)
		window.contentView?.addSubview(host.view)
		try await fixture.engine.client.open(fixture.tab)

		#expect(Fixture.pageView.superview === host.view)
		#expect(fixture.engine.isAttached(fixture.tab.id))
		host.dismantle()
	}
}

@MainActor
private struct Fixture {
	fileprivate static var pageView: NSView = FixturePageView()
	fileprivate static var createdPages: Int = 0
	fileprivate let runtime: ChromiumRuntime
	fileprivate let engine: ChromiumBrowserEngine
	fileprivate let tab: Tab

	fileprivate init() throws {
		Self.pageView = FixturePageView()
		Self.createdPages = 0
		var api = ArxEngineAPI()
		api.prepare_private_profile = { _ in true }
		api.create_page = { _, _ in
			MainActor.assumeIsolated {
				Fixture.createdPages += 1
				return UInt64(Fixture.createdPages)
			}
		}
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { Fixture.pageView }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.navigate = { _, _ in true }
		api.page_close_generation = { _ in 1 }
		api.destroy_page = { _ in }
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		let profileID = Profile.ID(rawValue: UUID())

		// Mark this mock profile ready without any filesystem or native runtime work.
		try runtime.preparePrivateProfile(profileID.rawValue)
		self.runtime = runtime
		self.engine = .init(
			runtime: runtime,
			profileID: .init(rawValue: UUID()),
			enableUnhandledEscape: true
		)
		self.tab = .init(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			restoration: .init(title: "Surface fixture", url: URL(string: "https://fixture.invalid")!)
		)
	}

	fileprivate func host(
		in window: NSWindow? = nil,
		isFocused: Bool = true,
		isSuppressed: Bool = false
	) -> Host {
		let coordinator = BrowserSurface.Coordinator(client: engine.surface)
		let view = coordinator.makeHost()
		view.frame = .init(x: 0, y: 0, width: 600, height: 400)
		window?.contentView?.addSubview(view)
		coordinator.update(
			tabID: tab.id,
			isFocused: isFocused,
			isSuppressed: isSuppressed,
			in: view
		)
		return .init(view: view, coordinator: coordinator)
	}

	fileprivate func close() {
		engine.closeAll()
		runtime.finish()
	}
}

@MainActor
private struct Host {
	fileprivate let view: NSView
	fileprivate let coordinator: BrowserSurface.Coordinator

	fileprivate init(
		view: NSView,
		coordinator: BrowserSurface.Coordinator
	) {
		self.view = view
		self.coordinator = coordinator
	}

	fileprivate func dismantle() {
		BrowserSurface.dismantleNSView(view, coordinator: coordinator)
		view.removeFromSuperview()
	}
}

@MainActor
private final class FixtureWindow: NSWindow {
	fileprivate var focusRequests: Int = 0
	fileprivate var fixtureVisible: Bool = false
	fileprivate var fixtureKey: Bool = false
	fileprivate var fixtureMinimized: Bool = false

	internal override var isVisible: Bool { fixtureVisible }
	internal override var isKeyWindow: Bool { fixtureKey }
	internal override var isMiniaturized: Bool { fixtureMinimized }

	fileprivate init() {
		super.init(
			contentRect: .init(x: 0, y: 0, width: 600, height: 400),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		isReleasedWhenClosed = false
	}

	internal override func makeKeyAndOrderFront(_ sender: Any?) {
		// Observe ownership refusal without displaying test windows.
		focusRequests += 1
	}
}

@MainActor
private final class FixturePageView: NSView {
	internal override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class EscapeWork {
	fileprivate var current: (@MainActor @Sendable () -> Bool)?
}
