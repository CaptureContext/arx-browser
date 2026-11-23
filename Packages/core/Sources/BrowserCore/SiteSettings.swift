import Foundation

/// A permission a site asks for, as Settings and automation name it (DEV-716).
public enum SitePermission: String, Codable, CaseIterable, Comparable, Sendable {
	case camera
	case microphone
	case location
	case notifications
	case popups
	case clipboard

	public static func < (lhs: Self, rhs: Self) -> Bool {
		allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
	}

	/// What a site may be set to. Pop-ups have no prompt, so they take no `ask`.
	public var siteSettings: [SitePermissionSetting] {
		self == .popups ? [.allow, .block] : [.allow, .block, .ask]
	}

	/// What the profile's default may be. Sites never get a permission that prompts
	/// by default; only pop-ups may be allowed everywhere.
	public var defaultSettings: [SitePermissionSetting] {
		self == .popups ? [.allow, .block] : [.ask, .block]
	}
}

public enum SitePermissionSetting: String, Codable, CaseIterable, Sendable {
	case allow
	case block
	case ask
}

/// A site's own setting for one permission. `origin` is `scheme://host[:port]`, or
/// Chromium's pattern text for a rule wider than one origin, which can only be removed.
public struct SitePermissionException: Codable, Equatable, Hashable, Sendable {
	public var origin: String
	public var permission: SitePermission
	public var setting: SitePermissionSetting

	/// Set by policy, an extension or supervision; Arx can't change it.
	public var isManaged: Bool

	public init(
		origin: String,
		permission: SitePermission,
		setting: SitePermissionSetting,
		isManaged: Bool = false
	) {
		self.origin = origin
		self.permission = permission
		self.setting = setting
		self.isManaged = isManaged
	}
}

public struct SitePermissionDefault: Codable, Equatable, Hashable, Sendable {
	public var permission: SitePermission
	public var setting: SitePermissionSetting
	public var isManaged: Bool

	public init(
		permission: SitePermission,
		setting: SitePermissionSetting,
		isManaged: Bool = false
	) {
		self.permission = permission
		self.setting = setting
		self.isManaged = isManaged
	}
}

/// A host's page zoom, as a factor (1 is 100%).
public struct SiteZoom: Codable, Equatable, Hashable, Sendable {
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

/// One ordinary profile's site permissions and page zoom, as Chromium holds them.
public struct SiteSettings: Codable, Equatable, Sendable {
	/// Page zoom factors Settings and Zoom In and Zoom Out offer: Chromium's presets
	/// (`blink::kPresetBrowserZoomFactors`), with 1/3 and 2/3 as 0.33 and 0.67.
	public static let zoomFactors: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.33, 1.4, 1.5, 1.75, 2, 2.5, 3, 4, 5]
	public static let zoomRange: ClosedRange<Double> = 0.25 ... 5

	public var defaults: [SitePermissionDefault]

	/// Sorted by origin, then permission.
	public var exceptions: [SitePermissionException]
	public var defaultZoom: Double

	/// Sorted by host.
	public var zoom: [SiteZoom]

	/// Chromium had more rows than one listing carries (5000 of each).
	public var isTruncated: Bool

	/// Whether the engine can turn content blocking off for one site (DEV-884).
	public var contentBlockingIsAvailable: Bool

	/// Sites the person turned content blocking off for, as origins or Chromium's
	/// pattern text. Sorted.
	public var contentBlockingOff: [String]

	/// Sites where policy, an extension or supervision keeps content blocking on (a managed
	/// BLOCK of the Ads setting). They win over `contentBlockingOff`. Sorted.
	public var contentBlockingManaged: [String]

	/// Sites where a managed rule turns content blocking off. Also in `contentBlockingOff`.
	public var contentBlockingManagedOff: [String]

	/// Policy, an extension or supervision decides the Ads default, so no site's own rule
	/// can change content blocking.
	public var contentBlockingDefaultIsManaged: Bool

	public init(
		defaults: [SitePermissionDefault] = [],
		exceptions: [SitePermissionException] = [],
		defaultZoom: Double = 1,
		zoom: [SiteZoom] = [],
		isTruncated: Bool = false,
		contentBlockingIsAvailable: Bool = false,
		contentBlockingOff: [String] = [],
		contentBlockingManaged: [String] = [],
		contentBlockingManagedOff: [String] = [],
		contentBlockingDefaultIsManaged: Bool = false
	) {
		self.defaults = defaults
		self.exceptions = exceptions.sorted { ($0.origin, $0.permission) < ($1.origin, $1.permission) }
		self.defaultZoom = defaultZoom
		self.zoom = zoom.sorted { $0.host < $1.host }
		self.isTruncated = isTruncated
		self.contentBlockingIsAvailable = contentBlockingIsAvailable
		self.contentBlockingOff = contentBlockingOff.sorted()
		self.contentBlockingManaged = contentBlockingManaged.sorted()
		self.contentBlockingManagedOff = contentBlockingManagedOff.sorted()
		self.contentBlockingDefaultIsManaged = contentBlockingDefaultIsManaged
	}

