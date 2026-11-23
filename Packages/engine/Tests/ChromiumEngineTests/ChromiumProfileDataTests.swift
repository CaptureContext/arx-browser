import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumProfileDataTests {
	@Test
	internal func countsPassKindsAndTimeAndDecode() async throws {
		let fixture = ProfileDataFixture()
		let since = Date(timeIntervalSince1970: 1_800_000_000)
		let task = Task {
			try await fixture.data.count(profileKey: "a", kinds: [.cookies, .cache, .history], since: since)
		}
		let request = await fixture.nextRequest()
		#expect(request.kind == .count)
		#expect(request.profileKey == "a")
		#expect(request.kinds == ARX_BROWSING_DATA_COOKIES.rawValue | ARX_BROWSING_DATA_CACHE.rawValue | ARX_BROWSING_DATA_HISTORY.rawValue)
		#expect(request.since == 1_800_000_000)
		fixture.reply(request, status: ARX_PROFILE_DATA_OK, json: #"""
		{"cookies":{"sites":3},"cache":{"bytes":2048,"upperLimit":true}}
		"""#)
		let counts = try await task.value
		#expect(counts == .init(cookies: .init(sites: 3), cache: .init(bytes: 2048, upperLimit: true)))
	}

	@Test
	internal func allTimeIsZeroAndClearNamesFailedKinds() async throws {
		let fixture = ProfileDataFixture()
		let task = Task {
			try await fixture.data.clear(profileKey: "", kinds: Set(ChromiumBrowsingDataKind.allCases), since: nil)
		}
		let request = await fixture.nextRequest()
		#expect(request.kind == .clear)
		#expect(request.since == 0)
		#expect(request.kinds == 0b11_1111)
		fixture.reply(request, status: ARX_PROFILE_DATA_OK, json: #"{"failed":["cache","unknown"]}"#)
		#expect(try await task.value == [.cache])
	}

	@Test
	internal func downloadSettingsPassFolderAndQuestion() async throws {
		let fixture = ProfileDataFixture()
		let json = #"{"directory":"/Users/a/Downloads","ask":true,"defaultDirectory":"/Users/a/Downloads","managed":false}"#
		let task = Task { try await fixture.data.setDownloadSettings(profileKey: "a", directory: "/Volumes/Data", ask: true) }
		let request = await fixture.nextRequest()
		#expect(request.kind == .setDownloads)
		#expect(request.text == "/Volumes/Data")
		#expect(request.ask == true)
		fixture.reply(request, status: ARX_PROFILE_DATA_OK, json: json)
		#expect(try await task.value == .init(directory: "/Users/a/Downloads", ask: true, defaultDirectory: "/Users/a/Downloads"))

		// No folder keeps the current one.
		let keep = Task { try await fixture.data.setDownloadSettings(profileKey: "a", directory: nil, ask: false) }
		let kept = await fixture.nextRequest()
		#expect(kept.text == nil)
		fixture.reply(kept, status: ARX_PROFILE_DATA_OK, json: json)
		_ = try await keep.value

		let read = Task { try await fixture.data.downloadSettings(profileKey: "a") }
		let readRequest = await fixture.nextRequest()
		#expect(readRequest.kind == .readDownloads)
		fixture.reply(readRequest, status: ARX_PROFILE_DATA_OK, json: json)
		_ = try await read.value
	}

	@Test
	internal func refusedBeforeReachingNative() async throws {
		let fixture = ProfileDataFixture()
		await #expect(throws: ChromiumProfileDataFailure.invalid(reason: "kinds")) {
			try await fixture.data.clear(profileKey: "", kinds: [], since: nil)
		}
		await #expect(throws: ChromiumProfileDataFailure.invalid(reason: "since")) {
			try await fixture.data.count(profileKey: "", kinds: [.cache], since: Date(timeIntervalSince1970: -5))
		}
		await #expect(throws: ChromiumProfileDataFailure.invalid(reason: "directory")) {
			try await fixture.data.setDownloadSettings(profileKey: "", directory: "Downloads", ask: false)
		}
		#expect(ProfileDataFixture.pending.isEmpty)
	}

	@Test(arguments: [
		(ARX_PROFILE_DATA_INVALID, #"{"reason":"directory"}"#, ChromiumProfileDataFailure.invalid(reason: "directory")),
		(ARX_PROFILE_DATA_BUSY, "{}", .busy),
		(ARX_PROFILE_DATA_MANAGED, #"{"reason":"managed"}"#, .managed),
		(ARX_PROFILE_DATA_UNAVAILABLE, "{}", .unavailable),
		(ARX_PROFILE_DATA_OK, "not json", .failed),
	])
	internal func failuresMapFromNativeStatuses(
		status: ArxProfileDataStatus,
		json: String,
		failure: ChromiumProfileDataFailure
	) async throws {
		// A reply that isn't JSON breaks the bridge's contract, so it's reported too (DEV-969).
		await withKnownIssue("A malformed reply from the bridge is reported") {
			let fixture = ProfileDataFixture()
			let task = Task { try await fixture.data.downloadSettings(profileKey: "") }
			fixture.reply(await fixture.nextRequest(), status: status, json: json)
			await #expect(throws: failure) { try await task.value }
		} when: {
			json == "not json"
		}
	}

	@Test
	internal func siteScopeAndClearPassAddressAndKinds() async throws {
		let fixture = ProfileDataFixture()
		let url = try #require(URL(string: "https://mail.example.co.uk/inbox?x=1"))
		let scope = Task { try await fixture.data.siteScope(profileKey: "a", url: url) }
		let scopeRequest = await fixture.nextRequest()
		#expect(scopeRequest.kind == .siteScope)
		#expect(scopeRequest.profileKey == "a")
		#expect(scopeRequest.text == url.absoluteString)
		fixture.reply(scopeRequest, status: ARX_PROFILE_DATA_OK, json: #"{"domain":"example.co.uk"}"#)
		#expect(try await scope.value == "example.co.uk")

		let clear = Task { try await fixture.data.clearSite(profileKey: "a", url: url, kinds: [.cookies]) }
		let clearRequest = await fixture.nextRequest()
		#expect(clearRequest.kind == .clearSite)
		#expect(clearRequest.kinds == ARX_BROWSING_DATA_COOKIES.rawValue)
		fixture.reply(clearRequest, status: ARX_PROFILE_DATA_OK, json: #"{"domain":"example.co.uk","failed":["cookies"]}"#)
		let cleared = try await clear.value
		#expect(cleared.domain == "example.co.uk")
		#expect(cleared.failed == [.cookies])
	}

	@Test
	internal func siteClearRefusesOtherKindsAndAddresses() async throws {
		let fixture = ProfileDataFixture()
		let page = try #require(URL(string: "https://example.com"))
		await #expect(throws: ChromiumProfileDataFailure.invalid(reason: "kinds")) {
			try await fixture.data.clearSite(profileKey: "", url: page, kinds: [.history])
		}
		await #expect(throws: ChromiumProfileDataFailure.invalid(reason: "kinds")) {
			try await fixture.data.clearSite(profileKey: "", url: page, kinds: [])
		}
		await #expect(throws: ChromiumProfileDataFailure.invalid(reason: "url")) {
			try await fixture.data.siteScope(profileKey: "", url: try #require(URL(string: "file:///tmp/a.html")))
		}
		#expect(ProfileDataFixture.pending.isEmpty)
	}

	@Test
	internal func siteDataNeedsItsOwnEntries() async throws {
		var api = ArxEngineAPI()
		api.count_browsing_data = { _, _, _, _ in }
		api.clear_browsing_data = { _, _, _, _ in }
		api.download_settings = { _, _ in }
		api.set_download_settings = { _, _, _, _ in }
		let data = ChromiumProfileDataRequests(api: api)
		#expect(data.isAvailable)
		#expect(!data.isSiteDataAvailable)
		await #expect(throws: ChromiumProfileDataFailure.unavailable) {
			try await data.siteScope(profileKey: "", url: try #require(URL(string: "https://example.com")))
		}
	}

	@Test
	internal func stopFailsPendingRequests() async throws {
		let fixture = ProfileDataFixture()
		let pending = Task { try await fixture.data.count(profileKey: "", kinds: [.cache], since: nil) }
		_ = await fixture.nextRequest()
		fixture.data.stop()
		await #expect(throws: ChromiumProfileDataFailure.unavailable) { try await pending.value }
	}
}

@MainActor
private struct ProfileDataFixture {
	fileprivate enum Kind: Equatable {
		case count
		case clear
		case readDownloads
		case setDownloads
		case siteScope
		case clearSite
	}

	fileprivate struct Request {
		fileprivate var id: UInt64
		fileprivate var kind: Kind
		fileprivate var profileKey: String
		fileprivate var kinds: UInt32 = 0
		fileprivate var since: Double = 0
		fileprivate var text: String? = nil
		fileprivate var ask: Bool? = nil
	}

	fileprivate static var pending: [Request] = []
	fileprivate let data: ChromiumProfileDataRequests

	fileprivate init() {
		Self.pending = []
		var api = ArxEngineAPI()
		api.count_browsing_data = { request, key, kinds, since in
			MainActor.assumeIsolated {
				ProfileDataFixture.pending.append(.init(
					id: request,
					kind: .count,
					profileKey: String(cString: key!),
					kinds: kinds,
					since: since
				))
			}
		}
		api.clear_browsing_data = { request, key, kinds, since in
			MainActor.assumeIsolated {
				ProfileDataFixture.pending.append(.init(
					id: request,
					kind: .clear,
					profileKey: String(cString: key!),
					kinds: kinds,
					since: since
				))
			}
		}
		api.download_settings = { request, key in
			MainActor.assumeIsolated {
				ProfileDataFixture.pending.append(.init(id: request, kind: .readDownloads, profileKey: String(cString: key!)))
			}
		}
		api.set_download_settings = { request, key, directory, ask in
			MainActor.assumeIsolated {
				ProfileDataFixture.pending.append(.init(
					id: request,
					kind: .setDownloads,
					profileKey: String(cString: key!),
					text: directory.map { String(cString: $0) },
					ask: ask
				))
			}
		}
		api.site_data_scope = { request, key, url in
			MainActor.assumeIsolated {
				ProfileDataFixture.pending.append(.init(
					id: request,
					kind: .siteScope,
					profileKey: String(cString: key!),
					text: url.map { String(cString: $0) }
				))
			}
		}
		api.clear_site_data = { request, key, url, kinds in
			MainActor.assumeIsolated {
				ProfileDataFixture.pending.append(.init(
					id: request,
					kind: .clearSite,
					profileKey: String(cString: key!),
					kinds: kinds,
					text: url.map { String(cString: $0) }
				))
			}
		}
		self.data = .init(api: api)
	}

	fileprivate func nextRequest() async -> Request {
		while Self.pending.isEmpty { await Task.yield() }
		return Self.pending.removeFirst()
	}

	fileprivate func reply(
		_ request: Request,
		status: ArxProfileDataStatus,
		json: String
	) {
		let bytes = Array(json.utf8)
		bytes.withUnsafeBufferPointer { buffer in
			data.complete(request.id, status: status, json: buffer.baseAddress, count: buffer.count)
		}
	}
}
