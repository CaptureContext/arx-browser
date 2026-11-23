import BrowserCore
import Foundation

// Passwords and sign-ins from another browser (DEV-650, DEV-896).
//
// Values in this file never reach TCA state, logs, MCP or disk: features see sites,
// usernames' counts and outcomes only. Decrypted records stay inside the client's
// session until they are written or the session is discarded.

/// A source browser whose saved passwords and sign-ins Arx can read directly: after one
/// Keychain approval for Chromium browsers, from the profile's files for Firefox and Zen,
/// and with Full Disk Access for Safari's sign-ins (DEV-896).
public struct CredentialSource: Equatable, Sendable {
	/// What reading the source asks of the user.
	public enum Access: Equatable, Sendable {
		/// macOS asks whether Arx may use this Keychain item, for example "Chrome Safe Storage".
		/// `isVerified` is false while the item's name hasn't been checked against the real
		/// browser; the read is still tried once, and a wrong name reads as missing and leads to CSV.
		case keychain(service: String, isVerified: Bool)

		/// Read from the profile's own files with no prompt: Firefox and Zen without a
		/// primary password.
		case profileFiles

		/// Safari's sign-ins, with the Full Disk Access the import already has. Its
		/// passwords stay in the Passwords app.
		case fullDiskAccess
	}

	public var sourceID: MigrationSource.ID
	public var browserName: String
	public var access: Access

	/// The source browser's profiles. One is read at a time.
	public var profiles: [MigrationSourceProfile]

	public init(
		sourceID: MigrationSource.ID,
		browserName: String,
		access: Access,
		profiles: [MigrationSourceProfile]
	) {
		self.sourceID = sourceID
		self.browserName = browserName
		self.access = access
		self.profiles = profiles
	}

	public init(
		sourceID: MigrationSource.ID,
		browserName: String,
		keychainService: String,
		isKeychainItemVerified: Bool,
		profiles: [MigrationSourceProfile]
	) {
		self.init(
			sourceID: sourceID,
			browserName: browserName,
			access: .keychain(service: keychainService, isVerified: isKeychainItemVerified),
			profiles: profiles
		)
	}

	/// The Keychain item macOS will name in its prompt, when there is one.
	public var keychainService: String? {
		if case let .keychain(service, _) = access { return service }
		return nil
	}

	/// False only for a Keychain item whose name hasn't been checked.
	public var isKeychainItemVerified: Bool {
		if case let .keychain(_, isVerified) = access { return isVerified }
		return true
	}
}

/// Why passwords and sign-ins couldn't be read or written.
public enum CredentialMigrationFailure: Error, Equatable, Sendable {
	/// Arx wasn't the active app. The step runs in the foreground only.
	case notForeground

	/// The device owner didn't confirm.
	case presenceDenied

	/// The user chose Deny in macOS's prompt. Arx doesn't ask again in this run.
	case keyDenied

	/// The browser keeps no readable key: no item, another name, or the data protection keychain.
	case keyMissing

	/// Firefox or Zen protects its logins with a primary password, which Arx doesn't ask for.
	case primaryPassword

	/// A headless run: nobody is there to answer macOS's Keychain or Touch ID prompt, so
	/// nothing is read.
	case unattended

	/// The browser's files couldn't be read.
	case unreadable

	/// This engine can't take decrypted passwords or cookies yet.
	case writerUnavailable

	/// The read session ended; read again.
	case unknownSession
	case writeFailed
}

/// What one read found, by site. No values.
public struct CredentialInventory: Equatable, Sendable {
	public var sessionID: UUID
	public var sourceID: MigrationSource.ID
	public var sourceProfileID: String
	public var passwordCount: Int

	/// Passwords Arx couldn't decrypt; they stay in the source browser.
	public var unreadablePasswordCount: Int

	/// Logins for HTTP sign-in prompts, which aren't imported (DEV-896).
	public var httpAuthPasswordCount: Int

	/// Sorted by host.
	public var sites: [CredentialSite]

