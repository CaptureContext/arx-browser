import Foundation

public enum LinkCopyMode: String, CaseIterable, Equatable, Sendable {
	case original
	case clean
	case markdownOriginal
	case proxy
	case markdownProxy

	/// Copy Proxy Link and its Markdown form, which a proxy link rule has to match (DEV-1262).
	public var isProxy: Bool {
		self == .proxy || self == .markdownProxy
	}
}

public struct LinkCopyItem: Equatable, Sendable {
	public var title: String
	public var url: URL

	public init(
		title: String,
		url: URL
	) {
		self.title = title
		self.url = url
	}
}

public struct LinkTransformation: Equatable, Sendable {
	public var original: LinkCopyItem
	public var output: URL
	public var outcome: Outcome

	public init(
		original: LinkCopyItem,
		output: URL,
		outcome: Outcome
	) {
		self.original = original
		self.output = output
		self.outcome = outcome
	}

	public enum Outcome: Equatable, Sendable {
		case original
		case cleaned([String])
		case sensitiveParametersPreserved
		case noTrackingParameters
		case proxy(ProxyLinkRule)
		case noMatchingRule
		case preserved(LinkTransformationError)
	}
}

public struct LinkCopyResult: Equatable, Sendable {
	public var mode: LinkCopyMode
	public var transformations: [LinkTransformation]
	public var text: String

	public init(
		mode: LinkCopyMode,
		transformations: [LinkTransformation],
		text: String
	) {
		self.mode = mode
		self.transformations = transformations
		self.text = text
	}
}

/// Pure, local transformations. No redirect lookup, navigation or provider request.
public enum LinkTransformer {
	public static func validate(_ url: URL) throws {
		_ = try LinkURLParts(url.absoluteString)
	}

	/// Whether a proxy link rule turns `url` into a proxy link: the link, without its username and
	/// password, is http or https on the default port, and an enabled rule matches its host. The
	/// proxy link items are offered only then (DEV-1262).
	public static func proxies(
		_ url: URL,
		rules: [ProxyLinkRule]
	) -> Bool {
		let link = removingCredentials(.init(title: "", url: url)).url
		guard (try? validate(link)) != nil else { return false }

		return rules.contains { $0.matches(link) }
	}

	/// A `mailto:` link's addresses, as Chromium's Copy Email Address copies them:
	/// without the scheme and query, percent-decoded. Nil for any other link.
	public static func emailAddress(_ url: URL) -> String? {
		guard url.scheme?.lowercased() == "mailto" else { return nil }
		let string = url.absoluteString
		let body = string.dropFirst("mailto:".count).prefix(while: { $0 != "?" })
		let address = String(body).removingPercentEncoding ?? String(body)
		return address.isEmpty ? nil : address
	}

