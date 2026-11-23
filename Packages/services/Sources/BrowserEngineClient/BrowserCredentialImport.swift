import BrowserCore
import Foundation

// Passwords and sign-ins moved from another Chromium browser straight into an
// ordinary profile (DEV-650, DEV-830). Only the migration assistant's
// credentials step calls these; MCP and the agent tools never reach them.

/// One decrypted saved password on its way into a profile. Its descriptions
/// never show the password.
public struct BrowserImportedPassword: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
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

	public var description: String { "BrowserImportedPassword(\(signonRealm), \(username), <redacted>)" }
	public var debugDescription: String { description }
}

/// One decrypted persistent cookie with everything that makes up its identity.
/// Its descriptions never show the value.
public struct BrowserImportedCookie: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
	/// `host_key`: a leading dot marks a domain cookie.
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
		topFrameSiteKey: String,
		hasCrossSiteAncestor: Bool
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

	public var description: String { "BrowserImportedCookie(\(domain), \(name), <redacted>)" }
	public var debugDescription: String { description }
}

/// A password the engine imported, as its store keeps it. `dateCreated` is the
/// engine's own creation stamp; undo removes the entry only while it still has it.
public struct BrowserPasswordKey: Hashable, Sendable {
	public var signonRealm: String
	public var username: String
	public var dateCreated: String

	public init(
		signonRealm: String,
		username: String,
		dateCreated: String
	) {
		self.signonRealm = signonRealm
		self.username = username
		self.dateCreated = dateCreated
	}
}

/// A cookie's full identity: name, domain, path, partition, source scheme and port.
/// Unpartitioned cookies always carry `hasCrossSiteAncestor` false.
public struct BrowserCookieKey: Hashable, Sendable {
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
}

public struct BrowserPasswordRecordImport: Equatable, Sendable {
	/// Confirmed stored.
	public var imported: [BrowserPasswordKey]

	/// May be stored: the write began but couldn't be confirmed. Counted as
	/// skipped; keep them for undo, which removes only what the import added.
	public var unconfirmed: [BrowserPasswordKey]

	/// Already saved for that site and username; the saved password was kept.
	public var conflicts: Int
	public var skipped: Int

	public init(
		imported: [BrowserPasswordKey],
		unconfirmed: [BrowserPasswordKey] = [],
		conflicts: Int = 0,
		skipped: Int = 0
	) {
		self.imported = imported
		self.unconfirmed = unconfirmed
		self.conflicts = conflicts
		self.skipped = skipped
	}
}

/// Every cookie in exactly one list, by its full key.
public struct BrowserCookieImport: Equatable, Sendable {
	public var accepted: [BrowserCookieKey]

	/// The profile already had that cookie; it was kept.
	public var existing: [BrowserCookieKey]
	public var rejected: [BrowserCookieKey]

	/// Also in `rejected`, but may be stored. Keep them for undo.
	public var unconfirmed: [BrowserCookieKey]

	public init(
		accepted: [BrowserCookieKey],
		existing: [BrowserCookieKey] = [],
		rejected: [BrowserCookieKey] = [],
		unconfirmed: [BrowserCookieKey] = []
	) {
		self.accepted = accepted
		self.existing = existing
		self.rejected = rejected
		self.unconfirmed = unconfirmed
	}
}

public enum BrowserCredentialImportFailure: Error, Equatable, Sendable {
	/// This engine can't take decrypted records, or the profile is private or retiring.
	case unavailable
	case invalid

	/// Another import is running for that profile.
	case busy
	case failed
}

extension BrowserEngineClient {
	public typealias ImportPasswordRecords = @MainActor @Sendable (
		Profile.ID,
		[BrowserImportedPassword]
	) async throws(BrowserCredentialImportFailure) -> BrowserPasswordRecordImport

	public typealias ImportCookies = @MainActor @Sendable (
		Profile.ID,
		[BrowserImportedCookie]
	) async throws(BrowserCredentialImportFailure) -> BrowserCookieImport

	public typealias CheckCookies = @MainActor @Sendable (
		Profile.ID,
		[BrowserCookieKey]
	) async throws(BrowserCredentialImportFailure) -> Set<BrowserCookieKey>

	public typealias UndoCredentialImport = @MainActor @Sendable (
		Profile.ID,
		_ passwords: [BrowserPasswordKey],
		_ cookies: [BrowserCookieKey]
	) async throws(BrowserCredentialImportFailure) -> Int
}
