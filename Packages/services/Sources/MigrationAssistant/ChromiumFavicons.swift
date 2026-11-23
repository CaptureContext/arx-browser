import BrowserCore
import Foundation

/// Reads page icons from a Chromium profile's `Favicons` database (DEV-897), so imported
/// Favorites and pinned tabs show their real icons before their pages load.
///
/// `icon_mapping(page_url, icon_id)` names each page's icons, `favicons(id, url, icon_type)`
/// the icons and `favicon_bitmaps(icon_id, width, image_data)` their PNGs. A page takes its
/// own favicon (`icon_type` 1), else the newest one of a page on the same origin, at the
/// smallest width of at least 32 pixels, else the widest. Only PNGs up to Arx's site icon
/// limit are kept. The database is read from a private copy.
internal enum ChromiumFavicons {
	/// `BrowserSiteIconStore`'s per-icon limit.
	internal static let maximumBytes: Int = 64 * 1024
	internal static let maximumPages: Int = 1000
	internal static let preferredWidth: Int = 32

	private static let pngSignature: Data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

	/// Icons by page address, for the pages that have one.
	internal static func icons(
		_ database: SQLiteDatabase,
		pages: [String]
	) throws -> [String: Data] {
		guard
			try database.hasTable("icon_mapping"),
			try database.hasTable("favicons"),
			try database.hasTable("favicon_bitmaps")
		else { return [:] }

		var icons: [String: Data] = [:]
		for page in pages.prefix(maximumPages) where icons[page] == nil {
			guard
				let url = URL(string: page),
				url.hasWebScheme,
				let host = url.host()
			else { continue }

			let withoutFragment = page.split(separator: "#", maxSplits: 1).first.map(String.init) ?? page
			if let icon = try lookUp(database, exact: [page, withoutFragment]) {
				icons[page] = icon
				continue
			}

			let port = url.port.map { ":\($0)" } ?? ""
			let origin = "\(url.scheme!.lowercased())://\(host.lowercased())\(port)"
			icons[page] = try lookUp(database, origin: origin)
		}
		return icons
	}

	private static func lookUp(
		_ database: SQLiteDatabase,
		exact pages: [String]
	) throws -> Data? {
		for page in Set(pages).sorted() {
			let found = try first(database, where: "icon_mapping.page_url = \(literal(page))", order: "")
			if let found { return found }
		}
		return nil
	}

	private static func lookUp(
		_ database: SQLiteDatabase,
		origin: String
	) throws -> Data? {
		// Every page under the origin: its address sorts between "<origin>/" and "<origin>0".
		try first(
			database,
			where: "icon_mapping.page_url >= \(literal(origin + "/")) AND icon_mapping.page_url < \(literal(origin + "0"))",
			order: "icon_mapping.page_url = \(literal(origin + "/")) DESC, icon_mapping.id DESC,"
		)
	}

	private static func first(
		_ database: SQLiteDatabase,
		where condition: String,
		order: String
	) throws -> Data? {
		let rows = try database.rows(
			"""
			SELECT favicon_bitmaps.image_data
			FROM icon_mapping
			JOIN favicons ON favicons.id = icon_mapping.icon_id
			JOIN favicon_bitmaps ON favicon_bitmaps.icon_id = favicons.id
			WHERE \(condition) AND favicons.icon_type = 1
				AND length(favicon_bitmaps.image_data) BETWEEN 1 AND \(maximumBytes)
			ORDER BY \(order)
				CASE WHEN favicon_bitmaps.width >= \(preferredWidth) THEN favicon_bitmaps.width
				ELSE 1000000 - favicon_bitmaps.width END
			LIMIT 8
			"""
		) { $0.blob(0) }
		return rows.first { $0.starts(with: pngSignature) }
	}

	/// A SQL string literal; addresses come from another browser's files.
	private static func literal(_ text: String) -> String {
		"'" + text.replacingOccurrences(of: "'", with: "''") + "'"
	}

	/// Adds icons to the Favorites and pinned tabs in `records`, reading each profile's
	/// `Favicons` once. A profile whose database can't be read adds none.
	internal static func addingIcons(
		to records: [MigrationRecord],
		directory: (String) -> URL
	) -> [MigrationRecord] {
		var records = records
		var pagesByProfile: [String: [String]] = [:]
		for record in records where record.kind == .tab && [.favorites, .bookmarks].contains(record.category) {
			guard let profile = record.profile?.id ?? record.space?.profile.id else { continue }

			pagesByProfile[profile, default: []].append(record.url)
		}
		var icons: [String: [String: Data]] = [:]

		// A profile is a folder name from the browser's own files; nothing outside User Data.
		for (profile, pages) in pagesByProfile where !profile.contains("/") && !profile.hasPrefix(".") {
			let database = directory(profile).appending(path: "Favicons")
			guard FileManager.default.isReadableFile(atPath: database.path(percentEncoded: false))
			else { continue }

			icons[profile] = try? FirefoxPlaces.withCopy(of: database, logSuffixes: ["-journal", "-wal"]) {
				try Self.icons($0, pages: Array(Set(pages)).sorted())
			}
		}
		for index in records.indices {
			let record = records[index]
			guard
				record.kind == .tab,
				[.favorites, .bookmarks].contains(record.category),
				let profile = record.profile?.id ?? record.space?.profile.id
			else { continue }

			records[index].icon = icons[profile]?[record.url]
		}
		return records
	}
}
