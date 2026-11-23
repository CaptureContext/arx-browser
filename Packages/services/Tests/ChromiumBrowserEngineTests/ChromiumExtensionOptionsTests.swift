import AppKit
import BrowserCore
import BrowserEngineClient
import BrowserExtensionsClient
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.serialized)
@MainActor
internal struct ChromiumExtensionOptionsTests {
	@Test(arguments: ["revoke", "close", "refused", "reentrant"])
	internal func runtimeOptionsRollbackRemovesOnlyTheOfferedEngineSession(caseName: String) async throws {
		let fixture = OptionsFixture()
		defer { fixture.close() }

		try await fixture.engine.client.open(fixture.source)
		let before = fixture.engine.client.snapshot(fixture.source.id)
		var offered: BrowserExtensionViewOffer?
		var revoked: [BrowserExtensionViewOffer] = []
		var settled: [BrowserExtensionViewOffer] = []
		fixture.engine.onExtensionOptionsRevoked = { revoked.append($0) }
		fixture.engine.onExtensionOptionsSettled = { settled.append($0) }
		_ = fixture.engine.extensions(ordinaryProfileExists: { $0 == fixture.source.profileID })
		fixture.engine.onExtensionView = { offer in
			offered = offer
			if caseName == "reentrant" { fixture.revoke() }
			return caseName != "refused"
		}

		let accepted = fixture.runtime.receiveRuntimeExtensionOptions(
			profileKey: "",
			extensionID: OptionsFixture.extensionID,
			child: 2,
			target: OptionsFixture.target
		)
		let offer = try #require(offered)
		#expect(accepted == (caseName == "revoke" || caseName == "close"))

		if caseName == "close" { fixture.engine.client.close(offer.tab.id) }
		fixture.revoke()
		fixture.revoke()

		#expect(fixture.engine.client.snapshot(offer.tab.id) == nil)
		#expect(fixture.engine.client.snapshot(fixture.source.id) == before)
		#expect(revoked == (caseName == "revoke" || caseName == "reentrant" ? [offer] : []))
		#expect(settled == (caseName == "close" ? [offer] : []))
		#expect(OptionsFixture.destroyed == (caseName == "close" ? [2] : []))
	}

	@Test(arguments: [true, false])
	internal func retirementRefusesOptionsBeforePublishing(physicalOperation: Bool) async throws {
		let fixture = OptionsFixture()
		defer { fixture.close() }

		try await fixture.engine.client.open(fixture.source)
		let before = fixture.engine.client.snapshot(fixture.source.id)
		var offers = 0
		fixture.engine.onExtensionView = { _ in
			offers += 1
			return true
		}
		let client = fixture.engine.extensions(ordinaryProfileExists: { $0 == fixture.source.profileID })
		let inventory = try await client.inspect(fixture.source.profileID)
		if physicalOperation {
			fixture.engine.retiringProfiles.insert(fixture.source.profileID)
		} else {
			fixture.engine.client.blockProfileRetirement(fixture.source.profileID)
		}

		await #expect(throws: BrowserExtensionsClient.Failure.failed) {
			try await client.openOptions(.init(inventory: inventory, extensionID: OptionsFixture.extensionID))
		}
		#expect(offers == 0)
		#expect(fixture.engine.client.snapshot(fixture.source.id) == before)
		#expect(OptionsFixture.navigations == 1)
		#expect(OptionsFixture.destroyed.isEmpty)
	}

	@Test(arguments: [true, false])
	internal func optionsAdoptsExactlyTheOfferedSessionAndRollsBackRefusal(accept: Bool) async throws {
		let fixture = OptionsFixture()
		defer { fixture.close() }

		try await fixture.engine.client.open(fixture.source)
		let before = fixture.engine.client.snapshot(fixture.source.id)
		var offered: BrowserExtensionViewOffer?
		fixture.engine.onExtensionView = { offer in
			offered = offer
			return accept
		}
		let client = fixture.engine.extensions(ordinaryProfileExists: { $0 == fixture.source.profileID })
		let inventory = try await client.inspect(fixture.source.profileID)
		let request = BrowserExtensionViewRequest(inventory: inventory, extensionID: OptionsFixture.extensionID)

		if accept {
			_ = try await client.openOptions(request)
		} else {
			await #expect(throws: BrowserExtensionsClient.Failure.failed) {
				try await client.openOptions(request)
			}
		}

		let offer = try #require(offered)
		#expect(offer.profileID == fixture.source.profileID)
		#expect(offer.extensionID == OptionsFixture.extensionID)
		#expect(offer.tab.reopeningURL.absoluteString == OptionsFixture.target)
		#expect((fixture.engine.client.snapshot(offer.tab.id) != nil) == accept)
		#expect(fixture.engine.client.snapshot(fixture.source.id) == before)
		#expect(OptionsFixture.navigations == 1)
		#expect(OptionsFixture.destroyed.isEmpty)
		#expect(!fixture.offer(request: OptionsFixture.lastRequest))
	}
}

