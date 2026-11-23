import Foundation

/// Reads Safari's own files (DEV-840): `Bookmarks.plist`, `SafariTabs.db` and `History.db`.
///
/// macOS protects these with Full Disk Access, so the adapter is offered whether or not
/// Arx has it, and features ask for it before inspecting (`FullDiskAccessClient`). The
/// databases are read from private copies, like Firefox's.
///
/// - Bookmarks are shared by every Safari profile. The Favorites bar's links become the
///   default profile's favorites; its folders, the Bookmarks Menu and other folders become
///   bookmarks in a space named after the profile. Reading List becomes a folder there.
/// - Tab groups become spaces of their own, in their profile, with their tabs as open tabs.
///   The tabs of open windows outside a tab group are open tabs in their profile's space.
///   Private windows are left out.
/// - History becomes each profile's history, one entry per page at its latest visit.
internal enum SafariData {
	/// The profile Safari had before profiles existed. It has no row of its own.
	internal static let defaultProfile: MigrationSourceProfile = .init(id: "default", name: "Safari")

	/// Where Safari keeps its data under a home folder.
	internal struct Location: Sendable {
		internal var library: URL
		internal var container: URL

		internal init(home: URL) {
			self.library = home.appending(path: "Library/Safari", directoryHint: .isDirectory)
			self.container = home.appending(
				path: "Library/Containers/com.apple.Safari/Data/Library/Safari",
				directoryHint: .isDirectory
			)
		}

		internal var bookmarks: URL {
			library.appending(path: "Bookmarks.plist")
		}

		/// Newer Safari keeps tabs in its container; older ones beside the bookmarks.
		internal var tabs: [URL] {
			[
				container.appending(path: "SafariTabs.db"),
				library.appending(path: "SafariTabs.db"),
			]
		}

		/// The default profile's history is beside the bookmarks; other profiles' in
		/// `Profiles/<identifier>`, by the profile's server or external identifier.
		internal func history(for profile: SafariTabs.Profile?) -> [URL] {
			guard let profile else { return [library.appending(path: "History.db")] }

			return profile.identifiers.flatMap { identifier in
				[library, container].map { root in
					root.appending(path: "Profiles/\(identifier)/History.db")
				}
			}
		}
	}

	internal static func snapshot(_ location: Location) throws -> MigrationSnapshot {
		let fileManager: FileManager = .default
		func readable(_ url: URL) -> Bool {
			fileManager.isReadableFile(atPath: url.path(percentEncoded: false))
		}

		guard let bookmarks = try? Data(contentsOf: location.bookmarks) else {
			throw MigrationFailure.unreadableSource("Arx needs Full Disk Access to read Safari's bookmarks.")
		}

		// Without a tabs database (older macOS, or Safari never opened) there are only bookmarks.
		let tabs: SafariTabs.Contents = try location.tabs.first(where: readable).map { url in
			try FirefoxPlaces.withCopy(of: url) { try SafariTabs.read($0) }
		} ?? .init()

		var history: [MigrationRecord] = []
		for profile in [nil] + tabs.profiles.map(Optional.some) {
			guard let file = location.history(for: profile).first(where: readable) else { continue }

			let owner = profile.map(\.source) ?? defaultProfile
			history += try FirefoxPlaces.withCopy(of: file) { try SafariHistory.records($0, profile: owner) }
		}

		var records = try SafariBookmarks.records(bookmarks)
		records += SafariTabs.records(tabs)
		records += history
		return .init(id: MigrationBrowserSources.snapshotID(records), records: records)
	}

	/// The space holding a profile's bookmarks and the tabs of its windows.
	internal static func space(of profile: MigrationSourceProfile) -> MigrationSourceSpace {
		.init(
			id: profile.id + MigrationBrowserSources.spaceSeparator + "safari",
			name: profile.name,
			profile: profile
		)
	}
}

// MARK: - Bookmarks

/// Reads `Bookmarks.plist`: nested dictionaries with `WebBookmarkType` of
/// `WebBookmarkTypeList` (a folder, with `Title` and `Children`), `WebBookmarkTypeLeaf`
/// (a link, with `URLString` and `URIDictionary.title`) or `WebBookmarkTypeProxy` (History).
internal enum SafariBookmarks {
	internal static let readingList: String = "com.apple.ReadingList"

