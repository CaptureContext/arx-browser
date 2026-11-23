import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumSiteSettingsTests {
	@Test
	internal func listingsDecodePermissionsAndZoom() async throws {
		let fixture = SiteSettingsFixture()
		let task = Task { try await fixture.settings.list(profileKey: "a") }
		let request = await fixture.nextRequest()
		#expect(request.kind == .list)
		#expect(request.profileKey == "a")
		fixture.reply(request, status: ARX_SITE_SETTINGS_OK, json: #"""
		{"permissions":{"defaults":{"camera":"ask","popups":"block"},"managedDefaults":["popups"],
		"sites":[{"origin":"https://meet.example","permission":"camera","setting":"allow","managed":false}]},
		"zoom":{"default":1.25,"sites":[{"host":"docs.example","factor":1.5}]},"truncated":false}
		"""#)
		let listing = try await task.value
		#expect(listing.permissions.defaults == ["camera": "ask", "popups": "block"])
		#expect(listing.permissions.managedDefaults == ["popups"])
		#expect(listing.permissions.sites == [.init(origin: "https://meet.example", permission: "camera", setting: "allow")])
		#expect(listing.zoom == .init(default: 1.25, sites: [.init(host: "docs.example", factor: 1.5)]))
	}

	@Test
	internal func permissionsPassOriginAndSetting() async throws {
		let fixture = SiteSettingsFixture()
		let task = Task {
			try await fixture.settings.setPermission(profileKey: "", origin: "https://a.example", permission: .microphone, setting: .block)
		}
		let request = await fixture.nextRequest()
		#expect(request.kind == .permission)
		#expect(request.text == "https://a.example")
		#expect(request.permission == ARX_SITE_PERMISSION_MICROPHONE)
		#expect(request.setting == ARX_SITE_PERMISSION_SETTING_BLOCK)
		fixture.reply(request, status: ARX_SITE_SETTINGS_OK, json: Self.empty)
		_ = try await task.value

		// No origin is the profile's default; no setting removes the site's own.
		let removal = Task {
			try await fixture.settings.setPermission(profileKey: "", origin: "https://a.example", permission: .camera, setting: nil)
		}
		let removed = await fixture.nextRequest()
		#expect(removed.setting == ARX_SITE_PERMISSION_SETTING_DEFAULT)
		fixture.reply(removed, status: ARX_SITE_SETTINGS_OK, json: Self.empty)
		_ = try await removal.value

		let fallback = Task {
			try await fixture.settings.setPermission(profileKey: "", origin: nil, permission: .location, setting: .ask)
		}
		let defaulted = await fixture.nextRequest()
		#expect(defaulted.text == "")
		#expect(defaulted.setting == ARX_SITE_PERMISSION_SETTING_ASK)
		fixture.reply(defaulted, status: ARX_SITE_SETTINGS_OK, json: Self.empty)
		_ = try await fallback.value
	}

	@Test
	internal func zoomPassesHostAndFactor() async throws {
		let fixture = SiteSettingsFixture()
		let task = Task { try await fixture.settings.setZoom(profileKey: "", host: "a.example", factor: nil) }
		let request = await fixture.nextRequest()
		#expect(request.kind == .zoom)
		#expect(request.text == "a.example")
		#expect(request.factor == 0)
		fixture.reply(request, status: ARX_SITE_SETTINGS_OK, json: Self.empty)
		_ = try await task.value
	}

	@Test
	internal func refusedBeforeReachingNative() async throws {
		let fixture = SiteSettingsFixture()
		await #expect(throws: ChromiumSiteSettingsFailure.invalid(reason: nil)) {
			try await fixture.settings.setPermission(profileKey: "", origin: nil, permission: .camera, setting: nil)
		}
		await #expect(throws: ChromiumSiteSettingsFailure.invalid(reason: nil)) {
			try await fixture.settings.setZoom(profileKey: "", host: nil, factor: nil)
		}
		await #expect(throws: ChromiumSiteSettingsFailure.invalid(reason: nil)) {
			try await fixture.settings.setZoom(profileKey: "", host: "a.example", factor: 7)
		}
		#expect(SiteSettingsFixture.pending.isEmpty)
	}

	@Test(arguments: [
		(ARX_SITE_SETTINGS_INVALID, #"{"reason":"origin"}"#, ChromiumSiteSettingsFailure.invalid(reason: "origin")),
		(ARX_SITE_SETTINGS_MANAGED, #"{"reason":"managed"}"#, .managed),
		(ARX_SITE_SETTINGS_UNAVAILABLE, "{}", .unavailable),
		(ARX_SITE_SETTINGS_OK, "not json", .failed),
	])
	internal func failuresMapFromNativeStatuses(
		status: ArxSiteSettingsStatus,
		json: String,
		failure: ChromiumSiteSettingsFailure
	) async throws {
		// A reply that isn't JSON breaks the bridge's contract, so it's reported too (DEV-969).
		await withKnownIssue("A malformed reply from the bridge is reported") {
			let fixture = SiteSettingsFixture()
			let task = Task { try await fixture.settings.list(profileKey: "") }
			fixture.reply(await fixture.nextRequest(), status: status, json: json)
			await #expect(throws: failure) { try await task.value }
		} when: {
			json == "not json"
		}
	}

	@Test
	internal func changesReachEveryObserverAndStopEndsThem() async throws {
		let fixture = SiteSettingsFixture()
		let first = fixture.settings.changes()
		let second = fixture.settings.changes()
		fixture.settings.changed(profileKey: "a")
		var firstIterator = first.makeAsyncIterator()
		var secondIterator = second.makeAsyncIterator()
		#expect(await firstIterator.next() == "a")
		#expect(await secondIterator.next() == "a")

		let pending = Task { try await fixture.settings.list(profileKey: "") }
		_ = await fixture.nextRequest()
		fixture.settings.stop()
		await #expect(throws: ChromiumSiteSettingsFailure.unavailable) { try await pending.value }
		#expect(await firstIterator.next() == nil)
	}

	private static let empty: String = #"{"permissions":{"defaults":{},"managedDefaults":[],"sites":[]},"zoom":{"default":1,"sites":[]},"truncated":false}"#
}

@MainActor
private struct SiteSettingsFixture {
	fileprivate enum Kind: Equatable {
		case list
		case permission
		case zoom
	}

	fileprivate struct Request {
		fileprivate var id: UInt64
		fileprivate var kind: Kind
		fileprivate var profileKey: String
		fileprivate var text: String? = nil
		fileprivate var permission: ArxSitePermission? = nil
		fileprivate var setting: ArxSitePermissionSetting? = nil
		fileprivate var factor: Double? = nil
	}

	fileprivate static var pending: [Request] = []
	fileprivate let settings: ChromiumSiteSettingsRequests

	fileprivate init() {
		Self.pending = []
		var api = ArxEngineAPI()
		api.list_site_settings = { request, key in
			MainActor.assumeIsolated {
				SiteSettingsFixture.pending.append(.init(id: request, kind: .list, profileKey: String(cString: key!)))
			}
		}
		api.set_site_permission = { request, key, origin, permission, setting in
			MainActor.assumeIsolated {
				SiteSettingsFixture.pending.append(.init(
					id: request,
					kind: .permission,
					profileKey: String(cString: key!),
					text: origin.map { String(cString: $0) },
					permission: permission,
					setting: setting
				))
			}
		}
		api.set_site_zoom = { request, key, host, factor in
			MainActor.assumeIsolated {
				SiteSettingsFixture.pending.append(.init(
					id: request,
					kind: .zoom,
					profileKey: String(cString: key!),
					text: host.map { String(cString: $0) },
					factor: factor
				))
			}
		}
		self.settings = .init(api: api)
	}

	fileprivate func nextRequest() async -> Request {
		while Self.pending.isEmpty { await Task.yield() }
		return Self.pending.removeFirst()
	}

	fileprivate func reply(
		_ request: Request,
		status: ArxSiteSettingsStatus,
		json: String
	) {
		let bytes = Array(json.utf8)
		bytes.withUnsafeBufferPointer { buffer in
			settings.complete(request.id, status: status, json: buffer.baseAddress, count: buffer.count)
		}
	}
}
