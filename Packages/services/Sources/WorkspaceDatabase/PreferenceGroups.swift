import BrowserCore
import Foundation
import _SQLiteData

// MARK: - Preferences groups (DEV-982)

/// A part of Preferences the person can keep on this Mac while the rest syncs (ADR 0001, decision 3).
/// A group kept local holds this Mac's values in an override row of `localPreference`, never writes
/// its synced rows, and doesn't show other Macs' changes to them, which still arrive.
public enum PreferenceGroup: String, CaseIterable, Codable, Hashable, Sendable {
	/// The `appearance`, `links` and `littleArx` domains.
	case appearance

	/// The shared search shortcuts, `searchShortcut` rows. Each profile's search engine follows that
	/// profile's own sync toggle (DEV-981), not this one.
	case searchEngines

	/// `keyboardShortcut` rows and the whole `commandBar` domain, its aliases and its empty-delete
	/// behavior both: one synced row.
	case shortcuts

	/// The `routing` domain, `routingRule` and `proxyLinkRule` rows.
	case routing

	/// The synced domains it covers.
	public var domains: [PreferenceDomain] {
		switch self {
		case .appearance: [.appearance, .links, .littleArx]
		case .searchEngines: []
		case .shortcuts: [.commandBar]
		case .routing: [.routing]
		}
	}

	/// The `BrowserPreferences` coding keys it covers, as its override row holds them.
	public var codingKeys: [String] {
		let lists: [String] = switch self {
		case .appearance: []
		case .searchEngines: ["searchShortcuts"]
		case .shortcuts: ["keyboardShortcuts"]
		case .routing: ["proxyLinkRules"]
		}

		// `routing` itself, with its rules, is the routing domain's one key.
		return domains.flatMap(\.keys) + lists
	}

	/// The `localPreference` row holding this Mac's values while the group is kept local.
	public var overrideKey: String { "\(Self.overridePrefix)\(rawValue)" }

	internal static let overridePrefix: String = "override."

	/// The groups kept on this Mac, read from the preferences file's override rows. The rows are the
	/// one record of the choice: never synced, they stay on this Mac.
	public static func local(_ db: Database) throws -> Set<Self> {
		let ids: [String] = try LocalPreferenceRecord
			.where { $0.id.like("\(overridePrefix)%") }
			.fetchAll(db)
			.map(\.id)
		return Set(allCases.filter { ids.contains($0.overrideKey) })
	}
}

extension PreferenceRows {
	/// The groups whose override rows these rows hold: the ones kept on this Mac.
	public var localGroups: Set<PreferenceGroup> {
		Set(PreferenceGroup.allCases.filter { local[$0.overrideKey] != nil })
	}

	/// These rows with `groups` kept local: their synced rows as `previous` has them, so a save never
	/// writes them, and an override row with `preferences`' values for each.
	internal func keepingLocal(
		_ groups: Set<PreferenceGroup>,
		of preferences: BrowserPreferences,
		previous: Self
	) throws -> Self {
		guard !groups.isEmpty else { return self }

		var rows: Self = self
		guard let fields = try JSONColumn.deserialize(JSONColumn.encode(preferences)) as? [String: Any]
		else { throw ReadError.notAnObject }

		for group in groups {
			for domain in group.domains {
				rows.domains[domain.rawValue] = previous.domains[domain.rawValue]
			}
			switch group {
			case .appearance:
				break
			case .searchEngines:
				rows.searchShortcuts = previous.searchShortcuts
			case .shortcuts:
				rows.keyboardShortcuts = previous.keyboardShortcuts
			case .routing:
				rows.routingRules = previous.routingRules
				rows.proxyLinkRules = previous.proxyLinkRules
			}
			var values: [String: Any] = [:]
			for key in group.codingKeys {
				values[key] = fields[key]
			}
			rows.local[group.overrideKey] = .init(id: group.overrideKey, value: try JSONColumn.serialize(values))
		}
		return rows
	}
}

extension BrowserPreferences {
	/// These preferences with `group`'s values taken from `other`.
	public func replacing(
		_ group: PreferenceGroup,
		with other: Self
	) throws -> Self {
		guard
			var fields = try JSONColumn.deserialize(JSONColumn.encode(self)) as? [String: Any],
			let replacement = try JSONColumn.deserialize(JSONColumn.encode(other)) as? [String: Any]
		else { throw PreferenceRows.ReadError.notAnObject }

		for key in group.codingKeys {
			fields[key] = replacement[key]
		}
		let data: Data = try JSONSerialization.data(withJSONObject: fields)
		return try JSONDecoder().decode(Self.self, from: data)
	}
}
