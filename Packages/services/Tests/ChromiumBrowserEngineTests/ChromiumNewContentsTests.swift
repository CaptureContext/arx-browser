import AppKit
import BrowserCore
import BrowserEngineClient
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.serialized)
@MainActor
internal struct ChromiumNewContentsTests {
	@Test(arguments: [true, false], [true, false])
	internal func childOfferPreservesSourceAndNativeSessionWithoutRenavigation(
		accept: Bool,
		isPrivate: Bool
	) async throws {
		let fixture = try Fixture(isPrivate: isPrivate)
		defer { fixture.close() }
		try await fixture.engine.client.open(fixture.tab)
		let before = fixture.engine.client.snapshot(fixture.tab.id)
		var child: BrowserNewContents?
		fixture.engine.onNewContents = { offer in
			child = offer
			return accept
		}

		let result = fixture.offer()
		#expect(result == accept)
		let offer = try #require(child)
		#expect(offer.sourceTabID == fixture.tab.id)
		#expect(offer.tab.profileID == fixture.tab.profileID)
		#expect(offer.disposition == .popup)
		#expect(offer.isPrivate == isPrivate)
		#expect((fixture.engine.client.snapshot(offer.tab.id) != nil) == accept)
		#expect(fixture.engine.client.snapshot(fixture.tab.id) == before)
		#expect(Fixture.navigations == 1) // only the original source navigation
		#expect(Fixture.destroyed.isEmpty) // rejected child destruction belongs to the native offer
	}


	@Test
	internal func privateReleaseWaitsUntilAllAdoptedSessionsClose() async throws {
		let fixture = try Fixture(isPrivate: true)
		defer { fixture.close() }
		try await fixture.engine.client.open(fixture.tab)
		var child: BrowserNewContents?
		fixture.engine.onNewContents = { offer in
			child = offer
			return true
		}

		let accepted = fixture.offer()
		#expect(accepted)
		let childID = try #require(child?.tab.id)
		fixture.engine.client.close(fixture.tab.id)
		fixture.engine.client.releasePrivateProfile(fixture.tab.profileID)
		#expect(Fixture.releases == 0)
		#expect(fixture.engine.client.snapshot(childID) != nil)
		fixture.engine.client.close(childID)
		#expect(Fixture.releases == 1)
		#expect(Set(Fixture.destroyed) == [1, 2])
	}

	@Test(arguments: ["intent", "operation"])
	internal func profileRetirementBlocksAdoptionFromAnExistingLiveSource(stage: String) async throws {
		let fixture = try Fixture()
		defer { fixture.close() }
		try await fixture.engine.client.open(fixture.tab)
		let original = fixture.engine.client.snapshot(fixture.tab.id)
		var published = 0
		fixture.engine.onNewContents = { _ in
			published += 1
			return true
		}

		if stage == "intent" {
			fixture.engine.client.blockProfileRetirement(fixture.tab.profileID)
		} else {
			fixture.engine.retiringProfiles.insert(fixture.tab.profileID)
		}

		let accepted = fixture.offer()
		#expect(!accepted)
		#expect(published == 0)
		#expect(fixture.engine.client.snapshot(fixture.tab.id) == original)
		#expect(Fixture.navigations == 1)
		#expect(Fixture.destroyed.isEmpty) // only the native offer owns rejected-child destruction
	}

	@Test(arguments: ["hidden", "minimized", "detached", "document"])
	internal func staleOrInvisibleSourceNeverPublishesChild(reason: String) async throws {
		let fixture = try Fixture()
		defer { fixture.close() }
		try await fixture.engine.client.open(fixture.tab)
		var offers = 0
		fixture.engine.onNewContents = { _ in
			offers += 1
			return true
		}

		switch reason {
		case "hidden": fixture.window.fixtureVisible = false
		case "minimized": fixture.window.fixtureMinimized = true
		case "detached": fixture.engine.surface.detach(fixture.host)
		default: break
		}

		let result = fixture.offer(generation: reason == "document" ? 2 : 1)
		#expect(!result)
		#expect(offers == 0)
		#expect(fixture.engine.client.snapshot(fixture.tab.id) != nil)
	}
}

@MainActor
private final class Fixture {
	fileprivate static weak var activeRuntime: ChromiumRuntime?
	fileprivate static var releases: Int = 0
	fileprivate static var views: [UInt64: NSView] = [:]
	fileprivate static var navigations: Int = 0
	fileprivate static var destroyed: [UInt64] = []
	fileprivate let runtime: ChromiumRuntime
	fileprivate let engine: ChromiumBrowserEngine
	fileprivate let tab: Tab
	fileprivate let host: NSView
	fileprivate let window: FixtureWindow

	fileprivate init(isPrivate: Bool = false) throws {
		Fixture.releases = 0
		Fixture.views = [1: NSView(), 2: NSView()]
		Fixture.navigations = 0
		Fixture.destroyed = []
		var api = ArxEngineAPI()
		api.prepare_profile = { _, request in
			MainActor.assumeIsolated { Fixture.activeRuntime?.complete(request, true) }
		}
		api.prepare_private_profile = { _ in true }
		api.release_private_profile = { _ in MainActor.assumeIsolated { Fixture.releases += 1 } }
		api.create_page = { _, _ in 1 }
		api.page_view = { id in
			let view = MainActor.assumeIsolated { Fixture.views[id] }
			return view.map { Unmanaged.passUnretained($0).toOpaque() }
		}
		api.destroy_page = { id in MainActor.assumeIsolated { Fixture.destroyed.append(id) } }
		api.navigate = { _, _ in
			MainActor.assumeIsolated {
				Fixture.navigations += 1
				return true
			}
		}
		api.history_count = { _ in 0 }
		api.page_close_generation = { _ in 1 }
		api.configure_content_hosting = { _, _ in true }
		self.runtime = ChromiumRuntime(api: api)
		Fixture.activeRuntime = runtime
		self.runtime.didBecomeReady()
		let profile = Profile.ID(rawValue: UUID())
		if isPrivate { try runtime.preparePrivateProfile(profile.rawValue) }

		self.engine = .init(
			runtime: runtime,
			profileID: isPrivate ? .init(rawValue: UUID()) : profile,
			enableContentHosting: true
		)
		self.tab = .init(
			id: .init(rawValue: UUID()),
			profileID: profile,
			restoration: .init(title: "Source", url: URL(string: "https://source.example/")!)
		)
		self.window = FixtureWindow()
		self.host = NSView(frame: .init(x: 0, y: 0, width: 600, height: 400))
		self.window.contentView = host
		self.engine.surface.attach(tab.id, host)
	}

	fileprivate func offer(generation: UInt64 = 1) -> Bool {
		runtime.receiveNewContents(
			source: 1,
			generation: generation,
			child: 2,
			target: "https://child.example/",
			disposition: 4
		)
	}

	fileprivate func close() {
		engine.closeAll()
		runtime.finish()
		window.close()
	}
}

@MainActor
private final class FixtureWindow: NSWindow {
	fileprivate var fixtureVisible: Bool = true
	fileprivate var fixtureMinimized: Bool = false

	internal override var isVisible: Bool { fixtureVisible }
	internal override var isMiniaturized: Bool { fixtureMinimized }

	fileprivate init() {
		super.init(
			contentRect: .init(x: 0, y: 0, width: 600, height: 400),
			styleMask: [.borderless],
			backing: .buffered,
			defer: true
		)
		isReleasedWhenClosed = false
	}
}
