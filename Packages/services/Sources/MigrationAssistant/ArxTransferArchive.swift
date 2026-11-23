import BrowserCore
import Foundation

/// The documented, versioned file Arx exports for moving to another Mac.
///
/// One JSON file. It holds profiles, spaces, folders, favorites, pinned and regular
/// tabs, and portable preferences. Version 2 adds browsing history and the Tab
/// Archive when the user includes them, and always lists installed extensions. It
/// never holds cookies, sessions, passwords, passkeys, profile directories, routing
/// rules or MCP grants. Version 1 files are still read.
public struct ArxTransferArchive: Codable, Equatable, Sendable {
	public static let format: String = "dev.capturecontext.arx.transfer"
	public static let currentVersion: Int = 2

	/// Files larger than this are refused before they're read.
	public static let maximumSize: Int = 64 * 1024 * 1024

	public var format: String
	public var version: Int
	public var createdAt: Date
	public var appVersion: String?
	public var categories: [String]
	public var profiles: [Profile]
	public var spaces: [Space]
	public var preferences: MigrationPortablePreferences?

	/// Version 2, when included: each profile's browsing history.
	public var history: [History]?

	/// Version 2, when included: closed tabs from the Tab Archive.
	public var archivedTabs: [ArchivedTab]?

	/// Version 2: installed extensions, listed for reinstalling by hand.
	public var extensions: [Extension]?

	internal init(
		format: String,
		version: Int,
		createdAt: Date,
		appVersion: String? = nil,
		categories: [String],
		profiles: [Profile],
		spaces: [Space],
		preferences: MigrationPortablePreferences? = nil,
		history: [History]? = nil,
		archivedTabs: [ArchivedTab]? = nil,
		extensions: [Extension]? = nil
	) {
		self.format = format
		self.version = version
		self.createdAt = createdAt
		self.appVersion = appVersion
		self.categories = categories
		self.profiles = profiles
		self.spaces = spaces
		self.preferences = preferences
		self.history = history
		self.archivedTabs = archivedTabs
		self.extensions = extensions
	}

	public struct Profile: Codable, Equatable, Sendable {
		public var id: UUID
		public var name: String
		public var searchEngine: SearchEngine?
		public var appearance: AppearanceOverride?
		public var favorites: [Tab]

		internal init(
			id: UUID,
			name: String,
			searchEngine: SearchEngine? = nil,
			appearance: AppearanceOverride? = nil,
			favorites: [Tab]
		) {
			self.id = id
			self.name = name
			self.searchEngine = searchEngine
			self.appearance = appearance
			self.favorites = favorites
		}
	}

	public struct Space: Codable, Equatable, Sendable {
		public var id: UUID
		public var profileID: UUID
		public var name: String
		public var icon: String?
		public var appearance: AppearanceOverride?
		public var pinned: [Item]
		public var regular: [Tab]

		internal init(
			id: UUID,
			profileID: UUID,
			name: String,
			icon: String? = nil,
			appearance: AppearanceOverride? = nil,
			pinned: [Item],
			regular: [Tab]
		) {
			self.id = id
			self.profileID = profileID
			self.name = name
			self.icon = icon
			self.appearance = appearance
			self.pinned = pinned
			self.regular = regular
		}
	}

	/// A tab or a folder, in sidebar order.
	public struct Item: Codable, Equatable, Sendable {
		public var tab: Tab?
		public var folder: Folder?

		internal init(
			tab: Tab? = nil,
			folder: Folder? = nil
		) {
			self.tab = tab
			self.folder = folder
		}
	}

	public struct Folder: Codable, Equatable, Sendable {
		public var id: UUID
		public var name: String
		public var isExpanded: Bool
		public var children: [Item]

		internal init(
			id: UUID,
			name: String,
			isExpanded: Bool,
			children: [Item]
		) {
			self.id = id
			self.name = name
			self.isExpanded = isExpanded
			self.children = children
		}
	}

	public struct Tab: Codable, Equatable, Sendable {
		public var id: UUID
		public var title: String
		public var customTitle: String?

		/// The icon chosen for the tab (DEV-1251). Absent from archives made before it.
		public var icon: SpaceIcon?

		/// Where a pinned tab returns to. Absent for regular tabs.
		public var savedURL: URL?

		/// Where the tab last was.
		public var currentURL: URL
		public var currentTitle: String

