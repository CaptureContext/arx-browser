import BrowserCore
import Foundation

/// One decrypted saved password, on its way to the engine. Its descriptions never show
/// the password, so a stray `print` or dump can't leak it.
public struct CredentialPasswordRecord: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
	/// `origin_url` as the source saved it.
	public var url: String
	public var signonRealm: String
	public var username: String
	public var password: String

	public init(
		url: String,
		signonRealm: String,
		username: String,
		password: String
	) {
		self.url = url
		self.signonRealm = signonRealm
		self.username = username
		self.password = password
	}

	public var key: CredentialUndoRecord.Password {
		.init(signonRealm: signonRealm, username: username)
	}

	public var description: String { "CredentialPasswordRecord(\(signonRealm), \(username), <redacted>)" }
	public var debugDescription: String { description }
}

/// One decrypted persistent cookie with the fields `SetCanonicalCookie` needs to keep its
/// identity: scheme, port and partition.
public struct CredentialCookieRecord: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
	/// `host_key` as stored: a leading dot marks a domain cookie.
	public var domain: String
	public var name: String
	public var value: String
	public var path: String
	public var created: Date
	public var expires: Date
	public var lastAccessed: Date
	public var isSecure: Bool
	public var isHTTPOnly: Bool

	/// Chromium's `CookieSameSite`: -1 unspecified, 0 none, 1 lax, 2 strict.
	public var sameSite: Int

	/// Chromium's `CookiePriority`: 0 low, 1 medium, 2 high.
	public var priority: Int

	/// Chromium's `CookieSourceScheme`: 0 unset, 1 non-secure, 2 secure.
	public var sourceScheme: Int

	/// -1 when unknown.
	public var sourcePort: Int

	/// Empty for an unpartitioned cookie.
	public var topFrameSiteKey: String
	public var hasCrossSiteAncestor: Bool

	public init(
		domain: String,
		name: String,
		value: String,
		path: String,
		created: Date,
		expires: Date,
		lastAccessed: Date,
		isSecure: Bool,
		isHTTPOnly: Bool,
		sameSite: Int,
		priority: Int,
		sourceScheme: Int,
		sourcePort: Int,
		topFrameSiteKey: String = "",
		hasCrossSiteAncestor: Bool = false
	) {
		self.domain = domain
		self.name = name
		self.value = value
		self.path = path
		self.created = created
		self.expires = expires
		self.lastAccessed = lastAccessed
		self.isSecure = isSecure
		self.isHTTPOnly = isHTTPOnly
		self.sameSite = sameSite
		self.priority = priority
		self.sourceScheme = sourceScheme
		self.sourcePort = sourcePort
		self.topFrameSiteKey = topFrameSiteKey
		self.hasCrossSiteAncestor = hasCrossSiteAncestor
	}

	public var description: String { "CredentialCookieRecord(\(domain), \(name), <redacted>)" }
	public var debugDescription: String { description }
}

/// What one batch added, so Undo removes exactly that and nothing Arx had before.
/// Keys only, no values.
public struct CredentialUndoRecord: Equatable, Sendable {
	public struct Password: Hashable, Sendable {
		public var signonRealm: String
		public var username: String

		/// The engine's creation stamp for the entry it added. Undo removes the entry only
		/// while it still has this stamp, so a password the user saved again stays.
		public var dateCreated: String

		public init(
			signonRealm: String,
			username: String,
			dateCreated: String = ""
		) {
			self.signonRealm = signonRealm
			self.username = username
			self.dateCreated = dateCreated
		}
	}

	/// A cookie's full identity as Chromium keys it: name, domain and path, its partition
	/// (top-frame site and cross-site ancestor) and, for scheme-bound cookies, its source
	/// scheme and port. Undo removes only a cookie matching all of them, never a sibling
	/// Arx already had.
	public struct Cookie: Hashable, Sendable {
		public var domain: String
		public var name: String
		public var path: String
		public var topFrameSiteKey: String
		public var hasCrossSiteAncestor: Bool
		public var sourceScheme: Int
		public var sourcePort: Int

		public init(
			domain: String,
			name: String,
			path: String,
			topFrameSiteKey: String = "",
			hasCrossSiteAncestor: Bool = false,
			sourceScheme: Int = 0,
			sourcePort: Int = -1
		) {
			self.domain = domain
			self.name = name
			self.path = path
			self.topFrameSiteKey = topFrameSiteKey
			self.hasCrossSiteAncestor = hasCrossSiteAncestor
			self.sourceScheme = sourceScheme
			self.sourcePort = sourcePort
		}

