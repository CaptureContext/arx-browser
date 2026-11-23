import Foundation

/// A single local substitution. Ordering is the preference between alternatives: of the enabled
/// rules that match a link, the first one wins.
public struct ProxyLinkRule: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var name: String
	public var sourceHosts: [String]
	public var destinationTemplate: String
	public var isEnabled: Bool

	public init(
		id: UUID,
		name: String,
		sourceHosts: [String],
		destinationTemplate: String,
		isEnabled: Bool = true
	) {
		self.id = id
		self.name = name
		self.sourceHosts = sourceHosts
		self.destinationTemplate = destinationTemplate
		self.isEnabled = isEnabled
	}

	public var representation: String {
		let hosts = sourceHosts.map { "\"\($0)\"" }.joined(separator: ", ")
		return "host(\(hosts)) => \"\(destinationTemplate)\""
	}

	/// Whether the rule carries a link's subdomain over with `{subdomain}`. Such a rule also
	/// matches its hosts' subdomains; any other matches its hosts exactly (DEV-1003).
	public var keepsSubdomains: Bool {
		destinationTemplate.contains("{subdomain}")
	}

	/// The rules Arx starts with, so shared links embed in chats (DEV-1003). Their IDs are fixed,
	/// so two Macs that each add them sync one copy.
	public static let defaults: [Self] = [
		.init(
			id: UUID(uuidString: "09BDE0F5-A343-49E7-9239-13F8D2BC190C")!,
			name: "Instagram (kkinstagram)",
			sourceHosts: ["instagram.com", "www.instagram.com"],
			destinationTemplate: "https://kkinstagram.com{path}{query}{fragment}"
		),
		.init(
			id: UUID(uuidString: "3F521615-D938-4AEE-A393-49124D63370A")!,
			name: "X (fxtwitter)",
			sourceHosts: ["x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"],
			destinationTemplate: "https://fxtwitter.com{path}{query}{fragment}"
		),
		.init(
			id: UUID(uuidString: "F779B43F-6420-4637-9B24-CE1E3298DF69")!,
			name: "TikTok (vxtiktok)",
			sourceHosts: ["tiktok.com"],
			destinationTemplate: "https://{subdomain}vxtiktok.com{path}{query}{fragment}"
		),
	]

	/// Whether `id` is one of the rules Arx ships.
	public static func isDefault(_ id: UUID) -> Bool {
		defaults.contains { $0.id == id }
	}

	/// The removed defaults after deleting the rule `id`: a default joins them, sorted, so it
	/// isn't offered again (DEV-1113). Any other rule leaves them as they are.
	public static func removedDefaults(
		_ removed: [UUID],
		deleting id: UUID
	) -> [UUID] {
		guard isDefault(id), !removed.contains(id) else { return removed }

		return (removed + [id]).sorted { $0.uuidString < $1.uuidString }
	}

	/// `rules` with every default back as Arx ships it: one the person changed is reset in place,
	/// and one they removed returns after their own rules, so theirs stay preferred.
	public static func restoringDefaults(_ rules: [Self]) -> [Self] {
		var restored: [Self] = rules.map { rule in
			defaults.first { $0.id == rule.id } ?? rule
		}
		for rule in defaults where !restored.contains(where: { $0.id == rule.id }) {
			restored.append(rule)
		}
		return restored
	}

	/// The source host a link on `host` matches: `host` itself, or for a rule that keeps
	/// subdomains, the longest source host it's a subdomain of. `host` is normalized.
	internal func sourceHost(matching host: String) -> String? {
		let hosts: [String] = sourceHosts.compactMap { try? Self.normalizedHost($0) }
		if hosts.contains(host) { return host }
		guard keepsSubdomains else { return nil }

		return hosts
			.filter { host.hasSuffix("." + $0) }
			.max { $0.count < $1.count }
	}

	/// Whether the rule, on or off, already handles links on `host`.
	public func covers(host: String) -> Bool {
		guard let normalized = try? Self.normalizedHost(host) else { return false }
		return sourceHost(matching: normalized) != nil
	}

	public func validate() throws {
		guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sourceHosts.isEmpty
		else { throw LinkTransformationError.invalidRule }
		for host in sourceHosts { _ = try Self.normalizedHost(host) }

		var remainder = destinationTemplate
		for placeholder in ["{subdomain}", "{host}", "{path}", "{query}", "{fragment}"] {
			guard remainder.components(separatedBy: placeholder).count <= 2
			else { throw LinkTransformationError.invalidTemplate }
			remainder = remainder.replacingOccurrences(of: placeholder, with: "")
		}
		guard !remainder.contains("{"), !remainder.contains("}")
		else { throw LinkTransformationError.invalidTemplate }

		let sample = Self.normalizedTemplate(destinationTemplate)
			.replacingOccurrences(of: "{subdomain}", with: "arx-sub.")
			.replacingOccurrences(of: "{host}", with: "arx-host.example")
			.replacingOccurrences(of: "{path}", with: "/__arx_path__")
			.replacingOccurrences(of: "{query}", with: "?__arx_query__")
			.replacingOccurrences(of: "{fragment}", with: "#__arx_fragment__")
		let parts = try LinkURLParts(sample)

		// `{subdomain}` starts the destination host, as `vm.` does in `vm.vxtiktok.com`.
		guard
			!keepsSubdomains || parts.host.hasPrefix("arx-sub."),
			!destinationTemplate.contains("{host}") || parts.host.contains("arx-host.example"),
			!destinationTemplate.contains("{path}") || parts.path.contains("/__arx_path__"),
			!destinationTemplate.contains("{query}") || parts.query == "?__arx_query__",
			!destinationTemplate.contains("{fragment}") || parts.fragment == "#__arx_fragment__"
		else { throw LinkTransformationError.invalidTemplate }
	}

	/// `{path}` brings its own leading slash, so a template written `/{path}` shouldn't double it.
	public static func normalizedTemplate(_ template: String) -> String {
		template.replacingOccurrences(of: "/{path}", with: "{path}")
	}

	public func matches(_ url: URL) -> Bool {
		guard isEnabled, let parts = try? LinkURLParts(url.absoluteString)
		else { return false }

		return sourceHost(matching: parts.host) != nil
	}

	public static func normalizedHost(_ host: String) throws -> String {
		guard
			!host.isEmpty,
			host == host.trimmingCharacters(in: .whitespacesAndNewlines),
			!host.contains(where: { "/?#@:[]%\\".contains($0) || $0.isWhitespace }),
			let url = URL(string: "https://\(host)"),
			let normalized = url.host(percentEncoded: false)?.lowercased(),
			!normalized.isEmpty
		else { throw LinkTransformationError.invalidHost }
		let result = normalized.hasSuffix(".") ? String(normalized.dropLast()) : normalized
		let labels = result.split(separator: ".", omittingEmptySubsequences: false)
		let areLabelsValid = labels.allSatisfy { label in
			!label.isEmpty
			&& label.utf8.count <= 63
			&& label.first != "-"
			&& label.last != "-"
			&& label.utf8.allSatisfy { (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 }
		}

		guard
			!result.isEmpty,
			result.utf8.count <= 253,
			areLabelsValid
		else { throw LinkTransformationError.invalidHost }

		return result
	}
}

