import Foundation

/// Turns Adblock Plus–style filter lists, the syntax uBlock Origin's lists use, into WebKit
/// content rules (DEV-877), so WebKit pages block what Chromium pages' uBlock Origin blocks.
///
/// It converts what WebKit can express: network filters with `||`, `|` and `^` anchors and `*`,
/// their `third-party`, resource type and `domain=` options, exceptions, `$document` and
/// `$generichide` exceptions for a site, and element hiding. Regular-expression filters,
/// scriptlets, redirects, `removeparam` and uBlock's procedural selectors are left out.
public struct ContentRuleConverter: Sendable {
	/// WebKit compiles at most 150 000 rules into one list; this leaves room for exceptions.
	public static let ruleLimit: Int = 140_000

	/// How many generic element-hiding selectors share one rule.
	public static let selectorsPerRule: Int = 50

	/// Changes whenever the same list converts differently, so lists compiled by an older
	/// conversion compile again. 2: entity-domain-only filters left out (DEV-1202).
	public static let revision: Int = 2

	public init() {}

	/// One WebKit content rule.
	public struct Rule: Encodable, Equatable, Sendable {
		public struct Trigger: Encodable, Equatable, Sendable {
			public var urlFilter: String
			public var resourceType: [String]?
			public var loadType: [String]?
			public var loadContext: [String]?
			public var ifDomain: [String]?
			public var unlessDomain: [String]?

			public init(
				urlFilter: String,
				resourceType: [String]? = nil,
				loadType: [String]? = nil,
				loadContext: [String]? = nil,
				ifDomain: [String]? = nil,
				unlessDomain: [String]? = nil
			) {
				self.urlFilter = urlFilter
				self.resourceType = resourceType
				self.loadType = loadType
				self.loadContext = loadContext
				self.ifDomain = ifDomain
				self.unlessDomain = unlessDomain
			}

			private enum CodingKeys: String, CodingKey {
				case urlFilter = "url-filter"
				case resourceType = "resource-type"
				case loadType = "load-type"
				case loadContext = "load-context"
				case ifDomain = "if-domain"
				case unlessDomain = "unless-domain"
			}
		}

		public struct Action: Encodable, Equatable, Sendable {
			public var type: String
			public var selector: String?

			public init(
				type: String,
				selector: String? = nil
			) {
				self.type = type
				self.selector = selector
			}
		}

		public var trigger: Trigger
		public var action: Action

		public init(
			trigger: Trigger,
			action: Action
		) {
			self.trigger = trigger
			self.action = action
		}
	}

	/// A list's rules. WebKit's `ignore-previous-rules` undoes every rule before it that the
	/// same request matches, so the order keeps each exception to what it means: element hiding,
	/// then the sites with element hiding off, then network blocking, then network and whole-site
	/// exceptions.
	public struct Conversion: Equatable, Sendable {
		public var hiding: [Rule]

		/// `$elemhide` and `$generichide`: element hiding off for a site, blocking still on.
		public var hidingExceptions: [Rule]
		public var blocking: [Rule]
		public var exceptions: [Rule]

		public init(
			hiding: [Rule] = [],
			hidingExceptions: [Rule] = [],
			blocking: [Rule] = [],
			exceptions: [Rule] = []
		) {
			self.hiding = hiding
			self.hidingExceptions = hidingExceptions
			self.blocking = blocking
			self.exceptions = exceptions
		}

		/// Every exception, and as many blocking and hiding rules as fit the limit (blocking
		/// first), in WebKit's order.
		public func rules(limit: Int = ContentRuleConverter.ruleLimit) -> [Rule] {
			let exceptions = Array(exceptions.prefix(limit))
			let hidingExceptions = Array(self.hidingExceptions.prefix(max(0, limit - exceptions.count)))
			var room = max(0, limit - exceptions.count - hidingExceptions.count)
			let blocking = Array(self.blocking.prefix(room))
			room -= blocking.count
			let hiding = Array(self.hiding.prefix(room))
			return hiding + hidingExceptions + blocking + exceptions
		}
	}

	public func convert(_ text: String) -> Conversion {
		var conversion = Conversion()
		var genericSelectors: [String] = []
		text.enumerateLines { line, _ in
			let filter = line.trimmingCharacters(in: .whitespaces)
			guard
				!filter.isEmpty,
				!filter.hasPrefix("!"),
				!filter.hasPrefix("["),
				filter.allSatisfy(\.isASCII)
			else { return }

			if let range = filter.range(of: "##") {
				guard let hiding = Self.hiding(filter, separator: range) else { return }
				switch hiding {
				case let .generic(selector):
					genericSelectors.append(selector)

				case let .specific(rule):
					conversion.hiding.append(rule)
				}
				return
			}

			// Other cosmetic and scriptlet syntaxes: #@#, #?#, #$#, #%#, ##+js, $$ and friends.
			if filter.contains("#@#") || filter.contains("#?#") || filter.contains("#$#")
				|| filter.contains("#%#") || filter.contains("$$") { return }

			guard let network = Self.network(filter) else { return }
			switch network.kind {
			case .blocking: conversion.blocking.append(network.rule)
			case .exception: conversion.exceptions.append(network.rule)
			case .hidingException: conversion.hidingExceptions.append(network.rule)
			}
		}
		for start in stride(from: 0, to: genericSelectors.count, by: Self.selectorsPerRule) {
			let batch = genericSelectors[start ..< min(start + Self.selectorsPerRule, genericSelectors.count)]
			conversion.hiding.append(.init(
				trigger: .init(urlFilter: ".*"),
				action: .init(type: "css-display-none", selector: batch.joined(separator: ", "))
			))
		}
		return conversion
	}

