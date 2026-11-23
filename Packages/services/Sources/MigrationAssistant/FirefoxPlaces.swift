import Foundation
import SQLite3

/// Reads Firefox-based browsers (Firefox and Zen): their profiles from `profiles.ini`
/// and each profile's bookmarks from `places.sqlite`.
///
/// The browser keeps `places.sqlite` open with a write-ahead log, so the database and
/// its log are copied into a temporary folder and only the copy is opened.
internal enum FirefoxPlaces {
	/// A profile listed in `profiles.ini`.
	internal struct Profile: Equatable, Sendable {
		/// The profile's `Path` as written, which stays the same across renames.
		internal var id: String
		internal var name: String
		internal var directory: URL

		internal init(
			id: String,
			name: String,
			directory: URL
		) {
			self.id = id
			self.name = name
			self.directory = directory
		}

		internal var places: URL { directory.appending(path: "places.sqlite") }
	}

	/// One row of `moz_bookmarks`, joined with its URL from `moz_places`.
	internal struct Bookmark: Equatable, Sendable {
		internal var id: Int64

		/// 1 bookmark, 2 folder, 3 separator.
		internal var type: Int64
		internal var parent: Int64
		internal var position: Int64
		internal var title: String
		internal var guid: String
		internal var url: String?
		internal var pageTitle: String?

		internal init(
			id: Int64,
			type: Int64,
			parent: Int64,
			position: Int64,
			title: String,
			guid: String,
			url: String? = nil,
			pageTitle: String? = nil
		) {
			self.id = id
			self.type = type
			self.parent = parent
			self.position = position
			self.title = title
			self.guid = guid
			self.url = url
			self.pageTitle = pageTitle
		}
	}

	internal static let bookmarkType: Int64 = 1
	internal static let folderType: Int64 = 2

	/// Firefox's built-in roots, by GUID, with the names Firefox shows for them.
	/// The toolbar is the space's top level, like Chromium's bookmarks bar; tags aren't bookmarks.
	internal static let roots: [(guid: String, name: String, nested: Bool)] = [
		("toolbar_____", "Bookmarks Toolbar", false),
		("menu________", "Bookmarks Menu", true),
		("unfiled_____", "Other Bookmarks", true),
		("mobile______", "Mobile Bookmarks", true),
	]

	// MARK: - profiles.ini