	public init(
		sessionID: UUID,
		sourceID: MigrationSource.ID,
		sourceProfileID: String,
		passwordCount: Int,
		unreadablePasswordCount: Int = 0,
		httpAuthPasswordCount: Int = 0,
		sites: [CredentialSite]
	) {
		self.sessionID = sessionID
		self.sourceID = sourceID
		self.sourceProfileID = sourceProfileID
		self.passwordCount = passwordCount
		self.unreadablePasswordCount = unreadablePasswordCount
		self.httpAuthPasswordCount = httpAuthPasswordCount
		self.sites = sites
	}

	public var signInSites: [CredentialSite] {
		sites.filter(\.offersSignIn)
	}
}

/// One site in the inventory, keyed as `CredentialSiteGrouping` groups hosts.
public struct CredentialSite: Equatable, Identifiable, Sendable {
	public var host: String
	public var passwordCount: Int

	/// Persistent cookies Arx could decrypt. These are what moves a sign-in.
	public var cookieCount: Int

	/// Cookies that end with the source's session; they never move.
	public var sessionOnlyCookieCount: Int
	public var unreadableCookieCount: Int

	public var id: String { host }

	public init(
		host: String,
		passwordCount: Int = 0,
		cookieCount: Int = 0,
		sessionOnlyCookieCount: Int = 0,
		unreadableCookieCount: Int = 0
	) {
		self.host = host
		self.passwordCount = passwordCount
		self.cookieCount = cookieCount
		self.sessionOnlyCookieCount = sessionOnlyCookieCount
		self.unreadableCookieCount = unreadableCookieCount
	}

	/// Whether the site shows in the sign-ins list: it has cookies of any kind.
	public var offersSignIn: Bool {
		cookieCount + sessionOnlyCookieCount + unreadableCookieCount > 0
	}
}

/// What the user chose to move.
public struct CredentialSelection: Equatable, Sendable {
	public var passwords: Bool

	/// Sites, by `CredentialSite.host`, whose sign-ins move.
	public var signInHosts: Set<String>

	public init(
		passwords: Bool,
		signInHosts: Set<String>
	) {
		self.passwords = passwords
		self.signInHosts = signInHosts
	}

	/// Everything that can move is selected at first; the user deselects.
	public static func all(in inventory: CredentialInventory) -> Self {
		.init(
			passwords: inventory.passwordCount > 0,
			signInHosts: Set(inventory.sites.filter { $0.cookieCount > 0 }.map(\.host))
		)
	}

	public var isEmpty: Bool { !passwords && signInHosts.isEmpty }
}

/// The result of one write, kept so it can be undone as a batch.
public struct CredentialReport: Equatable, Sendable {
	public struct Passwords: Equatable, Sendable {
		public var imported: Int

		/// Already saved in Arx for that site and username; Arx's password was kept.
		public var conflicts: Int
		public var skipped: Int

		/// Logins for HTTP sign-in prompts that stayed in the source (DEV-896).
		public var httpAuthNotImported: Int

		public init(
			imported: Int,
			conflicts: Int = 0,
			skipped: Int = 0,
			httpAuthNotImported: Int = 0
		) {
			self.imported = imported
			self.conflicts = conflicts
			self.skipped = skipped
			self.httpAuthNotImported = httpAuthNotImported
		}
	}

	public var batchID: UUID
	public var passwords: Passwords?

	/// Every site from the sign-ins list, selected or not, sorted by host.
	public var sites: [CredentialSiteOutcome]

	public init(
		batchID: UUID,
		passwords: Passwords?,
		sites: [CredentialSiteOutcome]
	) {
		self.batchID = batchID
		self.passwords = passwords
		self.sites = sites
	}

	public var keptCount: Int { sites.filter { $0.result == .kept }.count }

	public var signInAgain: [CredentialSiteOutcome] {
		sites.filter {
			if case .signInAgain = $0.result { return true }
			return false
		}
	}
}

public struct CredentialSiteOutcome: Equatable, Identifiable, Sendable {
	public enum Result: Equatable, Sendable {
		/// Arx checked after writing and the site's cookies are there.
		case kept
		case signInAgain(Reason)

		/// Written, but this engine can't read cookies back to check.
		case notChecked

		/// The user left it out.
		case skipped
	}