	internal static func records(_ data: Data) throws -> [MigrationRecord] {
		guard
			let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
			root["WebBookmarkType"] as? String == "WebBookmarkTypeList"
		else {
			throw MigrationFailure.unreadableSource("Safari's bookmarks file has an unknown format.")
		}

		let profile = SafariData.defaultProfile
		let space = SafariData.space(of: profile)
		var records: [MigrationRecord] = [
			.init(sourceItemID: "space:" + space.id, kind: .space, category: .bookmarks, space: space),
		]
		for child in children(of: root) {
			// Links and anything else at the top level go through `walk` like any bookmark.
			let title = child["WebBookmarkType"] as? String == "WebBookmarkTypeList"
			? child["Title"] as? String ?? ""
			: nil
			switch title {
			case "BookmarksBar"?:
				for item in children(of: child) {
					if item["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf" {
						records.append(link(item, category: .favorites, folders: [], space: nil, profile: profile))
					} else {
						walk(item, folders: [], space: space, records: &records)
					}
				}

			case "BookmarksMenu"?:
				for item in children(of: child) {
					walk(item, folders: [], space: space, records: &records)
				}

			case readingList?:
				let folder: MigrationSourceFolder = .init(id: id(of: child), name: "Reading List")
				for item in children(of: child) {
					walk(item, folders: [folder], space: space, records: &records)
				}

			default:
				walk(child, folders: [], space: space, records: &records)
			}
		}
		return records
	}

	private static func children(of node: [String: Any]) -> [[String: Any]] {
		node["Children"] as? [[String: Any]] ?? []
	}

	private static func id(of node: [String: Any]) -> String {
		"bookmark:" + (node["WebBookmarkUUID"] as? String ?? UUID().uuidString)
	}

	private static func link(
		_ node: [String: Any],
		category: MigrationCategory,
		folders: [MigrationSourceFolder],
		space: MigrationSourceSpace?,
		profile: MigrationSourceProfile?
	) -> MigrationRecord {
		let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
		return .init(
			sourceItemID: id(of: node),
			category: category,
			title: title ?? "",
			url: node["URLString"] as? String ?? "",
			folders: folders,
			space: space,
			profile: profile
		)
	}

	private static func walk(
		_ node: [String: Any],
		folders: [MigrationSourceFolder],
		space: MigrationSourceSpace,
		records: inout [MigrationRecord]
	) {
		switch node["WebBookmarkType"] as? String {
		case "WebBookmarkTypeLeaf":
			records.append(link(node, category: .bookmarks, folders: folders, space: space, profile: nil))

		case "WebBookmarkTypeList":
			let folder: MigrationSourceFolder = .init(id: id(of: node), name: node["Title"] as? String ?? "")
			let contents = children(of: node)
			if contents.isEmpty {
				records.append(
					.init(
						sourceItemID: "folder:" + folder.id,
						kind: .folder,
						category: .bookmarks,
						folders: folders + [folder],
						space: space
					)
				)
			}
			for child in contents {
				walk(child, folders: folders + [folder], space: space, records: &records)
			}

		default:
			// The History proxy and anything unknown.
			break
		}
	}
}

// MARK: - Tabs

/// Reads `SafariTabs.db`, which keeps tab groups, profiles and windows in a `bookmarks`
/// table shaped like Safari's bookmarks database, plus `windows`.
///
/// Folders are `type = 1` and tabs `type = 0`. Among folders at the top level
/// (`parent = 0`, `special_id = 0`), `subtype = 0` are the default profile's tab groups and
/// `subtype = 2` are profiles. A profile's tab groups sit in a `subtype = 3` folder under
/// it. A window's ungrouped tabs are in its `local_tab_group_id` folder; its profile is
/// `active_profile_id`. These come from the queries in macOS 27's SafariShared.
internal enum SafariTabs {
	internal struct Profile: Equatable, Sendable {
		internal var id: Int64
		internal var externalID: String
		internal var serverID: String?
		internal var name: String

		internal var source: MigrationSourceProfile {
			.init(id: externalID, name: name.isEmpty ? "Profile" : name)
		}

		/// Names its history folder may have: the server ID, or the local identifier before migration.
		internal var identifiers: [String] {
			[serverID, externalID].compactMap { $0 }.filter { !$0.isEmpty }
		}
	}

	internal struct Tab: Equatable, Sendable {
		internal var externalID: String
		internal var title: String
		internal var url: String
	}

	internal struct Group: Equatable, Sendable {
		internal var externalID: String
		internal var name: String

		/// Nil for the default profile.
		internal var profileID: Int64?
		internal var tabs: [Tab]
	}

	internal struct Window: Equatable, Sendable {
		internal var profileID: Int64?
		internal var tabs: [Tab]
	}