	/// Profiles in `profiles.ini`, the default one first, then in the file's order.
	internal static func profiles(
		ini: String,
		root: URL
	) -> [Profile] {
		var sections: [(name: String, values: [String: String])] = []
		for line in ini.split(whereSeparator: \.isNewline) {
			let text = line.trimmingCharacters(in: .whitespaces)
			if text.hasPrefix("["), text.hasSuffix("]") {
				sections.append((String(text.dropFirst().dropLast()), [:]))
			} else if let equals = text.firstIndex(of: "="), !sections.isEmpty, !text.hasPrefix(";"), !text.hasPrefix("#") {
				let key = String(text[..<equals]).trimmingCharacters(in: .whitespaces)
				let value = String(text[text.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
				sections[sections.count - 1].values[key] = value
			}
		}

		// `[Install…] Default=` names the profile the installed app opens.
		let installDefault = sections.first { $0.name.hasPrefix("Install") }?.values["Default"]
		var profiles: [(profile: Profile, isDefault: Bool)] = []
		for section in sections where section.name.hasPrefix("Profile") {
			guard let path = section.values["Path"], !path.isEmpty else { continue }

			let isRelative = section.values["IsRelative"] != "0"
			let directory = isRelative
			? root.appending(path: path, directoryHint: .isDirectory)
			: URL(filePath: path, directoryHint: .isDirectory)
			let name = section.values["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? path
			let isDefault = installDefault.map { $0 == path } ?? (section.values["Default"] == "1")
			profiles.append((.init(id: path, name: name, directory: directory), isDefault))
		}
		return profiles.filter(\.isDefault).map(\.profile) + profiles.filter { !$0.isDefault }.map(\.profile)
	}

	// MARK: - places.sqlite

	/// Every bookmark row.
	internal static func bookmarks(_ database: SQLiteDatabase) throws -> [Bookmark] {
		try database.rows(
				"""
				SELECT b.id, b.type, b.parent, b.position, b.title, b.guid, p.url, p.title
				FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk
				ORDER BY b.parent, b.position, b.id
				"""
			) { row in
				Bookmark(
					id: row.int(0),
					type: row.int(1),
					parent: row.int(2),
					position: row.int(3),
					title: row.text(4) ?? "",
					guid: row.text(5) ?? "",
					url: row.text(6),
					pageTitle: row.text(7)
				)
			}
	}

	/// One history record per page at its latest visit, newest first (DEV-896).
	///
	/// `moz_places(url, title, last_visit_date, hidden, visit_count, typed)`, where
	/// `last_visit_date` counts microseconds since 1970 and `typed` is 1 for an address typed in
	/// the address bar; Firefox keeps no typed count, so it seeds one typed visit (DEV-1015). Hidden pages (subframes, redirect sources) and pages never
	/// visited, such as bookmarks only, are left out, and so are Firefox's own pages:
	/// history is kept for web pages.
	internal static func history(
		_ database: SQLiteDatabase,
		profile: MigrationSourceProfile
	) throws -> [MigrationRecord] {
		guard try database.hasTable("moz_places") else { return [] }

		let visitCount = try database.column("visit_count", in: "moz_places", or: "1")
		let typed = try database.column("typed", in: "moz_places", or: "0")
		return try database.rows(
			"""
			SELECT url, title, last_visit_date, \(visitCount), \(typed)
			FROM moz_places
			WHERE hidden = 0 AND last_visit_date > 0
				AND (url LIKE 'https://%' OR url LIKE 'http://%')
			ORDER BY last_visit_date DESC
			"""
		) { row in
			let url = row.text(0) ?? ""
			return .init(
				sourceItemID: "history:" + profile.id + "/" + url,
				category: .history,
				title: row.text(1) ?? "",
				url: url,
				profile: profile,
				lastVisited: Date(timeIntervalSince1970: Double(row.int(2)) / 1_000_000),
				visitCount: Int(row.int(3)),
				typedCount: row.int(4) > 0 ? 1 : 0
			)
		}
	}

	/// Copies the database and its logs aside, opens the copy, and removes it after.
	///
	/// `logSuffixes` names the logs SQLite applies on open: the write-ahead log, and for
	/// Chromium's stores, which may use a rollback journal, `-journal` too.
	internal static func withCopy<Result>(
		of database: URL,
		logSuffixes: [String] = ["-wal"],
		_ body: (SQLiteDatabase) throws -> Result
	) throws -> Result {
		let fileManager = FileManager.default
		let folder = fileManager.temporaryDirectory
			.appending(path: "arx-migration-\(UUID().uuidString)", directoryHint: .isDirectory)

		// Only this user may read the copies: they can hold encrypted secrets (DEV-650).
		try fileManager.createDirectory(
			at: folder,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		defer { try? fileManager.removeItem(at: folder) }

		let copy = folder.appending(path: database.lastPathComponent)
		let logs: [URL] = logSuffixes.map { suffix in
			database.deletingLastPathComponent().appending(path: database.lastPathComponent + suffix)
		}

		/// Size and modification date, to tell whether the browser wrote during the copy.
		func stamp(_ file: URL) -> [String] {
			let attributes = try? fileManager.attributesOfItem(atPath: file.path(percentEncoded: false))
			return [
				"\(attributes?[.size] ?? "none")",
				"\((attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)",
			]
		}

		func stamps() -> [String] {
			([database] + logs).flatMap(stamp)
		}

		// The database and its logs are separate files. If the browser checkpoints between
		// the copies, they come from different moments, so the copy is retried until
		// no file changed while it was made.
		var isConsistent = false
		for _ in 0..<5 {
			try? fileManager.removeItem(at: copy)
			for log in logs {
				try? fileManager.removeItem(at: folder.appending(path: log.lastPathComponent))
			}
			let before = stamps()
			do {
				try fileManager.copyItem(at: database, to: copy)
				for log in logs where fileManager.fileExists(atPath: log.path(percentEncoded: false)) {
					try fileManager.copyItem(at: log, to: folder.appending(path: log.lastPathComponent))
				}
			} catch {
				throw MigrationFailure.unreadableSource(error.localizedDescription)
			}
			if stamps() == before {
				isConsistent = true
				break
			}
		}
		guard isConsistent else {
			throw MigrationFailure.unreadableSource("The browser kept writing its database while Arx read it. Quit it and try again.")
		}
		let opened = try SQLiteDatabase(copy)
		return try body(opened)
	}

	/// Bookmark records for one profile's space. Separators are skipped.
	internal static func records(
		_ bookmarks: [Bookmark],
		profile: MigrationSourceProfile,
		space: MigrationSourceSpace
	) -> [MigrationRecord] {
		let children: [Int64: [Bookmark]] = Dictionary(grouping: bookmarks, by: \.parent)
		var records: [MigrationRecord] = []

		func walk(
			_ node: Bookmark,
			folders: [MigrationSourceFolder]
		) {
			let id = profile.id + "/" + (node.guid.isEmpty ? "\(node.id)" : node.guid)
			switch node.type {
			case bookmarkType:
				let title = node.title.isEmpty ? node.pageTitle ?? "" : node.title
				records.append(
					.init(
						sourceItemID: id,
						category: .bookmarks,
						title: title,
						url: node.url ?? "",
						folders: folders,
						space: space
					)
				)

			case folderType:
				let contents = children[node.id] ?? []
				let folder: MigrationSourceFolder = .init(id: id, name: node.title)
				if contents.isEmpty {
					records.append(
						.init(
							sourceItemID: "folder:" + id,
							kind: .folder,
							category: .bookmarks,
							folders: folders + [folder],
							space: space
						)
					)
				}
				for child in contents {
					walk(child, folders: folders + [folder])
				}

			default:
				break
			}
		}

		let byGUID: [String: Bookmark] = Dictionary(
			bookmarks.map { ($0.guid, $0) },
			uniquingKeysWith: { first, _ in first }
		)
		for root in roots {
			guard let node = byGUID[root.guid] else { continue }

			let contents = children[node.id] ?? []
			let folders: [MigrationSourceFolder] = root.nested && !contents.isEmpty
			? [.init(id: profile.id + "/" + root.guid, name: root.name)]
			: []
			for child in contents {
				walk(child, folders: folders)
			}
		}
		return records
	}
}

// MARK: - SQLite

/// A minimal read-only view of a SQLite database, enough to run a query and read its rows.
internal final class SQLiteDatabase {
	private var handle: OpaquePointer?

	/// The copy is ours, so it's opened writable by default: SQLite applies the copied log on open.
	internal init(
		_ url: URL,
		flags: Int32 = SQLITE_OPEN_READWRITE
	) throws {
		let status = sqlite3_open_v2(url.path(percentEncoded: false), &handle, flags, nil)
		guard status == SQLITE_OK else {
			let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(status)"

			// `deinit` still runs for this object, so the handle is closed only there.
			throw MigrationFailure.unreadableSource(message)
		}
	}

	deinit {
		sqlite3_close(handle)
	}

	internal struct Row {
		fileprivate let statement: OpaquePointer

		internal func int(_ column: Int32) -> Int64 {
			sqlite3_column_int64(statement, column)
		}

		internal func double(_ column: Int32) -> Double {
			sqlite3_column_double(statement, column)
		}

		internal func text(_ column: Int32) -> String? {
			sqlite3_column_text(statement, column).map { String(cString: $0) }
		}

		internal func blob(_ column: Int32) -> Data {
			let count = Int(sqlite3_column_bytes(statement, column))
			guard
				count > 0,
				let bytes = sqlite3_column_blob(statement, column)
			else { return Data() }

			return Data(bytes: bytes, count: count)
		}

		internal func isNull(_ column: Int32) -> Bool {
			sqlite3_column_type(statement, column) == SQLITE_NULL
		}
	}

	/// Runs statements that return no rows, for writing fixtures.
	internal func execute(_ sql: String) throws {
		guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
			throw MigrationFailure.unreadableSource(String(cString: sqlite3_errmsg(handle)))
		}
	}

	/// Whether the database has a table with this name.
	internal func hasTable(_ name: String) throws -> Bool {
		let names = try rows("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) ?? "" }
		return names.contains(name)
	}

	/// Whether `table` has `column`. `table` must be a name this code wrote, never input.
	internal func hasColumn(
		_ column: String,
		in table: String
	) throws -> Bool {
		let names = try rows("PRAGMA table_info(\(table))") { $0.text(1) ?? "" }
		return names.contains(column)
	}

	/// `column` when `table` has it, else `fallback`, for a `SELECT` over databases from older
	/// browser versions.
	internal func column(
		_ column: String,
		in table: String,
		or fallback: String
	) throws -> String {
		try hasColumn(column, in: table) ? column : fallback
	}

	internal func rows<Value>(
		_ sql: String,
		_ map: (Row) throws -> Value
	) throws -> [Value] {
		var statement: OpaquePointer?
		guard
			sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
			let statement
		else {
			throw MigrationFailure.unreadableSource(String(cString: sqlite3_errmsg(handle)))
		}
		defer { sqlite3_finalize(statement) }

		var values: [Value] = []
		while true {
			switch sqlite3_step(statement) {
			case SQLITE_ROW:
				values.append(try map(Row(statement: statement)))
			case SQLITE_DONE:
				return values
			default:
				throw MigrationFailure.unreadableSource(String(cString: sqlite3_errmsg(handle)))
			}
		}
	}
}

// MARK: - Profiles

/// Builds a snapshot of every profile of a Firefox-based browser.
internal enum MozillaProfiles {
	internal static func snapshot(
		browser: MigrationBrowserSources.MozillaBrowser,
		profiles: [FirefoxPlaces.Profile]
	) throws -> MigrationSnapshot {
		var records: [MigrationRecord] = []
		var history: [MigrationRecord] = []
		for profile in profiles {
			let places = profile.places
			guard FileManager.default.isReadableFile(atPath: places.path(percentEncoded: false))
			else { continue }

			let source: MigrationSourceProfile = .init(id: profile.id, name: profile.name)
			let (bookmarks, storedLayout, visits) = try FirefoxPlaces.withCopy(of: places) { database in
				(
					try FirefoxPlaces.bookmarks(database),
					browser == .zen ? (try? FirefoxSession.zenLayout(database)) ?? .init() : .init(),
					// History that can't be read only means none from this profile.
					(try? FirefoxPlaces.history(database, profile: source)) ?? []
				)
			}
			history += visits
			records += self.records(
				browser: browser,
				profile: profile,
				bookmarks: bookmarks,
				storedLayout: storedLayout,
				session: { name in
					try? Data(contentsOf: profile.directory.appending(path: name))
				}
			)
		}

		// The browser writes history on every visit, and it merges by URL, so it's left out
		// of the snapshot ID like Chromium's (DEV-845): newer rows at commit time do no harm.
		return .init(id: MigrationBrowserSources.snapshotID(records), records: records + history)
	}

	/// One profile's records. Firefox's profile is one space holding its bookmarks and open
	/// tabs. Zen's spaces come from its session file, or from the tables older versions
	/// kept, and its bookmarks get a space of their own.
	internal static func records(
		browser: MigrationBrowserSources.MozillaBrowser,
		profile: FirefoxPlaces.Profile,
		bookmarks: [FirefoxPlaces.Bookmark],
		storedLayout: FirefoxSession.ZenLayout = .init(),
		session: (String) -> Data?
	) -> [MigrationRecord] {
		let source: MigrationSourceProfile = .init(id: profile.id, name: profile.name)
		var records: [MigrationRecord] = []
		var openTabs: [(url: String, title: String)] = []
		var bookmarksSpaceName = profile.name

		switch browser {
		case .firefox:
			// A file that can't be read only means no open tabs.
			for name in FirefoxSession.firefoxFiles {
				guard let json = session(name).flatMap({ try? FirefoxSession.json($0) })
				else { continue }

				openTabs = FirefoxSession.firefoxOpenTabs(json)
				break
			}

		case .zen:
			let current = session(FirefoxSession.zenFile)
				.flatMap { try? FirefoxSession.json($0) }
				.map(FirefoxSession.zenLayout) ?? .init()
			var layout = current.spaces.isEmpty ? storedLayout : current

			// Older Zen's open tabs, or newer Zen's unsynced windows, are in Firefox's session.
			for name in FirefoxSession.firefoxFiles {
				guard let firefox = session(name).flatMap({ try? FirefoxSession.json($0) })
				else { continue }

				layout.tabs += FirefoxSession.zenLegacyOpenTabs(firefox, unsyncedWindowsOnly: !current.spaces.isEmpty)
				break
			}
			if !layout.isEmpty {
				records += FirefoxSession.zenRecords(layout, profile: source)
				bookmarksSpaceName = "Bookmarks"
			}
		}

		let space: MigrationSourceSpace = .init(
			id: profile.id + MigrationBrowserSources.spaceSeparator + browser.rawValue,
			name: bookmarksSpaceName,
			profile: source
		)
		let bookmarkRecords = FirefoxPlaces.records(bookmarks, profile: source, space: space)
		guard !bookmarkRecords.isEmpty || !openTabs.isEmpty else { return records }

		records.append(.init(sourceItemID: "space:" + space.id, kind: .space, category: .bookmarks, space: space))
		records += bookmarkRecords
		var occurrences: [String: Int] = [:]
		for tab in openTabs {
			let occurrence = occurrences[tab.url, default: 0]
			occurrences[tab.url] = occurrence + 1
			records.append(
				.init(
					sourceItemID: profile.id + "/open/" + tab.url + "#\(occurrence)",
					category: .openTabs,
					title: tab.title,
					url: tab.url,
					space: space
				)
			)
		}
		return records
	}
}
