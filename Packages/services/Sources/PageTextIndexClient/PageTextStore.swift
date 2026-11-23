import BrowserCore
import Foundation
import SQLite3

/// One SQLite file per profile, `<profile>.text.sqlite` beside its history: a table of pages and
/// a full-text index of their titles and words. Deleted text is overwritten, not left in free
/// pages, and clearing a profile deletes its file. Serial, as an actor.
internal actor PageTextStore {
	private let directory: URL
	private var connections: [Profile.ID: OpaquePointer] = [:]

	/// The newest generation each profile's pages were cleared or pruned at: a page read at an
	/// older one is from before that, so it isn't saved however late it arrives.
	private var clearedGenerations: [Profile.ID: Int] = [:]

	/// The generation each page saved in this run was read at, by address, while it's in the
	/// index. A removal at a generation takes only pages read before it, so it applies whenever it
	/// arrives, even after a newer one, and never takes a page read since (DEV-1098). Pages from an
	/// earlier run are older than every removal in this one.
	private var savedGenerations: [Profile.ID: [String: Int]] = [:]

	internal init(directory: URL) {
		self.directory = directory
	}

	internal func save(
		_ page: PageText,
		profileID: Profile.ID,
		generation: Int
	) {
		let url = page.url.absoluteString

		// A read from before the page's saved text, arriving after it, would put older text under
		// a newer generation, where a clear between them would leave it (DEV-1098).
		guard
			generation >= clearedGenerations[profileID, default: .min],
			generation >= savedGenerations[profileID]?[url] ?? .min,
			let database = connection(profileID, creates: true)
		else { return }

		let text = Self.bounded(page.text)
		let title = Self.bounded(page.title, limit: 1_000)
		var saved = false
		var evicted: [String] = []
		Self.transaction(database) {
			guard
				let id = Self.queryInt(
					database,
					"INSERT INTO pages(url, visited) VALUES(?1, ?2) ON CONFLICT(url) DO UPDATE SET visited = excluded.visited RETURNING id",
					[.text(url), .real(page.visited.timeIntervalSince1970)]
				)
			else { return false }

			Self.run(database, "DELETE FROM page_text WHERE rowid = ?1", [.integer(id)])
			Self.run(database, "INSERT INTO page_text(rowid, title, body) VALUES(?1, ?2, ?3)", [.integer(id), .text(title), .text(text)])

			// The oldest pages go once there are more than the limit.
			let count = Self.queryInt(database, "SELECT count(*) FROM pages", []).map(Int.init) ?? 0
			let excess = count - PageTextIndexClient.maximumPages
			if excess > 0 {
				let oldest = "SELECT id FROM pages ORDER BY visited ASC LIMIT \(excess)"
				evicted = Self.queryTexts(database, "SELECT url FROM pages WHERE id IN (\(oldest))", [])
				Self.run(database, "DELETE FROM page_text WHERE rowid IN (\(oldest))", [])
				Self.run(database, "DELETE FROM pages WHERE id IN (\(oldest))", [])
			}
			saved = true
			return true
		}
		guard saved else { return }
		savedGenerations[profileID, default: [:]][url] = generation
		forget(evicted, profileID: profileID)
	}

	internal func search(
		_ query: String,
		limit: Int,
		profileID: Profile.ID
	) -> [PageTextHit] {
		guard
			let expression = Self.matchExpression(query),
			let database = connection(profileID, creates: false)
		else { return [] }

		var statement: OpaquePointer?
		let sql = """
		SELECT pages.url, snippet(page_text, 1, '', '', '…', 16) FROM page_text
		JOIN pages ON pages.id = page_text.rowid
		WHERE page_text MATCH ?1 ORDER BY rank LIMIT ?2
		"""
		guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
		defer { sqlite3_finalize(statement) }

		Self.bind(statement, [.text(expression), .integer(Int64(max(1, limit)))])
		var hits: [PageTextHit] = []
		while sqlite3_step(statement) == SQLITE_ROW {
			guard
				let urlText = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
				let url = URL(string: urlText)
			else { continue }

			let passage = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
			hits.append(.init(url: url, passage: Self.collapsed(passage)))
		}
		return hits
	}

	internal func clear(
		_ profileID: Profile.ID,
		generation: Int
	) {
		let kept = record(profileID, at: generation)

		// Pages read after this clear stay, when it arrived late; everything else goes.
		guard kept.isEmpty else {
			guard let database = connection(profileID, creates: false) else { return }
			forget(Self.remove(database, where: "1", [], keeping: kept), profileID: profileID)

			// Always, since a kept page may have replaced its own text from before the clear.
			Self.purge(database)
			return
		}
		savedGenerations[profileID] = nil
		close(profileID)
		let file = file(profileID)
		for suffix in ["", "-journal", "-wal", "-shm"] {
			try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + suffix))
		}
	}

	internal func clear(
		_ profileID: Profile.ID,
		since: Date,
		generation: Int
	) {
		let kept = record(profileID, at: generation)
		guard let database = connection(profileID, creates: false) else { return }

		let removed = Self.remove(database, where: "visited >= ?1", [.real(since.timeIntervalSince1970)], keeping: kept)
		forget(removed, profileID: profileID)
		Self.purge(database)
	}

	internal func retain(
		_ urls: Set<URL>,
		profileID: Profile.ID,
		generation: Int
	) {
		let kept = record(profileID, at: generation)
		guard let database = connection(profileID, creates: false) else { return }

		let removed = Self.remove(
			database,
			where: "1",
			[],
			keeping: kept.union(urls.map(\.absoluteString))
		)
		forget(removed, profileID: profileID)

		// Each launch matches the index to history; it's rewritten only when pages went, or when it
		// arrived late and kept a page read since, which may have replaced its own earlier text.
		if !removed.isEmpty || !kept.isEmpty { Self.purge(database) }
	}

	internal func size(_ profileID: Profile.ID) -> Int? {
		let attributes = try? FileManager.default.attributesOfItem(atPath: file(profileID).path)
		return (attributes?[.size] as? NSNumber)?.intValue
	}

	// MARK: - Connections

	/// Records a clear, range or prune at `generation`, and returns the pages it must leave: those
	/// read at it or later. Removals run in their own tasks, so one may arrive after a newer one,
	/// which doesn't cover it: a narrower range, say (DEV-1098). It still applies, to the pages
	/// read before it.
	private func record(
		_ profileID: Profile.ID,
		at generation: Int
	) -> Set<String> {
		clearedGenerations[profileID] = max(generation, clearedGenerations[profileID, default: .min])
		let saved = savedGenerations[profileID] ?? [:]
		return Set(saved.filter { $0.value >= generation }.keys)
	}

	/// Drops the generations of pages no longer in the index, so the record stays as small as it.
	private func forget(
		_ urls: [String],
		profileID: Profile.ID
	) {
		guard !urls.isEmpty else { return }
		for url in urls {
			savedGenerations[profileID]?[url] = nil
		}
	}

	private func file(_ profileID: Profile.ID) -> URL {
		directory.appendingPathComponent(profileID.rawValue.uuidString + ".text.sqlite")
	}

	private func connection(
		_ profileID: Profile.ID,
		creates: Bool
	) -> OpaquePointer? {
		if let existing = connections[profileID] { return existing }

		let file = file(profileID)
		guard creates || FileManager.default.fileExists(atPath: file.path) else { return nil }

		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var database: OpaquePointer?
		let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
		guard sqlite3_open_v2(file.path, &database, flags, nil) == SQLITE_OK, let database else {
			sqlite3_close(database)
			return nil
		}
		let schema = """
		PRAGMA secure_delete = ON;
		CREATE TABLE IF NOT EXISTS pages(id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, visited REAL NOT NULL);
		CREATE INDEX IF NOT EXISTS pages_visited ON pages(visited);
		CREATE VIRTUAL TABLE IF NOT EXISTS page_text USING fts5(title, body, tokenize = 'unicode61 remove_diacritics 2');
		"""
		guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
			sqlite3_close(database)
			return nil
		}
		connections[profileID] = database
		return database
	}

	private func close(_ profileID: Profile.ID) {
		guard let database = connections.removeValue(forKey: profileID) else { return }
		sqlite3_close(database)
	}

	// MARK: - Text

	/// The query's words, each matching any word it begins: `"word"*`, all of them required.
	/// Nil without a word.
	internal static func matchExpression(_ query: String) -> String? {
		let words = query
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
			.prefix(8)
		guard !words.isEmpty else { return nil }
		return words.map { "\"" + $0 + "\"*" }.joined(separator: " ")
	}

	/// At most `limit` characters, without splitting one.
	internal static func bounded(
		_ text: String,
		limit: Int = PageTextIndexClient.maximumCharacters
	) -> String {
		text.count > limit ? String(text.prefix(limit)) : text
	}

	private static func collapsed(_ text: String) -> String {
		text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	// MARK: - SQL

	private enum SQLValue {
		case text(String)
		case integer(Int64)
		case real(Double)
	}

	/// The SQLITE_TRANSIENT destructor: SQLite copies bound text at once.
	private static let transient: sqlite3_destructor_type = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

	private static func bind(
		_ statement: OpaquePointer?,
		_ values: [SQLValue]
	) {
		for (index, value) in values.enumerated() {
			let position = Int32(index + 1)
			switch value {
			case let .text(text): sqlite3_bind_text(statement, position, text, -1, transient)
			case let .integer(number): sqlite3_bind_int64(statement, position, number)
			case let .real(number): sqlite3_bind_double(statement, position, number)
			}
		}
	}

	@discardableResult
	private static func run(
		_ database: OpaquePointer,
		_ sql: String,
		_ values: [SQLValue]
	) -> Bool {
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
		defer { sqlite3_finalize(statement) }

		bind(statement, values)
		var result = sqlite3_step(statement)
		while result == SQLITE_ROW { result = sqlite3_step(statement) }
		return result == SQLITE_DONE
	}

	private static func queryInt(
		_ database: OpaquePointer,
		_ sql: String,
		_ values: [SQLValue]
	) -> Int64? {
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
		defer { sqlite3_finalize(statement) }

		bind(statement, values)
		guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
		let value = sqlite3_column_int64(statement, 0)

		// Steps past the row, so a RETURNING statement finishes its write.
		while sqlite3_step(statement) == SQLITE_ROW {}
		return value
	}

	/// The first column of every row.
	private static func queryTexts(
		_ database: OpaquePointer,
		_ sql: String,
		_ values: [SQLValue]
	) -> [String] {
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
		defer { sqlite3_finalize(statement) }

		bind(statement, values)
		var texts: [String] = []
		while sqlite3_step(statement) == SQLITE_ROW {
			guard let text = sqlite3_column_text(statement, 0) else { continue }
			texts.append(String(cString: text))
		}
		return texts
	}

	/// Deletes the pages matching `condition`, but for the addresses in `kept`, with their words.
	/// Returns the addresses that went.
	private static func remove(
		_ database: OpaquePointer,
		where condition: String,
		_ values: [SQLValue],
		keeping kept: Set<String>
	) -> [String] {
		var removed: [String] = []
		transaction(database) {
			run(database, "CREATE TEMP TABLE IF NOT EXISTS kept(url TEXT PRIMARY KEY)", [])
			run(database, "DELETE FROM kept", [])
			for url in kept {
				run(database, "INSERT OR IGNORE INTO kept(url) VALUES(?1)", [.text(url)])
			}
			let gone = "SELECT id FROM pages WHERE (\(condition)) AND url NOT IN (SELECT url FROM kept)"
			removed = queryTexts(database, "SELECT url FROM pages WHERE id IN (\(gone))", values)
			if !removed.isEmpty {
				run(database, "DELETE FROM page_text WHERE rowid IN (\(gone))", values)
				run(database, "DELETE FROM pages WHERE id IN (\(gone))", values)
			}
			run(database, "DELETE FROM kept", [])
			return true
		}
		return removed
	}

	/// Merges the index's segments, so the words of deleted pages are gone from it too, not only
	/// marked deleted; with secure delete on, the space they took is overwritten.
	private static func purge(_ database: OpaquePointer) {
		run(database, "INSERT INTO page_text(page_text) VALUES('optimize')", [])
	}

	/// Runs `body` in a transaction, kept when it returns true.
	private static func transaction(
		_ database: OpaquePointer,
		_ body: () -> Bool
	) {
		guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
		let commits = body()
		sqlite3_exec(database, commits ? "COMMIT" : "ROLLBACK", nil, nil, nil)
	}
}
