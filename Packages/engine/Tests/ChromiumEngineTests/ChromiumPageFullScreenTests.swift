import AppKit
import ChromiumBridge
import Testing

@testable import ChromiumEngine

/// ABI54 (DEV-949): page full screen reports and the app's way out.
@MainActor
@Suite(.serialized)
internal struct ChromiumPageFullScreenTests {
	@Test
	internal func reportsReachTheirPageWhateverItsGeneration() async throws {
		let fixture = FullScreenFixture()
		let page = try fixture.runtime.makePage()
		let reports = FullScreenReports()
		fixture.runtime.onPageFullScreen = { page, isFullScreen in
			reports.values.append((page.identifier, isFullScreen))
		}

		fixture.runtime.receivePageFullScreen(page: page.identifier, isFullScreen: true)

		// Same-document navigations move the generation on but keep full screen.
		FullScreenFixture.generation += 1
		fixture.runtime.receivePageFullScreen(page: page.identifier, isFullScreen: false)

		// A page the app no longer has reports nothing.
		fixture.runtime.receivePageFullScreen(page: 404, isFullScreen: true)

		#expect(reports.values.map(\.0) == [page.identifier, page.identifier])
		#expect(reports.values.map(\.1) == [true, false])
	}

	@Test
	internal func exitReachesOnlyItsOwnPage() async throws {
		let fixture = FullScreenFixture()
		let page = try fixture.runtime.makePage()

		#expect(fixture.runtime.supportsPageFullScreen)
		#expect(fixture.runtime.exitFullScreen(page))
		#expect(FullScreenFixture.exits == [page.identifier])
	}

	@Test
	internal func olderEnginesHaveNoPageFullScreen() async throws {
		let fixture = FullScreenFixture(supportsFullScreen: false)
		let page = try fixture.runtime.makePage()

		#expect(!fixture.runtime.supportsPageFullScreen)
		#expect(!fixture.runtime.exitFullScreen(page))
		#expect(FullScreenFixture.exits.isEmpty)
	}
}

@MainActor
private final class FullScreenReports {
	fileprivate var values: [(UInt64, Bool)] = []
}

@MainActor
private final class FullScreenFixture {
	fileprivate static var generation: UInt64 = 1
	fileprivate static var nextPage: UInt64 = 1
	fileprivate static var exits: [UInt64] = []
	fileprivate static let view: NSView = .init()
	fileprivate let runtime: ChromiumRuntime

	fileprivate init(supportsFullScreen: Bool = true) {
		Self.generation = 1
		Self.nextPage = 1
		Self.exits = []
		var api = ArxEngineAPI()
		api.create_page = { _, _ in
			MainActor.assumeIsolated {
				defer { FullScreenFixture.nextPage += 1 }
				return FullScreenFixture.nextPage
			}
		}
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { FullScreenFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.history_count = { _ in 0 }
		api.page_close_generation = { _ in MainActor.assumeIsolated { FullScreenFixture.generation } }
		if supportsFullScreen {
			api.exit_page_fullscreen = { page in
				MainActor.assumeIsolated { FullScreenFixture.exits.append(page) }
				return true
			}
		}
		runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
	}
}
