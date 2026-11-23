import ChromiumBridge
import Foundation

/// ABI38. One ordinary profile's site permissions and page zoom (DEV-716).
/// Permission names are `camera`, `microphone`, `location`, `notifications`,
/// `popups`, `clipboard` and (DEV-884) `ads`; settings are `allow`, `block` or `ask`.
public struct ChromiumSiteSettings: Decodable, Equatable, Sendable {
	public struct Permissions: Decodable, Equatable, Sendable {
		public var defaults: [String: String]

		/// Permissions whose default policy, an extension or supervision decides.
		public var managedDefaults: [String]
		public var sites: [Site]

		public init(
			defaults: [String: String],
			managedDefaults: [String] = [],
			sites: [Site] = []
		) {
			self.defaults = defaults
			self.managedDefaults = managedDefaults
			self.sites = sites
		}
	}

	public struct Site: Decodable, Equatable, Sendable {
		/// `scheme://host[:port]`, or Chromium's pattern text for a wider rule.
		public var origin: String
		public var permission: String
		public var setting: String
		public var managed: Bool

		public init(
			origin: String,
			permission: String,
			setting: String,
			managed: Bool = false
		) {
			self.origin = origin
			self.permission = permission
			self.setting = setting
			self.managed = managed
		}
	}

	public struct Zoom: Decodable, Equatable, Sendable {
		public struct Host: Decodable, Equatable, Sendable {
			public var host: String
			public var factor: Double

			public init(
				host: String,
				factor: Double
			) {
				self.host = host
				self.factor = factor
			}
		}

		public var `default`: Double
		public var sites: [Host]

		public init(
			default: Double,
			sites: [Host] = []
		) {
			self.default = `default`
			self.sites = sites
		}
	}

	public var permissions: Permissions
	public var zoom: Zoom
	public var truncated: Bool

	public init(
		permissions: Permissions,
		zoom: Zoom,
		truncated: Bool = false
	) {
		self.permissions = permissions
		self.zoom = zoom
		self.truncated = truncated
	}
}

public enum ChromiumSitePermission: String, CaseIterable, Sendable {
	case camera
	case microphone
	case location
	case notifications
	case popups
	case clipboard

	/// DEV-884. Chromium's Ads setting: `allow` turns Arx's content blocking off for the site.
	case ads

	internal var native: ArxSitePermission {
		switch self {
		case .camera: ARX_SITE_PERMISSION_CAMERA
		case .microphone: ARX_SITE_PERMISSION_MICROPHONE
		case .location: ARX_SITE_PERMISSION_LOCATION
		case .notifications: ARX_SITE_PERMISSION_NOTIFICATIONS
		case .popups: ARX_SITE_PERMISSION_POPUPS
		case .clipboard: ARX_SITE_PERMISSION_CLIPBOARD
		case .ads: ARX_SITE_PERMISSION_ADS
		}
	}
}

public enum ChromiumSitePermissionSetting: String, CaseIterable, Sendable {
	case allow
	case block
	case ask

	internal var native: ArxSitePermissionSetting {
		switch self {
		case .allow: ARX_SITE_PERMISSION_SETTING_ALLOW
		case .block: ARX_SITE_PERMISSION_SETTING_BLOCK
		case .ask: ARX_SITE_PERMISSION_SETTING_ASK
		}
	}
}

public enum ChromiumSiteSettingsFailure: Error, Equatable, Sendable {
	/// No site settings in this engine, or a private, unknown or stopped profile.
	case unavailable

	/// `origin`, `host`, `factor`, `setting` or `permission`.
	case invalid(reason: String?)

	/// Policy, an extension or supervision decides that setting.
	case managed
	case failed
}

