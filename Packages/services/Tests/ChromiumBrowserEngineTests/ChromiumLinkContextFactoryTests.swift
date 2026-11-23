import AppKit
import BrowserCore
import ChromiumBridge
import CustomDump
import Foundation
import Testing
import _TestSupport

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.serialized)
@MainActor
internal struct ChromiumLinkContextFactoryTests {
	@Test(arguments: [true, false])
	internal func callbackMapsOnlyTheOriginalNativePageAndProfile(isPrivate: Bool) async throws {
		let fixture = NativeLinkFixture()
		let profile = Profile.ID(rawValue: UUID(4))
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(3)),
			profileID: profile,
			restoration: .init(title: "Page", url: URL(string: "https://page.example/")!)
		)
		fixture.runtime.didBecomeReady()
		defer { fixture.runtime.finish() }
		if isPrivate { try fixture.runtime.preparePrivateProfile(profile.rawValue) }
		try await fixture.engine.client.open(tab)
		let events = fixture.engine.client.linkContexts()
		var iterator = events.makeAsyncIterator()
		expectNoDifference(fixture.emit(page: 999), false)
		expectNoDifference(fixture.emit(page: 1), true)
		let context = try #require(await iterator.next())
		expectNoDifference(context.tabID, tab.id)
		expectNoDifference(context.profileID, profile)
		expectNoDifference(context.documentRevision, 7)
		expectNoDifference(context.isPrivate, isPrivate)
		expectNoDifference(context.item.url.absoluteString, "https://x.com/linked-post?a=1&a=2#fragment")
		fixture.engine.closeAll()
		expectNoDifference(fixture.engine.client.linkContextIsCurrent(context), false)
		fixture.engine.client.dismissLinkContext(context)
		expectNoDifference(NativeLinkFixture.dismissed, [1])
	}

	@Test
	internal func aRetainedClientBeforeReadinessCannotInventNativeContexts() async throws {
		let fixture = NativeLinkFixture()
		let client = fixture.engine.client
		let early = client.linkContexts()
		var iterator = early.makeAsyncIterator()
		let end = await iterator.next()
		expectNoDifference(end, nil)
		expectNoDifference(fixture.emit(page: 1), false)
	}
}

@MainActor
private final class NativeLinkFixture {
	fileprivate static var view: NSView = .init(frame: .init(x: 0, y: 0, width: 400, height: 300))
	fileprivate static var dismissed: [UInt64] = []
	private static weak var runtimeOwner: ChromiumRuntime?
	fileprivate let runtime: ChromiumRuntime
	fileprivate let engine: ChromiumBrowserEngine

	fileprivate init() {
		Self.dismissed = []
		var api = ArxEngineAPI()
		api.page_view = { _ in Unmanaged.passUnretained(MainActor.assumeIsolated { NativeLinkFixture.view }).toOpaque() }
		api.prepare_profile = { _, request in
			MainActor.assumeIsolated { NativeLinkFixture.runtimeOwner?.complete(request, true) }
		}
		api.prepare_private_profile = { _ in true }
		api.create_page = { _, _ in 1 }
		api.destroy_page = { _ in }
		api.navigate = { _, _ in true }
		api.page_close_generation = { _ in 7 }
		api.link_context_is_current = { _, _ in true }
		api.dismiss_link_context = { _, token in MainActor.assumeIsolated { NativeLinkFixture.dismissed.append(token) } }
		self.runtime = .init(api: api)
		self.engine = .init(runtime: runtime, profileID: .init(rawValue: UUID(0)))
		Self.runtimeOwner = runtime
	}

	fileprivate func emit(page: UInt64) -> Bool {
		let urlBytes = Array("https://x.com/linked-post?a=1&a=2#fragment".utf8)
		let textBytes = Array("Clicked link".utf8)
		return urlBytes.withUnsafeBufferPointer { url in
			textBytes.withUnsafeBufferPointer { text in
				let native = ArxLinkContext(
					token: 1,
					document_generation: 7,
					url: url.baseAddress,
					text: text.baseAddress,
					url_size: url.count,
					text_size: text.count,
					x: 4,
					y: 5
				)
				return runtime.receiveLinkContext(page: page, native: native)
			}
		}
	}
}
