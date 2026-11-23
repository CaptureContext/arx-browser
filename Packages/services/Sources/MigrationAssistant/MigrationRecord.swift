import BrowserCore
import Foundation

/// A read-only copy of what an adapter read from a source.
///
/// Adapters build snapshots from exported files or copy-on-read reads of
/// individual source files. They must not open, lock, copy or modify another
/// browser's live profile directory.
public struct MigrationSnapshot: Equatable, Sendable {
	/// Identifies the exact data a preview was built from. Execution refuses to
	/// commit when the source now produces a different snapshot.
	public var id: String
	public var records: [MigrationRecord]

	/// What the source holds that Arx can't represent, reported rather than dropped silently.
	public var issues: [MigrationIssue]

	/// Portable settings, for sources that have them.
	public var preferences: MigrationPortablePreferences?

	public init(
		id: String,
		records: [MigrationRecord],
		issues: [MigrationIssue] = [],
		preferences: MigrationPortablePreferences? = nil
	) {
		self.id = id
		self.records = records
		self.issues = issues
		self.preferences = preferences
	}
}

/// A browser profile in the source.
public struct MigrationSourceProfile: Equatable, Sendable, Identifiable {
	public var id: String
	public var name: String
	public var searchEngine: SearchEngine?
	public var appearance: AppearanceOverride?

	public init(
		id: String,
		name: String,
		searchEngine: SearchEngine? = nil,
		appearance: AppearanceOverride? = nil
	) {
		self.id = id
		self.name = name
		self.searchEngine = searchEngine
		self.appearance = appearance
	}

	/// The ID standing for a whole source without profiles of its own, such as Firefox
	/// with passwords but no bookmarks or open tabs (DEV-844).
	public static let wholeSource: String = ""
}

/// A space in the source. Browsers without spaces use one per profile.
public struct MigrationSourceSpace: Equatable, Sendable, Identifiable {
	public var id: String
	public var name: String

	/// An emoji or an Arx symbol name, when the source has one Arx can show.
	public var icon: String?
	public var appearance: AppearanceOverride?
	public var profile: MigrationSourceProfile

	public init(
		id: String,
		name: String,
		icon: String? = nil,
		appearance: AppearanceOverride? = nil,
		profile: MigrationSourceProfile
	) {
		self.id = id
		self.name = name
		self.icon = icon
		self.appearance = appearance
		self.profile = profile
	}
}

/// A folder in the source. The ID keeps two folders with the same name apart.
public struct MigrationSourceFolder: Equatable, Sendable {
	public var id: String
	public var name: String
	public var isExpanded: Bool

	public init(
		id: String,
		name: String,
		isExpanded: Bool = true
	) {
		self.id = id
		self.name = name
		self.isExpanded = isExpanded
	}
}

/// What a record makes. Folders and spaces are records only when no tab would create
/// them, or to fix their place in the order.
public enum MigrationItemKind: Equatable, Sendable {
	case tab
	case folder
	case space
	case profile
}

/// One unvalidated item as the source describes it.
public struct MigrationRecord: Equatable, Sendable {
	/// The source's own stable identity for this item (for example a bookmark GUID).
	public var sourceItemID: String
	public var kind: MigrationItemKind
	public var category: MigrationCategory
	public var title: String

	/// Raw URL text; validation decides whether it can be imported.
	public var url: String

	/// Folders from the source root, outermost first.
	public var folders: [MigrationSourceFolder]

	/// Where the item lives in the source, when the source has that structure.
	public var space: MigrationSourceSpace?

	/// The owning profile of a favorite, which belongs to no single space.
	public var profile: MigrationSourceProfile?

	/// Where a pinned tab last was, when that differs from where it returns to.
	public var currentURL: String?
	public var currentTitle: String?
	public var customTitle: String?

	/// The icon an Arx archive's tab had chosen for it (DEV-1251), not the page's own `icon`.
	public var tabIcon: SpaceIcon?

	/// When a history entry was last visited.
	public var lastVisited: Date?

	/// How often the source browser says a history entry was visited, and how often its address
	/// was typed, when it keeps those counts (DEV-1015). They seed the command bar's ranking.
	public var visitCount: Int?
	public var typedCount: Int?

	/// When and where an archived tab was closed.
	public var archived: MigrationArchivedPlacement?

	/// The page's icon as the source browser last showed it, a PNG, so the sidebar shows it
	/// before the page loads (DEV-897). Left out of the snapshot ID.
	public var icon: Data?

