import BrowserCore
import Foundation

/// The portable `BrowserPreferences` domains: each is one synced ``PreferenceRecord`` holding these
/// coding keys. The four lists users add to concurrently are rows of their own instead (ADR 0001,
/// section 4), and every key not listed here is device-local, so a field added later stays on this
/// Mac until someone decides it's portable.
public enum PreferenceDomain: String, CaseIterable, Sendable {
	case appearance
	case links
	case littleArx
	case routing
	case commandBar

	public var keys: [String] {
		switch self {
		case .appearance:
			["appIcon", "appTheme", "chromeAccent", "chromeMatchesSite", "chromeTint", "darkPages", "grainEnabled", "grainIntensity", "grainSize", "identityCardStyle", "sidebarPosition"]

		case .links:
			[
				"crossSiteLinkFromFavorites",
				"crossSiteLinkFromPinnedTabs",
				"forceClickLinkAction",
				"littleArxLinkBinding",
				"newTabPlacement",
				"openedTabPlacement",
				"shiftClickLinkAction",
				"showsLinkStatus",
				"switchesToLinkTabs",
			]

		case .littleArx:
			["globalLittleArxEnabled", "littleArxArchiveInterval", "littleArxLauncherPosition", "runwayAppearance"]

		case .routing:
			// Without its `rules`, which are `routingRule` rows. The deleted default Proxy Links
			// rules sync with them, so no Mac offers one again (DEV-1113).
			["removedProxyLinkDefaults", "routing"]

		case .commandBar:
			["closesCommandBarOnEmptyDelete", "commandAliases"]
		}
	}

	/// Coding keys kept out of both domains and local rows because they're rows of their own.
	internal static let listKeys: Set<String> = ["keyboardShortcuts", "proxyLinkRules", "searchShortcuts"]
}

/// `BrowserPreferences` as the preferences database's rows, and back.
public struct PreferenceRows: Equatable, Sendable {
	public var domains: [String: PreferenceRecord]
	public var searchShortcuts: [String: SearchShortcutRecord]
	public var keyboardShortcuts: [String: KeyboardShortcutRecord]
	public var routingRules: [UUID: RoutingRuleRecord]
	public var proxyLinkRules: [UUID: ProxyLinkRuleRecord]
	public var local: [String: LocalPreferenceRecord]

	public init(
		domains: [String: PreferenceRecord] = [:],
		searchShortcuts: [String: SearchShortcutRecord] = [:],
		keyboardShortcuts: [String: KeyboardShortcutRecord] = [:],
		routingRules: [UUID: RoutingRuleRecord] = [:],
		proxyLinkRules: [UUID: ProxyLinkRuleRecord] = [:],
		local: [String: LocalPreferenceRecord] = [:]
	) {
		self.domains = domains
		self.searchShortcuts = searchShortcuts
		self.keyboardShortcuts = keyboardShortcuts
		self.routingRules = routingRules
		self.proxyLinkRules = proxyLinkRules
		self.local = local
	}

	/// The rows for `preferences`, keeping `previous`'s list positions where the order allows.
	public init(
		_ preferences: BrowserPreferences,
		previous: Self = .init()
	) throws {
		self.init()
		guard var fields = try JSONColumn.deserialize(JSONColumn.encode(preferences)) as? [String: Any]
		else { throw ReadError.notAnObject }

		if var routing = fields["routing"] as? [String: Any] {
			routing.removeValue(forKey: "rules")
			fields["routing"] = routing
		}
		for key in PreferenceDomain.listKeys {
			fields.removeValue(forKey: key)
		}
		for domain in PreferenceDomain.allCases {
			var members: [String: Any] = [:]
			for key in domain.keys {
				members[key] = fields.removeValue(forKey: key)
			}
			domains[domain.rawValue] = .init(id: domain.rawValue, value: try JSONColumn.serialize(members))
		}

		// Dictionaries keyed by IDs encode as `[key, value, ...]` in hash order; sort them so an
		// unchanged value is unchanged text.
		fields["tabsLastViewed"] = fields["tabsLastViewed"].map(Self.sortingPairs)
		fields["unreadBadgeTabs"] = fields["unreadBadgeTabs"].map(Self.sortingPairs)
		if var translation = fields["translation"] as? [String: Any] {
			translation["profiles"] = translation["profiles"].map(Self.sortingPairs)
			fields["translation"] = translation
		}
		for (key, value) in fields {
			local[key] = .init(id: key, value: try JSONColumn.serialize(value))
		}
		try addLists(preferences, previous: previous)
	}

