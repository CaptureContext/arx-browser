import Foundation

/// Committed top-level HTTP(S) origin. Paths, credentials, queries and fragments never become site permissions.
public struct MediaSite: Hashable, Codable, Sendable {
	public let origin: URL

	public init?(url: URL) {
		guard
			var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let scheme = parts.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			let host = parts.host?.lowercased(),
			!host.isEmpty,
			parts.user == nil,
			parts.password == nil
		else { return nil }
		parts.scheme = scheme
		parts.host = host
		if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
		parts.path = ""
		parts.query = nil
		parts.fragment = nil
		guard let origin = parts.url else { return nil }
		self.origin = origin
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		let url = try container.decode(URL.self)
		guard let site = Self(url: url), site.origin == url else {
			throw DecodingError.dataCorruptedError(
				in: container,
				debugDescription: "Expected an exact HTTP(S) origin"
			)
		}
		self = site
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(origin)
	}
}

/// Automatic PiP is on for every ordinary site unless the profile turned it off for that
/// exact origin. Private sources never qualify. `enabledSites` keeps earlier explicit opt-ins.
/// A tab's own choice (DEV-1246) wins over its site's.
public struct AutomaticPiPPreferences: Equatable, Codable, Sendable {
	/// What floats when a tab's media goes into Picture in Picture on its own.
	public enum Kind: String, CaseIterable, Codable, Sendable {
		/// The video alone, in the system's Picture in Picture window.
		case video

		/// The whole live page, in Page PiP (DEV-950).
		case page
	}

	/// How one tab behaves, set from its context menu. Nil fields follow Arx's defaults.
	public struct TabChoice: Hashable, Codable, Sendable {
		/// On or off for this tab, whatever its site's setting; nil follows the site.
		public var isAutomatic: Bool?

		/// What floats; nil lets Arx pick: Page PiP for a call, the video otherwise.
		public var kind: Kind?

		public init(
			isAutomatic: Bool? = nil,
			kind: Kind? = nil
		) {
			self.isAutomatic = isAutomatic
			self.kind = kind
		}

		/// Whether it follows Arx's defaults in every respect, and so needn't be stored.
		public var isDefault: Bool { isAutomatic == nil && kind == nil }
	}

	public struct Site: Hashable, Codable, Sendable {
		public var profileID: Profile.ID
		public var site: MediaSite

		public init(
			profileID: Profile.ID,
			site: MediaSite
		) {
			self.profileID = profileID
			self.site = site
		}
	}

	/// Leaving a tab with playing video opens PiP. Off turns it off for every site.
	public var isEnabled: Bool

	/// Coming back to the video's tab closes its PiP.
	public var closesOnReturn: Bool
	public var enabledSites: Set<Site>
	public var disabledSites: Set<Site>

	/// Tabs with a choice of their own (DEV-1246).
	public var tabs: [Tab.ID: TabChoice]

	public init(
		isEnabled: Bool = true,
		closesOnReturn: Bool = true,
		enabledSites: Set<Site> = [],
		disabledSites: Set<Site> = [],
		tabs: [Tab.ID: TabChoice] = [:]
	) {
		self.isEnabled = isEnabled
		self.closesOnReturn = closesOnReturn
		self.enabledSites = enabledSites
		self.disabledSites = disabledSites
		self.tabs = tabs
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
		self.closesOnReturn = try values.decodeIfPresent(Bool.self, forKey: .closesOnReturn) ?? true
		self.enabledSites = try values.decodeIfPresent(Set<Site>.self, forKey: .enabledSites) ?? []
		self.disabledSites = try values.decodeIfPresent(Set<Site>.self, forKey: .disabledSites) ?? []
		self.tabs = try values.decodeIfPresent([Tab.ID: TabChoice].self, forKey: .tabs) ?? [:]
	}

	/// Whether `source` may float on its own: automatic PiP is on, the source isn't private, and
	/// its tab's choice, or failing that its site's setting, allows it.
	public func permits(_ source: BrowserMediaSource) -> Bool {
		guard isEnabled, !source.isPrivate, let site = source.site else { return false }
		if let isAutomatic = tabs[source.id.tabID]?.isAutomatic { return isAutomatic }
		return !disabledSites.contains(.init(profileID: source.id.profileID, site: site))
	}

	/// What floats for `source`: its tab's choice, or Page PiP for a call (DEV-1246) and the
	/// video otherwise.
	public func kind(for source: BrowserMediaSource) -> Kind {
		tabs[source.id.tabID]?.kind ?? (source.isCall ? .page : .video)
	}

	/// The choice `tabID` has, or the default one.
	public func choice(for tabID: Tab.ID) -> TabChoice {
		tabs[tabID] ?? .init()
	}

	/// Sets `tabID`'s choice; the default one is forgotten rather than stored.
	public mutating func setChoice(
		_ choice: TabChoice,
		for tabID: Tab.ID
	) {
		tabs[tabID] = choice.isDefault ? nil : choice
	}

	@discardableResult
	public mutating func setEnabled(
		_ enabled: Bool,
		for source: BrowserMediaSource
	) -> Bool {
		guard !source.isPrivate, let site = source.site else { return false }
		let value = Site(profileID: source.id.profileID, site: site)
		if enabled {
			disabledSites.remove(value)
		} else {
			enabledSites.remove(value)
			disabledSites.insert(value)
		}
		return true
	}
}
