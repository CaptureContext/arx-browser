import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-1020: dark pages are an optional export outside the ABI table.
@Suite(.serialized)
@MainActor
internal struct ChromiumDarkPagesTests {
	@Test
	internal func olderEnginesDoNothing() async throws {
		let fixture = DarkPagesFixture(exports: false)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		#expect(!fixture.runtime.supportsDarkPages)
		#expect(!fixture.runtime.setDefaultDarkPages(enabled: true))
		#expect(!fixture.runtime.setDarkPages(page, enabled: true, offSites: []))
	}

	@Test
	internal func theDefaultAndEachPagesSitesReachTheEngine() async throws {
		let fixture = DarkPagesFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		#expect(fixture.runtime.supportsDarkPages)
		#expect(fixture.runtime.setDefaultDarkPages(enabled: true))
		#expect(fixture.runtime.setDarkPages(page, enabled: true, offSites: ["figma.com", "[::1]"]))
		#expect(fixture.runtime.setDarkPages(page, enabled: false, offSites: []))
		#expect(DarkPagesFixture.calls == [
			.init(page: 0, enabled: true, sites: []),
			.init(page: page.id, enabled: true, sites: ["figma.com", "[::1]"]),
			.init(page: page.id, enabled: false, sites: []),
		])
	}

	@Test
	internal func nothingBeforeTheEngineRunsOrForAClosedPage() async throws {
		let waiting = DarkPagesFixture(exports: true, running: false)
		#expect(!waiting.runtime.setDefaultDarkPages(enabled: true))

		let fixture = DarkPagesFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()
		page.close()

		#expect(!fixture.runtime.setDarkPages(page, enabled: true, offSites: []))
		#expect(DarkPagesFixture.calls.isEmpty)
	}
}

@MainActor
private final class DarkPagesFixture {
	fileprivate struct Call: Equatable {
		var page: UInt64
		var enabled: Bool
		var sites: [String]
	}

	private static var view: NSView = .init()
	fileprivate static var calls: [Call] = []
	fileprivate let runtime: ChromiumRuntime

	fileprivate init(
		exports: Bool,
		running: Bool = true
	) {
		Self.calls = []
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { DarkPagesFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		self.runtime = .init(api: api)
		if exports {
			runtime.optionalExports.darkPages = { page, enabled, sites, count in
				let names: [String] = (0 ..< count).compactMap { index in
					sites?[index].map { String(cString: $0) }
				}
				MainActor.assumeIsolated {
					DarkPagesFixture.calls.append(.init(page: page, enabled: enabled, sites: names))
				}
				return true
			}
		}
		if running { runtime.didBecomeReady() }
	}
}
