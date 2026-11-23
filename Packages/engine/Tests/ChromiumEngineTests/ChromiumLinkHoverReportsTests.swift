import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-1111: the app's window asks for hovered-link reports before the engine runs, so the
/// runtime applies the request once the engine is ready instead of dropping it.
@Suite(.serialized)
@MainActor
internal struct ChromiumLinkHoverReportsTests {
	@Test
	internal func aRequestBeforeTheEngineRunsAppliesWhenItIsReady() async throws {
		LinkHoverReportsFixture.calls = []
		let runtime = LinkHoverReportsFixture.runtime()
		defer { runtime.finish() }

		runtime.setLinkHoverReports(true)
		#expect(LinkHoverReportsFixture.calls.isEmpty)

		runtime.didBecomeReady()
		#expect(LinkHoverReportsFixture.calls == [true])

		runtime.setLinkHoverReports(false)
		#expect(LinkHoverReportsFixture.calls == [true, false])
	}

	@Test
	internal func reportsStayOffWhenNobodyAsked() async throws {
		LinkHoverReportsFixture.calls = []
		let runtime = LinkHoverReportsFixture.runtime()
		defer { runtime.finish() }

		runtime.didBecomeReady()
		#expect(LinkHoverReportsFixture.calls.isEmpty)
	}

	@Test
	internal func aRequestTurnedOffBeforeTheEngineRunsStaysOff() async throws {
		LinkHoverReportsFixture.calls = []
		let runtime = LinkHoverReportsFixture.runtime()
		defer { runtime.finish() }

		runtime.setLinkHoverReports(true)
		runtime.setLinkHoverReports(false)
		runtime.didBecomeReady()
		#expect(LinkHoverReportsFixture.calls.isEmpty)
	}
}

@MainActor
private enum LinkHoverReportsFixture {
	fileprivate static var calls: [Bool] = []

	fileprivate static func runtime() -> ChromiumRuntime {
		var api = ArxEngineAPI()
		api.set_link_hover_reports = { enabled in
			MainActor.assumeIsolated { LinkHoverReportsFixture.calls.append(enabled) }
		}
		return .init(api: api)
	}
}
