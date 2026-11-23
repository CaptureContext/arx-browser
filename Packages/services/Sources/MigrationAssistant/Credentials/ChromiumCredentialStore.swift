import Foundation
import SQLite3

/// Reads one Chromium profile's saved passwords and persistent cookies (DEV-650).
///
/// `Login Data` and `Cookies` are copied with their logs into a private (0700) temporary
/// folder, opened there, decrypted in memory and deleted. The originals are never opened,
/// and nothing is ever copied into an Arx profile: Chromium deletes rows it can't decrypt,
/// and a copied cookie fails its host hash under Arx's key.
internal enum ChromiumCredentialStore {
	internal struct Contents: Sendable {
		internal var passwords: [CredentialPasswordRecord] = []
		internal var unreadablePasswords: Int = 0

		/// Firefox and Zen logins for HTTP sign-in prompts, which the engine doesn't import
		/// (DEV-896). They stay in the browser and are counted in the summary.
		internal var httpAuthPasswords: Int = 0

		/// Persistent, unexpired and decrypted.
		internal var cookies: [CredentialCookieRecord] = []

		/// By cookie host, without its leading dot.
		internal var sessionOnlyCookies: [String: Int] = [:]

		/// By cookie host, without its leading dot.
		internal var unreadableCookies: [String: Int] = [:]

		/// By password host, for passwords that couldn't be decrypted, so the site still shows.
		internal var unreadablePasswordSites: [String: Int] = [:]

		/// Hosts some cookie was set for as a domain cookie (`.example.com`), which Chromium
		/// refuses for a public suffix, so each is a registrable domain or below one.
		internal var domainCookieHosts: Set<String> = []

		/// Rows that couldn't be decrypted, until every store is read: a pair another store
		/// holds readably isn't counted.
		fileprivate var unreadablePasswordRows: [(key: CredentialUndoRecord.Password, host: String)] = []

		internal init() {}

		internal var grouping: CredentialSiteGrouping {
			.init(domainCookieHosts: domainCookieHosts)
		}
	}

	/// Cookie databases from this version on hash the host into the plaintext.
	internal static let hashedHostVersion: Int = 24

	/// Chromium's profile password store and its account store.
	internal static let loginStores: [String] = ["Login Data", "Login Data For Account"]

	internal static func read(
		profile directory: URL,
		key: ChromiumCipher.Key,
		now: Date
	) throws -> Contents {
		var contents: Contents = .init()
		let fileManager = FileManager.default
		let cookies = directory.appending(path: "Cookies")

		// The profile store first, then the account store Chrome uses when passwords are
		// saved to the Google account but kept on this Mac. A site and username in both
		// is kept once, from the profile store.
		for name in loginStores {
			let logins = directory.appending(path: name)
			guard fileManager.fileExists(atPath: logins.path(percentEncoded: false))
			else { continue }

			try FirefoxPlaces.withCopy(of: logins, logSuffixes: ["-wal", "-journal"]) { database in
				try readPasswords(database, key: key, into: &contents)
			}
		}
		let readable: Set<CredentialUndoRecord.Password> = Set(contents.passwords.map(\.key))
		var unreadable: Set<CredentialUndoRecord.Password> = []
		for row in contents.unreadablePasswordRows where !readable.contains(row.key) {
			guard unreadable.insert(row.key).inserted else { continue }

			contents.unreadablePasswords += 1
			contents.unreadablePasswordSites[row.host, default: 0] += 1
		}
		contents.unreadablePasswordRows = []
		if fileManager.fileExists(atPath: cookies.path(percentEncoded: false)) {
			try FirefoxPlaces.withCopy(of: cookies, logSuffixes: ["-wal", "-journal"]) { database in
				try readCookies(database, key: key, now: now, into: &contents)
			}
		}
		return contents
	}

	/// The sites the contents cover, sorted by host, with counts only.
	internal static func sites(of contents: Contents) -> [CredentialSite] {
		let grouping = contents.grouping
		var sites: [String: CredentialSite] = [:]
		func update(
			_ host: String,
			_ change: (inout CredentialSite) -> Void
		) {
			let key = grouping.site(forHost: host)
			var site = sites[key] ?? .init(host: key)
			change(&site)
			sites[key] = site
		}

		for password in contents.passwords {
			update(passwordHost(password.url, realm: password.signonRealm)) { $0.passwordCount += 1 }
		}
		for host in contents.unreadablePasswordSites.keys {
			update(host) { _ in }
		}
		for cookie in contents.cookies {
			update(cookie.domain) { $0.cookieCount += 1 }
		}
		for (host, count) in contents.sessionOnlyCookies {
			update(host) { $0.sessionOnlyCookieCount += count }
		}
		for (host, count) in contents.unreadableCookies {
			update(host) { $0.unreadableCookieCount += count }
		}
		return sites.values.sorted { $0.host < $1.host }
	}

	internal static func passwordHost(
		_ url: String,
		realm: String
	) -> String {
		URL(string: url)?.host() ?? URL(string: realm)?.host() ?? realm
	}

	// MARK: - Passwords