		internal init(
			id: UUID,
			title: String,
			customTitle: String? = nil,
			icon: SpaceIcon? = nil,
			savedURL: URL? = nil,
			currentURL: URL,
			currentTitle: String
		) {
			self.id = id
			self.title = title
			self.customTitle = customTitle
			self.icon = icon
			self.savedURL = savedURL
			self.currentURL = currentURL
			self.currentTitle = currentTitle
		}
	}
}

extension ArxTransferArchive {
	public struct History: Codable, Equatable, Sendable {
		public var profileID: UUID

		/// Newest first.
		public var entries: [HistoryEntry]

		internal init(
			profileID: UUID,
			entries: [HistoryEntry]
		) {
			self.profileID = profileID
			self.entries = entries
		}
	}

	public struct HistoryEntry: Codable, Equatable, Sendable {
		public var id: UUID
		public var url: URL
		public var title: String
		public var lastVisited: Date

		/// Absent from archives made before DEV-1015.
		public var visitCount: Int?
		public var typedCount: Int?

		internal init(
			id: UUID,
			url: URL,
			title: String,
			lastVisited: Date,
			visitCount: Int? = nil,
			typedCount: Int? = nil
		) {
			self.id = id
			self.url = url
			self.title = title
			self.lastVisited = lastVisited
			self.visitCount = visitCount
			self.typedCount = typedCount
		}
	}

	/// A closed tab. `spaceID` names a space in `spaces` when that space was exported;
	/// otherwise the tab returns to the profile's destination space.
	public struct ArchivedTab: Codable, Equatable, Sendable {
		public var id: UUID

		/// Tabs closed together share a group.
		public var groupID: UUID
		public var closedAt: Date
		public var profileID: UUID
		public var spaceID: UUID
		public var spaceName: String

		/// Its position among the space's regular tabs when it closed.
		public var index: Int
		public var tab: Tab

		internal init(
			id: UUID,
			groupID: UUID,
			closedAt: Date,
			profileID: UUID,
			spaceID: UUID,
			spaceName: String,
			index: Int,
			tab: Tab
		) {
			self.id = id
			self.groupID = groupID
			self.closedAt = closedAt
			self.profileID = profileID
			self.spaceID = spaceID
			self.spaceName = spaceName
			self.index = index
			self.tab = tab
		}
	}

	/// An installed extension. Only what finds it again: no files, settings or data.
	public struct Extension: Codable, Equatable, Sendable {
		public var profileID: UUID

		/// The Chromium extension ID.
		public var id: String
		public var name: String
		public var fromWebStore: Bool

		internal init(
			profileID: UUID,
			id: String,
			name: String,
			fromWebStore: Bool
		) {
			self.profileID = profileID
			self.id = id
			self.name = name
			self.fromWebStore = fromWebStore
		}
	}
}

/// What an export wrote, and what it left out or changed.
public struct MigrationExportSummary: Equatable, Sendable {
	public var profiles: Int
	public var spaces: Int
	public var folders: Int
	public var tabs: Int

	/// Regular tabs a format has no place for.
	public var omittedRegularTabs: Int
	public var historyEntries: Int
	public var archivedTabs: Int
	public var extensions: Int

	internal init(
		profiles: Int,
		spaces: Int,
		folders: Int,
		tabs: Int,
		omittedRegularTabs: Int,
		historyEntries: Int = 0,
		archivedTabs: Int = 0,
		extensions: Int = 0
	) {
		self.profiles = profiles
		self.spaces = spaces
		self.folders = folders
		self.tabs = tabs
		self.omittedRegularTabs = omittedRegularTabs
		self.historyEntries = historyEntries
		self.archivedTabs = archivedTabs
		self.extensions = extensions
	}
}

// MARK: - Export

