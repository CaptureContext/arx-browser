import AppKit
import ChromiumBridge
import Testing

@testable import ChromiumEngine

@Suite(.serialized)
@MainActor
internal struct ChromiumDeveloperToolsTests {
	fileprivate static let view: NSView = .init(frame: .init(x: 0, y: 0, width: 20, height: 10))
	fileprivate static var opened: [UInt64] = []
	fileprivate static var configured: [Bool] = []
	fileprivate static var bypassed: [UInt64] = []
	fileprivate static var available: Bool = true

	private func makeRuntime(available: Bool = true) -> ChromiumRuntime {
		Self.opened = []
		Self.configured = []
		Self.bypassed = []
		Self.available = available
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 7 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { ChromiumDeveloperToolsTests.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		api.devtools_available = { MainActor.assumeIsolated { ChromiumDeveloperToolsTests.available } }
		api.configure_devtools = { _, _, enabled in
			MainActor.assumeIsolated { ChromiumDeveloperToolsTests.configured.append(enabled) }
		}
		api.open_devtools = { page in
			MainActor.assumeIsolated { ChromiumDeveloperToolsTests.opened.append(page) }
			return ARX_DEVTOOLS_OPENED
		}
		api.devtools_is_open = { page in MainActor.assumeIsolated { ChromiumDeveloperToolsTests.opened.contains(page) } }
		api.close_devtools = { _ in true }
		api.reload_bypassing_cache = { page in
			MainActor.assumeIsolated { ChromiumDeveloperToolsTests.bypassed.append(page) }
		}
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		return runtime
	}

	@Test
	internal func opensInspectorForItsExactPage() throws {
		let runtime = makeRuntime()
		let page = try runtime.makePage()

		#expect(runtime.supportsDeveloperTools)
		#expect(runtime.openDeveloperTools(for: page) == .opened)
		#expect(Self.opened == [7])
		#expect(runtime.developerToolsAreOpen(for: page))
	}

	@Test
	internal func closedPageNeverReachesNativeInspector() throws {
		let runtime = makeRuntime()
		let page = try runtime.makePage()
		page.close()

		#expect(runtime.openDeveloperTools(for: page) == .invalid)
		#expect(Self.opened.isEmpty)
		#expect(!runtime.developerToolsAreOpen(for: page))
	}

	@Test
	internal func unavailableEngineReportsUnavailable() throws {
		let runtime = makeRuntime(available: false)
		let page = try runtime.makePage()

		#expect(!runtime.supportsDeveloperTools)
		#expect(runtime.openDeveloperTools(for: page) == .unavailable)
		#expect(Self.opened.isEmpty)
	}

	@Test
	internal func configurationAndBypassReloadReachNativeOnlyWhileRunning() throws {
		let runtime = makeRuntime()
		let page = try runtime.makePage()
		runtime.configureDeveloperTools(windowTitle: "Developer Tools", inspectTitle: "Inspect Element", inspectsContext: true)
		try page.reloadBypassingCache()
		#expect(Self.configured == [true])
		#expect(Self.bypassed == [7])

		runtime.finish()
		runtime.configureDeveloperTools(windowTitle: "Developer Tools", inspectTitle: "Inspect Element", inspectsContext: false)
		#expect(Self.configured == [true])
		#expect(throws: ChromiumError.self) { try page.reloadBypassingCache() }
	}

	@Test
	internal func aDockedPageGoesWhereTheFrontendSays() async throws {
		let layout = ChromiumDeveloperToolsLayout(
			dock: .right,
			view: NSView(),
			pageBounds: .init(x: 0, y: 0, width: 600, height: 400)
		)
		let bounds = CGRect(x: 0, y: 0, width: 1000, height: 400)
		#expect(layout.pageFrame(in: bounds, isFlipped: true) == .init(x: 0, y: 0, width: 600, height: 400))

		let bottom = ChromiumDeveloperToolsLayout(
			dock: .bottom,
			view: NSView(),
			pageBounds: .init(x: 0, y: 0, width: 1000, height: 250)
		)

		// Unflipped hosts count from the bottom: the page stays on top.
		#expect(bottom.pageFrame(in: bounds, isFlipped: false) == .init(x: 0, y: 150, width: 1000, height: 250))

		let left = ChromiumDeveloperToolsLayout(
			dock: .left,
			view: NSView(),
			pageBounds: .init(x: 300, y: 0, width: 700, height: 400)
		)
		#expect(left.pageFrame(in: bounds, isFlipped: false) == .init(x: 300, y: 0, width: 700, height: 400))
	}

	@Test
	internal func aPageFillsItsHostUntilTheFrontendLaysOutOrWhenUndocked() async throws {
		let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
		let pending = ChromiumDeveloperToolsLayout(dock: .pending, view: NSView(), pageBounds: .zero)
		#expect(pending.pageFrame(in: bounds, isFlipped: true) == bounds)
		let undocked = ChromiumDeveloperToolsLayout(
			dock: .undocked,
			view: nil,
			pageBounds: .init(x: 0, y: 0, width: 400, height: 600)
		)
		#expect(undocked.pageFrame(in: bounds, isFlipped: true) == bounds)
		// A frontend that asks for more than the host has is clamped to it.
		let oversized = ChromiumDeveloperToolsLayout(
			dock: .right,
			view: NSView(),
			pageBounds: .init(x: 0, y: 0, width: 2000, height: 900)
		)
		#expect(oversized.pageFrame(in: bounds, isFlipped: true) == bounds)
	}

	@Test
	internal func theNativeLayoutMapsEveryDockSide() async throws {
		var native = ArxDevToolsLayout()
		native.dock = ARX_DEVTOOLS_DOCK_BOTTOM
		native.width = 10
		native.height = 20
		#expect(ChromiumDeveloperToolsLayout(native) == .init(
			dock: .bottom,
			view: nil,
			pageBounds: .init(x: 0, y: 0, width: 10, height: 20)
		))
		native.dock = ARX_DEVTOOLS_UNDOCKED
		#expect(ChromiumDeveloperToolsLayout(native).dock == .undocked)
		native.dock = ARX_DEVTOOLS_DOCK_LEFT
		#expect(ChromiumDeveloperToolsLayout(native).dock == .left)
		native.dock = ARX_DEVTOOLS_DOCK_PENDING
		#expect(ChromiumDeveloperToolsLayout(native).dock == .pending)
	}
}