	private static func readPasswords(
		_ database: SQLiteDatabase,
		key: ChromiumCipher.Key,
		into contents: inout Contents
	) throws {
		guard try database.hasTable("logins") else { return }

		// `blacklisted_by_user` marks "never save" sites, which carry no password.
		let rows = try database.rows(
			"""
			SELECT origin_url, signon_realm, username_value, password_value
			FROM logins
			WHERE blacklisted_by_user = 0
			"""
		) { row in
			(
				url: row.text(0) ?? "",
				realm: row.text(1) ?? "",
				username: row.text(2) ?? "",
				blob: row.blob(3)
			)
		}

		// A pair is taken once, from the first row that decrypts: a damaged copy never hides
		// a readable one, in this store or the other.
		var seen: Set<CredentialUndoRecord.Password> = Set(contents.passwords.map(\.key))
		for row in rows where !row.blob.isEmpty {
			let pair: CredentialUndoRecord.Password = .init(signonRealm: row.realm, username: row.username)
			guard !seen.contains(pair) else { continue }

			do {
				let plain = try ChromiumCipher.decrypt(row.blob, with: key)
				guard
					let password = String(data: plain, encoding: .utf8),
					!password.isEmpty
				else { throw ChromiumCipher.Failure.undecryptable }

				contents.passwords.append(
					.init(
						url: row.url,
						signonRealm: row.realm,
						username: row.username,
						password: password
					)
				)
				seen.insert(pair)
			} catch {
				contents.unreadablePasswordRows.append((pair, passwordHost(row.url, realm: row.realm)))
			}
		}
	}

	// MARK: - Cookies

	private static func readCookies(
		_ database: SQLiteDatabase,
		key: ChromiumCipher.Key,
		now: Date,
		into contents: inout Contents
	) throws {
		guard try database.hasTable("cookies") else { return }

		let version = try database.hasTable("meta")
		? try database.rows("SELECT value FROM meta WHERE key = 'version'") { Int($0.text(0) ?? "") ?? 0 }.first ?? 0
		: 0
		let columns: Set<String> = Set(try database.rows("PRAGMA table_info(cookies)") { $0.text(1) ?? "" })
		func column(
			_ name: String,
			or fallback: String
		) -> String {
			columns.contains(name) ? name : "\(fallback) AS \(name)"
		}

		let rows = try database.rows(
			"""
			SELECT host_key, name, value, encrypted_value, path,
				creation_utc, expires_utc, last_access_utc,
				is_secure, is_httponly, samesite, priority, is_persistent,
				\(column("source_scheme", or: "0")), \(column("source_port", or: "-1")),
				\(column("top_frame_site_key", or: "''")), \(column("has_cross_site_ancestor", or: "0"))
			FROM cookies
			"""
		) { row in
			Row(
				domain: row.text(0) ?? "",
				name: row.text(1) ?? "",
				plainValue: row.text(2) ?? "",
				encrypted: row.blob(3),
				path: row.text(4) ?? "/",
				created: row.int(5),
				expires: row.int(6),
				lastAccessed: row.int(7),
				isSecure: row.int(8) != 0,
				isHTTPOnly: row.int(9) != 0,
				sameSite: Int(row.int(10)),
				priority: Int(row.int(11)),
				isPersistent: row.int(12) != 0,
				sourceScheme: Int(row.int(13)),
				sourcePort: Int(row.int(14)),
				topFrameSiteKey: row.text(15) ?? "",
				hasCrossSiteAncestor: row.int(16) != 0
			)
		}
		for row in rows {
			let site = CredentialSiteGrouping.normalized(row.domain)
			if row.domain.hasPrefix(".") { contents.domainCookieHosts.insert(site) }
			guard row.isPersistent else {
				contents.sessionOnlyCookies[site, default: 0] += 1
				continue
			}

			let expires = date(fromChromiumTime: row.expires)
			guard expires > now else { continue }

			let value: String
			if row.encrypted.isEmpty {
				value = row.plainValue
			} else {
				do {
					let plain = try ChromiumCipher.decryptCookie(
						row.encrypted,
						host: row.domain,
						hashesHost: version >= hashedHostVersion,
						with: key
					)
					guard let text = String(data: plain, encoding: .utf8) else {
						throw ChromiumCipher.Failure.undecryptable
					}

					value = text
				} catch {
					contents.unreadableCookies[site, default: 0] += 1
					continue
				}
			}
			contents.cookies.append(
				.init(
					domain: row.domain,
					name: row.name,
					value: value,
					path: row.path,
					created: date(fromChromiumTime: row.created),
					expires: expires,
					lastAccessed: date(fromChromiumTime: row.lastAccessed),
					isSecure: row.isSecure,
					isHTTPOnly: row.isHTTPOnly,
					sameSite: row.sameSite,
					priority: row.priority,
					sourceScheme: row.sourceScheme,
					sourcePort: row.sourcePort,
					topFrameSiteKey: row.topFrameSiteKey,
					hasCrossSiteAncestor: row.hasCrossSiteAncestor
				)
			)
		}
	}

	private struct Row {
		internal var domain: String
		internal var name: String
		internal var plainValue: String
		internal var encrypted: Data
		internal var path: String
		internal var created: Int64
		internal var expires: Int64
		internal var lastAccessed: Int64
		internal var isSecure: Bool
		internal var isHTTPOnly: Bool
		internal var sameSite: Int
		internal var priority: Int
		internal var isPersistent: Bool
		internal var sourceScheme: Int
		internal var sourcePort: Int
		internal var topFrameSiteKey: String
		internal var hasCrossSiteAncestor: Bool
	}

	/// Chromium stores times as microseconds since 1601-01-01 UTC.
	private static let secondsFrom1601To1970: Double = 11_644_473_600

	internal static func date(fromChromiumTime microseconds: Int64) -> Date {
		return Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - secondsFrom1601To1970)
	}

	internal static func chromiumTime(from date: Date) -> Int64 {
		return Int64((date.timeIntervalSince1970 + secondsFrom1601To1970) * 1_000_000)
	}
}