	public init(
		sourceItemID: String,
		kind: MigrationItemKind = .tab,
		category: MigrationCategory,
		title: String = "",
		url: String = "",
		folders: [MigrationSourceFolder] = [],
		space: MigrationSourceSpace? = nil,
		profile: MigrationSourceProfile? = nil,
		currentURL: String? = nil,
		currentTitle: String? = nil,
		customTitle: String? = nil,
		tabIcon: SpaceIcon? = nil,
		lastVisited: Date? = nil,
		visitCount: Int? = nil,
		typedCount: Int? = nil,
		archived: MigrationArchivedPlacement? = nil,
		icon: Data? = nil
	) {
		self.sourceItemID = sourceItemID
		self.kind = kind
		self.category = category
		self.title = title
		self.url = url
		self.folders = folders
		self.space = space
		self.profile = profile
		self.currentURL = currentURL
		self.currentTitle = currentTitle
		self.customTitle = customTitle
		self.tabIcon = tabIcon
		self.lastVisited = lastVisited
		self.visitCount = visitCount
		self.typedCount = typedCount
		self.archived = archived
		self.icon = icon
	}

	/// For sources whose folders have no identity of their own: the path is the identity.
	public init(
		sourceItemID: String,
		category: MigrationCategory,
		title: String,
		url: String,
		folderPath: [String]
	) {
		self.init(
			sourceItemID: sourceItemID,
			category: category,
			title: title,
			url: url,
			folders: folderPath.indices.map { index in
				.init(
					id: folderPath[...index].joined(separator: "/"),
					name: folderPath[index]
				)
			}
		)
	}
}

/// When and where a tab in the Tab Archive was closed.
public struct MigrationArchivedPlacement: Equatable, Sendable {
	/// Tabs closed together share a group.
	public var groupID: String
	public var closedAt: Date

	/// The tab's position among the space's regular tabs when it closed.
	public var index: Int

	public init(
		groupID: String,
		closedAt: Date,
		index: Int
	) {
		self.groupID = groupID
		self.closedAt = closedAt
		self.index = index
	}
}

/// The idempotence key of one imported item: the same source item is imported at
/// most once into a destination, however many times a plan runs.
public struct MigrationItemKey: Hashable, Codable, Sendable {
	public var sourceID: MigrationSource.ID
	public var category: MigrationCategory
	public var sourceItemID: String

	public init(
		sourceID: MigrationSource.ID,
		category: MigrationCategory,
		sourceItemID: String
	) {
		self.sourceID = sourceID
		self.category = category
		self.sourceItemID = sourceItemID
	}
}

/// A validated item ready to be mapped into the organization.
public struct MigrationItem: Equatable, Sendable {
	public var key: MigrationItemKey
	public var kind: MigrationItemKind
	public var title: String

	/// Absent for folders, spaces and profiles.
	public var url: URL?
	public var folders: [MigrationSourceFolder]
	public var space: MigrationSourceSpace?
	public var profile: MigrationSourceProfile?
	public var currentURL: URL?
	public var currentTitle: String?
	public var customTitle: String?

	/// The icon chosen for the tab (DEV-1251).
	public var tabIcon: SpaceIcon?
	public var lastVisited: Date?

	/// The source's visit and typed counts for a history entry (DEV-1015).
	public var visitCount: Int?
	public var typedCount: Int?
	public var archived: MigrationArchivedPlacement?

	/// A PNG the source showed for the page (DEV-897).
	public var icon: Data?

	public init(
		key: MigrationItemKey,
		kind: MigrationItemKind = .tab,
		title: String,
		url: URL?,
		folders: [MigrationSourceFolder] = [],
		space: MigrationSourceSpace? = nil,
		profile: MigrationSourceProfile? = nil,
		currentURL: URL? = nil,
		currentTitle: String? = nil,
		customTitle: String? = nil,
		tabIcon: SpaceIcon? = nil,
		lastVisited: Date? = nil,
		visitCount: Int? = nil,
		typedCount: Int? = nil,
		archived: MigrationArchivedPlacement? = nil,
		icon: Data? = nil
	) {
		self.key = key
		self.kind = kind
		self.title = title
		self.url = url
		self.folders = folders
		self.space = space
		self.profile = profile
		self.currentURL = currentURL
		self.currentTitle = currentTitle
		self.customTitle = customTitle
		self.tabIcon = tabIcon
		self.lastVisited = lastVisited
		self.visitCount = visitCount
		self.typedCount = typedCount
		self.archived = archived
		self.icon = icon
	}

	public var folderPath: [String] { folders.map(\.name) }
}

