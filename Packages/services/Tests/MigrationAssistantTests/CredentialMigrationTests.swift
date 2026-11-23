import BrowserCore
import CryptoKit
import CustomDump
import Foundation
import SQLite3
import Testing
@testable import MigrationAssistant

/// Passwords and sign-ins (DEV-650), with throwaway fixtures only: a made-up Keychain
/// secret, and `Login Data` and `Cookies` databases built here from Chromium's schema
/// (trimmed to the columns read). No real Keychain item, profile or cookie is touched.
internal struct CredentialMigrationTests {
	// MARK: - Fixtures

	/// A throwaway secret. The expected key and blobs below came from Python's
	/// `hashlib.pbkdf2_hmac` and the `openssl enc` CLI, as in the research spike,
	/// so the Swift cipher is checked against an independent implementation.
	private static let secret: Data = .init("throwaway-fixture-secret".utf8)
	private static let derivedKeyHex: String = "dd2c05b25a8075134bc0f9ad8d8f5758"
	private static let passwordBlobHex: String = "76313067dec9e0da40434a04b7ae7d62f8a4adf8b932aedcdecc280b77cf5a95156762"
	private static let cookieBlobHex: String =
		"763130d6df3e207d84a283ae95edb354e35c4b62c8a217615f5e79af739b09044b99a1a91cf440aad9bb1c37118fe86a52cc95"

	private static let now: Date = .init(timeIntervalSince1970: 1_800_000_000)
	private static let profileID: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

	private static func data(hex: String) -> Data {
		var data: Data = .init()
		var index = hex.startIndex
		while index < hex.endIndex {
			let next = hex.index(index, offsetBy: 2)
			data.append(UInt8(hex[index..<next], radix: 16)!)
			index = next
		}
		return data
	}

	private static var key: ChromiumCipher.Key { .init(secret: secret) }

	private static func encrypt(_ text: String) throws -> Data {
		try ChromiumCipher.encrypt(Data(text.utf8), with: key)
	}

	private static func encryptCookie(
		_ value: String,
		host: String,
		key: ChromiumCipher.Key = key
	) throws -> Data {
		let digest = Data(SHA256.hash(data: Data(host.utf8)))
		return try ChromiumCipher.encrypt(digest + Data(value.utf8), with: key)
	}

	private static func hex(_ data: Data) -> String {
		"X'" + data.map { String(format: "%02x", $0) }.joined() + "'"
	}

