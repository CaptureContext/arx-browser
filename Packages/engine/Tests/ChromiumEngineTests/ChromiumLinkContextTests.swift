import AppKit
import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized)
@MainActor
internal struct ChromiumLinkContextTests {
	@Test(arguments: [
		"unsupported",
		"stale",
		"zeroToken",
		"generation",
		"urlBudget",
		"textBudget",
		"unparsable",
		"coordinate",
		"outside",
		"utf8",
	])
	internal func invalidOrUnownedCallbacksNeverReachTheMenu(change: String) async throws {
		let fixture = LinkContextFixture()
		let events = fixture.bridge.events()
		defer {
			fixture.bridge.stop()
			_ = events
		}
		expectNoDifference(fixture.emit(change: change), false)
	}

	/// DEV-853: as in Chromium, every link reaches the menu; its items decide what it offers.
	@Test(arguments: [
		("port", "http://localhost:3000/app"),
		("securePort", "https://x.com:8443/post"),
		("credentials", "https://user:secret@x.com/post"),
		("mailto", "mailto:hello@capturecontext.dev"),
		("tel", "tel:+15555550100"),
		("urlLimit", "https://x.com/"),
	])
	internal func everyValidLinkReachesTheMenuWhateverItsSchemePortOrCredentials(
		change: String,
		expected: String
	) async throws {
		let fixture = LinkContextFixture()
		let events = fixture.bridge.events()
		var iterator = events.makeAsyncIterator()
		expectNoDifference(fixture.emit(change: change), true)
		let context = try #require(await iterator.next())
		if change == "urlLimit" {
			expectNoDifference(context.url.absoluteString.utf8.count, ChromiumLinkContext.maximumURLBytes)
			#expect(context.url.absoluteString.hasPrefix(expected))
		} else {
			expectNoDifference(context.url.absoluteString, expected)
		}
		fixture.bridge.stop()
	}

	@Test
	internal func exactPayloadAuthorityAndBorrowedBytesSurviveOnlyUntilDismissal() async throws {
		let fixture = LinkContextFixture()
		let events = fixture.bridge.events()
		var iterator = events.makeAsyncIterator()
		expectNoDifference(fixture.emit(), true)
		let context = try #require(await iterator.next())
		expectNoDifference(context.url.absoluteString, "https://x.com/post?a=1&a=2#fragment")
		expectNoDifference(context.text, "Own [link] title")
		#expect(fixture.bridge.isCurrent(context))
		let forged = ChromiumLinkContext(
			pageID: context.pageID,
			token: context.token,
			documentGeneration: context.documentGeneration,
			url: URL(string: "https://other.example/")!,
			text: context.text,
			x: context.x,
			y: context.y
		)
		#expect(!fixture.bridge.isCurrent(forged))
		fixture.bridge.dismiss(page: context.pageID, token: context.token + 1)
		#expect(fixture.bridge.isCurrent(context))
		fixture.bridge.dismiss(page: context.pageID, token: context.token)
		#expect(!fixture.bridge.isCurrent(context))
		expectNoDifference(LinkContextFixture.dismissed, [1])
		fixture.bridge.stop()
		let end = await iterator.next()
		expectNoDifference(end, nil)
	}

	@Test
	internal func replacingTheObserverReleasesEveryPrivatePayloadAndOldStream() async throws {
		let fixture = LinkContextFixture()
		let first = fixture.bridge.events()
		var iterator = first.makeAsyncIterator()
		#expect(fixture.emit())
		let context = try #require(await iterator.next())
		let second = fixture.bridge.events()
		defer {
			fixture.bridge.stop()
			_ = second
		}
		let end = await iterator.next()
		expectNoDifference(end, nil)
		#expect(!fixture.bridge.isCurrent(context))
		expectNoDifference(LinkContextFixture.dismissed, [1])
	}

	@Test
	internal func noObserverDoesNotSuppressTheNativeFallback() async throws {
		let fixture = LinkContextFixture()
		expectNoDifference(fixture.emit(), false)
	}
}

@MainActor
private final class LinkContextFixture {
	fileprivate static var current: Bool = true
	fileprivate static var dismissed: [UInt64] = []
	fileprivate let bridge: ChromiumLinkContexts
	private let runtime: ChromiumRuntime
	private let page: ChromiumPage

	fileprivate init() {
		Self.current = true
		Self.dismissed = []
		var api = ArxEngineAPI()
		api.link_context_is_current = { _, _ in MainActor.assumeIsolated { LinkContextFixture.current } }
		api.dismiss_link_context = { _, token in MainActor.assumeIsolated { LinkContextFixture.dismissed.append(token) } }
		self.runtime = ChromiumRuntime(api: api)
		self.bridge = ChromiumLinkContexts(api: api)
		self.page = ChromiumPage(id: 10, view: NSView(frame: .init(x: 0, y: 0, width: 400, height: 300)), runtime: runtime, isPrivate: true)
	}

	fileprivate func emit(change: String? = nil) -> Bool {
		if change == "unsupported" { return ChromiumLinkContexts(api: .init()).receive(page: page, native: .init(), generation: 7) }
		if change == "stale" { Self.current = false }
		let url: String = switch change {
		case "port": "http://localhost:3000/app"
		case "securePort": "https://x.com:8443/post"
		case "credentials": "https://user:secret@x.com/post"
		case "mailto": "mailto:hello@capturecontext.dev"
		case "tel": "tel:+15555550100"
		case "unparsable": "no scheme here"
		case "urlLimit", "urlBudget":
			"https://x.com/" + String(repeating: "a", count: ChromiumLinkContext.maximumURLBytes - 14)
		default: "https://x.com/post?a=1&a=2#fragment"
		}
		let urlBytes = change == "utf8" ? [UInt8(255)] : Array(url.utf8)
		let textBytes = Array("Own [link] title".utf8)
		return urlBytes.withUnsafeBufferPointer { url in
			textBytes.withUnsafeBufferPointer { text in
				let native = ArxLinkContext(
					token: change == "zeroToken" ? 0 : 1,
					document_generation: change == "generation" ? 8 : 7,
					url: url.baseAddress,
					text: text.baseAddress,
					url_size: change == "urlBudget" ? ChromiumLinkContext.maximumURLBytes + 1 : url.count,
					text_size: change == "textBudget" ? 4097 : text.count,
					x: change == "coordinate" ? .infinity : change == "outside" ? 400 : 4,
					y: 5
				)
				return bridge.receive(page: page, native: native, generation: 7)
			}
		}
	}
}
