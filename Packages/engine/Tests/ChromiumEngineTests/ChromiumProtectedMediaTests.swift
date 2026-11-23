import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-877: protected media requests and site cookies are exports outside the ABI table.
@Suite(.serialized)
@MainActor
internal struct ChromiumProtectedMediaTests {
	@Test
	internal func olderEnginesReportNothingAndReadNoCookies() async throws {
		let fixture = ProtectedMediaFixture(exports: false)
		defer { fixture.runtime.finish() }

		#expect(!fixture.runtime.supportsProtectedMediaRequests)
		#expect(!fixture.runtime.supportsSiteCookies)
		fixture.runtime.observeProtectedMedia { _, _, _ in Issue.record("no handler") }
		let cookies = await fixture.runtime.siteCookies(
			for: URL(string: "https://www.netflix.com")!,
			page: nil,
			profile: nil
		)
		#expect(cookies == nil)
	}

	@Test
	internal func requestsReachTheHandlerForOwnedPagesOnly() async throws {
		let fixture = ProtectedMediaFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		var heard: [(UInt64, URL, ChromiumProtectedMediaReason)] = []
		fixture.runtime.observeProtectedMedia { page, url, reason in heard.append((page.identifier, url, reason)) }
		let handler = try #require(ProtectedMediaFixture.handler)
		"https://www.netflix.com/watch/1".withCString { handler(ProtectedMediaFixture.context, page.identifier, $0) }
		"https://other.example".withCString { handler(ProtectedMediaFixture.context, 99, $0) }

		#expect(heard.map(\.0) == [page.identifier])
		#expect(heard.map(\.1) == [URL(string: "https://www.netflix.com/watch/1")!])
		// An engine without the reason handler (before DEV-1211) reports every page as a failure.
		#expect(heard.map(\.2) == [.playbackFailed])

		fixture.runtime.observeProtectedMedia(nil)
		#expect(ProtectedMediaFixture.handler == nil)
	}

	/// DEV-1211: an engine with the reason handler says why each page is reported, and the old
	/// handler is never set.
	@Test
	internal func theReasonHandlerWinsAndPassesEachReason() async throws {
		let fixture = ProtectedMediaFixture(exports: true, reasons: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()
		#expect(fixture.runtime.supportsProtectedMediaRequests)

		var heard: [ChromiumProtectedMediaReason] = []
		fixture.runtime.observeProtectedMedia { _, _, reason in heard.append(reason) }
		#expect(ProtectedMediaFixture.handler == nil)
		let handler = try #require(ProtectedMediaFixture.reasonHandler)
		for code: Int32 in [0, 1, 7] {
			"https://resend.com/".withCString { handler(ProtectedMediaFixture.context, page.identifier, $0, code) }
		}
		#expect(heard == [.playbackFailed, .keysWithoutMedia, .playbackFailed])

		fixture.runtime.observeProtectedMedia(nil)
		#expect(ProtectedMediaFixture.reasonHandler == nil)
	}

	@Test
	internal func cookiesDecodeAndPassThePageAndProfile() async throws {
		let fixture = ProtectedMediaFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		ProtectedMediaFixture.json = """
		[{"name":"NetflixId","value":"v","domain":".netflix.com","path":"/","expires":1900000000,\
		"secure":true,"httpOnly":true,"sameSite":"lax"},
		{"name":"session","value":"s","domain":"www.netflix.com","path":"/","expires":null,\
		"secure":false,"httpOnly":false,"sameSite":"unspecified"},
		{"broken":true}]
		"""
		let cookies = try #require(
			await fixture.runtime.siteCookies(
				for: URL(string: "https://www.netflix.com/browse")!,
				page: page,
				profile: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")
			)
		)
		#expect(cookies.map(\.name) == ["NetflixId", "session"])
		#expect(cookies.first?.expires == 1_900_000_000)
		#expect(cookies.last?.expires == nil)
		#expect(ProtectedMediaFixture.copies.map(\.page) == [page.identifier])
		#expect(ProtectedMediaFixture.copies.map(\.key) == ["6f9619ff-8b86-d011-b42d-00c04fc964ff"])
		#expect(ProtectedMediaFixture.copies.map(\.url) == ["https://www.netflix.com/browse"])

		ProtectedMediaFixture.refuses = true
		let refused = await fixture.runtime.siteCookies(
			for: URL(string: "https://www.netflix.com")!,
			page: nil,
			profile: nil
		)
		#expect(refused == nil)
		#expect(ProtectedMediaFixture.copies.last?.page == 0)
		#expect(ProtectedMediaFixture.copies.last?.key == "")
	}
}

@MainActor
private final class ProtectedMediaFixture {
	fileprivate static var view: NSView = .init()
	fileprivate static var handler: ChromiumProtectedMediaHandler?
	fileprivate static var reasonHandler: ChromiumProtectedMediaReasonHandler?
	fileprivate static var context: UnsafeMutableRawPointer?
	fileprivate static var json: String = "[]"
	fileprivate static var refuses: Bool = false
	fileprivate static var copies: [(key: String, page: UInt64, url: String)] = []
	fileprivate let runtime: ChromiumRuntime

	fileprivate init(
		exports: Bool,
		reasons: Bool = false
	) {
		Self.handler = nil
		Self.reasonHandler = nil
		Self.context = nil
		Self.json = "[]"
		Self.refuses = false
		Self.copies = []
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { ProtectedMediaFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		self.runtime = .init(api: api)
		if exports {
			runtime.optionalExports.setProtectedMediaHandler = { handler, context in
				MainActor.assumeIsolated {
					ProtectedMediaFixture.handler = handler
					ProtectedMediaFixture.context = context
				}
			}
			if reasons {
				runtime.optionalExports.setProtectedMediaReasonHandler = { handler, context in
					MainActor.assumeIsolated {
						ProtectedMediaFixture.reasonHandler = handler
						ProtectedMediaFixture.context = context
					}
				}
			}
			runtime.optionalExports.copySiteCookies = { key, page, url, done, context in
				MainActor.assumeIsolated {
					ProtectedMediaFixture.copies.append((
						key.map { String(cString: $0) } ?? "",
						page,
						url.map { String(cString: $0) } ?? ""
					))
					guard !ProtectedMediaFixture.refuses else { return false }
					ProtectedMediaFixture.json.withCString { done?(context, $0, strlen($0)) }
					return true
				}
			}
		}
		runtime.didBecomeReady()
	}
}