extension ArxTransferArchive {
	/// - Parameters:
	///   - history: each profile's history, when the user chose to include it.
	///   - includesArchivedTabs: whether the user chose to include the Tab Archive.
	///   - extensions: installed extensions, which are always listed.
	public init(
		organization: BrowserOrganization,
		preferences: BrowserPreferences,
		createdAt: Date,
		appVersion: String?,
		history: [BrowsingHistorySnapshot]? = nil,
		includesArchivedTabs: Bool = false,
		extensions: [BrowserCore.Profile.ID: [BrowserExtension]] = [:]
	) {
		let tabs = Dictionary(uniqueKeysWithValues: organization.tabs.map { ($0.id, $0) })
		let folders = Dictionary(uniqueKeysWithValues: organization.folders.map { ($0.id, $0) })

		func tab(_ id: BrowserCore.Tab.ID) -> Tab? {
			tabs[id].map { tab in
				.init(
					id: tab.id.rawValue,
					title: tab.savedDestination?.title ?? tab.restoration.title,
					customTitle: tab.customTitle,
					icon: tab.icon,
					savedURL: tab.savedDestination?.url,
					currentURL: tab.restoration.url,
					currentTitle: tab.restoration.title
				)
			}
		}

		func item(_ saved: SavedItem) -> Item? {
			switch saved {
			case let .tab(id):
				return tab(id).map { .init(tab: $0) }

			case let .folder(id):
				return folders[id].map { folder in
					.init(
						folder: .init(
							id: folder.id.rawValue,
							name: folder.name,
							isExpanded: folder.isExpanded,
							children: folder.children.compactMap(item)
						)
					)
				}
			}
		}

		let profileIDs = Set(organization.profiles.map(\.id))
		var categories: [String] = ["organization", "preferences", "extensions"]
		if history != nil { categories.append("history") }
		if includesArchivedTabs { categories.append("archivedTabs") }

		self.init(
			format: Self.format,
			version: Self.currentVersion,
			createdAt: createdAt,
			appVersion: appVersion,
			categories: categories,
			profiles: organization.profiles.map { profile in
				.init(
					id: profile.id.rawValue,
					name: profile.name,
					searchEngine: profile.searchEngine,
					appearance: profile.appearance,
					favorites: profile.favorites.compactMap(tab)
				)
			},
			spaces: organization.spaces.map { space in
				.init(
					id: space.id.rawValue,
					profileID: space.profileID.rawValue,
					name: space.name,
					icon: space.icon?.rawValue,
					appearance: space.appearance,
					pinned: space.savedItems.compactMap(item),
					regular: space.unpinnedTabs.compactMap(tab)
				)
			},
			preferences: .init(preferences),
			history: history.map { snapshots in
				snapshots
					.filter { profileIDs.contains($0.profileID) }
					.map { snapshot in
						.init(
							profileID: snapshot.profileID.rawValue,
							entries: snapshot.entries.map { entry in
								.init(
									id: entry.id,
									url: entry.url,
									title: entry.title,
									lastVisited: entry.lastVisited,
									visitCount: entry.visitCount,
									typedCount: entry.typedCount
								)
							}
						)
					}
			},
			archivedTabs: includesArchivedTabs ? organization.archive.map(ArchivedTab.init) : nil,
			extensions: organization.profiles.flatMap { profile in
				(extensions[profile.id] ?? []).map { value in
					Extension(
						profileID: profile.id.rawValue,
						id: value.id,
						name: value.name,
						fromWebStore: value.fromWebStore
					)
				}
			}
		)
	}

	public func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		encoder.dateEncodingStrategy = .iso8601
		return try encoder.encode(self)
	}

	public var summary: MigrationExportSummary {
		func count(_ items: [Item]) -> (tabs: Int, folders: Int) {
			var total = (tabs: 0, folders: 0)
			for item in items {
				if item.tab != nil { total.tabs += 1 }
				if let folder = item.folder {
					let nested = count(folder.children)
					total.tabs += nested.tabs
					total.folders += nested.folders + 1
				}
			}
			return total
		}

		let pinned = spaces.map { count($0.pinned) }
		let tabCount = pinned.reduce(0) { $0 + $1.tabs }
		+ spaces.reduce(0) { $0 + $1.regular.count }
		+ profiles.reduce(0) { $0 + $1.favorites.count }

		return .init(
			profiles: profiles.count,
			spaces: spaces.count,
			folders: pinned.reduce(0) { $0 + $1.folders },
			tabs: tabCount,
			omittedRegularTabs: 0,
			historyEntries: (history ?? []).reduce(0) { $0 + $1.entries.count },
			archivedTabs: archivedTabs?.count ?? 0,
			extensions: extensions?.count ?? 0
		)
	}

	/// What this file can import, for the source the user picked.
	internal var importableCategories: [MigrationCategory] {
		var result: [MigrationCategory] = [.favorites, .bookmarks, .openTabs]
		if archivedTabs?.isEmpty == false { result.append(.archivedTabs) }
		if history?.contains(where: { !$0.entries.isEmpty }) == true { result.append(.history) }
		if extensions?.isEmpty == false { result.append(.extensions) }
		result.append(.preferences)
		return result
	}
}