	/// The rules as the JSON `WKContentRuleListStore` compiles.
	public static func json(_ rules: [Rule]) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return String(decoding: try encoder.encode(rules), as: UTF8.self)
	}

	// MARK: - Element hiding

	private enum Hiding {
		case generic(String)
		case specific(Rule)
	}

	private static func hiding(
		_ filter: String,
		separator: Range<String.Index>
	) -> Hiding? {
		let domains = String(filter[..<separator.lowerBound])
		let selector = String(filter[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
		guard isPlainSelector(selector) else { return nil }
		guard !domains.isEmpty else { return .generic(selector) }
		guard let scope = domainScope(domains.split(separator: ",").map(String.init))
		else { return nil }

		return .specific(.init(
			trigger: .init(urlFilter: ".*", ifDomain: scope.ifDomain, unlessDomain: scope.unlessDomain),
			action: .init(type: "css-display-none", selector: selector)
		))
	}

	/// A selector WebKit's CSS understands: none of uBlock's procedural operators or scriptlets.
	internal static func isPlainSelector(_ selector: String) -> Bool {
		guard
			!selector.isEmpty,
			!selector.hasPrefix("+js("),
			!selector.hasPrefix("^")
		else { return false }
		let procedural = [
			":has-text(", ":xpath(", ":matches-css", ":matches-attr(", ":matches-path(", ":matches-prop(",
			":min-text-length(", ":upward(", ":remove(", ":style(", ":watch-attr(", ":-abp-", ":others(",
			":remove-attr(", ":remove-class(", ":nth-ancestor(", ":if(", ":if-not(", ":contains(",
		]
		return !procedural.contains { selector.contains($0) }
	}

	// MARK: - Network filters

	private enum NetworkKind {
		case blocking
		case exception
		case hidingException
	}

	private static func network(_ line: String) -> (rule: Rule, kind: NetworkKind)? {
		var filter = Substring(line)
		let isException = filter.hasPrefix("@@")
		if isException { filter = filter.dropFirst(2) }

		var options: [Substring] = []

		// A regular expression filter (`/…/`) is left out; WebKit's patterns are a small subset.
		if filter.hasPrefix("/"), filter.count > 1 {
			let body = filter.split(separator: "$", maxSplits: 1).first ?? filter
			if body.hasSuffix("/") { return nil }
		}
		if let dollar = filter.lastIndex(of: "$") {
			options = filter[filter.index(after: dollar)...].split(separator: ",")
			filter = filter[..<dollar]
		}

		var resourceTypes: Set<String> = []
		var loadType: [String]?
		var loadContext: [String]?
		var domains: DomainScope?
		var wholeSite = false
		var hidingOnly = false
		for option in options {
			let name = option.lowercased()
			switch name {
			case "third-party", "3p": loadType = ["third-party"]

			case "~third-party", "1p", "first-party", "~3p": loadType = ["first-party"]

			case "script": resourceTypes.insert("script")

			case "image": resourceTypes.insert("image")

			case "stylesheet", "css": resourceTypes.insert("style-sheet")

			case "font": resourceTypes.insert("font")

			case "media": resourceTypes.insert("media")

			case "xmlhttprequest", "xhr": resourceTypes.insert("fetch")

			case "websocket": resourceTypes.insert("websocket")

			case "ping", "beacon": resourceTypes.insert("ping")

			case "other": resourceTypes.insert("other")

			case "popup": resourceTypes.insert("popup")

			case "subdocument", "frame":
				resourceTypes.insert("document")
				loadContext = ["child-frame"]

			case "important", "match-case", "all": continue

			case "document", "doc":
				// Only an exception can name a whole site; blocking a document isn't converted.
				guard isException else { return nil }
				wholeSite = true

			case "elemhide", "ehide", "generichide", "ghide":
				// Element hiding off for the site; its network blocking stays.
				guard isException else { return nil }
				wholeSite = true
				hidingOnly = true

			default:
				guard name.hasPrefix("domain=") || name.hasPrefix("from=") else { return nil }
				let list = name.drop { $0 != "=" }.dropFirst().split(separator: "|").map(String.init)
				guard let scope = domainScope(list) else { return nil }
				domains = scope
			}
		}

		if wholeSite {
			guard let host = siteHost(filter) else { return nil }
			return (
				.init(
					trigger: .init(urlFilter: ".*", ifDomain: ["*" + host]),
					action: .init(type: "ignore-previous-rules")
				),
				hidingOnly ? .hidingException : .exception
			)
		}

		guard let pattern = urlFilter(filter) else { return nil }

		// A filter matching every address needs a domain to be safe.
		if pattern == ".*", domains == nil { return nil }
		let rule = Rule(
			trigger: .init(
				urlFilter: pattern,
				resourceType: resourceTypes.isEmpty ? nil : resourceTypes.sorted(),
				loadType: loadType,
				loadContext: loadContext,
				ifDomain: domains?.ifDomain,
				unlessDomain: domains?.unlessDomain
			),
			action: .init(type: isException ? "ignore-previous-rules" : "block")
		)
		return (rule, isException ? .exception : .blocking)
	}

	/// `||host^` as a host, for site-wide exceptions.
	private static func siteHost(_ filter: Substring) -> String? {
		guard filter.hasPrefix("||") else { return nil }
		var host = filter.dropFirst(2)
		if host.hasSuffix("^") { host = host.dropLast() }
		guard
			!host.isEmpty,
			host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
		else { return nil }

		return host.lowercased()
	}

	/// An ABP pattern as a WebKit `url-filter`, or nil when it can't be expressed.
	internal static func urlFilter(_ filter: Substring) -> String? {
		var pattern = filter
		var result = ""
		var hostAnchored = false
		if pattern.hasPrefix("||") {
			result = "^[^:]+://+([^:/]+\\.)?"
			pattern = pattern.dropFirst(2)
			hostAnchored = true
		} else if pattern.hasPrefix("|") {
			result = "^"
			pattern = pattern.dropFirst()
		}
		var endAnchored = false
		if pattern.hasSuffix("|") {
			endAnchored = true
			pattern = pattern.dropLast()
		}
		if pattern.isEmpty { return result.isEmpty ? ".*" : nil }

		var inHost = hostAnchored
		for character in pattern {
			switch character {
			case "*":
				result += ".*"
				inHost = false

			case "^":
				// After a host, the separator is the port's colon or the path's slash.
				result += inHost ? "[/:]" : "[^a-zA-Z0-9_.%-]"
				inHost = false

			case "/", "?", "=", "&":
				if character == "?" {
					result += "\\?"
				} else {
					result += String(character)
				}
				inHost = false

			case ".", "+", "(", ")", "[", "]", "{", "}", "\\", "$":
				result += "\\" + String(character)

			case "|":
				// A bar inside a pattern would be alternation, which WebKit doesn't have.
				return nil

			default:
				result.append(character)
			}
		}
		if endAnchored { result += "$" }

		// Leading wildcards add nothing; WebKit matches anywhere unless anchored.
		while result.hasPrefix(".*"), result.count > 2 { result.removeFirst(2) }
		return result
	}

	// MARK: - Domains

	internal struct DomainScope: Equatable {
		internal var ifDomain: [String]?
		internal var unlessDomain: [String]?
	}

	/// `example.com|~ads.example.com` as WebKit domains. WebKit takes either the included or
	/// the excluded domains, not both. Entity domains (`example.*`) and other names WebKit can't
	/// match are skipped, and a filter that skipping would widen isn't converted (DEV-1202).
	internal static func domainScope(_ entries: [String]) -> DomainScope? {
		var included: [String] = []
		var excluded: [String] = []
		var skippedIncluded = false
		for entry in entries {
			let entry = entry.trimmingCharacters(in: .whitespaces).lowercased()
			let isExcluded = entry.hasPrefix("~")
			let domain = isExcluded ? String(entry.dropFirst()) : entry
			guard
				!domain.isEmpty,
				!domain.hasSuffix(".*"),
				domain.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
			else {
				skippedIncluded = skippedIncluded || !isExcluded
				continue
			}

			if isExcluded {
				excluded.append("*" + domain)
			} else {
				included.append("*" + domain)
			}
		}

		// WebKit can't say "these domains except those", and leaving out either half would block
		// where the list doesn't: such filters aren't converted.
		if !included.isEmpty, !excluded.isEmpty { return nil }

		// Fewer included sites only narrow a filter.
		if !included.isEmpty { return .init(ifDomain: included) }

		// A filter for skipped sites only would otherwise apply everywhere but its exceptions:
		// `*$script,1p,domain=kat.*|~kat.ai` blocked every site's own scripts. A skipped
		// exception (`~[::1]`) only applies a filter on that one more site, so it stays.
		guard !skippedIncluded else { return nil }
		if !excluded.isEmpty { return .init(unlessDomain: excluded) }
		return nil
	}
}