/// Pending site-settings requests. Native replies to each once, always posted.
@MainActor
internal final class ChromiumSiteSettingsRequests {
	private let api: ArxEngineAPI
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: CheckedContinuation<(ArxSiteSettingsStatus, Data), Never>] = [:]
	private var observers: [UUID: AsyncStream<String>.Continuation] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool {
		api.list_site_settings != nil
		&& api.set_site_permission != nil
		&& api.set_site_zoom != nil
	}

	internal func list(profileKey: String) async throws(ChromiumSiteSettingsFailure) -> ChromiumSiteSettings {
		try Self.listing(try await request { [api] id in
			profileKey.withCString { api.list_site_settings?(id, $0) }
		})
	}

	/// `origin` nil sets the profile's default; `setting` nil removes the site's own.
	internal func setPermission(
		profileKey: String,
		origin: String?,
		permission: ChromiumSitePermission,
		setting: ChromiumSitePermissionSetting?
	) async throws(ChromiumSiteSettingsFailure) -> ChromiumSiteSettings {
		guard origin != nil || setting != nil, (origin?.utf8.count ?? 0) <= 2048
		else { throw .invalid(reason: nil) }

		let native = setting?.native ?? ARX_SITE_PERMISSION_SETTING_DEFAULT
		return try Self.listing(try await request { [api] id in
			profileKey.withCString { key in
				(origin ?? "").withCString { api.set_site_permission?(id, key, $0, permission.native, native) }
			}
		})
	}

	/// `host` nil sets the profile's default; `factor` nil removes the host's own.
	internal func setZoom(
		profileKey: String,
		host: String?,
		factor: Double?
	) async throws(ChromiumSiteSettingsFailure) -> ChromiumSiteSettings {
		guard
			host != nil || factor != nil,
			(host?.utf8.count ?? 0) <= 2048,
			factor.map({ $0.isFinite && (0.25 ... 5).contains($0) }) ?? true
		else { throw .invalid(reason: nil) }

		return try Self.listing(try await request { [api] id in
			profileKey.withCString { key in
				(host ?? "").withCString { api.set_site_zoom?(id, key, $0, factor ?? 0) }
			}
		})
	}

	internal func changes() -> AsyncStream<String> {
		let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(64))
		let id = UUID()
		observers[id] = continuation
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor in self?.observers.removeValue(forKey: id) }
		}
		return stream
	}

	internal func complete(
		_ id: UInt64,
		status: ArxSiteSettingsStatus,
		json: UnsafePointer<UInt8>?,
		count: Int
	) {
		let body = json.map { Data(bytes: $0, count: count) } ?? Data()
		requests.removeValue(forKey: id)?.resume(returning: (status, body))
	}

	internal func changed(profileKey: String) {
		for observer in observers.values {
			observer.yield(profileKey)
		}
	}

	internal func stop() {
		for id in Array(requests.keys) {
			requests.removeValue(forKey: id)?.resume(returning: (ARX_SITE_SETTINGS_UNAVAILABLE, Data()))
		}
		for observer in observers.values {
			observer.finish()
		}
		observers.removeAll()
	}

	/// Native never drops a request, so there's nothing to cancel: a caller that
	/// stops waiting simply ignores the reply.
	private func request(
		start: @escaping (UInt64) -> Void
	) async throws(ChromiumSiteSettingsFailure) -> Data {
		guard isAvailable, requests.count < 32, nextRequest < UInt64.max
		else { throw .unavailable }

		let id = nextRequest
		nextRequest += 1
		let (status, body) = await withCheckedContinuation { continuation in
			requests[id] = continuation
			start(id)
		}
		guard status == ARX_SITE_SETTINGS_OK
		else { throw Self.failure(status, body: body) }

		return body
	}

	private static func listing(_ body: Data) throws(ChromiumSiteSettingsFailure) -> ChromiumSiteSettings {
		guard let listing = ChromiumReply.decode(ChromiumSiteSettings.self, from: body)
		else { throw .failed }

		return listing
	}

	internal static func failure(
		_ status: ArxSiteSettingsStatus,
		body: Data
	) -> ChromiumSiteSettingsFailure {
		let reason = ChromiumReply.failureReason(from: body)
		return switch status {
		case ARX_SITE_SETTINGS_INVALID: .invalid(reason: reason)
		case ARX_SITE_SETTINGS_MANAGED: .managed
		case ARX_SITE_SETTINGS_UNAVAILABLE: .unavailable
		default: .failed
		}
	}
}
