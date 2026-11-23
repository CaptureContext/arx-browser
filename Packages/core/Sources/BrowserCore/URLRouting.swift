import Darwin
import Foundation

public enum RoutingWindowMode: String, Codable, CaseIterable, Sendable {
	case mainBrowser
	case littleArx
}

public struct RoutingDestination: Codable, Equatable, Sendable {
	public var scope: Scope
	public var mode: RoutingWindowMode

	public init(
		scope: Scope,
		mode: RoutingWindowMode = .littleArx
	) {
		self.scope = scope
		self.mode = mode
	}

	public enum Scope: Codable, Equatable, Sendable {
		/// The space used most recently, in any profile.
		case currentSpace

		/// The space of this profile used most recently, else its first space.
		case profile(Profile.ID)
		case space(Space.ID)

		/// Nothing opens until the person picks a destination.
		case ask
	}
}

public struct RoutingRule: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var name: String
	public var host: String
	public var includesSubdomains: Bool
	public var scheme: String?
	public var port: Int?
	public var pathPrefix: String?
	public var destination: RoutingDestination
	public var isEnabled: Bool

	public init(
		id: UUID,
		name: String,
		host: String,
		includesSubdomains: Bool = false,
		scheme: String? = nil,
		port: Int? = nil,
		pathPrefix: String? = nil,
		destination: RoutingDestination,
		isEnabled: Bool = true
	) {
		self.id = id
		self.name = name
		self.host = host
		self.includesSubdomains = includesSubdomains
		self.scheme = scheme
		self.port = port
		self.pathPrefix = pathPrefix
		self.destination = destination
		self.isEnabled = isEnabled
	}

	public func validate() throws {
		guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else { throw URLRoutingError.invalidDefinition }
		_ = try RoutingHost.normalize(host)
		guard scheme == nil || ["http", "https"].contains(scheme)
		else { throw URLRoutingError.invalidDefinition }
		guard port == nil || (1 ... 65_535).contains(port!)
		else { throw URLRoutingError.invalidDefinition }
		if let pathPrefix {
			guard
				pathPrefix.hasPrefix("/"),
				let url = URL(string: "https://capturecontext.dev" + pathPrefix, encodingInvalidCharacters: false),
				let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
				parts.percentEncodedPath == pathPrefix,
				parts.query == nil,
				parts.fragment == nil
			else { throw URLRoutingError.invalidDefinition }
		}
	}

	public func matches(_ url: URL) -> Bool {
		guard
			isEnabled,
			let components = try? RoutingURLComponents(url),
			let source = try? RoutingHost.normalize(host)
		else { return false }
		let matchesHost = components.host == source
		|| (includesSubdomains && components.host.hasSuffix("." + source))
		let matchesScheme = scheme == nil || components.scheme == scheme
		let matchesPort = components.port == (port ?? components.defaultPort)
		let matchesPath = pathPrefix.map { components.path.hasPrefix($0) } ?? true
		return matchesHost && matchesScheme && matchesPort && matchesPath
	}
}

public struct RoutingPreferences: Codable, Equatable, Sendable {
	public var rules: [RoutingRule]

	/// Where links no rule matches open; `nil` asks, as `.ask` does.
	public var fallback: RoutingDestination?

	/// Handlers for pages' links to other apps (DEV-857). Missing before DEV-857.
	public var appLinks: AppLinkPreferences

	public init(
		rules: [RoutingRule] = [],
		fallback: RoutingDestination? = .init(scope: .currentSpace),
		appLinks: AppLinkPreferences = .init()
	) {
		self.rules = rules
		self.fallback = fallback
		self.appLinks = appLinks
	}

	private enum CodingKeys: String, CodingKey {
		case rules
		case fallback
		case appLinks
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.rules = try values.decode([RoutingRule].self, forKey: .rules)

		// Synthesized decoding before DEV-857 read a missing fallback as nil (Ask).
		self.fallback = try values.decodeIfPresent(RoutingDestination.self, forKey: .fallback)

		// Handlers a later Arx can't read are dropped rather than losing every route.
		self.appLinks = (try? values.decodeIfPresent(AppLinkPreferences.self, forKey: .appLinks)) ?? .init()
	}

	public func validate() throws {
		var ids: Set<UUID> = []
		for rule in rules {
			try rule.validate()
			guard ids.insert(rule.id).inserted
			else { throw URLRoutingError.invalidDefinition }
		}
		try appLinks.validate()
	}
}

public struct RoutingTarget: Equatable, Sendable {
	public var profileID: Profile.ID
	public var spaceID: Space.ID
	public var mode: RoutingWindowMode

	public init(
		profileID: Profile.ID,
		spaceID: Space.ID,
		mode: RoutingWindowMode
	) {
		self.profileID = profileID
		self.spaceID = spaceID
		self.mode = mode
	}
}

