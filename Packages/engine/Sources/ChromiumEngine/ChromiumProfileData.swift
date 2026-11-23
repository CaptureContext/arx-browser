import ChromiumBridge
import Foundation

/// ABI39. What Chromium itself stores for one ordinary profile that Clear Browsing
/// Data removes (DEV-647). History and downloads are cleared from Chromium's own
/// records too, but the app keeps and counts its own lists of both.
public enum ChromiumBrowsingDataKind: String, CaseIterable, Sendable {
	case history
	case downloads
	case cookies
	case cache
	case autofill
	case siteSettings

	internal var mask: UInt32 {
		switch self {
		case .history: ARX_BROWSING_DATA_HISTORY.rawValue
		case .downloads: ARX_BROWSING_DATA_DOWNLOADS.rawValue
		case .cookies: ARX_BROWSING_DATA_COOKIES.rawValue
		case .cache: ARX_BROWSING_DATA_CACHE.rawValue
		case .autofill: ARX_BROWSING_DATA_AUTOFILL.rawValue
		case .siteSettings: ARX_BROWSING_DATA_SITE_SETTINGS.rawValue
		}
	}

	internal static func mask(_ kinds: Set<Self>) -> UInt32 {
		kinds.reduce(0) { $0 | $1.mask }
	}
}

/// What clearing would remove. A kind is nil when it wasn't asked for, isn't counted
/// by the engine, or didn't answer in time.
public struct ChromiumBrowsingDataCounts: Decodable, Equatable, Sendable {
	public struct Sites: Decodable, Equatable, Sendable {
		public var sites: Int

		public init(sites: Int) {
			self.sites = sites
		}
	}

	public struct Cache: Decodable, Equatable, Sendable {
		public var bytes: Double

		/// Chromium could only bound the size of a cache limited by time.
		public var upperLimit: Bool

		public init(
			bytes: Double,
			upperLimit: Bool = false
		) {
			self.bytes = bytes
			self.upperLimit = upperLimit
		}
	}

	public struct Autofill: Decodable, Equatable, Sendable {
		public var entries: Int
		public var addresses: Int
		public var cards: Int

		public init(
			entries: Int,
			addresses: Int = 0,
			cards: Int = 0
		) {
			self.entries = entries
			self.addresses = addresses
			self.cards = cards
		}
	}

	public var cookies: Sites?
	public var cache: Cache?
	public var autofill: Autofill?
	public var siteSettings: Sites?

	public init(
		cookies: Sites? = nil,
		cache: Cache? = nil,
		autofill: Autofill? = nil,
		siteSettings: Sites? = nil
	) {
		self.cookies = cookies
		self.cache = cache
		self.autofill = autofill
		self.siteSettings = siteSettings
	}
}

/// Where an ordinary profile saves downloads, and whether it asks first.
public struct ChromiumDownloadSettings: Decodable, Equatable, Sendable {
	public var directory: String
	public var ask: Bool
	public var defaultDirectory: String

	/// Policy decides the location or the question.
	public var managed: Bool

	public init(
		directory: String,
		ask: Bool = false,
		defaultDirectory: String,
		managed: Bool = false
	) {
		self.directory = directory
		self.ask = ask
		self.defaultDirectory = defaultDirectory
		self.managed = managed
	}
}

public enum ChromiumProfileDataFailure: Error, Equatable, Sendable {
	/// Not in this engine, or a private, unknown or stopped profile.
	case unavailable

	/// `kinds`, `since` or `directory`.
	case invalid(reason: String?)

	/// A clear is already running for that profile.
	case busy

	/// Policy decides the downloads location, or keeps history.
	case managed
	case failed
}