@MainActor
private final class OptionsFixture {
	fileprivate static let extensionID: String = String(repeating: "a", count: 32)
	fileprivate static let target: String = "chrome-extension://\(extensionID)/options.html"
	private static weak var active: OptionsFixture?
	fileprivate static var navigations: Int = 0
	fileprivate static var destroyed: [UInt64] = []
	fileprivate static var lastRequest: UInt64 = 0
	private let views: [UInt64: NSView] = [1: .init(), 2: .init()]
	fileprivate let runtime: ChromiumRuntime
	fileprivate let engine: ChromiumBrowserEngine
	fileprivate let source: Tab

	fileprivate init() {
		Self.navigations = 0
		Self.destroyed = []
		Self.lastRequest = 0
		var api = ArxEngineAPI()
		api.prepare_profile = { _, request in
			MainActor.assumeIsolated { OptionsFixture.active?.runtime.complete(request, true) }
		}
		api.create_page = { _, _ in 1 }
		api.page_view = { id in
			let view = MainActor.assumeIsolated { OptionsFixture.active?.views[id] }
			return view.map { Unmanaged.passUnretained($0).toOpaque() }
		}
		api.destroy_page = { id in MainActor.assumeIsolated { OptionsFixture.destroyed.append(id) } }
		api.navigate = { _, _ in
			MainActor.assumeIsolated {
				OptionsFixture.navigations += 1
				return true
			}
		}
		api.history_count = { _ in 0 }
		api.page_close_generation = { _ in 1 }
		api.configure_content_hosting = { _, _ in true }
		api.inspect_extensions = { _, request in
			MainActor.assumeIsolated { OptionsFixture.active?.complete(request: request) }
		}
		api.extension_views_available = { true }
		api.open_extension_view = { _, request, revision, id, kind, source, generation in
			MainActor.assumeIsolated {
				guard let fixture = OptionsFixture.active else { return }

				#expect(revision == 1)
				#expect(String(cString: id!) == OptionsFixture.extensionID)
				#expect(kind == ARX_EXTENSION_VIEW_OPTIONS)
				#expect(source == 0 && generation == 0)
				OptionsFixture.lastRequest = request
				let accepted = fixture.offer(request: request)
				fixture.complete(request: request, status: accepted ? ARX_EXTENSION_SUCCESS : ARX_EXTENSION_FAILED)
			}
		}
		self.runtime = .init(api: api)
		self.source = .init(
			id: .init(rawValue: UUID()),
			profileID: .init(rawValue: UUID()),
			restoration: .init(title: "Original", url: URL(string: "https://source.example/")!)
		)
		self.engine = .init(runtime: runtime, profileID: source.profileID, enableExtensionViews: true)
		Self.active = self
		runtime.extensionBridge.configure(enabled: true, fixture: false)
		runtime.didBecomeReady()
	}

	fileprivate func revoke() {
		runtime.receiveRuntimeExtensionOptionsRevoked(
			profileKey: "",
			extensionID: Self.extensionID,
			child: 2,
			generation: 1
		)
	}

	fileprivate func offer(request: UInt64) -> Bool {
		runtime.receiveExtensionOptions(
			request: request,
			profileKey: "",
			extensionID: Self.extensionID,
			child: 2,
			target: Self.target,
			kind: ARX_EXTENSION_VIEW_OPTIONS
		)
	}

	private func complete(
		request: UInt64,
		status: ArxExtensionStatus = ARX_EXTENSION_SUCCESS
	) {
		let permissions: [String: Any] = ["apis": ["storage"], "hosts": []]
		let data = try! JSONSerialization.data(withJSONObject: ["extensions": [[
			"id": Self.extensionID,
			"name": "Options fixture",
			"version": "1.0",
			"manifestVersion": 3,
			"location": 4,
			"fromWebStore": false,
			"state": "enabled",
			"disableReasons": [],
			"permissionsIncreased": false,
			"isFixture": false,
			"canEnable": false,
			"canDisable": true,
			"canRemove": true,
			"canOpenOptions": true,
			"requiredPermissions": permissions,
			"optionalPermissions": permissions,
			"activePermissions": permissions,
			"withheldPermissions": permissions,
		]]])
		data.withUnsafeBytes { bytes in
			runtime.extensionBridge.complete(
				request,
				profileKey: "",
				status: status,
				revision: 1,
				bytes: bytes.bindMemory(to: UInt8.self).baseAddress,
				count: bytes.count
			)
		}
	}

	fileprivate func close() {
		engine.closeAll()
		runtime.finish()
		Self.active = nil
	}
}
