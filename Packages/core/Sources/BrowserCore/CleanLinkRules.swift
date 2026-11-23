import Foundation

/// What Copy Clean Link removes (DEV-918), kept as data in `CleanLinkRules.json` so the
/// list can change without code: tracking parameters removed everywhere, name prefixes such
/// as `utm_`, and per-site rules for parameters and path tails that only mean tracking on
/// one site, such as YouTube's `si` or Amazon's `/ref=…`.
///
/// Names compare lowercased. A site's hosts match themselves and their subdomains.
public struct CleanLinkRules: Codable, Equatable, Sendable {
	public struct Site: Codable, Equatable, Sendable {
		public var name: String
		public var hosts: [String]
		public var parameters: [String]
		public var prefixes: [String]

		/// A trailing path segment starting with one of these is dropped, as Amazon's `/ref=…`.
		public var pathSegmentPrefixes: [String]

		public init(
			name: String,
			hosts: [String],
			parameters: [String] = [],
			prefixes: [String] = [],
			pathSegmentPrefixes: [String] = []
		) {
			self.name = name
			self.hosts = hosts
			self.parameters = parameters
			self.prefixes = prefixes
			self.pathSegmentPrefixes = pathSegmentPrefixes
		}

		public init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			self.init(
				name: try container.decode(String.self, forKey: .name),
				hosts: try container.decode([String].self, forKey: .hosts),
				parameters: try container.decodeIfPresent([String].self, forKey: .parameters) ?? [],
				prefixes: try container.decodeIfPresent([String].self, forKey: .prefixes) ?? [],
				pathSegmentPrefixes: try container.decodeIfPresent([String].self, forKey: .pathSegmentPrefixes) ?? []
			)
		}

		/// Whether `host` is one of the site's hosts or below one.
		public func matches(host: String) -> Bool {
			let host = host.lowercased()
			return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
		}
	}

	public var version: Int
	public var parameters: [String]
	public var prefixes: [String]
	public var sites: [Site]

	public init(
		version: Int = 1,
		parameters: [String],
		prefixes: [String] = [],
		sites: [Site] = []
	) {
		self.version = version
		self.parameters = parameters
		self.prefixes = prefixes
		self.sites = sites
	}

	/// The rules shipped in the app. If the file were ever missing or damaged, the short list
	/// Arx had before stands in, so cleaning never removes more than it should; a test
	/// checks that the shipped file decodes.
	public static let bundled: Self = {
		guard
			let url = Bundle.module.url(forResource: "CleanLinkRules", withExtension: "json"),
			let data = try? Data(contentsOf: url),
			let rules = try? JSONDecoder().decode(Self.self, from: data)
		else { return fallback }

		return rules.normalized
	}()

	/// What Copy Clean Link removed before DEV-918.
	public static let fallback: Self = .init(
		parameters: [
			"utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
			"gclid", "dclid", "fbclid", "msclkid", "mc_cid", "mc_eid",
		]
	)

	/// Every name lowercased, so lookups need no further folding.
	public var normalized: Self {
		var rules = self
		rules.parameters = parameters.map { $0.lowercased() }
		rules.prefixes = prefixes.map { $0.lowercased() }
		rules.sites = sites.map { site in
			var site = site
			site.hosts = site.hosts.map { $0.lowercased() }
			site.parameters = site.parameters.map { $0.lowercased() }
			site.prefixes = site.prefixes.map { $0.lowercased() }
			site.pathSegmentPrefixes = site.pathSegmentPrefixes.map { $0.lowercased() }
			return site
		}
		return rules
	}

	/// The site rules that apply on `host`.
	public func sites(for host: String) -> [Site] {
		sites.filter { $0.matches(host: host) }
	}

	/// Whether a parameter named `name` (already lowercased) is tracking on `sites`.
	public func removes(
		_ name: String,
		on sites: [Site]
	) -> Bool {
		parameters.contains(name)
		|| prefixes.contains { name.hasPrefix($0) && name.count > $0.count }
		|| sites.contains { site in
			site.parameters.contains(name)
			|| site.prefixes.contains { name.hasPrefix($0) && name.count > $0.count }
		}
	}
}
