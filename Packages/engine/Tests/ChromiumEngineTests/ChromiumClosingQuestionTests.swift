import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-1188: a page answers one beforeunload question at a time, and Chromium refuses another
/// while it does. A second caller hears the first one's answer instead of a refusal.
@MainActor
@Suite(.serialized)
internal struct ChromiumClosingQuestionTests {
	@Test(arguments: [true, false])
	internal func aQuestionAskedWhileThePageAnswersHearsTheSameAnswer(answer: Bool) async throws {
		let fixture = ClosingFixture()
		let page = try fixture.runtime.makePage()

		async let first = fixture.runtime.permitsClosing(page)
		async let second = fixture.runtime.permitsClosing(page)
		try await ClosingFixture.waitForRequests(1)
		try await Task.sleep(for: .milliseconds(20))
		#expect(ClosingFixture.requests.count == 1)

		fixture.runtime.complete(try #require(ClosingFixture.requests.first), answer)
		#expect(await first == answer)
		#expect(await second == answer)

		// Answered, the next question asks the page again.
		async let third = fixture.runtime.permitsClosing(page)
		try await ClosingFixture.waitForRequests(2)
		fixture.runtime.complete(ClosingFixture.requests[1], true)
		#expect(await third)
	}

	@Test
	internal func aClosedPageAnswersEveryWaitingQuestion() async throws {
		let fixture = ClosingFixture()
		let page = try fixture.runtime.makePage()

		async let first = fixture.runtime.permitsClosing(page)
		async let second = fixture.runtime.permitsClosing(page)
		try await ClosingFixture.waitForRequests(1)
		try await Task.sleep(for: .milliseconds(20))
		fixture.runtime.close(page, destroyNative: false)

		#expect(await first == false)
		#expect(await second == false)
	}
}

@MainActor
private final class ClosingFixture {
	fileprivate static var nextPage: UInt64 = 1
	fileprivate static var requests: [UInt64] = []
	fileprivate static let view: NSView = .init()
	fileprivate let runtime: ChromiumRuntime

	fileprivate init() {
		Self.nextPage = 1
		Self.requests = []
		var api = ArxEngineAPI()
		api.create_page = { _, _ in
			MainActor.assumeIsolated {
				defer { ClosingFixture.nextPage += 1 }
				return ClosingFixture.nextPage
			}
		}
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { ClosingFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.history_count = { _ in 0 }
		api.request_close = { _, request in
			MainActor.assumeIsolated { ClosingFixture.requests.append(request) }
		}
		runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
	}

	fileprivate static func waitForRequests(_ count: Int) async throws {
		for _ in 0 ..< 200 where requests.count < count {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(requests.count >= count)
	}
}
