import BrowserCore
import CustomDump
import Foundation
import SQLite3
import Testing
@testable import MigrationAssistant

/// DEV-896's sources: more Chromium browsers and channels, Firefox and Zen history, Firefox
/// and Zen logins and cookies, and Safari's cookies. Every fixture is made here; no real
/// browser profile, Keychain item or cookie is read.
///
/// The NSS values (`key4.db` and `logins.json`) and the `Cookies.binarycookies` file came
/// from Python's `hashlib` and `hmac`, `struct` and the `openssl enc` CLI, so the Swift
/// readers are checked against an independent implementation, not against themselves.
internal struct MoreBrowserSourcesTests {
	// MARK: - Fixtures

	private static let now: Date = .init(timeIntervalSince1970: 1_800_000_000)

	private static func makeHome() -> URL {
		FileManager.default.temporaryDirectory
			.appending(path: "arx-more-sources-\(UUID().uuidString)", directoryHint: .isDirectory)
	}

	private static func write(
		_ text: String,
		to url: URL
	) throws {
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try text.write(to: url, atomically: true, encoding: .utf8)
	}

	private static func database(
		_ url: URL,
		_ sql: String
	) throws {
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let database = try SQLiteDatabase(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
		try database.execute(sql)
	}

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

	private static let bookmarks: String = """
	{"roots": {"bookmark_bar": {"name": "Bookmarks bar", "type": "folder", "children": [
		{"type": "url", "guid": "g1", "name": "Swift", "url": "https://swift.org"}
	]}}}
	"""

	/// Chromium's `urls` table with one visited page.
	private static let chromiumHistory: String = """
	CREATE TABLE urls (
		id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
		last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL
	);
	INSERT INTO urls (url, title, last_visit_time) VALUES ('https://visited.example.org/', 'Visited', 13400000000000000);
	"""

	// MARK: - Chromium browsers

	@Test(arguments: ChromiumBrowser.all)
	internal func everyChromiumBrowserIsReadFromItsOwnFolder(_ browser: ChromiumBrowser) async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let userData = browser.userData(home: home)

		// Opera lists no profiles and keeps its one profile at the root.
		let profile = browser.keepsDefaultProfileAtRoot ? userData : userData.appending(path: "Default")
		let localState = browser.keepsDefaultProfileAtRoot
		? #"{"profile": {}}"#
		: #"{"profile": {"info_cache": {"Default": {"name": "Personal"}}}}"#
		try Self.write(localState, to: userData.appending(path: "Local State"))
		try Self.write(Self.bookmarks, to: profile.appending(path: "Bookmarks"))
		try Self.database(profile.appending(path: "History"), Self.chromiumHistory)

		let adapters = MigrationBrowserSources.adapters(home: home, includesUnchecked: true)
		let adapter = try #require(adapters.first { $0.source.id == browser.id })
		#expect(adapter.source.name == browser.name)
		#expect(adapter.source.applicationIdentifier == browser.applicationIdentifier)
		#expect(adapter.source.categories == [.bookmarks, .openTabs, .history])

		let snapshot = try await adapter.snapshot()
		let tabs = snapshot.records.filter { $0.kind == .tab }
		expectNoDifference(tabs.filter { $0.category == .bookmarks }.map(\.url), ["https://swift.org"])
		expectNoDifference(tabs.filter { $0.category == .history }.map(\.url), ["https://visited.example.org/"])
		expectNoDifference(
			snapshot.records.filter { $0.kind == .space }.compactMap { $0.space?.name },
			[browser.keepsDefaultProfileAtRoot ? browser.name : "Personal"]
		)

		// Only the browser written here is offered.
		#expect(adapters.count == 1)
	}

	@Test
	internal func newBrowsersWaitForTheUncheckedSourcesSwitch() throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		for browser in ChromiumBrowser.all {
			try Self.write(#"{"profile": {}}"#, to: browser.userData(home: home).appending(path: "Local State"))
		}
		let checked = MigrationBrowserSources.adapters(home: home).map(\.source.id.rawValue)
		expectNoDifference(checked, ["dia", "chrome"])

		let all = MigrationBrowserSources.adapters(home: home, includesUnchecked: true).map(\.source.id.rawValue)
		expectNoDifference(all, ChromiumBrowser.all.filter(\.isChecked).map(\.id.rawValue)
			+ ChromiumBrowser.all.filter { !$0.isChecked }.map(\.id.rawValue))
		#expect(Set(all).count == ChromiumBrowser.all.count)
	}