public struct RoutingDecision: Equatable, Sendable {
	public var url: URL
	public var matchedRuleID: UUID?
	public var destination: RoutingDestination?
	public var result: Result<RoutingTarget, URLRoutingError>

	public init(
		url: URL,
		matchedRuleID: UUID?,
		destination: RoutingDestination?,
		result: Result<RoutingTarget, URLRoutingError>
	) {
		self.url = url
		self.matchedRuleID = matchedRuleID
		self.destination = destination
		self.result = result
	}
}

public enum URLRoutingError: Error, Equatable, Sendable {
	case invalidDefinition
	case unsupportedURL
	case missingDestination
	case missingProfile
	case missingSpace
}

public enum URLRouter {
	public static func decide(
		_ url: URL,
		preferences: RoutingPreferences,
		organization: BrowserOrganization,
		currentSpaceID: Space.ID?,
		recentSpaceIDs: [Space.ID] = [],
		override: RoutingDestination? = nil
	) -> RoutingDecision {
		// DEV-987: a local file opened with Arx. Rules name hosts, so none matches one; it
		// goes where a link no rule matches goes.
		let isLocalFile = Self.isLocalFile(url)
		if !isLocalFile {
			do {
				_ = try RoutingURLComponents(url)
			} catch {
				return .init(
					url: url,
					matchedRuleID: nil,
					destination: nil,
					result: .failure(.unsupportedURL)
				)
			}
		}

		let rule = override == nil && !isLocalFile ? preferences.rules.first(where: { $0.matches(url) }) : nil
		let destination = override ?? rule?.destination ?? preferences.fallback
		let result = Result { () throws(URLRoutingError) -> RoutingTarget in
			guard let destination else { throw .missingDestination }
			return try resolve(
				destination,
				preferences: preferences,
				organization: organization,
				currentSpaceID: currentSpaceID,
				recentSpaceIDs: recentSpaceIDs
			)
		}
		return .init(
			url: url,
			matchedRuleID: rule?.id,
			destination: destination,
			result: result
		)
	}

	/// A `file:` URL on this Mac: no host, or `localhost`, and a path.
	public static func isLocalFile(_ url: URL) -> Bool {
		guard url.scheme?.lowercased() == "file" else { return false }

		let host = url.host(percentEncoded: false) ?? ""
		return (host.isEmpty || host.lowercased() == "localhost") && !url.path(percentEncoded: false).isEmpty
	}

	public static func resolve(
		_ destination: RoutingDestination,
		preferences: RoutingPreferences,
		organization: BrowserOrganization,
		currentSpaceID: Space.ID?,
		recentSpaceIDs: [Space.ID] = []
	) throws(URLRoutingError) -> RoutingTarget {
		let spaceID: Space.ID
		switch destination.scope {
		case .ask:
			throw .missingDestination

		case .currentSpace:
			guard let currentSpaceID else { throw .missingSpace }
			spaceID = currentSpaceID

		case let .space(id):
			spaceID = id

		case let .profile(id):
			guard organization.profiles.ids.contains(id) else { throw .missingProfile }

			// The current space first, then the ones used before it, then the profile's first.
			let recent = (currentSpaceID.map { [$0] } ?? []) + recentSpaceIDs
			guard
				let space = recent.lazy.compactMap({ organization.spaces[id: $0] }).first(where: { $0.profileID == id })
				?? organization.spaces.first(where: { $0.profileID == id })
			else { throw .missingSpace }
			spaceID = space.id
		}
		guard let space = organization.spaces[id: spaceID] else { throw .missingSpace }
		guard organization.profiles.ids.contains(space.profileID) else { throw .missingProfile }
		return .init(profileID: space.profileID, spaceID: space.id, mode: destination.mode)
	}
}

private struct RoutingURLComponents {
	internal let host: String
	internal let scheme: String
	internal let port: Int
	internal let path: String

	internal init(_ url: URL) throws {
		guard
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let scheme = components.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			let host = url.host(percentEncoded: false),
			components.port == nil || (1 ... 65_535).contains(components.port!)
		else { throw URLRoutingError.unsupportedURL }
		self.host = try RoutingHost.normalize(host)
		self.scheme = scheme
		self.port = components.port ?? (scheme == "https" ? 443 : 80)
		self.path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
	}

	internal var defaultPort: Int { scheme == "https" ? 443 : 80 }
}

private enum RoutingHost {
	internal static func normalize(_ host: String) throws -> String {
		let value = host.hasPrefix("[") && host.hasSuffix("]")
		? String(host.dropFirst().dropLast())
		: host
		guard value.contains(":") else { return try ProxyLinkRule.normalizedHost(host) }
		var address = in6_addr()
		guard inet_pton(AF_INET6, value, &address) == 1
		else { throw URLRoutingError.invalidDefinition }

		var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
		guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil
		else { throw URLRoutingError.invalidDefinition }
		return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
	}
}