extension ArxTransferArchive.ArchivedTab {
	fileprivate init(_ entry: BrowserCore.ArchivedTab) {
		self.init(
			id: entry.id.rawValue,
			groupID: entry.groupID,
			closedAt: entry.closedAt,
			profileID: entry.tab.profileID.rawValue,
			spaceID: entry.originalSpaceID.rawValue,
			spaceName: entry.originalSpaceName,
			index: entry.originalIndex,
			tab: .init(
				id: entry.tab.id.rawValue,
				title: entry.tab.restoration.title,
				customTitle: entry.tab.customTitle,
				currentURL: entry.tab.restoration.url,
				currentTitle: entry.tab.restoration.title
			)
		)
	}
}

// MARK: - Import

extension ArxTransferArchive {
	/// Decodes and checks a file. Nothing is changed until the user has reviewed it.
	public static func decode(_ data: Data) throws -> Self {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		struct Header: Decodable {
			var format: String
			var version: Int
		}

		// An undecodable header means the file isn't an archive at all.
		let header = try? decoder.decode(Header.self, from: data)
		guard let header, header.format == format
		else { throw MigrationFailure.invalidFile }

		guard header.version <= currentVersion, header.version >= 1
		else { throw MigrationFailure.unsupportedVersion(header.version) }

		do {
			let archive = try decoder.decode(Self.self, from: data)
			try archive.preferences?.validate()
			return archive
		} catch {
			throw MigrationFailure.invalidFile
		}
	}

	/// Item identities come from the exporting browser, so importing a newer export of
	/// the same browser adds only what's new.
	internal var snapshot: MigrationSnapshot {
		var records: [MigrationRecord] = []
		var sourceProfiles: [UUID: MigrationSourceProfile] = [:]

		func record(
			_ tab: Tab,
			category: MigrationCategory,
			folders: [MigrationSourceFolder] = [],
			space: MigrationSourceSpace? = nil,
			profile: MigrationSourceProfile? = nil
		) {
			records.append(
				.init(
					sourceItemID: tab.id.uuidString,
					category: category,
					title: tab.savedURL == nil ? tab.currentTitle : tab.title,
					url: (tab.savedURL ?? tab.currentURL).absoluteString,
					folders: folders,
					space: space,
					profile: profile,
					currentURL: tab.savedURL == nil ? nil : tab.currentURL.absoluteString,
					currentTitle: tab.savedURL == nil ? nil : tab.currentTitle,
					customTitle: tab.customTitle,
					tabIcon: tab.icon
				)
			)
		}

		func walk(
			_ items: [Item],
			folders: [MigrationSourceFolder],
			space: MigrationSourceSpace
		) {
			for item in items {
				if let tab = item.tab {
					record(tab, category: .bookmarks, folders: folders, space: space)
				} else if let folder = item.folder {
					let source: MigrationSourceFolder = .init(
						id: folder.id.uuidString,
						name: folder.name,
						isExpanded: folder.isExpanded
					)
					if folder.children.isEmpty {
						records.append(
							.init(
								sourceItemID: "folder:" + folder.id.uuidString,
								kind: .folder,
								category: .bookmarks,
								folders: folders + [source],
								space: space
							)
						)
					}
					walk(folder.children, folders: folders + [source], space: space)
				}
			}
		}

		for profile in profiles {
			let source: MigrationSourceProfile = .init(
				id: profile.id.uuidString,
				name: profile.name,
				searchEngine: profile.searchEngine,
				appearance: profile.appearance
			)
			sourceProfiles[profile.id] = source
			records.append(
				.init(
					sourceItemID: "profile:" + profile.id.uuidString,
					kind: .profile,
					category: .favorites,
					profile: source
				)
			)
			for favorite in profile.favorites {
				record(favorite, category: .favorites, profile: source)
			}
		}

		var issues: [MigrationIssue] = []
		var sourceSpaces: [UUID: MigrationSourceSpace] = [:]
		for space in spaces {
			guard let profile = sourceProfiles[space.profileID] else {
				issues.append(
					.init(
						sourceItemID: space.id.uuidString,
						category: .bookmarks,
						reason: .invalidURL
					)
				)
				continue
			}

			let source: MigrationSourceSpace = .init(
				id: profile.id + MigrationBrowserSources.spaceSeparator + space.id.uuidString,
				name: space.name,
				icon: space.icon,
				appearance: space.appearance,
				profile: profile
			)
			sourceSpaces[space.id] = source
			records.append(
				.init(
					sourceItemID: "space:" + space.id.uuidString,
					kind: .space,
					category: .bookmarks,
					space: source
				)
			)
			walk(space.pinned, folders: [], space: source)
			for tab in space.regular {
				record(tab, category: .openTabs, space: source)
			}
		}
		for entry in archivedTabs ?? [] {
			guard let profile = sourceProfiles[entry.profileID] else {
				issues.append(
					.init(
						sourceItemID: entry.id.uuidString,
						category: .archivedTabs,
						reason: .invalidURL
					)
				)
				continue
			}

			records.append(
				.init(
					sourceItemID: entry.id.uuidString,
					category: .archivedTabs,
					title: entry.tab.currentTitle,
					url: entry.tab.currentURL.absoluteString,
					space: sourceSpaces[entry.spaceID],
					profile: profile,
					customTitle: entry.tab.customTitle,
					archived: .init(
						groupID: entry.groupID.uuidString,
						closedAt: entry.closedAt,
						index: entry.index
					)
				)
			)
		}

		for profileHistory in history ?? [] {
			guard let profile = sourceProfiles[profileHistory.profileID] else { continue }

			for entry in profileHistory.entries {
				records.append(
					.init(
						sourceItemID: entry.id.uuidString,
						category: .history,
						title: entry.title,
						url: entry.url.absoluteString,
						profile: profile,
						lastVisited: entry.lastVisited,
						visitCount: entry.visitCount,
						typedCount: entry.typedCount
					)
				)
			}
		}

		var listed: Set<String> = []
		for value in extensions ?? [] where listed.insert(value.id).inserted {
			issues.append(
				.init(
					sourceItemID: value.id,
					category: .extensions,
					reason: .reinstallManually(
						.init(
							id: value.id,
							name: value.name,
							fromWebStore: value.fromWebStore
						)
					)
				)
			)
		}

		return .init(
			id: MigrationBrowserSources.snapshotID(
				records,
				issues: issues,
				preferences: preferences
			),
			records: records,
			issues: issues,
			preferences: preferences
		)
	}
}

