import Foundation

/// A discovered place to import from. Adapters describe sources; they never expose
/// a live profile directory to callers.
public struct MigrationSource: Identifiable, Equatable, Sendable {
	public var id: ID
	public var kind: Kind
	public var name: String

	/// The source application's version when the adapter can read it.
	public var version: String?

	/// Categories this adapter can read from this source.
	public var categories: [MigrationCategory]

	/// The source has profiles and spaces worth recreating, so importing into new
	/// profiles is the default rather than one existing space.
	public var preservesOrganization: Bool

	/// Whether the user can choose new profiles or per-space placement at all.
	public var offersLayouts: Bool

	/// The source application's bundle identifier, for matching it to the default browser.
	public var applicationIdentifier: String?

	/// When the source last wrote the data the adapter reads, as a hint of recent use.
	public var lastUsed: Date?

	/// macOS protects the source's data with Full Disk Access (Safari), so features check
	/// `FullDiskAccessClient` before inspecting it.
	public var requiresFullDiskAccess: Bool

	public init(
		id: ID,
		kind: Kind,
		name: String,
		version: String? = nil,
		categories: [MigrationCategory],
		preservesOrganization: Bool = false,
		offersLayouts: Bool? = nil,
		applicationIdentifier: String? = nil,
		lastUsed: Date? = nil,
		requiresFullDiskAccess: Bool = false
	) {
		self.id = id
		self.kind = kind
		self.name = name
		self.version = version
		self.categories = categories
		self.preservesOrganization = preservesOrganization
		self.offersLayouts = offersLayouts ?? preservesOrganization
		self.applicationIdentifier = applicationIdentifier
		self.lastUsed = lastUsed
		self.requiresFullDiskAccess = requiresFullDiskAccess
	}
}

extension MigrationSource {
	/// Passwords and sign-ins can come from this source (DEV-842): directly from a Chromium
	/// browser whose key Arx knows, otherwise from the browser's CSV export. Arx files
	/// carry none.
	public var offersCredentials: Bool {
		kind == .externalBrowser
	}
}

/// A browser on this Mac that Arx can't import from yet. It's listed so the user
/// sees why it isn't offered, never to read it.
public struct MigrationUnsupportedBrowser: Identifiable, Equatable, Sendable {
	public var id: String
	public var name: String
	public var applicationIdentifier: String

	public init(
		id: String,
		name: String,
		applicationIdentifier: String
	) {
		self.id = id
		self.name = name
		self.applicationIdentifier = applicationIdentifier
	}
}

extension MigrationSource {
	/// Stable adapter-defined identity, for example a browser and profile name.
	/// It is part of every imported item's idempotence key.
	public struct ID: RawRepresentable, Hashable, Codable, Sendable {
		public let rawValue: String

		public init(rawValue: String) {
			self.rawValue = rawValue
		}

		/// Safari, whose passwords are in the Passwords app, which other apps can't read.
		public static let safari: Self = .init(rawValue: "safari")
	}

	/// External browsers and earlier Arx data use separate adapters.
	public enum Kind: Equatable, Sendable {
		case externalBrowser
		case arxArchive
		case arxSettings
	}
}

/// Data that can be mapped into a BrowserOrganization.
///
/// Passwords and sign-ins are never a category: they have their own protected flow,
/// `CredentialMigrationClient` (DEV-650), and never join the Arx archive.
public enum MigrationCategory: String, CaseIterable, Codable, Comparable, Sendable {
	/// Tabs pinned to a profile, imported as favorites.
	case favorites

	/// Bookmarks and tabs pinned to a space, imported as pinned tabs.
	case bookmarks

	/// Open tabs, imported as regular tabs.
	case openTabs

	/// Closed tabs from an Arx archive's Tab Archive.
	case archivedTabs

	/// Browsing history, merged into each profile's history.
	case history

	/// Installed extensions. Nothing is installed: each is reported for a manual reinstall.
	case extensions

	/// Portable settings from an Arx archive.
	case preferences

	public static func < (lhs: Self, rhs: Self) -> Bool {
		lhs.order < rhs.order
	}

	/// Execution order. Categories commit one at a time in this order.
	private var order: Int {
		switch self {
		case .favorites: 0
		case .bookmarks: 1
		case .openTabs: 2
		case .archivedTabs: 3
		case .history: 4
		case .extensions: 5
		case .preferences: 6
		}
	}
}