public enum LinkTransformationError: Error, Equatable, Sendable {
	case invalidURL
	case unsupportedScheme
	case credentialsNotAllowed
	case nonstandardPort
	case invalidHost
	case invalidRule
	case invalidTemplate
	case missingPreferredRule
	case duplicateRule
}

/// Preserve encoded components without URLComponents reserializing query items.
internal struct LinkURLParts {
	internal let url: URL
	internal let host: String
	internal let prefix: String
	internal let path: String
	internal let query: String
	internal let fragment: String

	internal init(_ string: String) throws {
		guard
			let url = URL(string: string, encodingInvalidCharacters: false),
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let scheme = components.scheme?.lowercased(),
			let host = url.host(percentEncoded: false),
			!host.isEmpty,
			let authority = string.range(of: "://")
		else { throw LinkTransformationError.invalidURL }
		guard scheme == "http" || scheme == "https"
		else { throw LinkTransformationError.unsupportedScheme }
		guard components.user == nil, components.password == nil
		else { throw LinkTransformationError.credentialsNotAllowed }
		guard components.port == nil || components.port == (scheme == "https" ? 443 : 80)
		else { throw LinkTransformationError.nonstandardPort }

		let fragmentStart = string.firstIndex(of: "#") ?? string.endIndex
		let beforeFragment = string[..<fragmentStart]
		let queryStart = beforeFragment.firstIndex(of: "?") ?? fragmentStart
		let pathStart = string[authority.upperBound..<queryStart].firstIndex(of: "/") ?? queryStart
		self.url = url
		self.host = try ProxyLinkRule.normalizedHost(host)
		self.prefix = String(string[..<queryStart])
		self.path = String(string[pathStart..<queryStart])
		self.query = String(string[queryStart..<fragmentStart])
		self.fragment = String(string[fragmentStart...])
	}
}
