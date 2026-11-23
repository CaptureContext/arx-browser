import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-1084: the all-frames check for typed input is an optional export outside the ABI table.
@Suite(.serialized)
@MainActor
internal struct ChromiumFormEditsTests {
	@Test
	internal func olderEnginesCantTell() async throws {
		let fixture = FormEditsFixture(answer: nil)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		#expect(!fixture.runtime.supportsFormEdits)
		#expect(await fixture.runtime.formEdits(on: page) == nil)
	}

	@Test
	internal func eachAnswerReachesTheApp() async throws {
		for (result, expected) in [(Int32(0), ChromiumFormEdits.clean), (1, .typed), (-1, .unknown), (7, .unknown)] {
			let fixture = FormEditsFixture(answer: result)
			defer { fixture.runtime.finish() }
			let page = try fixture.runtime.makePage()

			#expect(fixture.runtime.supportsFormEdits)
			#expect(await fixture.runtime.formEdits(on: page) == expected)
			#expect(FormEditsFixture.pages == [page.id])
		}
	}

	@Test
	internal func requestsAreNumberedApart() async throws {
		let fixture = FormEditsFixture(answer: 0)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		_ = await fixture.runtime.formEdits(on: page)
		_ = await fixture.runtime.formEdits(on: page)
		#expect(FormEditsFixture.requests.count == 2)
		#expect(Set(FormEditsFixture.requests).count == 2)
	}

	@Test
	internal func nothingBeforeTheEngineRunsOrForAClosedOrUnknownPage() async throws {
		let waiting = FormEditsFixture(answer: 1, running: false)
		#expect(!waiting.runtime.supportsFormEdits)

		let fixture = FormEditsFixture(answer: 1)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()
		page.close()
		#expect(await fixture.runtime.formEdits(on: page) == nil)

		// The engine doesn't know the page: no reply, and no answer.
		let refusing = FormEditsFixture(answer: 1, accepts: false)
		defer { refusing.runtime.finish() }
		let unknown = try refusing.runtime.makePage()
		#expect(await refusing.runtime.formEdits(on: unknown) == nil)
		#expect(FormEditsFixture.pages == [unknown.id])
	}
}

@MainActor
private final class FormEditsFixture {
	private static var view: NSView = .init()
	fileprivate static var pages: [UInt64] = []
	fileprivate static var requests: [UInt64] = []
	private static var answer: Int32 = 0
	private static var accepts: Bool = true
	fileprivate let runtime: ChromiumRuntime

	/// `answer` nil leaves the export out; otherwise the engine replies with it, after the call
	/// returns, as native does.
	fileprivate init(
		answer: Int32?,
		running: Bool = true,
		accepts: Bool = true
	) {
		Self.pages = []
		Self.requests = []
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { FormEditsFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		self.runtime = .init(api: api)
		Self.answer = answer ?? 0
		Self.accepts = accepts
		if answer != nil {
			runtime.optionalExports.formEdits = { page, request, reply, context in
				let (answer, accepts) = MainActor.assumeIsolated {
					FormEditsFixture.pages.append(page)
					FormEditsFixture.requests.append(request)
					return (FormEditsFixture.answer, FormEditsFixture.accepts)
				}
				guard accepts else { return false }

				let address = context.map { UInt(bitPattern: $0) }
				DispatchQueue.main.async {
					reply?(address.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }, request, page, answer)
				}
				return true
			}
		}
		if running { runtime.didBecomeReady() }
	}
}