	private mutating func addLists(
		_ preferences: BrowserPreferences,
		previous: Self
	) throws {
		let shortcutIDs: [String] = preferences.searchShortcuts.map(\.id)
		let shortcutPositions: [String] = OrderedPositions.assign(
			shortcutIDs,
			previous: previous.searchShortcuts.mapValues(\.position)
		)
		for (shortcut, position) in zip(preferences.searchShortcuts, shortcutPositions) {
			searchShortcuts[shortcut.id] = .init(
				id: shortcut.id,
				keyword: shortcut.keyword,
				name: shortcut.name,
				template: shortcut.template,
				homepage: shortcut.homepage?.absoluteString,
				isEnabled: shortcut.isEnabled,
				position: position
			)
		}

		// One row per command, in the order each command first appears.
		var commands: [BrowserCommand] = []
		var bindings: [BrowserCommand: [KeyboardShortcut?]] = [:]
		for binding in preferences.keyboardShortcuts {
			if bindings[binding.command] == nil { commands.append(binding.command) }
			bindings[binding.command, default: []].append(binding.shortcut)
		}
		let commandPositions: [String] = OrderedPositions.assign(
			commands.map(\.rawValue),
			previous: previous.keyboardShortcuts.mapValues(\.position)
		)
		for (command, position) in zip(commands, commandPositions) {
			keyboardShortcuts[command.rawValue] = .init(
				id: command.rawValue,
				bindings: try JSONColumn.encode(bindings[command] ?? []),
				position: position
			)
		}

		let rules: [RoutingRule] = preferences.routing.rules
		let rulePositions: [String] = OrderedPositions.assign(
			rules.map(\.id),
			previous: previous.routingRules.mapValues(\.position)
		)
		for (rule, position) in zip(rules, rulePositions) {
			routingRules[rule.id] = .init(
				id: rule.id,
				name: rule.name,
				host: rule.host,
				includesSubdomains: rule.includesSubdomains,
				scheme: rule.scheme,
				port: rule.port,
				pathPrefix: rule.pathPrefix,
				destination: try JSONColumn.encode(rule.destination),
				isEnabled: rule.isEnabled,
				position: position
			)
		}

		let proxyPositions: [String] = OrderedPositions.assign(
			preferences.proxyLinkRules.map(\.id),
			previous: previous.proxyLinkRules.mapValues(\.position)
		)
		for (rule, position) in zip(preferences.proxyLinkRules, proxyPositions) {
			proxyLinkRules[rule.id] = .init(
				id: rule.id,
				name: rule.name,
				sourceHosts: try JSONColumn.encode(rule.sourceHosts),
				destinationTemplate: rule.destinationTemplate,
				isEnabled: rule.isEnabled,
				position: position
			)
		}
	}

	/// The preferences these rows describe. Fields with no row take `BrowserPreferences`' defaults for
	/// missing fields, as an older JSON snapshot's would; the caller validates the result.
	public func preferences() throws -> BrowserPreferences {
		var fields: [String: Any] = [:]
		let overrides: Set<PreferenceGroup> = localGroups
		for record in local.values where !record.id.hasPrefix(PreferenceGroup.overridePrefix) {
			fields[record.id] = try JSONColumn.deserialize(record.value)
		}
		for record in domains.values {
			guard let members = try JSONColumn.deserialize(record.value) as? [String: Any]
			else { throw ReadError.notAnObject }

			fields.merge(members) { _, domain in domain }
		}
		var routing: [String: Any] = fields["routing"] as? [String: Any] ?? [:]
		routing["rules"] = []
		fields["routing"] = routing
		fields["searchShortcuts"] = []
		fields["keyboardShortcuts"] = []
		fields["proxyLinkRules"] = []

		// A group kept on this Mac takes its override's values, never the synced rows' (DEV-982).
		for group in overrides.sorted(by: { $0.rawValue < $1.rawValue }) {
			guard
				let record = local[group.overrideKey],
				let values = try JSONColumn.deserialize(record.value) as? [String: Any]
			else { continue }

			for key in group.codingKeys {
				fields[key] = values[key]
			}
		}

		let data: Data = try JSONSerialization.data(withJSONObject: fields)
		var preferences: BrowserPreferences = try JSONDecoder().decode(BrowserPreferences.self, from: data)

		if !overrides.contains(.searchEngines) {
			preferences.searchShortcuts = try searchShortcuts.values
				.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
				.map { record in
					.init(
						name: record.name,
						keyword: record.keyword,
						template: record.template,
						homepage: try record.homepage.map(Self.url),
						isEnabled: record.isEnabled
					)
				}
		}
		if !overrides.contains(.shortcuts) {
			preferences.keyboardShortcuts = try keyboardShortcuts.values
				.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
				.flatMap { record -> [ShortcutBinding] in

					// A command this build doesn't know came from a newer one; it can't be bound here.
					guard let command = BrowserCommand(rawValue: record.id) else { return [] }

					return try JSONColumn.decode([KeyboardShortcut?].self, from: record.bindings)
						.map { ShortcutBinding(command: command, shortcut: $0) }
				}
		}
		if !overrides.contains(.routing) {
			preferences.routing.rules = try routingRules.values
				.sorted { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }
				.map { record in
					.init(
						id: record.id,
						name: record.name,
						host: record.host,
						includesSubdomains: record.includesSubdomains,
						scheme: record.scheme,
						port: record.port,
						pathPrefix: record.pathPrefix,
						destination: try JSONColumn.decode(RoutingDestination.self, from: record.destination),
						isEnabled: record.isEnabled
					)
				}
			preferences.proxyLinkRules = try proxyLinkRules.values
				.sorted { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }
				.map { record in
					.init(
						id: record.id,
						name: record.name,
						sourceHosts: try JSONColumn.decode([String].self, from: record.sourceHosts),
						destinationTemplate: record.destinationTemplate,
						isEnabled: record.isEnabled
					)
				}
		}
		return preferences
	}

	public enum ReadError: Error, Equatable, Sendable {
		case notAnObject
		case invalidURL(String)
	}

	/// `[key, value, key, value]` sorted by key, or `value` unchanged when it isn't that shape.
	private static func sortingPairs(_ value: Any) -> Any {
		guard let array = value as? [Any], array.count.isMultiple(of: 2) else { return value }

		var pairs: [(key: String, value: Any)] = []
		for index in stride(from: 0, to: array.count, by: 2) {
			guard let key = array[index] as? String else { return value }

			pairs.append((key, array[index + 1]))
		}
		return pairs.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] as [Any] }
	}

	private static func url(_ text: String) throws -> URL {
		guard let url = URL(string: text) else { throw ReadError.invalidURL(text) }

		return url
	}
}