	/// Whether content blocking is on for an exact `origin` (`scheme://host[:port]`):
	/// on unless a listed site rule covers it.
	public func blocksContent(on origin: String) -> Bool {
		// Managed rules decide first; a managed default leaves only managed site rules in
		// `contentBlockingOff`.
		managedContentBlocking(on: origin) ?? contentBlockingRules(covering: origin).isEmpty
	}

	/// What managed site rules decide for an exact `origin`, as Chromium picks among them: the
	/// most specific one, a BLOCK on a tie. Nil when none covers it.
	private func managedContentBlocking(on origin: String) -> Bool? {
		guard let site = Self.Site(origin: origin) else { return nil }

		let on = contentBlockingManaged.compactMap { Self.specificity(of: $0, matching: site) }.max()
		let off = contentBlockingManagedOff.compactMap { Self.specificity(of: $0, matching: site) }.max()
		switch (on, off) {
		case (nil, nil): return nil
		case (_?, nil): return true
		case (nil, _?): return false
		case let (on?, off?): return on >= off
		}
	}

	/// Whether a managed rule keeps content blocking on for an exact `origin`, so the person
	/// can't turn it off there.
	public func contentBlockingIsManaged(on origin: String) -> Bool {
		contentBlockingDefaultIsManaged || managedContentBlocking(on: origin) != nil
	}

	/// The listed rules that turn content blocking off for an exact `origin`: its own, and
	/// wider ones such as `[*.]example.com`.
	public func contentBlockingRules(covering origin: String) -> [String] {
		guard let site = Self.Site(origin: origin) else { return [] }

		return contentBlockingOff.filter { Self.specificity(of: $0, matching: site) != nil }
	}

	/// Whether a content blocking rule is one the engine applies as listed: an exact origin, or
	/// `[*.]host` for any scheme and port. Others are left out of `contentBlockingOff`.
	public static func isContentBlockingRule(_ rule: String) -> Bool {
		if origin(rule) == rule { return true }
		guard rule.hasPrefix("[*.]") else { return false }

		let host = rule.dropFirst(4)
		return !host.isEmpty && !host.contains(where: { ":/*".contains($0) })
	}

	public func defaultSetting(for permission: SitePermission) -> SitePermissionDefault? {
		defaults.first { $0.permission == permission }
	}

	public func exception(
		origin: String,
		permission: SitePermission
	) -> SitePermissionException? {
		exceptions.first { $0.origin == origin && $0.permission == permission }
	}

	/// The site rule that decides `permission` for an exact `origin` (`scheme://host[:port]`),
	/// as Chromium picks it: a managed rule before the user's, then the most specific
	/// pattern. Nil when no listed rule matches, so the profile's default applies.
	///
	/// `excluding` leaves out a listed origin's own rule, to see what applies without it.
	public func rule(
		for permission: SitePermission,
		origin: String,
		excluding excluded: String? = nil
	) -> SitePermissionException? {
		guard let site = Self.Site(origin: origin) else { return nil }

		return exceptions
			.filter { $0.permission == permission && $0.origin != excluded }
			.compactMap { rule in Self.specificity(of: rule.origin, matching: site).map { (rule, $0) } }
			.max { lhs, rhs in
				lhs.0.isManaged == rhs.0.isManaged ? lhs.1 < rhs.1 : rhs.0.isManaged
			}?
			.0
	}

	private struct Site {
		internal var scheme: String
		internal var host: String
		internal var port: Int

		internal init?(origin: String) {
			guard
				let components = URLComponents(string: origin),
				let scheme = components.scheme?.lowercased(),
				let host = components.encodedHost?.lowercased(),
				!host.isEmpty
			else { return nil }

			self.scheme = scheme
			self.host = host
			self.port = components.port ?? (scheme == "https" ? 443 : 80)
		}
	}

	/// How specific a Chromium content-settings pattern such as `https://[*.]example.com`,
	/// `[*.]example.com:*` or an exact origin is when it matches `site`; nil when it doesn't.
	private static func specificity(
		of pattern: String,
		matching site: Site
	) -> Int? {
		var rest = Substring(pattern.lowercased())
		var scheme: Substring?
		if let range = rest.range(of: "://") {
			scheme = rest[..<range.lowerBound]
			rest = rest[range.upperBound...]
		}
		if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
		var port: Substring?
		if let colon = rest.lastIndex(of: ":"), !rest.hasSuffix("]") {
			port = rest[rest.index(after: colon)...]
			rest = rest[..<colon]
		}
		var score = 0
		switch scheme {
		case nil, "*": break
		case let scheme?:
			guard scheme == site.scheme else { return nil }
			score += 1
		}
		switch port {
		case "*": break
		case let port?:
			guard Int(port) == site.port else { return nil }
			score += 2
		case nil:
			// A scheme without a port means that scheme's default port.
			if let scheme, scheme != "*" {
				guard site.port == (scheme == "https" ? 443 : 80) else { return nil }
				score += 2
			}
		}
		if rest == "*" { return score }
		if rest.hasPrefix("[*.]") {
			let domain = rest.dropFirst(4)
			guard site.host == domain || site.host.hasSuffix("." + domain) else { return nil }
			return score + 4 * domain.count
		}
		guard rest == site.host else { return nil }
		return score + 4 * rest.count + 100_000
	}

