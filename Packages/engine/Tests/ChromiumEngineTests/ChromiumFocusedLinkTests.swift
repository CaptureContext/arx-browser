import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// ABI37 focused links (DEV-713): one answer per request, validated before Swift sees it.
@MainActor
@Suite(.serialized)
internal struct ChromiumFocusedLinkTests {
	fileprivate static var asked: [(page: UInt64, request: UInt64)] = []

	private func links() -> ChromiumFocusedLinks {
		Self.asked = []
		var api = ArxEngineAPI()
		api.focused_link = { page, request in
			MainActor.assumeIsolated { ChromiumFocusedLinkTests.asked.append((page, request)) }
		}
		return .init(api: api)
	}

	private func reply(
		_ links: ChromiumFocusedLinks,
		page: UInt64? = nil,
		revision: UInt64 = 7,
		url: String?
	) async {
		while Self.asked.isEmpty { await Task.yield() }
		let request = Self.asked.removeFirst()
		guard let url else {
			links.complete(request.request, page: page ?? request.page, documentRevision: revision, url: nil, count: 0)
			return
		}
		url.withCString { pointer in
			links.complete(
				request.request,
				page: page ?? request.page,
				documentRevision: revision,
				url: pointer,
				count: url.utf8.count
			)
		}
	}

	@Test
	internal func aFocusedHTTPLinkComesBackWithItsRevision() async {
		let links = links()
		async let link = links.read(page: 4)
		await reply(links, url: "https://example.com/next?a=1#b")
		#expect(await link == .init(documentRevision: 7, url: URL(string: "https://example.com/next?a=1#b")!))
	}

	@Test
	internal func noLinkOtherSchemesCredentialsAndOtherPagesAreNil() async {
		let links = links()
		for (url, page, revision) in [
			(nil, nil, 7),
			("javascript:void(0)", nil, 7),
			("mailto:someone@example.com", nil, 7),
			("https://user:secret@example.com/", nil, 7),
			("https://example.com/", UInt64(5), 7),
			("https://example.com/", nil, 0),
		] as [(String?, UInt64?, UInt64)] {
			async let link = links.read(page: 4)
			await reply(links, page: page, revision: revision, url: url)
			#expect(await link == nil, "\(String(describing: url))")
		}
	}

	@Test
	internal func stoppingAnswersPendingReadsAndLateRepliesAreDropped() async {
		let links = links()
		async let link = links.read(page: 4)
		while Self.asked.isEmpty { await Task.yield() }
		let request = Self.asked[0]
		links.stop()
		#expect(await link == nil)
		"https://example.com/".withCString {
			links.complete(request.request, page: 4, documentRevision: 7, url: $0, count: 20)
		}
	}

	@Test
	internal func withoutTheCallTheEngineAnswersNothing() async {
		let links = ChromiumFocusedLinks(api: ArxEngineAPI())
		#expect(!links.isAvailable)
		#expect(await links.read(page: 4) == nil)
	}
}