		public init(_ record: CredentialCookieRecord) {
			self.init(
				domain: record.domain,
				name: record.name,
				path: record.path,
				topFrameSiteKey: record.topFrameSiteKey,
				hasCrossSiteAncestor: record.hasCrossSiteAncestor,
				sourceScheme: record.sourceScheme,
				sourcePort: record.sourcePort
			)
		}
	}

	public var profileID: Profile.ID
	public var passwords: [Password]
	public var cookies: [Cookie]

	public init(
		profileID: Profile.ID,
		passwords: [Password] = [],
		cookies: [Cookie] = []
	) {
		self.profileID = profileID
		self.passwords = passwords
		self.cookies = cookies
	}
}

/// How decrypted records reach an Arx profile. AppFeature serves it with the engine's
/// in-memory import calls (ABI46, DEV-830) through `MigrationAssistantFeature`'s
/// `.browserEngine` writer. On an engine without them the writer reports itself
/// unavailable, and the step offers the CSV import instead without reading the Keychain.
public struct CredentialDestinationWriter: Sendable {
	public struct PasswordImport: Equatable, Sendable {
		public var imported: [CredentialUndoRecord.Password]

		/// May be stored: the engine began the write but couldn't confirm it. Counted
		/// in `skipped`, and kept in the batch's undo record all the same.
		public var unconfirmed: [CredentialUndoRecord.Password]
		public var conflicts: Int
		public var skipped: Int

		public init(
			imported: [CredentialUndoRecord.Password],
			unconfirmed: [CredentialUndoRecord.Password] = [],
			conflicts: Int = 0,
			skipped: Int = 0
		) {
			self.imported = imported
			self.unconfirmed = unconfirmed
			self.conflicts = conflicts
			self.skipped = skipped
		}
	}

	/// What the engine did with each cookie, by its full key. The client groups them into
	/// sites itself, so the engine needs no notion of a site.
	public struct CookieImport: Equatable, Sendable {
		public var accepted: [CredentialUndoRecord.Cookie]

		/// Arx already had a cookie with that key; Arx's was kept.
		public var existing: [CredentialUndoRecord.Cookie]
		public var rejected: [CredentialUndoRecord.Cookie]

		/// Also in `rejected`, but may be stored; kept in the undo record.
		public var unconfirmed: [CredentialUndoRecord.Cookie]

		public init(
			accepted: [CredentialUndoRecord.Cookie],
			existing: [CredentialUndoRecord.Cookie] = [],
			rejected: [CredentialUndoRecord.Cookie] = [],
			unconfirmed: [CredentialUndoRecord.Cookie] = []
		) {
			self.accepted = accepted
			self.existing = existing
			self.rejected = rejected
			self.unconfirmed = unconfirmed
		}
	}

	/// Whether the engine takes decrypted records. Checked before any Keychain read.
	public var isAvailable: @Sendable () async -> Bool

	/// Imports into one ordinary profile's own store, keeping existing site and username pairs.
	public var importPasswords: @Sendable (Profile.ID, [CredentialPasswordRecord]) async throws -> PasswordImport

	/// Sets cookies in one ordinary profile, keeping cookies Arx already has.
	public var setCookies: @Sendable (Profile.ID, [CredentialCookieRecord]) async throws -> CookieImport

	/// Reads the profile's cookies back and answers which of these keys it holds now.
	/// Nil when the engine can't read them back, so sites are reported as not checked.
	public var checkCookies: @Sendable (Profile.ID, [CredentialUndoRecord.Cookie]) async -> Set<CredentialUndoRecord.Cookie>?

	/// Removes exactly what a batch added.
	public var undo: @Sendable (CredentialUndoRecord) async throws -> Void

	public init(
		isAvailable: @escaping @Sendable () async -> Bool,
		importPasswords: @escaping @Sendable (Profile.ID, [CredentialPasswordRecord]) async throws -> PasswordImport,
		setCookies: @escaping @Sendable (Profile.ID, [CredentialCookieRecord]) async throws -> CookieImport,
		checkCookies: @escaping @Sendable (Profile.ID, [CredentialUndoRecord.Cookie]) async -> Set<CredentialUndoRecord.Cookie>?,
		undo: @escaping @Sendable (CredentialUndoRecord) async throws -> Void
	) {
		self.isAvailable = isAvailable
		self.importPasswords = importPasswords
		self.setCookies = setCookies
		self.checkCookies = checkCookies
		self.undo = undo
	}

	public static var unavailable: Self {
		.init(
			isAvailable: { false },
			importPasswords: { _, _ in throw CredentialMigrationFailure.writerUnavailable },
			setCookies: { _, _ in throw CredentialMigrationFailure.writerUnavailable },
			checkCookies: { _, _ in nil },
			undo: { _ in throw CredentialMigrationFailure.writerUnavailable }
		)
	}
}