	/// A user data folder with `Local State` and one `Default` profile.
	private static func makeUserData() throws -> URL {
		let root = FileManager.default.temporaryDirectory
			.appending(path: "dev650-\(UUID().uuidString)", directoryHint: .isDirectory)
		let profile = root.appending(path: "Default", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
		try Data(#"{"profile":{"info_cache":{"Default":{"name":"Work"}}}}"#.utf8)
			.write(to: root.appending(path: "Local State"))

		let other: ChromiumCipher.Key = .init(secret: Data("another-throwaway".utf8))
		let logins = try SQLiteDatabase(
			profile.appending(path: "Login Data"),
			flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
		)
		try logins.execute(
			"""
			CREATE TABLE logins (
				origin_url VARCHAR NOT NULL, signon_realm VARCHAR NOT NULL, username_value VARCHAR,
				password_value BLOB, blacklisted_by_user INTEGER NOT NULL
			);
			INSERT INTO logins VALUES
				('https://accounts.example.test/login', 'https://accounts.example.test/', 'ada', \(hex(try encrypt("first fixture"))), 0),
				('https://shop.fixture.test/', 'https://shop.fixture.test/', 'bob', \(hex(try ChromiumCipher.encrypt(Data("x".utf8), with: other))), 0),
				('https://never.example.test/', 'https://never.example.test/', '', X'', 1);
			"""
		)

		// Chrome's account store: one pair the profile store already has, one new.
		let accountLogins = try SQLiteDatabase(
			profile.appending(path: "Login Data For Account"),
			flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
		)
		try accountLogins.execute(
			"""
			CREATE TABLE logins (
				origin_url VARCHAR NOT NULL, signon_realm VARCHAR NOT NULL, username_value VARCHAR,
				password_value BLOB, blacklisted_by_user INTEGER NOT NULL
			);
			INSERT INTO logins VALUES
				('https://accounts.example.test/login', 'https://accounts.example.test/', 'ada', \(hex(try encrypt("account copy"))), 0),
				('https://www.example.test/', 'https://www.example.test/', 'carol', \(hex(try encrypt("second fixture"))), 0);
			"""
		)

		func cookie(
			_ host: String,
			_ name: String,
			value: Data,
			persistent: Bool = true,
			expires: Date = now.addingTimeInterval(86_400)
		) -> String {
			let created = ChromiumCredentialStore.chromiumTime(from: now.addingTimeInterval(-86_400))
			let expiry = ChromiumCredentialStore.chromiumTime(from: expires)
			return """
			('\(host)', '\(name)', '', \(hex(value)), '/', \(created), \(expiry), \(created), 1, 1, 1, 1, \(persistent ? 1 : 0), 2, 443, '', 0)
			"""
		}

		let cookies = try SQLiteDatabase(
			profile.appending(path: "Cookies"),
			flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
		)
		let rows: [String] = [
			cookie(".example.test", "sid", value: try encryptCookie("one", host: ".example.test")),
			cookie("accounts.example.test", "auth", value: try encryptCookie("two", host: "accounts.example.test")),
			cookie(".google.com", "SID", value: try encryptCookie("three", host: ".google.com")),
			cookie("news.fixture.test", "tmp", value: try encryptCookie("four", host: "news.fixture.test"), persistent: false),
			cookie("old.fixture.test", "gone", value: try encryptCookie("five", host: "old.fixture.test"), expires: now.addingTimeInterval(-1)),
			cookie(".broken.test", "copied", value: try encryptCookie("six", host: ".broken.test", key: other)),
		]
		try cookies.execute(
			"""
			CREATE TABLE meta (key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
			INSERT INTO meta VALUES ('version', '24');
			CREATE TABLE cookies (
				host_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL,
				path TEXT NOT NULL, creation_utc INTEGER NOT NULL, expires_utc INTEGER NOT NULL,
				last_access_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
				samesite INTEGER NOT NULL, priority INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
				source_scheme INTEGER NOT NULL, source_port INTEGER NOT NULL, top_frame_site_key TEXT NOT NULL,
				has_cross_site_ancestor INTEGER NOT NULL
			);
			INSERT INTO cookies VALUES \(rows.joined(separator: ",\n"));
			"""
		)
		return root
	}

	private static func browser(_ userData: URL) -> ChromiumSafeStorage.Browser {
		.init(
			sourceID: .init(rawValue: "fixture"),
			name: "Fixture Browser",
			item: .init(service: "Fixture Safe Storage", account: "Fixture", isVerified: true),
			userData: userData
		)
	}

	// MARK: - Cipher

	@Test
	internal func theKeyMatchesAnIndependentDerivation() {
		let key = Self.key
		#expect(key.isValid)
		let decrypted = try? ChromiumCipher.decrypt(Self.data(hex: Self.passwordBlobHex), with: key)
		#expect(decrypted == Data("correct horse fixture".utf8))
		#expect(
			(try? ChromiumCipher.decrypt(
				Self.data(hex: Self.passwordBlobHex),
				with: .init(derived: Array(Self.data(hex: Self.derivedKeyHex)))
			)) == Data("correct horse fixture".utf8)
		)
	}

	@Test
	internal func aCookieDecryptsOnlyForItsOwnHostAndKey() throws {
		let blob = Self.data(hex: Self.cookieBlobHex)
		#expect(
			try ChromiumCipher.decryptCookie(blob, host: ".example.test", hashesHost: true, with: Self.key)
			== Data("sid=fixture-1".utf8)
		)
		#expect(throws: ChromiumCipher.Failure.hostMismatch) {
			try ChromiumCipher.decryptCookie(blob, host: ".other.test", hashesHost: true, with: Self.key)
		}