	/// The link without its username and password, for proxy links and anything else
	/// that hands the address on. Copy Link keeps them, as in Chromium (DEV-853).
	public static func removingCredentials(_ item: LinkCopyItem) -> LinkCopyItem {
		guard
			var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false),
			components.user != nil || components.password != nil
		else { return item }
		components.user = nil
		components.password = nil
		guard let url = components.url else { return item }
		return .init(title: item.title, url: url)
	}

	/// The parameters removed on every site; `CleanLinkRules.bundled` has the prefixes and
	/// per-site rules too (DEV-918).
	public static var trackingParameterNames: [String] {
		CleanLinkRules.bundled.parameters
	}

	public static func copy(
		_ items: [LinkCopyItem],
		mode: LinkCopyMode,
		rules: [ProxyLinkRule] = [],
		preferredRuleID: UUID? = nil
	) -> LinkCopyResult {
		let transformations = items.map { item in
			switch mode {
			case .original, .markdownOriginal:
				LinkTransformation(original: item, output: item.url, outcome: .original)
			case .clean:
				clean(item)
			case .proxy, .markdownProxy:
				proxy(item, rules: rules, preferredRuleID: preferredRuleID)
			}
		}
		let markdown = mode == .markdownOriginal || mode == .markdownProxy
		let text = transformations.map { result in
			if mode == .original, let address = emailAddress(result.output) { return address }
			guard markdown else { return result.output.absoluteString }
			let title = result.original.title.isEmpty
			? result.original.url.absoluteString
			: result.original.title
			return "[\(escapeMarkdownTitle(title))](<\(result.output.absoluteString)>)"
		}.joined(separator: "\n")
		return .init(mode: mode, transformations: transformations, text: text)
	}

	/// Removes the tracking parameters `rules` name, and on a site with a path rule its
	/// tracking path tail. Everything else stays byte for byte: other parameters and their
	/// order, empty components, encoded paths and the fragment. A link with a signature or
	/// authentication parameter is never changed.
	public static func clean(
		_ item: LinkCopyItem,
		rules: CleanLinkRules = .bundled
	) -> LinkTransformation {
		do {
			let parts = try LinkURLParts(item.url.absoluteString)
			let sites = rules.sites(for: parts.host)
			let items = parts.query.isEmpty ? [] : parts.query.dropFirst().components(separatedBy: "&")
			let names = items.map {
				String($0.prefix(while: { $0 != "=" })).removingPercentEncoding?.lowercased()
			}
			guard !names.contains(where: { $0 == nil || isSensitiveParameter($0!) }) else {
				return .init(original: item, output: item.url, outcome: .sensitiveParametersPreserved)
			}

			let isRemoved: (String?) -> Bool = { name in
				name.map { !$0.isEmpty && rules.removes($0, on: sites) } ?? false
			}
			var removed: [String] = names.compactMap { $0 }.filter(isRemoved)
			var prefix = parts.prefix
			if let tail = trackingPathTail(parts.path, sites: sites) {
				prefix.removeLast(tail.count)
				removed.append(tail)
			}
			guard !removed.isEmpty else {
				return .init(original: item, output: item.url, outcome: .noTrackingParameters)
			}

			let kept = zip(items, names).filter { !isRemoved($0.1) }.map(\.0)
			let query = kept.isEmpty ? "" : "?" + kept.joined(separator: "&")
			let output = try LinkURLParts(prefix + query + parts.fragment).url
			return .init(original: item, output: output, outcome: .cleaned(removed))
		} catch {
			return .init(
				original: item,
				output: item.url,
				outcome: .preserved(error as? LinkTransformationError ?? .invalidURL)
			)
		}
	}

	/// The last path segment, with its slash, when a site's rule names it as tracking: for
	/// Amazon, `/ref=sr_1_1` in `/dp/B000/ref=sr_1_1`. A path that is only that segment keeps it.
	private static func trackingPathTail(
		_ path: String,
		sites: [CleanLinkRules.Site]
	) -> String? {
		guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return nil }

		let segment = path[path.index(after: slash)...].lowercased()
		let matches = sites.contains { site in
			site.pathSegmentPrefixes.contains { segment.hasPrefix($0) }
		}
		return matches ? String(path[slash...]) : nil
	}

	public static func proxy(
		_ item: LinkCopyItem,
		rules: [ProxyLinkRule],
		preferredRuleID: UUID? = nil
	) -> LinkTransformation {
		do {
			let parts = try LinkURLParts(item.url.absoluteString)
			let matches = rules.filter { $0.matches(item.url) }
			let rule: ProxyLinkRule?
			if let preferredRuleID {
				guard let preferred = matches.first(where: { $0.id == preferredRuleID })
				else { throw LinkTransformationError.missingPreferredRule }
				rule = preferred

			} else {
				rule = matches.first
			}
			guard let rule else {
				return .init(original: item, output: item.url, outcome: .noMatchingRule)
			}
			try rule.validate()

			// What comes before the matched source host, with its dot: `vm.` for `vm.tiktok.com`.
			let subdomain: String = rule.sourceHost(matching: parts.host)
				.map { String(parts.host.dropLast($0.count)) } ?? ""
			let string = ProxyLinkRule.normalizedTemplate(rule.destinationTemplate)
				.replacingOccurrences(of: "{subdomain}", with: subdomain)
				.replacingOccurrences(of: "{host}", with: parts.host)
				.replacingOccurrences(of: "{path}", with: parts.path)
				.replacingOccurrences(of: "{query}", with: parts.query)
				.replacingOccurrences(of: "{fragment}", with: parts.fragment)
			let output = try LinkURLParts(string).url
			return .init(original: item, output: output, outcome: .proxy(rule))
		} catch {
			return .init(
				original: item,
				output: item.url,
				outcome: .preserved(error as? LinkTransformationError ?? .invalidURL)
			)
		}
	}

	private static func isSensitiveParameter(_ name: String) -> Bool {
		let sensitiveNames: [String] = [
			"signature", "sig", "token", "access_token", "id_token", "refresh_token",
			"code", "state", "auth", "authorization", "key", "api_key", "apikey",
			"policy", "expires", "awsaccesskeyid", "credential", "hmac", "jwt",
		]

		return name.hasPrefix("x-amz-")
		|| name.hasPrefix("x-goog-")
		|| sensitiveNames.contains(name)
	}

	private static func escapeMarkdownTitle(_ title: String) -> String {
		title.reduce(into: "") { result, character in
			if character.isNewline {
				result.append(" ")
			} else if "\\`*_{}[]<>()!|".contains(character) {
				result.append("\\\(character)")
			} else {
				result.append(character)
			}
		}
	}
}