	@Test
	internal func operaUsesAProfileFolderWhenItHasOne() throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let userData = ChromiumBrowser.opera.userData(home: home)
		try FileManager.default.createDirectory(at: userData.appending(path: "Default"), withIntermediateDirectories: true)
		let directory = ChromiumProfileLayout.directory(
			profile: "Default",
			userData: userData,
			keepsDefaultProfileAtRoot: true
		)
		#expect(directory.lastPathComponent == "Default")
		// Other browsers never fall back to the root.
		let chrome = ChromiumProfileLayout.directory(profile: "Default", userData: home, keepsDefaultProfileAtRoot: false)
		#expect(chrome.lastPathComponent == "Default")
	}

	@Test
	internal func chromiumBrowsersNameTheirKeychainItems() {
		let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
		let browsers = Dictionary(uniqueKeysWithValues: ChromiumSafeStorage.browsers(home: home).map { ($0.sourceID.rawValue, $0) })
		#expect(browsers.count == ChromiumBrowser.all.count + 1)
		#expect(browsers["helium"]?.item == .init(service: "Helium Storage Key", account: "Helium", isVerified: true))
		#expect(browsers["helium"]?.userData.path == "/Users/fixture/Library/Application Support/net.imput.helium")
		#expect(browsers["chromium"]?.item == .init(service: "Chromium Safe Storage", account: "Chromium", isVerified: true))
		// Every Chrome channel shares Chrome's item.
		for channel in ["chrome-beta", "chrome-dev", "chrome-canary"] {
			#expect(browsers[channel]?.item == ChromiumSafeStorage.chrome)
		}
		#expect(browsers["chrome-canary"]?.userData.path == "/Users/fixture/Library/Application Support/Google/Chrome Canary")
		// Names not checked against the real browser are marked so.
		for id in ["opera", "opera-gx", "vivaldi", "island", "edge-beta", "brave-nightly"] {
			#expect(browsers[id]?.item.isVerified == false)
		}
		#expect(browsers["opera"]?.keepsDefaultProfileAtRoot == true)
	}

	// MARK: - Firefox and Zen history

	private static let mozillaProfilePath: String = "Profiles/abcd.default-release"

	/// `profiles.ini` and one profile folder for Firefox or Zen.
	@discardableResult
	private static func makeMozillaProfile(
		home: URL,
		folder: String
	) throws -> URL {
		let root = home.appending(path: "Library/Application Support/\(folder)", directoryHint: .isDirectory)
		let profile = root.appending(path: mozillaProfilePath, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
		try Self.write(
			"""
			[Profile0]
			Name=default-release
			IsRelative=1
			Path=\(mozillaProfilePath)
			Default=1
			""",
			to: root.appending(path: "profiles.ini")
		)
		return profile
	}

	private static let places: String = """
	CREATE TABLE moz_places (
		id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, hidden INTEGER DEFAULT 0 NOT NULL,
		last_visit_date INTEGER, guid TEXT
	);
	CREATE TABLE moz_bookmarks (
		id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER, position INTEGER,
		title LONGVARCHAR, guid TEXT
	);
	INSERT INTO moz_bookmarks (id, type, parent, position, title, guid) VALUES
		(1, 2, 0, 0, '', 'root________'),
		(3, 2, 1, 1, 'toolbar', 'toolbar_____');
	INSERT INTO moz_places (id, url, title, hidden, last_visit_date) VALUES
		(1, 'https://older.example.org/', 'Older', 0, 1700000000000000),
		(2, 'https://newer.example.org/', 'Newer', 0, 1700000060000000),
		(3, 'https://framed.example.org/', 'Framed', 1, 1700000120000000),
		(4, 'https://bookmarked.example.org/', 'Never visited', 0, NULL),
		(5, 'about:preferences', 'Settings', 0, 1700000180000000);
	INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES
		(10, 1, 4, 3, 0, 'Bookmarked', 'bookmarked');
	"""

	@Test(arguments: MigrationBrowserSources.MozillaBrowser.allCases)
	internal func mozillaBrowsersBringHistory(_ browser: MigrationBrowserSources.MozillaBrowser) async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let profile = try Self.makeMozillaProfile(home: home, folder: browser.folder)
		try Self.database(profile.appending(path: "places.sqlite"), Self.places)

		let adapter = try #require(
			MigrationBrowserSources.adapters(home: home, includesUnchecked: true)
				.first { $0.source.id.rawValue == browser.rawValue }
		)
		#expect(adapter.source.categories.contains(.history))

		let snapshot = try await adapter.snapshot()
		let history = snapshot.records.filter { $0.category == .history }
		expectNoDifference(history.map(\.url), ["https://newer.example.org/", "https://older.example.org/"])
		expectNoDifference(history.map(\.sourceItemID), [
			"history:\(Self.mozillaProfilePath)/https://newer.example.org/",
			"history:\(Self.mozillaProfilePath)/https://older.example.org/",
		])
		#expect(history.first?.lastVisited == Date(timeIntervalSince1970: 1_700_000_060))
		#expect(history.allSatisfy { $0.profile?.id == Self.mozillaProfilePath })

		// The browser writes history on every visit, so new visits don't change the snapshot.
		let database = try SQLiteDatabase(profile.appending(path: "places.sqlite"), flags: SQLITE_OPEN_READWRITE)
		try database.execute("INSERT INTO moz_places (url, title, last_visit_date) VALUES ('https://new.example.org/', 'New', 1700000300000000)")
		#expect(try await adapter.snapshot().id == snapshot.id)
	}

	// MARK: - Firefox and Zen logins

	private enum NSS {
		internal static let globalSalt: String = "101112131415161718191a1b1c1d1e1f20212223"

		/// `password-check` under PBES2 with an empty primary password, and with "hunter2".
		internal static let checkPBES2: String = "308183306f06092a864886f70d01050d3062304306092a864886f70d01050c30360420000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f020102020120300c06082a864886f70d02090500301b060960864801650304012a040ea0a1a2a3a4a5a6a7a8a9aaabacad0410b85d3b5879709e6514dfdad0f2b46a5d"
		internal static let checkPBES2Primary: String = "308183306f06092a864886f70d01050d3062304306092a864886f70d01050c30360420000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f020102020120300c06082a864886f70d02090500301b060960864801650304012a040ea0a1a2a3a4a5a6a7a8a9aaabacad0410d6edc2d8437c3c0f1d36e1aeb98a8adf"

		/// The Triple DES and AES-256 login keys, each under PBES2.
		/// The Triple DES key under "hunter2".
		internal static let desKeyPBES2Primary: String = "308193306f06092a864886f70d01050d3062304306092a864886f70d01050c303604200102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20020103020120300c06082a864886f70d02090500301b060960864801650304012a040eb0b1b2b3b4b5b6b7b8b9babbbcbd0420667c4a0bce9c56335efc872f332c911ab97cc3e6042a1a6d37ce0374c700cb5a"
		internal static let desKeyPBES2: String = "308193306f06092a864886f70d01050d3062304306092a864886f70d01050c303604200102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20020103020120300c06082a864886f70d02090500301b060960864801650304012a040eb0b1b2b3b4b5b6b7b8b9babbbcbd04202d4f4776afce143a90f0690975b3278434e7d3d425e65c1bb38b51809fe15335"
		internal static let aesKeyPBES2: String = "3081a3306f06092a864886f70d01050d3062304306092a864886f70d01050c3036042002030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2021020103020120300c06082a864886f70d02090500301b060960864801650304012a040ec0c1c2c3c4c5c6c7c8c9cacbcccd04309608444a028e5358ec1615efb3d1e666e9340bc1ea1afe5bea8ffd6565ad19f43565dbf4f7467d50ad6bb5d2ccc5bd90"

		/// The same check and Triple DES key under the older PKCS#12 scheme.
		internal static let checkPKCS12: String = "303c3028060b2a864886f70d010c05010330190414303132333435363738393a3b3c3d3e3f4041424302010104104d0e048468c3b0dea04f43f20182bcd2"
		internal static let desKeyPKCS12: String = "304c3028060b2a864886f70d010c05010330190414505152535455565758595a5b5c5d5e5f6061626302010104201988637eb3ab9e1b72d864a79f5d2d4b18b6e70732499b72d860efd9c9fb8f5c"
		internal static let desKeyID: String = "f8000000000000000000000000000001"
		internal static let aesKeyID: String = "f8000000000000000000000000000002"

		/// `ada@example.org` / `correct horse fixture` under the Triple DES key, and
		/// `grace@example.org` / `battery staple fixture` under the AES key.
		internal static let userDES: String = "MDoEEPgAAAAAAAAAAAAAAAAAAAEwFAYIKoZIhvcNAwcECAABAgMEBQYHBBDMSkpbyJXQnlJsME5DQruV"
		internal static let passwordDES: String = "MEIEEPgAAAAAAAAAAAAAAAAAAAEwFAYIKoZIhvcNAwcECAgJCgsMDQ4PBBjiBKZExW4clwWWLDtKd8JPWPP69ksMUWQ="
		internal static let userAES: String = "MFMEEPgAAAAAAAAAAAAAAAAAAAIwHQYJYIZIAWUDBAEqBBAAAQIDBAUGBwgJCgsMDQ4PBCDQmytKoVc1/jbF66VFOSbIW7YdDVB7aQFBpTXAa7rcDw=="
		internal static let passwordAES: String = "MFMEEPgAAAAAAAAAAAAAAAAAAAIwHQYJYIZIAWUDBAEqBBAQERITFBUWFxgZGhscHR4fBCAsNeQwAhJr34mDPxWBil0UG5R7ZUMH9Ki7pTKtjtVJtQ=="
	}

	private enum KeyScheme {
		case pbes2
		case pbes2WithPrimaryPassword
		case pkcs12
	}

	private static func writeKeyDatabase(
		_ scheme: KeyScheme,
		in profile: URL
	) throws {
		let (check, keys): (String, [(id: String, value: String)]) = switch scheme {
		case .pbes2: (NSS.checkPBES2, [(NSS.desKeyID, NSS.desKeyPBES2), (NSS.aesKeyID, NSS.aesKeyPBES2)])
		case .pbes2WithPrimaryPassword: (NSS.checkPBES2Primary, [(NSS.desKeyID, NSS.desKeyPBES2Primary)])
		case .pkcs12: (NSS.checkPKCS12, [(NSS.desKeyID, NSS.desKeyPKCS12)])
		}
		let rows = keys.map { "(X'\($0.value)', X'\($0.id)')" }.joined(separator: ", ")
		try Self.database(
			profile.appending(path: "key4.db"),
			"""
			CREATE TABLE metadata (id PRIMARY KEY UNIQUE ON CONFLICT REPLACE, item1, item2);
			CREATE TABLE nssPrivate (id PRIMARY KEY UNIQUE ON CONFLICT ABORT, a11, a102);
			INSERT INTO metadata VALUES ('password', X'\(NSS.globalSalt)', X'\(check)');
			INSERT INTO nssPrivate (a11, a102) VALUES \(rows);
			"""
		)
	}

	private static func writeLogins(
		in profile: URL,
		includesAES: Bool = true
	) throws {
		var logins = [
			"""
			{"id": 1, "hostname": "https://Example.org", "httpRealm": null, "formSubmitURL": "https://accounts.example.net/login",
			 "encryptedUsername": "\(NSS.userDES)", "encryptedPassword": "\(NSS.passwordDES)", "encType": 1}
			""",
			"""
			{"id": 2, "hostname": "chrome://FirefoxAccounts", "httpRealm": "Firefox Accounts credentials",
			 "encryptedUsername": "\(NSS.userDES)", "encryptedPassword": "\(NSS.passwordDES)", "encType": 1}
			""",
			"""
			{"id": 3, "hostname": "https://broken.example.org", "formSubmitURL": "",
			 "encryptedUsername": "\(NSS.userDES)", "encryptedPassword": "AAAA", "encType": 1}
			""",
		]
		if includesAES {
			logins.append(
				"""
				{"id": 4, "hostname": "https://intranet.example.org:8443", "httpRealm": null, "formSubmitURL": null,
				 "encryptedUsername": "\(NSS.userAES)", "encryptedPassword": "\(NSS.passwordAES)", "encType": 1}
				"""
			)
		}
		logins.append(
			"""
			{"id": 5, "hostname": "https://auth.example.org", "httpRealm": "Staff", "formSubmitURL": null,
			 "encryptedUsername": "\(NSS.userDES)", "encryptedPassword": "\(NSS.passwordDES)", "encType": 1}
			"""
		)
		try Self.write(
			#"{"nextId": 5, "logins": ["# + logins.joined(separator: ",") + "], \"version\": 3}",
			to: profile.appending(path: "logins.json")
		)
	}

	@Test
	internal func firefoxLoginsDecryptWithEitherKeyScheme() throws {
		for scheme in [KeyScheme.pbes2, .pkcs12] {
			let home = Self.makeHome()
			defer { try? FileManager.default.removeItem(at: home) }

			let profile = try Self.makeMozillaProfile(home: home, folder: "Firefox")
			try Self.writeKeyDatabase(scheme, in: profile)
			try Self.writeLogins(in: profile, includesAES: scheme == .pbes2)

			let contents = try MozillaCredentialStore.read(profile: profile, now: Self.now)

			// The record's URL is the login's origin, whatever page the form submitted to, so
			// the engine's realm check accepts it.
			var expected: [CredentialPasswordRecord] = [
				.init(
					url: "https://example.org/",
					signonRealm: "https://example.org/",
					username: "ada@example.org",
					password: "correct horse fixture"
				),
			]
			if scheme == .pbes2 {
				expected.append(
					.init(
						url: "https://intranet.example.org:8443/",
						signonRealm: "https://intranet.example.org:8443/",
						username: "grace@example.org",
						password: "battery staple fixture"
					)
				)
			}
			expectNoDifference(contents.passwords, expected)

			// Firefox's own account entry isn't a site; the damaged one is counted, and the HTTP
			// sign-in prompt's login, which the engine can't take, apart from it.
			#expect(contents.unreadablePasswordSites == ["broken.example.org": 1])
			#expect(contents.unreadablePasswords == 1)
			#expect(contents.httpAuthPasswords == 1)
		}
	}

	@Test
	internal func aPrimaryPasswordIsReportedNotGuessed() throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let profile = try Self.makeMozillaProfile(home: home, folder: "Firefox")
		try Self.writeKeyDatabase(.pbes2WithPrimaryPassword, in: profile)
		try Self.writeLogins(in: profile)

		#expect(throws: MozillaCredentialStore.Failure.primaryPassword) {
			try MozillaCredentialStore.read(profile: profile, now: Self.now)
		}

		// With the password, the same database opens, so the check really is the primary password.
		let keys = try FirefoxPlaces.withCopy(of: profile.appending(path: "key4.db")) { database in
			try MozillaKeyStore.loginKeys(database, primaryPassword: Data("hunter2".utf8))
		}
		#expect(keys.key(for: Self.data(hex: NSS.desKeyID))?.count == 24)
	}

	@Test
	internal func withoutAKeyDatabaseLoginsAreUnreadableAndSignInsStillMove() throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let profile = try Self.makeMozillaProfile(home: home, folder: "Firefox")
		try Self.writeLogins(in: profile)
		try Self.database(profile.appending(path: "cookies.sqlite"), Self.cookies)

		let contents = try MozillaCredentialStore.read(profile: profile, now: Self.now)
		#expect(contents.passwords.isEmpty)
		#expect(contents.unreadablePasswords == 3)
		#expect(contents.httpAuthPasswords == 1)
		expectNoDifference(contents.cookies.map(\.name), ["sid", "pref"])
	}

	@Test
	internal func derValuesReadNSSShapesAndRefuseDamage() throws {
		let value = try DERValue.parse(Self.data(hex: NSS.checkPKCS12))
		#expect(value[0][0].identifier == MozillaKeyStore.pkcs12TripleDES)
		#expect(value[0][1][1].intValue == 1)
		#expect(value[1].octets?.count == 16)
		#expect(throws: DERValue.Failure.malformed) {
			try DERValue.parse(Self.data(hex: String(NSS.checkPKCS12.dropLast(2))))
		}
		#expect(throws: DERValue.Failure.malformed) {
			try DERValue.parse(Self.data(hex: NSS.checkPKCS12 + "00"))
		}

		// A PBES2 value whose IV has an unexpected length is refused, never trapped on.
		func octets(_ count: Int) -> Data {
			Data([0x04, 0x82, UInt8(count >> 8), UInt8(count & 0xFF)]) + Data(repeating: 1, count: count)
		}
		func sequence(_ parts: Data...) -> Data {
			let body = parts.reduce(Data(), +)
			return Data([0x30, 0x82, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]) + body
		}
		let aesOID = Self.data(hex: "060960864801650304012a")
		let pbes2OID = Self.data(hex: "06092a864886f70d01050d")

		// The PBKDF2 parameters of the check value, as they are.
		let pbkdf2Params = Self.data(hex: String(NSS.checkPBES2.dropFirst(36).prefix(138)))
		let damaged = sequence(
			sequence(pbes2OID, sequence(pbkdf2Params, sequence(aesOID, octets(300)))),
			octets(16)
		)
		let damagedValue = try DERValue.parse(damaged)
		#expect(throws: MozillaCipher.Failure.unsupported) {
			try MozillaKeyStore.decrypt(damagedValue, globalSalt: Self.data(hex: NSS.globalSalt), password: Data())
		}
	}

	// MARK: - Firefox and Zen cookies

	private static let cookies: String = """
	CREATE TABLE moz_cookies (
		id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT, value TEXT, host TEXT,
		path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER, isSecure INTEGER,
		isHttpOnly INTEGER, inBrowserElement INTEGER DEFAULT 0, sameSite INTEGER DEFAULT 0,
		rawSameSite INTEGER DEFAULT 0, schemeMap INTEGER DEFAULT 0
	);
	INSERT INTO moz_cookies (originAttributes, name, value, host, path, expiry, lastAccessed, creationTime, isSecure, isHttpOnly, sameSite, schemeMap) VALUES
		('', 'sid', 'abc', '.example.org', '/', 1900000000, 1700000000000000, 1690000000000000, 1, 1, 0, 2),
		('', 'pref', 'dark', 'www.example.org', '/docs', 1900000000000, 1700000000000000, 1690000000000000, 0, 0, 1, 1),
		('', 'old', 'x', 'old.example.org', '/', 1600000000, 1500000000000000, 1500000000000000, 0, 0, 0, 1),
		('^userContextId=2', 'work', 'y', 'example.org', '/', 1900000000, 1700000000000000, 1690000000000000, 1, 0, 0, 2),
		('^partitionKey=%28https%2Cexample.com%29', 'embed', 'z', 'widget.example.net', '/', 1900000000, 1700000000000000, 1690000000000000, 1, 0, 0, 2);
	"""

	@Test
	internal func firefoxCookiesKeepTheirAttributesAndSkipOtherIdentities() throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let profile = try Self.makeMozillaProfile(home: home, folder: "zen")
		try Self.database(profile.appending(path: "cookies.sqlite"), Self.cookies)

		let contents = try MozillaCredentialStore.read(profile: profile, now: Self.now)
		#expect(contents.passwords.isEmpty)
		expectNoDifference(contents.cookies.map(\.name), ["sid", "pref"])
		let sid = try #require(contents.cookies.first)
		#expect(sid.domain == ".example.org")
		#expect(sid.expires == Date(timeIntervalSince1970: 1_900_000_000))
		#expect(sid.isSecure && sid.isHTTPOnly)
		#expect(sid.sameSite == 0)
		#expect(sid.sourceScheme == 2)
		let pref = contents.cookies[1]

		// Newer Firefox stores the expiry in milliseconds.
		#expect(pref.expires == Date(timeIntervalSince1970: 1_900_000_000))
		#expect(pref.sameSite == 1)
		#expect(pref.sourceScheme == 1)
		#expect(pref.path == "/docs")
		#expect(contents.domainCookieHosts == ["example.org"])
		// An insecure None cookie becomes unspecified, which Chromium accepts.
		#expect(MozillaCookies.sameSite(0, isSecure: false) == -1)
	}

	// MARK: - The credentials client

	private final class Writes: @unchecked Sendable {
		private let lock: NSLock = .init()
		private var _passwords: [CredentialPasswordRecord] = []
		private var _cookies: [CredentialCookieRecord] = []
		private var _keychainReads: Int = 0

		internal var passwords: [CredentialPasswordRecord] { lock.withLock { _passwords } }
		internal var cookies: [CredentialCookieRecord] { lock.withLock { _cookies } }
		internal var keychainReads: Int { lock.withLock { _keychainReads } }

		internal func wrote(_ records: [CredentialPasswordRecord]) { lock.withLock { _passwords += records } }
		internal func wrote(_ records: [CredentialCookieRecord]) { lock.withLock { _cookies += records } }
		internal func readKeychain() { lock.withLock { _keychainReads += 1 } }
	}

	private static func client(
		_ sources: [CredentialBrowser],
		writes: Writes
	) -> CredentialMigrationClient {
		.running(
			sources: sources,
			readSecret: { _ throws(ChromiumSafeStorage.KeyFailure) in
				writes.readKeychain()
				throw .missing
			},
			writer: .init(
				isAvailable: { true },
				importPasswords: { _, records in
					writes.wrote(records)
					return .init(imported: records.map(\.key))
				},
				setCookies: { _, records in
					writes.wrote(records)
					return .init(accepted: records.map(CredentialUndoRecord.Cookie.init))
				},
				checkCookies: { _, keys in Set(keys) },
				undo: { _ in }
			),
			now: { now }
		)
	}

	private static let profileID: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000896")!)

	@Test
	internal func firefoxPasswordsAndSignInsMoveWithoutTheKeychain() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let profile = try Self.makeMozillaProfile(home: home, folder: "Firefox")
		try Self.writeKeyDatabase(.pbes2, in: profile)
		try Self.writeLogins(in: profile)
		try Self.database(profile.appending(path: "cookies.sqlite"), Self.cookies)

		let writes: Writes = .init()
		let client = Self.client(CredentialBrowser.all(home: home), writes: writes)
		let source = try #require(await client.source(.init(rawValue: "firefox")))
		#expect(source.access == .profileFiles)
		#expect(source.keychainService == nil)
		expectNoDifference(source.profiles, [.init(id: Self.mozillaProfilePath, name: "default-release")])

		// Zen and Safari have nothing here, so they aren't offered.
		#expect(await client.source(.init(rawValue: "zen")) == nil)
		#expect(await client.source(.safari) == nil)

		await #expect(throws: CredentialMigrationFailure.unreadable) {
			try await client.read(.init(rawValue: "firefox"), "Profiles/../../elsewhere")
		}
		let inventory = try await client.read(.init(rawValue: "firefox"), Self.mozillaProfilePath)
		#expect(inventory.passwordCount == 2)
		#expect(inventory.unreadablePasswordCount == 1)
		#expect(inventory.httpAuthPasswordCount == 1)
		expectNoDifference(inventory.signInSites.map(\.host), ["example.org"])

		let report = try await client.migrate(inventory.sessionID, .all(in: inventory), Self.profileID)
		#expect(report.passwords?.imported == 2)
		// The summary says how many logins for HTTP sign-in prompts stayed behind.
		#expect(report.passwords?.httpAuthNotImported == 1)
		expectNoDifference(writes.passwords.map(\.username), ["ada@example.org", "grace@example.org"])
		expectNoDifference(writes.cookies.map(\.name), ["sid", "pref"])
		#expect(writes.keychainReads == 0)
	}

	@Test
	internal func onlyHTTPSignInLoginsStillShowInTheSummary() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let profile = try Self.makeMozillaProfile(home: home, folder: "Firefox")
		try Self.writeKeyDatabase(.pbes2, in: profile)
		try Self.write(
			"""
			{"logins": [{"id": 1, "hostname": "https://auth.example.org", "httpRealm": "Staff",
			 "encryptedUsername": "\(NSS.userDES)", "encryptedPassword": "\(NSS.passwordDES)"}]}
			""",
			to: profile.appending(path: "logins.json")
		)

		let writes: Writes = .init()
		let client = Self.client(CredentialBrowser.all(home: home), writes: writes)
		let inventory = try await client.read(.init(rawValue: "firefox"), Self.mozillaProfilePath)
		#expect(inventory.passwordCount == 0)
		#expect(inventory.httpAuthPasswordCount == 1)

		let report = try await client.migrate(inventory.sessionID, .all(in: inventory), Self.profileID)
		expectNoDifference(report.passwords, .init(imported: 0, httpAuthNotImported: 1))
		#expect(writes.passwords.isEmpty)
	}

	@Test
	internal func aPrimaryPasswordLeadsTheClientToCSV() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let profile = try Self.makeMozillaProfile(home: home, folder: "zen")
		try Self.writeKeyDatabase(.pbes2WithPrimaryPassword, in: profile)
		try Self.writeLogins(in: profile)

		let client = Self.client(CredentialBrowser.all(home: home), writes: .init())
		await #expect(throws: CredentialMigrationFailure.primaryPassword) {
			try await client.read(.init(rawValue: "zen"), Self.mozillaProfilePath)
		}
	}

	@Test
	internal func aHeadlessRunNeverReadsOrPrompts() async throws {
		let client = CredentialMigrationClient.unattended
		#expect(await client.source(.init(rawValue: "chrome")) == nil)
		#expect(await client.source(.safari) == nil)
		#expect(await client.canWrite() == false)
		#expect(await client.confirmPresence("Import") == false)
		await #expect(throws: CredentialMigrationFailure.unattended) {
			try await client.read(.init(rawValue: "firefox"), Self.mozillaProfilePath)
		}
		await #expect(throws: CredentialMigrationFailure.unattended) {
			try await client.readProfiles(.init(rawValue: "chrome"), ["Default"])
		}
	}

	// MARK: - Safari cookies

	/// Three cookies in one page: a secure, HTTP-only domain cookie, a host cookie with a
	/// path, and an expired one.
	private static let binaryCookies: String = """
	636f6f6b000000010000011b00000100030000001800000071000000c900000000000000590000000100000005000000000000003800000045000000\
	5000000052000000000000000000000000000040f577cb41000000401482c5412e6578616d706c652e6f72670073657373696f6e5f6964002f007333\
	63726574005800000001000000000000000000000038000000480000004d00000053000000000000000000000000000040f577cb41000000401482c5\
	417777772e6578616d706c652e6f72670070726566002f646f6373006461726b005200000001000000010000000000000038000000490000004e0000\
	00500000000000000000000000000000c02387c241000000806618bf412e6f6c642e6578616d706c652e6e657400676f6e65002f0078000000000007\
	1720050000004b
	"""

	@Test
	internal func safariCookiesAreReadFromTheirBinaryFile() throws {
		let cookies = try SafariCookies.cookies(Self.data(hex: Self.binaryCookies))
		expectNoDifference(cookies.map(\.name), ["session_id", "pref", "gone"])
		let session = cookies[0]
		#expect(session.domain == ".example.org")
		#expect(session.value == "s3cret")
		#expect(session.isSecure && session.isHTTPOnly)
		#expect(session.expires == Date(timeIntervalSince1970: 1_900_000_000))
		#expect(session.created == Date(timeIntervalSince1970: 1_700_000_000))
		#expect(cookies[1].path == "/docs")
		#expect(!cookies[1].isSecure)

		var contents: ChromiumCredentialStore.Contents = .init()
		try SafariCookies.read(Self.data(hex: Self.binaryCookies), now: Self.now, into: &contents)
		expectNoDifference(contents.cookies.map(\.name), ["session_id", "pref"])
		#expect(contents.cookies[0].sourceScheme == 2)

		#expect(throws: SafariCookies.Failure.notBinaryCookies) {
			try SafariCookies.cookies(Data("bplist00".utf8))
		}

		// A file cut short keeps what it holds whole and never reads past its end.
		let truncated = Self.data(hex: Self.binaryCookies).prefix(120)
		#expect((try? SafariCookies.cookies(truncated))?.isEmpty == true)
	}

	@Test
	internal func safariSignInsMoveWithFullDiskAccessAndNoPasswords() async throws {
		let home = Self.makeHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let file = SafariCookies.files(home: home)[0]
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Self.data(hex: Self.binaryCookies).write(to: file)

		let writes: Writes = .init()
		let client = Self.client(CredentialBrowser.all(home: home), writes: writes)
		let source = try #require(await client.source(.safari))
		#expect(source.access == .fullDiskAccess)
		expectNoDifference(source.profiles.map(\.id), [SafariData.defaultProfile.id])

		let inventory = try await client.read(.safari, SafariData.defaultProfile.id)
		#expect(inventory.passwordCount == 0)
		expectNoDifference(inventory.signInSites.map(\.host), ["example.org"])
		_ = try await client.migrate(inventory.sessionID, .all(in: inventory), Self.profileID)
		expectNoDifference(writes.cookies.map(\.name), ["session_id", "pref"])
		#expect(writes.passwords.isEmpty)
		#expect(writes.keychainReads == 0)
	}
}
