import Foundation
import _SQLiteData

// The preferences database: the Preferences sync category of ADR 0001.
//
// `preference` and the four list tables are synced, with the same rules as the organization's synced
// tables. `localPreference` holds every other `BrowserPreferences` field and never syncs.

// MARK: - Synced

/// One portable preference domain (``PreferenceDomain``) as a JSON object of its fields, so
/// last-writer-wins applies per domain rather than to the whole file.
@Table("preference")
public struct PreferenceRecord: Equatable, Identifiable, Sendable {
	/// The domain's name.
	@Column(primaryKey: true)
	public let id: String

	@Column("value")
	public var value: String

	public init(
		id: String,
		value: String
	) {
		self.id = id
		self.value = value
	}
}

/// A search shortcut. Its lowercased keyword is its ID, so two Macs adding the same keyword make one
/// record rather than a conflict.
@Table("searchShortcut")
public struct SearchShortcutRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: String

	@Column("keyword")
	public var keyword: String

	@Column("name")
	public var name: String

	@Column("template")
	public var template: String

	@Column("homepage")
	public var homepage: String?

	@Column("isEnabled")
	public var isEnabled: Bool

	@Column("position")
	public var position: String

	public init(
		id: String,
		keyword: String,
		name: String,
		template: String,
		homepage: String? = nil,
		isEnabled: Bool = true,
		position: String
	) {
		self.id = id
		self.keyword = keyword
		self.name = name
		self.template = template
		self.homepage = homepage
		self.isEnabled = isEnabled
		self.position = position
	}
}

/// A command's keyboard shortcuts. The command's raw value is its ID; a command may have several
/// shortcuts (DEV-920), and a `null` entry records a removed default.
@Table("keyboardShortcut")
public struct KeyboardShortcutRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: String

	/// `[KeyboardShortcut?]` as JSON.
	@Column("bindings")
	public var bindings: String

	@Column("position")
	public var position: String

	public init(
		id: String,
		bindings: String,
		position: String
	) {
		self.id = id
		self.bindings = bindings
		self.position = position
	}
}

@Table("routingRule")
public struct RoutingRuleRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("name")
	public var name: String

	@Column("host")
	public var host: String

	@Column("includesSubdomains")
	public var includesSubdomains: Bool

	@Column("scheme")
	public var scheme: String?

	@Column("port")
	public var port: Int?

	@Column("pathPrefix")
	public var pathPrefix: String?

	/// `RoutingDestination` as JSON.
	@Column("destination")
	public var destination: String

	@Column("isEnabled")
	public var isEnabled: Bool

	@Column("position")
	public var position: String

	public init(
		id: UUID,
		name: String,
		host: String,
		includesSubdomains: Bool = false,
		scheme: String? = nil,
		port: Int? = nil,
		pathPrefix: String? = nil,
		destination: String,
		isEnabled: Bool = true,
		position: String
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
		self.position = position
	}
}

@Table("proxyLinkRule")
public struct ProxyLinkRuleRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: UUID

	@Column("name")
	public var name: String

	/// `[String]` as JSON.
	@Column("sourceHosts")
	public var sourceHosts: String

	@Column("destinationTemplate")
	public var destinationTemplate: String

	@Column("isEnabled")
	public var isEnabled: Bool

	@Column("position")
	public var position: String

	public init(
		id: UUID,
		name: String,
		sourceHosts: String,
		destinationTemplate: String,
		isEnabled: Bool = true,
		position: String
	) {
		self.id = id
		self.name = name
		self.sourceHosts = sourceHosts
		self.destinationTemplate = destinationTemplate
		self.isEnabled = isEnabled
		self.position = position
	}
}

// MARK: - Device-local

/// The preferences file's copy of the store's identity and write revision (``StoreInfoKey``), so a
/// file restored or replaced without its partner is detected rather than read as current.
@Table("preferenceStoreInfo")
public struct PreferenceStoreInfoRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: String

	@Column("value")
	public var value: String

	public init(
		id: String,
		value: String
	) {
		self.id = id
		self.value = value
	}
}

/// One `BrowserPreferences` field that stays on this Mac, by its coding key, as JSON.
@Table("localPreference")
public struct LocalPreferenceRecord: Equatable, Identifiable, Sendable {
	@Column(primaryKey: true)
	public let id: String

	@Column("value")
	public var value: String

	public init(
		id: String,
		value: String
	) {
		self.id = id
		self.value = value
	}
}