	internal struct Contents: Equatable, Sendable {
		internal var profiles: [Profile] = []
		internal var groups: [Group] = []
		internal var windows: [Window] = []
	}

	internal static func read(_ database: SQLiteDatabase) throws -> Contents {
		guard try database.hasTable("bookmarks") else { return .init() }

		let profiles: [Profile] = try database.rows(
			"""
			SELECT id, external_uuid, server_id, title FROM bookmarks
			WHERE parent = 0 AND type = 1 AND subtype = 2 AND special_id = 0 AND deleted = 0
			ORDER BY order_index
			"""
		) { row in
			.init(
				id: row.int(0),
				externalID: row.text(1) ?? "profile-\(row.int(0))",
				serverID: row.text(2),
				name: row.text(3) ?? ""
			)
		}

		// The default profile's groups, then each profile's, through its container folder.
		let groupRows: [(id: Int64, externalID: String, name: String, profileID: Int64?)] = try database.rows(
			"""
			SELECT groups.id, groups.external_uuid, groups.title,
				CASE WHEN groups.parent = 0 THEN NULL ELSE container.parent END
			FROM bookmarks AS groups
			LEFT JOIN bookmarks AS container ON container.id = groups.parent
			WHERE groups.type = 1 AND groups.subtype = 0 AND groups.special_id = 0
				AND groups.hidden = 0 AND groups.deleted = 0
				AND ((groups.parent = 0 AND groups.syncable = 1) OR (container.type = 1 AND container.subtype = 3))
			ORDER BY CASE WHEN groups.parent = 0 THEN 0 ELSE 1 END, groups.order_index
			"""
		) { row in
			(
				row.int(0),
				row.text(1) ?? "group-\(row.int(0))",
				row.text(2) ?? "",
				row.isNull(3) ? nil : row.int(3)
			)
		}
		var windowGroups: Set<Int64> = []
		var windows: [Window] = []
		if try database.hasTable("windows") {
			let hasUnnamed = try database.hasTable("windows_unnamed_tab_groups")
			let unnamed = hasUnnamed ? "UNION SELECT tab_group_id FROM windows_unnamed_tab_groups" : ""
			windowGroups = Set(
				try database.rows(
					"""
					SELECT local_tab_group_id FROM windows WHERE local_tab_group_id IS NOT NULL
					UNION SELECT private_tab_group_id FROM windows WHERE private_tab_group_id IS NOT NULL
					\(unnamed)
					"""
				) { $0.int(0) }
			)
			let privateGroups = Set(
				try database.rows(
					"SELECT private_tab_group_id FROM windows WHERE private_tab_group_id IS NOT NULL"
				) { $0.int(0) }
			)

			// Open windows while Safari runs; after it quits, the ones it restores.
			let query = "SELECT id, local_tab_group_id, active_profile_id FROM windows WHERE %@ ORDER BY id"
			typealias WindowRow = (id: Int64, local: Int64?, profile: Int64?)
			let read: (SQLiteDatabase.Row) -> WindowRow = { row in
				(row.int(0), row.isNull(1) ? nil : row.int(1), row.isNull(2) ? nil : row.int(2))
			}
			var rows: [WindowRow] = try database.rows(
				query.replacingOccurrences(of: "%@", with: "date_closed IS NULL"),
				read
			)
			if rows.isEmpty {
				rows = try database.rows(query.replacingOccurrences(of: "%@", with: "is_last_session = 1"), read)
			}

			for window in rows {
				// A window's ungrouped tabs: its local group, and with profiles, one unnamed
				// group per profile it showed (`windows_unnamed_tab_groups`).
				var groups: [Int64] = window.local.map { [$0] } ?? []
				if hasUnnamed {
					groups += try database.rows(
						"SELECT tab_group_id FROM windows_unnamed_tab_groups WHERE window_id = \(window.id) ORDER BY id"
					) { $0.int(0) }
				}
				var seen: Set<Int64> = []
				for group in groups where !privateGroups.contains(group) && seen.insert(group).inserted {
					// An unnamed group belongs to the profile it sits under, or to the default
					// one at the top level. The local group falls back to the window's profile.
					let owner = try profile(owning: group, database)
					let isLocal = group == window.local
					windows.append(
						.init(
							profileID: isLocal ? owner ?? window.profile : owner,
							tabs: try tabs(in: group, database)
						)
					)
				}
			}
		}

		// A window's own tabs and private tabs are never a named group.
		let groups: [Group] = try groupRows.filter { !windowGroups.contains($0.id) }.map { group in
			.init(
				externalID: group.externalID,
				name: group.name,
				profileID: group.profileID,
				tabs: try tabs(in: group.id, database)
			)
		}

		return .init(profiles: profiles, groups: groups, windows: windows)
	}