	public enum Reason: Equatable, Sendable {
		/// Only session cookies, which end with the source browser's session.
		case sessionOnly

		/// Arx couldn't decrypt the site's cookies.
		case unreadable

		/// The engine refused the cookies.
		case rejected

		/// The engine refused some of the site's cookies, which may be the one that signs in.
		case partlyRejected

		/// The cookies were gone when Arx read them back, for example a device-bound session.
		case notKept
	}

	public var host: String
	public var result: Result

	public var id: String { host }

	public init(
		host: String,
		result: Result
	) {
		self.host = host
		self.result = result
	}
}

/// What the engine did with one site's cookies.
public struct CredentialCookieWrite: Equatable, Sendable {
	public var accepted: Int

	/// The engine refused them, for example an invalid domain or an expired date.
	public var rejected: Int

	/// Arx already had a cookie with that name; Arx's was kept.
	public var existing: Int

	public init(
		accepted: Int = 0,
		rejected: Int = 0,
		existing: Int = 0
	) {
		self.accepted = accepted
		self.rejected = rejected
		self.existing = existing
	}
}

/// Turns what was selected, written and read back into per-site outcomes.
/// A site is reported "sign in again" only for a reason Arx saw, never assumed by domain.
public enum CredentialReporting {
	public static func outcomes(
		inventory: CredentialInventory,
		selection: CredentialSelection,
		writes: [String: CredentialCookieWrite],
		checks: [String: Bool]?
	) -> [CredentialSiteOutcome] {
		inventory.signInSites.map { site in
			.init(
				host: site.host,
				result: result(
					site,
					isSelected: selection.signInHosts.contains(site.host),
					write: writes[site.host],
					check: checks.map { $0[site.host] ?? false }
				)
			)
		}
	}

	private static func result(
		_ site: CredentialSite,
		isSelected: Bool,
		write: CredentialCookieWrite?,
		check: Bool?
	) -> CredentialSiteOutcome.Result {
		guard site.cookieCount > 0 else {
			return site.unreadableCookieCount > 0
			? .signInAgain(.unreadable)
			: .signInAgain(.sessionOnly)
		}
		guard isSelected else { return .skipped }

		let write = write ?? .init()
		guard write.accepted + write.existing > 0 else { return .signInAgain(.rejected) }
		guard write.rejected == 0 else { return .signInAgain(.partlyRejected) }

		// An undecryptable cookie stayed behind, and it may be the one that signs in.
		guard site.unreadableCookieCount == 0 else { return .signInAgain(.unreadable) }

		// A session-only cookie never moves, and it may be the one that signs in.
		guard site.sessionOnlyCookieCount == 0 else { return .signInAgain(.sessionOnly) }
		guard let check else { return .notChecked }

		return check ? .kept : .signInAgain(.notKept)
	}
}

/// Groups cookie and password hosts into the sites the user picks from, without a public
/// suffix list.
///
/// Chromium refuses a domain cookie (`.example.com`) for a public suffix, so every domain
/// cookie the source holds names a registrable domain or something below one. A host joins
/// the most general such domain it falls under; a host under none stays a site of its own.
/// So `accounts.google.com` joins `google.com` when Google set a `.google.com` cookie, while
/// `alice.k12.ca.us` and `bob.k12.ca.us` stay apart: no browser accepts `.k12.ca.us`.
public struct CredentialSiteGrouping: Equatable, Sendable {
	public var domainCookieHosts: Set<String>

	public init(domainCookieHosts: Set<String>) {
		self.domainCookieHosts = Set(domainCookieHosts.map(Self.normalized))
	}

	public func site(forHost host: String) -> String {
		let host = Self.normalized(host)
		let labels = host.split(separator: ".", omittingEmptySubsequences: false)

		// From the most general ancestor down, so the widest domain cookie wins.
		for count in 1...max(labels.count, 1) {
			let candidate = labels.suffix(count).joined(separator: ".")
			if domainCookieHosts.contains(candidate) { return candidate }
		}
		return host
	}

	/// Lowercased, without leading or trailing dots.
	public static func normalized(_ host: String) -> String {
		host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
	}
}