/// Pending ABI39 requests. Native replies to each once, always posted.
@MainActor
internal final class ChromiumProfileDataRequests {
	private let api: ArxEngineAPI
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: CheckedContinuation<(ArxProfileDataStatus, Data), Never>] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool {
		api.count_browsing_data != nil
		&& api.clear_browsing_data != nil
		&& api.download_settings != nil
		&& api.set_download_settings != nil
	}

	/// `since` nil counts all time.
	internal func count(
		profileKey: String,
		kinds: Set<ChromiumBrowsingDataKind>,
		since: Date?
	) async throws(ChromiumProfileDataFailure) -> ChromiumBrowsingDataCounts {
		let (mask, seconds) = try Self.arguments(kinds, since)
		return try Self.decode(try await request { [api] id in
			profileKey.withCString { api.count_browsing_data?(id, $0, mask, seconds) }
		})
	}

	/// Returns the kinds Chromium couldn't fully clear.
	internal func clear(
		profileKey: String,
		kinds: Set<ChromiumBrowsingDataKind>,
		since: Date?
	) async throws(ChromiumProfileDataFailure) -> Set<ChromiumBrowsingDataKind> {
		struct Cleared: Decodable {
			var failed: [String]
		}
		let (mask, seconds) = try Self.arguments(kinds, since)
		let cleared: Cleared = try Self.decode(try await request { [api] id in
			profileKey.withCString { api.clear_browsing_data?(id, $0, mask, seconds) }
		})
		return Set(cleared.failed.compactMap(ChromiumBrowsingDataKind.init(rawValue:)))
	}

	/// ABI40 (DEV-633). The site a page's site data belongs to: its registrable domain.
	internal var isSiteDataAvailable: Bool {
		api.site_data_scope != nil && api.clear_site_data != nil
	}

	/// The domain `clearSite` would clear for that page's address.
	internal func siteScope(
		profileKey: String,
		url: URL
	) async throws(ChromiumProfileDataFailure) -> String {
		struct Scope: Decodable {
			var domain: String
		}
		let address = try Self.siteAddress(url)
		let scope: Scope = try Self.decode(try await request(requires: isSiteDataAvailable) { [api] id in
			profileKey.withCString { key in
				address.withCString { api.site_data_scope?(id, key, $0) }
			}
		})
		return scope.domain
	}

	/// Clears one site's cookies (with its site storage) and/or cache, all time. Returns
	/// the domain cleared and the kinds Chromium couldn't fully clear.
	internal func clearSite(
		profileKey: String,
		url: URL,
		kinds: Set<ChromiumBrowsingDataKind>
	) async throws(ChromiumProfileDataFailure) -> (domain: String, failed: Set<ChromiumBrowsingDataKind>) {
		struct Cleared: Decodable {
			var domain: String
			var failed: [String]
		}
		guard !kinds.isEmpty, kinds.isSubset(of: [.cookies, .cache])
		else { throw .invalid(reason: "kinds") }

		let address = try Self.siteAddress(url)
		let mask = ChromiumBrowsingDataKind.mask(kinds)
		let cleared: Cleared = try Self.decode(try await request(requires: isSiteDataAvailable) { [api] id in
			profileKey.withCString { key in
				address.withCString { api.clear_site_data?(id, key, $0, mask) }
			}
		})
		return (cleared.domain, Set(cleared.failed.compactMap(ChromiumBrowsingDataKind.init(rawValue:))))
	}

	private static func siteAddress(_ url: URL) throws(ChromiumProfileDataFailure) -> String {
		let address = url.absoluteString
		guard
			["http", "https"].contains(url.scheme?.lowercased() ?? ""),
			url.host() != nil,
			address.utf8.count <= 8192
		else { throw .invalid(reason: "url") }

		return address
	}

	internal func downloadSettings(profileKey: String) async throws(ChromiumProfileDataFailure) -> ChromiumDownloadSettings {
		try Self.decode(try await request { [api] id in
			profileKey.withCString { api.download_settings?(id, $0) }
		})
	}

	/// `directory` nil keeps the current folder.
	internal func setDownloadSettings(
		profileKey: String,
		directory: String?,
		ask: Bool
	) async throws(ChromiumProfileDataFailure) -> ChromiumDownloadSettings {
		if let directory {
			guard directory.hasPrefix("/"), directory.utf8.count <= 4096
			else { throw .invalid(reason: "directory") }
		}

		return try Self.decode(try await request { [api] id in
			profileKey.withCString { key in
				if let directory {
					directory.withCString { api.set_download_settings?(id, key, $0, ask) }
				} else {
					api.set_download_settings?(id, key, nil, ask)
				}
			}
		})
	}

	internal func complete(
		_ id: UInt64,
		status: ArxProfileDataStatus,
		json: UnsafePointer<UInt8>?,
		count: Int
	) {
		let body = json.map { Data(bytes: $0, count: count) } ?? Data()
		requests.removeValue(forKey: id)?.resume(returning: (status, body))
	}

	internal func stop() {
		for id in Array(requests.keys) {
			requests.removeValue(forKey: id)?.resume(returning: (ARX_PROFILE_DATA_UNAVAILABLE, Data()))
		}
	}

	private static func arguments(
		_ kinds: Set<ChromiumBrowsingDataKind>,
		_ since: Date?
	) throws(ChromiumProfileDataFailure) -> (UInt32, Double) {
		guard !kinds.isEmpty else { throw .invalid(reason: "kinds") }

		let seconds = since?.timeIntervalSince1970 ?? 0
		guard seconds.isFinite, seconds >= 0 else { throw .invalid(reason: "since") }

		// 0 is all time natively; a moment at the epoch means the same.
		return (ChromiumBrowsingDataKind.mask(kinds), seconds)
	}

	/// Native never drops a request, so there's nothing to cancel: a caller that
	/// stops waiting simply ignores the reply.
	private func request(
		requires available: Bool? = nil,
		start: @escaping (UInt64) -> Void
	) async throws(ChromiumProfileDataFailure) -> Data {
		guard available ?? isAvailable, requests.count < 32, nextRequest < UInt64.max
		else { throw .unavailable }

		let id = nextRequest
		nextRequest += 1
		let (status, body) = await withCheckedContinuation { continuation in
			requests[id] = continuation
			start(id)
		}
		guard status == ARX_PROFILE_DATA_OK
		else { throw Self.failure(status, body: body) }

		return body
	}

	private static func decode<Value: Decodable>(_ body: Data) throws(ChromiumProfileDataFailure) -> Value {
		guard let value = ChromiumReply.decode(Value.self, from: body)
		else { throw .failed }

		return value
	}

	internal static func failure(
		_ status: ArxProfileDataStatus,
		body: Data
	) -> ChromiumProfileDataFailure {
		let reason = ChromiumReply.failureReason(from: body)
		return switch status {
		case ARX_PROFILE_DATA_INVALID: .invalid(reason: reason)
		case ARX_PROFILE_DATA_BUSY: .busy
		case ARX_PROFILE_DATA_MANAGED: .managed
		case ARX_PROFILE_DATA_UNAVAILABLE: .unavailable
		default: .failed
		}
	}
}