/// Why a record was not imported.
public struct MigrationIssue: Error, Equatable, Sendable {
	public var sourceItemID: String?
	public var category: MigrationCategory
	public var reason: Reason

	public init(
		sourceItemID: String?,
		category: MigrationCategory,
		reason: Reason
	) {
		self.sourceItemID = sourceItemID
		self.category = category
		self.reason = reason
	}

	public enum Reason: Equatable, Sendable {
		/// The URL is missing, malformed or not HTTP(S).
		case invalidURL

		/// The record repeats a source item ID already seen in this snapshot.
		case repeatedSourceItem

		/// The source holds something Arx has no equivalent for.
		case unsupported(UnsupportedKind)

		/// The category's atomic commit failed; every item in it can be retried.
		case commitFailed(String)

		/// An extension the source had installed. Arx never installs it on its own: a
		/// Chrome Web Store one with a source profile is offered for install, with the
		/// user's approval of each, once the import has run (DEV-845).
		case reinstallManually(Extension)

		/// A history entry or archived tab without a usable date or position.
		case invalidDate
	}

	/// An installed extension, named so the user can find it again.
	public struct Extension: Equatable, Sendable {
		public var id: String
		public var name: String

		/// Installed from the Chrome Web Store, so its store page can be opened and it can
		/// be installed again by its ID.
		public var fromWebStore: Bool

		/// The version the source has, when it says.
		public var version: String?

		/// The source profile it's installed in, when the source has profiles (DEV-845).
		/// It's installed into the Arx profile that profile maps to.
		public var profile: MigrationSourceProfile?

		public init(
			id: String,
			name: String,
			fromWebStore: Bool,
			version: String? = nil,
			profile: MigrationSourceProfile? = nil
		) {
			self.id = id
			self.name = name
			self.fromWebStore = fromWebStore
			self.version = version
			self.profile = profile
		}

		/// Can be installed from the store into the profile its source profile maps to.
		public var installsFromStore: Bool {
			fromWebStore && profile != nil
		}
	}

	public enum UnsupportedKind: String, Equatable, Hashable, Sendable {
		case easel
		case note
		case onboardingItem
	}
}

extension MigrationRecord {
	/// Maps this record into an importable item or explains why it can't be imported.
	public func validated(
		from sourceID: MigrationSource.ID
	) -> Result<MigrationItem, MigrationIssue> {
		let key: MigrationItemKey = .init(
			sourceID: sourceID,
			category: category,
			sourceItemID: sourceItemID
		)
		let validFolders = folders
			.map { folder in
				MigrationSourceFolder(
					id: folder.id,
					name: folder.name.trimmingCharacters(in: .whitespacesAndNewlines),
					isExpanded: folder.isExpanded
				)
			}
			.filter { !$0.name.isEmpty }
		guard kind == .tab else {
			return .success(.init(
				key: key,
				kind: kind,
				title: title,
				url: nil,
				folders: validFolders,
				space: space,
				profile: profile ?? space?.profile
			))
		}

		guard let parsed = Self.webURL(url) else {
			return .failure(.init(
				sourceItemID: sourceItemID,
				category: category,
				reason: .invalidURL
			))
		}

		let hasValidDate: Bool = switch category {
		case .history:
			lastVisited.map { $0.timeIntervalSince1970.isFinite } == true

		case .archivedTabs:
			archived.map { $0.closedAt.timeIntervalSince1970.isFinite && $0.index >= 0 } == true

		case .favorites, .bookmarks, .openTabs, .extensions, .preferences:
			true
		}
		guard hasValidDate else {
			return .failure(.init(
				sourceItemID: sourceItemID,
				category: category,
				reason: .invalidDate
			))
		}

		let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
		return .success(.init(
			key: key,
			title: trimmedTitle.isEmpty ? parsed.host() ?? url : trimmedTitle,
			url: parsed,
			folders: category == .bookmarks ? validFolders : [],
			space: space,
			profile: profile ?? space?.profile,
			currentURL: currentURL.flatMap(Self.webURL),
			currentTitle: currentTitle,
			customTitle: customTitle,
			tabIcon: tabIcon,
			lastVisited: lastVisited,
			visitCount: visitCount.map { max(0, $0) },
			typedCount: typedCount.map { max(0, $0) },
			archived: archived,
			icon: icon
		))
	}

	private static func webURL(_ text: String) -> URL? {
		guard
			let parsed = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
			let scheme = parsed.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			parsed.host()?.isEmpty == false
		else { return nil }

		return parsed
	}
}