		// Another key fails on padding or, when the garbage happens to pad well, on the host hash.
		#expect(throws: ChromiumCipher.Failure.self) {
			try ChromiumCipher.decryptCookie(
				blob,
				host: ".example.test",
				hashesHost: true,
				with: .init(secret: Data("arx-throwaway".utf8))
			)
		}
		#expect(throws: ChromiumCipher.Failure.unknownVersion) {
			try ChromiumCipher.decrypt(Data("v11abc".utf8), with: Self.key)
		}
	}

	@Test
	internal func erasingTheKeyMakesItUnusable() {
		var key = Self.key
		key.erase()
		#expect(!key.isValid)
		#expect(throws: ChromiumCipher.Failure.undecryptable) {
			try ChromiumCipher.decrypt(Self.data(hex: Self.passwordBlobHex), with: key)
		}
	}

	// MARK: - Store

	@Test
	internal func aProfileReadsIntoSitesWithoutValues() throws {
		let userData = try Self.makeUserData()
		defer { try? FileManager.default.removeItem(at: userData) }

		let contents = try ChromiumCredentialStore.read(
			profile: userData.appending(path: "Default"),
			key: Self.key,
			now: Self.now
		)
		expectNoDifference(
			contents.passwords,
			[
				.init(
					url: "https://accounts.example.test/login",
					signonRealm: "https://accounts.example.test/",
					username: "ada",
					password: "first fixture"
				),
				// From `Login Data For Account`; its copy of ada's pair is left out.
				.init(
					url: "https://www.example.test/",
					signonRealm: "https://www.example.test/",
					username: "carol",
					password: "second fixture"
				),
			]
		)
		#expect(contents.unreadablePasswords == 1)
		#expect(contents.cookies.map(\.name).sorted() == ["SID", "auth", "sid"])
		#expect(contents.cookies.first { $0.name == "sid" }?.value == "one")
		#expect(contents.cookies.first { $0.name == "auth" }?.sourcePort == 443)
		expectNoDifference(
			ChromiumCredentialStore.sites(of: contents),
			[
				.init(host: "broken.test", unreadableCookieCount: 1),
				.init(host: "example.test", passwordCount: 2, cookieCount: 2),
				.init(host: "google.com", cookieCount: 1),
				// No `.fixture.test` domain cookie, so these hosts stay apart.
				.init(host: "news.fixture.test", sessionOnlyCookieCount: 1),
				.init(host: "shop.fixture.test"),
			]
		)

		// The originals are untouched and no copy is left behind.
		#expect(FileManager.default.fileExists(atPath: userData.appending(path: "Default/Cookies").path))
	}

	@Test
	internal func recordsNeverPrintTheirValues() {
		let password: CredentialPasswordRecord = .init(
			url: "https://a.test",
			signonRealm: "https://a.test/",
			username: "u",
			password: "secret-value"
		)
		#expect(!"\(password)".contains("secret-value"))
		#expect(!String(reflecting: password).contains("secret-value"))
	}

	@Test
	internal func hostsGroupUnderDomainCookiesOnly() {
		let grouping: CredentialSiteGrouping = .init(
			domainCookieHosts: [".google.com", "accounts.google.com", ".bbc.co.uk", ".alice.k12.ca.us"]
		)

		// The widest domain cookie wins.
		#expect(grouping.site(forHost: ".accounts.google.com") == "google.com")
		#expect(grouping.site(forHost: "mail.google.com") == "google.com")
		#expect(grouping.site(forHost: "www.bbc.co.uk") == "bbc.co.uk")
		// Under a multi-label public suffix, sites stay apart: no browser sets `.k12.ca.us`.
		#expect(grouping.site(forHost: "www.alice.k12.ca.us") == "alice.k12.ca.us")
		#expect(grouping.site(forHost: "bob.k12.ca.us") == "bob.k12.ca.us")
		#expect(grouping.site(forHost: "alice.herokuapp.com") == "alice.herokuapp.com")
		#expect(grouping.site(forHost: "Example.TEST.") == "example.test")
		#expect(grouping.site(forHost: "127.0.0.1") == "127.0.0.1")
		#expect(grouping.site(forHost: "localhost") == "localhost")
	}

	@Test
	internal func aDamagedCopyNeverHidesAReadableOne() throws {
		let profile = FileManager.default.temporaryDirectory
			.appending(path: "dev650-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: profile) }

		let other: ChromiumCipher.Key = .init(secret: Data("another-throwaway".utf8))
		let schema = """
		CREATE TABLE logins (
			origin_url VARCHAR NOT NULL, signon_realm VARCHAR NOT NULL, username_value VARCHAR,
			password_value BLOB, blacklisted_by_user INTEGER NOT NULL
		);
		"""
		let damaged = Self.hex(try ChromiumCipher.encrypt(Data("x".utf8), with: other))
		let profileStore = try SQLiteDatabase(
			profile.appending(path: "Login Data"),
			flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
		)

		// Damaged, then readable, in one store; damaged in the profile store, readable in the account store.
		try profileStore.execute(
			schema + """
			INSERT INTO logins VALUES
				('https://a.test/', 'https://a.test/', 'ann', \(damaged), 0),
				('https://a.test/', 'https://a.test/', 'ann', \(Self.hex(try Self.encrypt("readable"))), 0),
				('https://b.test/', 'https://b.test/', 'ben', \(damaged), 0);
			"""
		)
		let accountStore = try SQLiteDatabase(
			profile.appending(path: "Login Data For Account"),
			flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
		)
		try accountStore.execute(
			schema + """
			INSERT INTO logins VALUES ('https://b.test/', 'https://b.test/', 'ben', \(Self.hex(try Self.encrypt("account"))), 0);
			"""
		)

		let contents = try ChromiumCredentialStore.read(profile: profile, key: Self.key, now: Self.now)
		#expect(contents.passwords.map(\.username) == ["ann", "ben"])
		#expect(contents.passwords.map(\.password) == ["readable", "account"])
		#expect(contents.unreadablePasswords == 0)
		#expect(contents.unreadablePasswordSites.isEmpty)
	}

	// MARK: - Selection and reporting

	@Test
	internal func everythingThatCanMoveStartsSelected() {
		let inventory: CredentialInventory = .init(
			sessionID: UUID(),
			sourceID: .init(rawValue: "fixture"),
			sourceProfileID: "Default",
			passwordCount: 2,
			sites: [
				.init(host: "a.test", cookieCount: 1),
				.init(host: "b.test", sessionOnlyCookieCount: 2),
				.init(host: "c.test", passwordCount: 2),
			]
		)
		#expect(CredentialSelection.all(in: inventory) == .init(passwords: true, signInHosts: ["a.test"]))
		#expect(inventory.signInSites.map(\.host) == ["a.test", "b.test"])
	}

	@Test
	internal func outcomesComeFromWhatWasSeenNotFromTheDomain() {
		let inventory: CredentialInventory = .init(
			sessionID: UUID(),
			sourceID: .init(rawValue: "fixture"),
			sourceProfileID: "Default",
			passwordCount: 0,
			sites: [
				.init(host: "google.com", cookieCount: 3),
				.init(host: "gone.test", cookieCount: 1),
				.init(host: "half.test", cookieCount: 2),
				.init(host: "left.test", cookieCount: 1),
				.init(host: "mixed.test", cookieCount: 1, unreadableCookieCount: 1),
				.init(host: "partsession.test", cookieCount: 1, sessionOnlyCookieCount: 1),
				.init(host: "refused.test", cookieCount: 2),
				.init(host: "session.test", sessionOnlyCookieCount: 1),
				.init(host: "unreadable.test", unreadableCookieCount: 1),
			]
		)
		let outcomes = CredentialReporting.outcomes(
			inventory: inventory,
			selection: .init(
				passwords: false,
				signInHosts: ["google.com", "gone.test", "half.test", "mixed.test", "partsession.test", "refused.test"]
			),
			writes: [
				"google.com": .init(accepted: 3),
				"gone.test": .init(accepted: 1),
				// The refused cookie may be the one that signs in, even though the rest read back.
				"half.test": .init(accepted: 1, rejected: 1),
				// One readable tracking cookie moved; the undecryptable one may be the sign-in.
				"mixed.test": .init(accepted: 1),
				// A persistent tracking cookie moved; the session-only sign-in cookie can't.
				"partsession.test": .init(accepted: 1),
				"refused.test": .init(rejected: 2),
			],
			checks: ["google.com": true, "gone.test": false, "half.test": true, "mixed.test": true, "partsession.test": true]
		)
		expectNoDifference(
			outcomes,
			[
				.init(host: "google.com", result: .kept),
				.init(host: "gone.test", result: .signInAgain(.notKept)),
				.init(host: "half.test", result: .signInAgain(.partlyRejected)),
				.init(host: "left.test", result: .skipped),
				.init(host: "mixed.test", result: .signInAgain(.unreadable)),
				.init(host: "partsession.test", result: .signInAgain(.sessionOnly)),
				.init(host: "refused.test", result: .signInAgain(.rejected)),
				.init(host: "session.test", result: .signInAgain(.sessionOnly)),
				.init(host: "unreadable.test", result: .signInAgain(.unreadable)),
			]
		)

		let unchecked = CredentialReporting.outcomes(
			inventory: inventory,
			selection: .init(passwords: false, signInHosts: ["google.com"]),
			writes: ["google.com": .init(accepted: 3)],
			checks: nil
		)
		#expect(unchecked.first?.result == .notChecked)
	}

	@Test
	internal func knownBrowsersNameTheirKeychainItems() {
		let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
		let browsers = ChromiumSafeStorage.browsers(home: home)
		let items = Dictionary(uniqueKeysWithValues: browsers.map { ($0.sourceID.rawValue, $0.item) })
		#expect(items["arc"] == .init(service: "Arc Safe Storage", account: "Arc", isVerified: true))
		#expect(items["brave"] == .init(service: "Brave Safe Storage", account: "Brave", isVerified: true))
		#expect(items["edge"] == .init(service: "Microsoft Edge Safe Storage", account: "Microsoft Edge", isVerified: true))
		#expect(items["chrome"]?.isVerified == true)
		// Dia's name is still a guess (DEV-831).
		#expect(items["dia"]?.isVerified == false)

		let folders = Dictionary(uniqueKeysWithValues: browsers.map { ($0.sourceID.rawValue, $0.userData.path) })
		#expect(folders["brave"] == "/Users/fixture/Library/Application Support/BraveSoftware/Brave-Browser")
		#expect(folders["edge"] == "/Users/fixture/Library/Application Support/Microsoft Edge")
		#expect(folders["arc"] == "/Users/fixture/Library/Application Support/Arc/User Data")
	}

	@Test
	internal func braveAndEdgeAreSourcesOnlyWithUncheckedSources() throws {
		let home = FileManager.default.temporaryDirectory.appending(path: "dev-831-\(UUID().uuidString)", directoryHint: .isDirectory)
		defer { try? FileManager.default.removeItem(at: home) }

		let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
		for folder in ["BraveSoftware/Brave-Browser", "Microsoft Edge"] {
			let root = support.appending(path: folder, directoryHint: .isDirectory)
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			try Data("{}".utf8).write(to: root.appending(path: "Local State"))
		}

		#expect(MigrationBrowserSources.adapters(home: home).isEmpty)
		let unchecked = MigrationBrowserSources.adapters(home: home, includesUnchecked: true)
		expectNoDifference(unchecked.map(\.source.id.rawValue), ["brave", "edge"])
		expectNoDifference(unchecked.map(\.source.name), ["Brave", "Microsoft Edge"])
	}

	// MARK: - Sessions

	private final class Calls: @unchecked Sendable {
		private let lock: NSLock = .init()
		private var _keychainReads: Int = 0
		private var _passwords: [CredentialPasswordRecord] = []
		private var _cookies: [CredentialCookieRecord] = []
		private var _undone: [CredentialUndoRecord] = []

		internal var keychainReads: Int { lock.withLock { _keychainReads } }
		internal var passwords: [CredentialPasswordRecord] { lock.withLock { _passwords } }
		internal var cookies: [CredentialCookieRecord] { lock.withLock { _cookies } }
		internal var undone: [CredentialUndoRecord] { lock.withLock { _undone } }

		internal func readKeychain() { lock.withLock { _keychainReads += 1 } }
		internal func wrote(_ passwords: [CredentialPasswordRecord]) { lock.withLock { _passwords += passwords } }
		internal func wrote(_ cookies: [CredentialCookieRecord]) { lock.withLock { _cookies += cookies } }
		internal func undid(_ record: CredentialUndoRecord) { lock.withLock { _undone.append(record) } }
	}

	private struct CookieFailure: Error {}

	private static func writer(
		_ calls: Calls,
		isAvailable: Bool = true,
		failsCookies: Bool = false,
		unconfirms: Bool = false
	) -> CredentialDestinationWriter {
		.init(
			isAvailable: { isAvailable },
			importPasswords: { _, records in
				calls.wrote(records)
				let keys: [CredentialUndoRecord.Password] = records.map {
					.init(signonRealm: $0.signonRealm, username: $0.username, dateCreated: "7")
				}

				// An engine that began the write but couldn't confirm it.
				return unconfirms
				? .init(imported: [], unconfirmed: keys, skipped: keys.count)
				: .init(imported: keys)
			},
			setCookies: { _, records in
				if failsCookies { throw CookieFailure() }
				calls.wrote(records)
				let keys = records.map(CredentialUndoRecord.Cookie.init)
				return unconfirms
				? .init(accepted: [], rejected: keys, unconfirmed: keys)
				: .init(accepted: keys)
			},
			checkCookies: { _, keys in Set(keys) },
			undo: { calls.undid($0) }
		)
	}

	private static func client(
		_ userData: URL,
		calls: Calls,
		secret: Result<Data, ChromiumSafeStorage.KeyFailure> = .success(secret),
		isAvailable: Bool = true,
		failsCookies: Bool = false,
		unconfirms: Bool = false
	) -> CredentialMigrationClient {
		.running(
			browsers: [browser(userData)],
			readSecret: { _ throws(ChromiumSafeStorage.KeyFailure) in
				calls.readKeychain()
				return try secret.get()
			},
			writer: writer(calls, isAvailable: isAvailable, failsCookies: failsCookies, unconfirms: unconfirms),
			now: { now }
		)
	}

	@Test
	internal func withoutAWriterTheKeychainIsNeverRead() async throws {
		let userData = try Self.makeUserData()
		defer { try? FileManager.default.removeItem(at: userData) }

		let calls: Calls = .init()
		let client = Self.client(userData, calls: calls, isAvailable: false)
		await #expect(throws: CredentialMigrationFailure.writerUnavailable) {
			try await client.read(.init(rawValue: "fixture"), "Default")
		}
		#expect(calls.keychainReads == 0)
	}

	@Test
	internal func aDenialIsNotAskedAgain() async throws {
		let userData = try Self.makeUserData()
		defer { try? FileManager.default.removeItem(at: userData) }

		let calls: Calls = .init()
		let client = Self.client(userData, calls: calls, secret: .failure(.denied))
		for _ in 0..<2 {
			await #expect(throws: CredentialMigrationFailure.keyDenied) {
				try await client.read(.init(rawValue: "fixture"), "Default")
			}
		}
		#expect(calls.keychainReads == 1)

		let missing = Self.client(userData, calls: calls, secret: .failure(.missing))
		await #expect(throws: CredentialMigrationFailure.keyMissing) {
			try await missing.read(.init(rawValue: "fixture"), "Default")
		}
	}

	@Test
	internal func onlyListedProfilesAreRead() async throws {
		let userData = try Self.makeUserData()
		defer { try? FileManager.default.removeItem(at: userData) }

		let calls: Calls = .init()
		let client = Self.client(userData, calls: calls)
		let source = await client.source(.init(rawValue: "fixture"))
		#expect(source?.profiles.map(\.id) == ["Default"])
		#expect(source?.keychainService == "Fixture Safe Storage")
		await #expect(throws: CredentialMigrationFailure.unreadable) {
			try await client.read(.init(rawValue: "fixture"), "../Default")
		}
		#expect(calls.keychainReads == 0)
	}

	@Test
	internal func severalProfilesShareOneKeychainRead() async throws {
		let userData = try Self.makeUserData()
		defer { try? FileManager.default.removeItem(at: userData) }

		try FileManager.default.copyItem(
			at: userData.appending(path: "Default", directoryHint: .isDirectory),
			to: userData.appending(path: "Profile 1", directoryHint: .isDirectory)
		)
		try Data(#"{"profile":{"info_cache":{"Default":{"name":"Work"},"Profile 1":{"name":"Home"}}}}"#.utf8)
			.write(to: userData.appending(path: "Local State"))

		let calls: Calls = .init()
		let client = Self.client(userData, calls: calls)

		// One unlisted profile refuses the whole read before macOS is asked.
		await #expect(throws: CredentialMigrationFailure.unreadable) {
			try await client.readProfiles(.init(rawValue: "fixture"), ["Default", "../Default"])
		}
		#expect(calls.keychainReads == 0)

		let inventories = try await client.readProfiles(.init(rawValue: "fixture"), ["Profile 1", "Default"])
		#expect(calls.keychainReads == 1)
		expectNoDifference(inventories.map(\.sourceProfileID), ["Profile 1", "Default"])
		expectNoDifference(inventories.map(\.passwordCount), [2, 2])
		#expect(inventories[0].sessionID != inventories[1].sessionID)

		// Each profile writes on its own.
		let report = try await client.migrate(
			inventories[0].sessionID,
			.init(passwords: true, signInHosts: []),
			Self.profileID
		)
		#expect(report.passwords?.imported == 2)
		await client.discard(inventories[1].sessionID)
		await #expect(throws: CredentialMigrationFailure.unknownSession) {
			try await client.migrate(inventories[1].sessionID, .init(passwords: true, signInHosts: []), Self.profileID)
		}
	}

	@Test
	internal func theSelectionMovesAndUndoesAsOneBatch() async throws {
		let userData = try Self.makeUserData()
		defer { try? FileManager.default.removeItem(at: userData) }

		let calls: Calls = .init()
		let client = Self.client(userData, calls: calls)
		let inventory = try await client.read(.init(rawValue: "fixture"), "Default")
		#expect(inventory.passwordCount == 2)
		#expect(inventory.unreadablePasswordCount == 1)

		let report = try await client.migrate(
			inventory.sessionID,
			.init(passwords: true, signInHosts: ["google.com"]),
			Self.profileID
		)
		#expect(calls.passwords.map(\.username) == ["ada", "carol"])
		#expect(calls.cookies.map(\.name) == ["SID"])
		#expect(report.passwords == .init(imported: 2, skipped: 1))
		expectNoDifference(
			report.sites,
			[
				.init(host: "broken.test", result: .signInAgain(.unreadable)),
				.init(host: "example.test", result: .skipped),
				.init(host: "google.com", result: .kept),
				.init(host: "news.fixture.test", result: .signInAgain(.sessionOnly)),
			]
		)

		// The decrypted records were used once.
		await #expect(throws: CredentialMigrationFailure.unknownSession) {
			try await client.migrate(inventory.sessionID, .init(passwords: true, signInHosts: []), Self.profileID)
		}

		try await client.undo(report.batchID)
		expectNoDifference(
			calls.undone,
			[
				.init(
					profileID: Self.profileID,
					passwords: [
						// The engine's stamp travels with each key, so undo keeps a password saved again since.
						.init(signonRealm: "https://accounts.example.test/", username: "ada", dateCreated: "7"),
						.init(signonRealm: "https://www.example.test/", username: "carol", dateCreated: "7"),
					],
					cookies: [.init(domain: ".google.com", name: "SID", path: "/", sourceScheme: 2, sourcePort: 443)]
				),
			]
		)
		await #expect(throws: CredentialMigrationFailure.unknownSession) {
			try await client.undo(report.batchID)
		}
	}

	@Test
	internal func passwordsWrittenBeforeACookieFailureStayUndoable() async throws {
		let userData = try Self.makeUserData()
		defer { try? FileManager.default.removeItem(at: userData) }

		let calls: Calls = .init()
		let client = Self.client(userData, calls: calls, failsCookies: true)
		let inventory = try await client.read(.init(rawValue: "fixture"), "Default")
		let report = try await client.migrate(
			inventory.sessionID,
			.init(passwords: true, signInHosts: ["google.com"]),
			Self.profileID
		)
		#expect(report.passwords?.imported == 2)
		#expect(report.sites.first { $0.host == "google.com" }?.result == .signInAgain(.rejected))

		try await client.undo(report.batchID)
		#expect(calls.undone.first?.passwords.count == 2)
		#expect(calls.undone.first?.cookies.isEmpty == true)

		// With no passwords written, the failure is the result.
		let again = try await client.read(.init(rawValue: "fixture"), "Default")
		await #expect(throws: CookieFailure.self) {
			try await client.migrate(again.sessionID, .init(passwords: false, signInHosts: ["google.com"]), Self.profileID)
		}
	}

	@Test
	internal func unconfirmedWritesStayInTheUndoRecord() async throws {
		let userData = try Self.makeUserData()
		defer { try? FileManager.default.removeItem(at: userData) }

		let calls: Calls = .init()
		let client = Self.client(userData, calls: calls, unconfirms: true)
		let inventory = try await client.read(.init(rawValue: "fixture"), "Default")
		let report = try await client.migrate(
			inventory.sessionID,
			.init(passwords: true, signInHosts: ["google.com"]),
			Self.profileID
		)

		// Nothing is reported imported or kept...
		#expect(report.passwords?.imported == 0)
		#expect(report.sites.first { $0.host == "google.com" }?.result == .signInAgain(.rejected))

		// ...but undo still covers whatever the engine may have stored.
		try await client.undo(report.batchID)
		#expect(calls.undone.first?.passwords.count == 2)
		#expect(calls.undone.first?.cookies.count == 1)
	}

	@Test
	internal func discardingAllDropsEveryReadSession() async throws {
		let userData = try Self.makeUserData()
		defer { try? FileManager.default.removeItem(at: userData) }

		let calls: Calls = .init()
		let client = Self.client(userData, calls: calls)
		let first = try await client.read(.init(rawValue: "fixture"), "Default")
		let second = try await client.read(.init(rawValue: "fixture"), "Default")
		await client.discardAll()
		for session in [first.sessionID, second.sessionID] {
			await #expect(throws: CredentialMigrationFailure.unknownSession) {
				try await client.migrate(session, .init(passwords: true, signInHosts: []), Self.profileID)
			}
		}
		#expect(calls.passwords.isEmpty)
	}

	@Test
	internal func theClientGroupsPerCookieResultsIntoSites() async throws {
		let userData = try Self.makeUserData()
		defer { try? FileManager.default.removeItem(at: userData) }

		let calls: Calls = .init()
		var writer = Self.writer(calls)

		// The engine refuses `auth` on accounts.example.test and keeps everything else.
		writer.setCookies = { _, records in
			let keys = records.map(CredentialUndoRecord.Cookie.init)
			return .init(
				accepted: keys.filter { $0.name != "auth" },
				rejected: keys.filter { $0.name == "auth" }
			)
		}
		let client: CredentialMigrationClient = .running(
			browsers: [Self.browser(userData)],
			readSecret: { _ throws(ChromiumSafeStorage.KeyFailure) in Self.secret },
			writer: writer,
			now: { Self.now }
		)
		let inventory = try await client.read(.init(rawValue: "fixture"), "Default")
		let report = try await client.migrate(
			inventory.sessionID,
			.init(passwords: false, signInHosts: ["example.test", "google.com"]),
			Self.profileID
		)
		#expect(report.sites.first { $0.host == "example.test" }?.result == .signInAgain(.partlyRejected))
		#expect(report.sites.first { $0.host == "google.com" }?.result == .kept)
	}

	// MARK: - Receiving profile

	@Test
	internal func theReceivingProfileFollowsTheRouteAndTheLedger() {
		var organization = MigrationFixtures.organization()
		let created: Profile = .init(id: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!), name: "Work")
		organization.profiles.append(created)
		let ledger: MigrationLedger = .init(createdProfiles: ["Default": created.id])

		// Everything into the current space: the current profile.
		#expect(
			organization.receivingProfile(
				forSourceProfile: "Default",
				destination: MigrationFixtures.destination,
				ledger: ledger
			)?.id == MigrationFixtures.profileID
		)

		var newProfiles = MigrationFixtures.destination
		newProfiles.defaultRoute = .newProfile

		// The profile an earlier run created for it.
		#expect(
			organization.receivingProfile(forSourceProfile: "Default", destination: newProfiles, ledger: ledger)
			== created
		)

		// None yet: the user picks.
		#expect(
			organization.receivingProfile(forSourceProfile: "Profile 1", destination: newProfiles, ledger: ledger)
			== nil
		)

		// Routed into an existing space: that space's profile.
		var routed = newProfiles
		routed.routes = ["Profile 1/chrome": .existingSpace(MigrationFixtures.profileID, MigrationFixtures.spaceID)]
		#expect(
			organization.receivingProfile(forSourceProfile: "Profile 1", destination: routed, ledger: ledger)?.id
			== MigrationFixtures.profileID
		)
	}

	/// A source without profiles of its own (Firefox or Zen with passwords only) is one
	/// whole source, and it goes where items without a profile go: the destination's
	/// profile, even under a new-profile default (DEV-844).
	@Test
	internal func aWholeSourceGoesToTheDestinationsProfile() {
		let organization = MigrationFixtures.organization()
		var newProfiles = MigrationFixtures.destination
		newProfiles.defaultRoute = .newProfile

		#expect(
			organization.receivingProfile(
				forSourceProfile: MigrationSourceProfile.wholeSource,
				destination: newProfiles,
				ledger: .init()
			)?.id == MigrationFixtures.profileID
		)
	}
}