// MARK: - Preferences

/// Settings that mean the same thing on another Mac. Machine paths, windows, routing
/// rules that name local spaces, and MCP grants stay behind.
public struct MigrationPortablePreferences: Codable, Equatable, Sendable {
	public var grainEnabled: Bool
	public var grainIntensity: Double
	public var grainSize: Double
	public var searchShortcuts: [SearchShortcut]
	public var keyboardShortcuts: [ShortcutBinding]
	public var proxyLinkRules: [ProxyLinkRule]

	public init(_ preferences: BrowserPreferences) {
		self.grainEnabled = preferences.grainEnabled
		self.grainIntensity = preferences.grainIntensity
		self.grainSize = preferences.grainSize
		self.searchShortcuts = preferences.searchShortcuts
		self.keyboardShortcuts = preferences.keyboardShortcuts
		self.proxyLinkRules = preferences.proxyLinkRules
	}

	internal func validate() throws {
		_ = try BrowserPreferences().applyingMigration(self)
	}
}

extension BrowserPreferences {
	/// Keeps this Mac's search shortcuts and link rules and adds the file's new ones.
	/// Appearance and key bindings have one value each, so the file's are used.
	public func applyingMigration(_ portable: MigrationPortablePreferences) throws -> Self {
		var result = self
		result.grainEnabled = portable.grainEnabled
		result.grainIntensity = portable.grainIntensity
		result.grainSize = portable.grainSize
		result.keyboardShortcuts = portable.keyboardShortcuts

		var keywords = Set(result.searchShortcuts.map { $0.keyword.lowercased() })
		result.searchShortcuts += portable.searchShortcuts.filter {
			keywords.insert($0.keyword.lowercased()).inserted
		}
		var rules = Set(result.proxyLinkRules.map(\.id))
		result.proxyLinkRules += portable.proxyLinkRules.filter { rules.insert($0.id).inserted }

		try result.validate()
		return result
	}
}