	/// The profile a folder sits under, when one of its ancestors is a profile's folder
	/// (`subtype = 2` at the top level). Nil for the default profile's folders.
	private static func profile(
		owning folder: Int64,
		_ database: SQLiteDatabase
	) throws -> Int64? {
		var current = folder
		for _ in 0..<8 {
			let rows: [(parent: Int64, type: Int64, subtype: Int64)] = try database.rows(
				"SELECT parent, type, subtype FROM bookmarks WHERE id = \(current)"
			) { ($0.int(0), $0.int(1), $0.int(2)) }
			guard let row = rows.first else { return nil }

			if current != folder, row.type == 1, row.subtype == 2, row.parent == 0 { return current }
			guard row.parent != 0 else { return nil }

			current = row.parent
		}
		return nil
	}

	private static func tabs(
		in folder: Int64,
		_ database: SQLiteDatabase
	) throws -> [Tab] {
		try database.rows(
			"""
			SELECT id, external_uuid, title, url FROM bookmarks
			WHERE parent = \(folder) AND type = 0 AND deleted = 0
			ORDER BY order_index
			"""
		) { row in
			.init(
				externalID: row.text(1) ?? "tab-\(row.int(0))",
				title: row.text(2) ?? "",
				url: row.text(3) ?? ""
			)
		}
	}

	/// Records for what was read. A group's tabs are known by their own ID; a window's,
	/// which Safari recreates each session, by URL and occurrence.
	internal static func records(_ contents: Contents) -> [MigrationRecord] {
		var owners: [Int64: MigrationSourceProfile] = [:]
		for profile in contents.profiles {
			owners[profile.id] = profile.source
		}
		func owner(_ id: Int64?) -> MigrationSourceProfile {
			id.flatMap { owners[$0] } ?? SafariData.defaultProfile
		}

		var records: [MigrationRecord] = []
		var occurrences: [String: Int] = [:]
		for window in contents.windows {
			let profile = owner(window.profileID)
			let space = SafariData.space(of: profile)
			for tab in window.tabs {
				let key = profile.id + "/open/" + tab.url
				let occurrence = occurrences[key, default: 0]
				occurrences[key] = occurrence + 1
				records.append(
					.init(
						sourceItemID: key + "#\(occurrence)",
						category: .openTabs,
						title: tab.title,
						url: tab.url,
						space: space
					)
				)
			}
		}

		for group in contents.groups {
			let profile = owner(group.profileID)
			let space: MigrationSourceSpace = .init(
				id: profile.id + MigrationBrowserSources.spaceSeparator + group.externalID,
				name: group.name,
				profile: profile
			)

			// Keeps an empty group, and the groups' order.
			records.append(.init(sourceItemID: "space:" + space.id, kind: .space, category: .openTabs, space: space))
			for tab in group.tabs {
				records.append(
					.init(
						sourceItemID: "tab:" + tab.externalID,
						category: .openTabs,
						title: tab.title,
						url: tab.url,
						space: space
					)
				)
			}
		}
		return records
	}
}

// MARK: - History

/// Reads `History.db`: `history_items(id, url)` and `history_visits(history_item,
/// visit_time, title)`, where `visit_time` counts seconds from 1 January 2001. Each visit is a
/// row, so counting them gives the visit count; Safari keeps no typed count (DEV-1015).
internal enum SafariHistory {
	internal static func records(
		_ database: SQLiteDatabase,
		profile: MigrationSourceProfile
	) throws -> [MigrationRecord] {
		guard
			try database.hasTable("history_items"),
			try database.hasTable("history_visits")
		else { return [] }

		// SQLite takes the bare `title` from the row that holds the `MAX`: the latest visit's.
		return try database.rows(
			"""
			SELECT items.url, visits.title, MAX(visits.visit_time), COUNT(*)
			FROM history_items AS items
			JOIN history_visits AS visits ON visits.history_item = items.id
			GROUP BY items.id
			ORDER BY 3 DESC
			"""
		) { row in
			let url = row.text(0) ?? ""
			return .init(
				sourceItemID: "history:" + profile.id + "/" + url,
				category: .history,
				title: row.text(1) ?? "",
				url: url,
				profile: profile,
				lastVisited: Date(timeIntervalSinceReferenceDate: row.double(2)),
				visitCount: Int(row.int(3))
			)
		}
	}
}