	/// The listed origins, each once, in order.
	public var origins: [String] {
		var seen: Set<String> = []
		return exceptions.map(\.origin).filter { seen.insert($0).inserted }
	}

	public func zoom(for host: String) -> Double? {
		zoom.first { $0.host == host }?.factor
	}

	/// Whether `edit` already holds, so applying it changes nothing.
	public func holds(_ edit: SiteSettingsEdit) -> Bool {
		switch edit {
		case let .setPermission(origin?, permission, setting):
			exception(origin: origin, permission: permission)?.setting == setting
		case let .setPermission(nil, permission, setting):
			defaultSetting(for: permission)?.setting == setting
		case let .setZoom(host?, nil):
			zoom(for: host) == nil
		case let .setZoom(host?, factor?):
			// Native drops a host's zoom that equals the default.
			Self.sameZoom(zoom(for: host) ?? defaultZoom, factor)
		case let .setZoom(nil, factor):
			factor.map { Self.sameZoom($0, defaultZoom) } ?? false
		case let .setContentBlocking(origin, isOn):
			blocksContent(on: origin) == isOn
		}
	}

	public static func sameZoom(_ lhs: Double, _ rhs: Double) -> Bool {
		abs(lhs - rhs) < 0.001
	}

	/// `scheme://host[:port]` for an http(s) address without user info, the form
	/// listings use; nil otherwise. A bare host means https.
	public static func origin(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed.utf8.count <= 2048 else { return nil }

		let address = trimmed.contains("://") ? trimmed : "https://" + trimmed
		guard
			let components = URLComponents(string: address),
			let scheme = components.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			// The ASCII (punycode) form, as Chromium lists hosts.
			let host = components.encodedHost?.lowercased(),
			!host.isEmpty,
			components.user == nil,
			components.password == nil
		else { return nil }

		let defaultPort = scheme == "https" ? 443 : 80
		let port = components.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
		return "\(scheme)://\(host)\(port)"
	}

	/// A host for page zoom: a bare host, or an address's host. Nil when there is none.
	public static func zoomHost(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed.utf8.count <= 2048 else { return nil }

		let address = trimmed.contains("://") ? trimmed : "https://" + trimmed
		guard
			let components = URLComponents(string: address),
			let host = components.encodedHost?.lowercased(),
			!host.isEmpty,
			!host.contains(":")
		else { return nil }

		return host
	}
}

/// One change to a profile's site settings, from Settings or automation.
public enum SiteSettingsEdit: Codable, Equatable, Hashable, Sendable {
	/// A site's setting (nil removes the site's own setting), or with no origin the
	/// profile's default.
	case setPermission(origin: String?, SitePermission, SitePermissionSetting?)

	/// A host's zoom factor (nil removes it, so the default applies), or with no host the
	/// profile's default zoom.
	case setZoom(host: String?, factor: Double?)

	/// Turns content blocking off for an exact origin, or back on (DEV-884).
	case setContentBlocking(origin: String, isOn: Bool)

	/// Checks the edit's shape, not whether the site is listed.
	public func validate() throws(SiteSettingsFailure) {
		switch self {
		case let .setPermission(origin?, permission, setting):
			guard !origin.isEmpty, origin.utf8.count <= 2048 else { throw .invalid }
			if let setting {
				guard SiteSettings.origin(origin) == origin, permission.siteSettings.contains(setting)
				else { throw .invalid }
			}

		case let .setPermission(nil, permission, setting):
			guard let setting, permission.defaultSettings.contains(setting) else { throw .invalid }

		case let .setZoom(host, factor):
			if let host {
				guard SiteSettings.zoomHost(host) == host else { throw .invalid }
			} else if factor == nil {
				throw .invalid
			}
			if let factor {
				guard factor.isFinite, SiteSettings.zoomRange.contains(factor) else { throw .invalid }
			}

		case let .setContentBlocking(origin, _):
			guard
				!origin.isEmpty,
				origin.utf8.count <= 2048,
				SiteSettings.origin(origin) == origin
			else { throw .invalid }
		}
	}
}

public enum SiteSettingsFailure: Error, Equatable, Sendable {
	/// No site settings in this engine, or a private, unknown or retiring profile.
	case unavailable
	case invalid

	/// Policy, an extension or supervision decides it.
	case managed
	case failed
}
