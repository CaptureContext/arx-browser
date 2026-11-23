import Foundation

public struct Profile: Identifiable, Equatable, Codable, Sendable {
	public let id: ID
	public var name: String
	public var favorites: [Tab.ID]

	/// Missing from older snapshots, which searched with Google.
	public var searchEngine: SearchEngine?
	public var appearance: AppearanceOverride?

	/// How long a regular tab may go unviewed before it's archived, as the person chose it.
	/// Missing or `nil` means they haven't, so ``TabArchiveInterval/default`` applies
	/// (``effectiveTabArchiveInterval``); ``TabArchiveInterval/never`` is the choice to keep
	/// every tab (DEV-1326).
	public var tabArchiveInterval: TabArchiveInterval?

	/// Whether the command bar asks the search provider for suggestions. Missing means on.
	public var remoteSearchSuggestions: Bool?

	/// Whether the address bar shows the whole URL rather than the host. Missing means the host.
	public var showsFullURL: Bool?

	/// Sites whose tabs Arx never unloads (DEV-932), as ``KeptLoadedSite`` hosts, sorted.
	/// Missing means none.
	public var keptLoadedSites: [String]?

	/// Sites dark pages leave as they draw themselves (DEV-1020), as ``KeptLoadedSite`` sites,
	/// sorted. Missing means none.
	public var darkPagesOffSites: [String]?

	/// The profile's unread badges (DEV-1258): shown, hidden, or missing to follow the browser
	/// default. A site's or a tab's own choice wins over it.
	public var unreadBadges: UnreadBadgeVisibility?

	/// Whether the profile syncs with iCloud when iCloud sync is on (DEV-981). `false` makes it "this
	/// Mac only": its spaces, pins, Favorites, settings, history and Tab Archive stay on this Mac.
	/// Missing means it syncs.
	public var syncsWithICloud: Bool?

	public init(
		id: ID,
		name: String,
		favorites: [Tab.ID] = [],
		searchEngine: SearchEngine? = nil,
		appearance: AppearanceOverride? = nil,
		tabArchiveInterval: TabArchiveInterval? = nil,
		remoteSearchSuggestions: Bool? = nil,
		showsFullURL: Bool? = nil,
		keptLoadedSites: [String]? = nil,
		darkPagesOffSites: [String]? = nil,
		unreadBadges: UnreadBadgeVisibility? = nil,
		syncsWithICloud: Bool? = nil
	) {
		self.id = id
		self.name = name
		self.favorites = favorites
		self.searchEngine = searchEngine
		self.appearance = appearance
		self.tabArchiveInterval = tabArchiveInterval
		self.remoteSearchSuggestions = remoteSearchSuggestions
		self.showsFullURL = showsFullURL
		self.keptLoadedSites = keptLoadedSites
		self.darkPagesOffSites = darkPagesOffSites
		self.unreadBadges = unreadBadges
		self.syncsWithICloud = syncsWithICloud
	}

	/// How long a regular tab may go unviewed before it's archived: the person's choice, or the
	/// default when they made none (DEV-1326).
	public var effectiveTabArchiveInterval: TabArchiveInterval { tabArchiveInterval ?? .default }

	/// Whether the profile is "this Mac only" (DEV-981).
	public var isThisMacOnly: Bool { syncsWithICloud == false }

	/// Remote search suggestions are on unless the profile turned them off.
	public var suggestsRemotely: Bool { remoteSearchSuggestions ?? true }

	/// The address bar shows the host unless the profile chose the whole URL.
	public var showsWholeURL: Bool { showsFullURL ?? false }

	/// Whether Arx keeps `url`'s tabs in this profile loaded (DEV-932).
	public func keepsLoaded(_ url: URL?) -> Bool {
		guard let sites = keptLoadedSites, !sites.isEmpty, let url else { return false }

		return sites.contains { KeptLoadedSite.matches(url, site: $0) }
	}
}

/// How long a regular tab may go unviewed before Arx archives it, or never.
///
/// Stored and synced as its raw value in the profile's `tabArchiveInterval` column, where no
/// value means the person hasn't chosen, so ``default`` applies (DEV-1326). A raw value this
/// build doesn't know, from a newer one, reads as no value: the default. A build from before
/// ``sixHours`` and ``never`` reads both as no value, which meant never there.
public enum TabArchiveInterval: String, CaseIterable, Codable, Sendable {
	case sixHours
	case twelveHours
	case day
	case week
	case month
	case never

	/// Max's decision of 22 November 2026 (DEV-1326): twice the three hours a hidden tab waits
	/// before it unloads (``TabUnloadDelay/provisionalDefault``), so it's unloaded first.
	public static let `default`: Self = .sixHours

	/// How long a tab goes unviewed before it's archived, or nil when it never is.
	public var duration: TimeInterval? {
		switch self {
		case .sixHours: 6 * 60 * 60
		case .twelveHours: 12 * 60 * 60
		case .day: 24 * 60 * 60
		case .week: 7 * 24 * 60 * 60
		case .month: 30 * 24 * 60 * 60
		case .never: nil
		}
	}
}

extension Profile {
	public typealias ID = BrowserID<Self>

	/// As the synthesized decoding, except that an archive interval this build doesn't know, from
	/// a newer one, reads as none chosen instead of failing the whole profile (DEV-1326).
	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		let interval = try values.decodeIfPresent(String.self, forKey: .tabArchiveInterval)
		self.init(
			id: try values.decode(ID.self, forKey: .id),
			name: try values.decode(String.self, forKey: .name),
			favorites: try values.decode([Tab.ID].self, forKey: .favorites),
			searchEngine: try values.decodeIfPresent(SearchEngine.self, forKey: .searchEngine),
			appearance: try values.decodeIfPresent(AppearanceOverride.self, forKey: .appearance),
			tabArchiveInterval: interval.flatMap(TabArchiveInterval.init(rawValue:)),
			remoteSearchSuggestions: try values.decodeIfPresent(Bool.self, forKey: .remoteSearchSuggestions),
			showsFullURL: try values.decodeIfPresent(Bool.self, forKey: .showsFullURL),
			keptLoadedSites: try values.decodeIfPresent([String].self, forKey: .keptLoadedSites),
			darkPagesOffSites: try values.decodeIfPresent([String].self, forKey: .darkPagesOffSites),
			unreadBadges: try values.decodeIfPresent(UnreadBadgeVisibility.self, forKey: .unreadBadges),
			syncsWithICloud: try values.decodeIfPresent(Bool.self, forKey: .syncsWithICloud)
		)
	}
}
