import CommonCrypto
import CryptoKit
import Foundation

/// Reads one Firefox or Zen profile's saved logins and persistent cookies (DEV-896).
///
/// - Logins are in `logins.json`, each username and password encrypted with a key NSS keeps
///   in `key4.db`. That key is itself encrypted with one derived from the primary password,
///   which is empty unless the user set one; with a primary password Arx reads nothing
///   (`primaryPassword`) and the step offers the CSV export.
/// - Cookies are cleartext rows in `cookies.sqlite`.
///
/// `key4.db` and `cookies.sqlite` are read from private copies, like Chromium's stores.
/// Nothing is written back, and every key is erased after the read.
internal enum MozillaCredentialStore {
	internal enum Failure: Error, Equatable, Sendable {
		/// The profile has a primary password; Arx doesn't ask for it.
		case primaryPassword

		/// `key4.db` is missing, damaged or in a scheme Arx doesn't know.
		case unreadableKey
	}

	/// NSS's `CKA_ID` for the key that encrypts logins.
	internal static let loginKeyID: Data = Data([0xF8] + [UInt8](repeating: 0, count: 14) + [0x01])

	internal static func read(
		profile directory: URL,
		now: Date
	) throws -> ChromiumCredentialStore.Contents {
		var contents: ChromiumCredentialStore.Contents = .init()
		let fileManager: FileManager = .default
		let logins = directory.appending(path: "logins.json")
		let keys = directory.appending(path: "key4.db")
		let cookies = directory.appending(path: "cookies.sqlite")

		if fileManager.fileExists(atPath: logins.path(percentEncoded: false)) {
			let entries = try MozillaLogins.entries(Data(contentsOf: logins))
			if !entries.isEmpty {
				var key: MozillaKeyStore.Keys
				do {
					key = try FirefoxPlaces.withCopy(of: keys, logSuffixes: ["-wal", "-journal"]) { database in
						try MozillaKeyStore.loginKeys(database)
					}
				} catch MozillaCredentialStore.Failure.primaryPassword {
					throw Failure.primaryPassword
				} catch {
					// No usable key: the logins are counted as unreadable, and sign-ins still move.
					key = .init([:])
				}
				defer { key.erase() }

				MozillaLogins.decrypt(entries, with: key, into: &contents)
			}
		}
		if fileManager.fileExists(atPath: cookies.path(percentEncoded: false)) {
			try FirefoxPlaces.withCopy(of: cookies, logSuffixes: ["-wal", "-journal"]) { database in
				try MozillaCookies.read(database, now: now, into: &contents)
			}
		}
		return contents
	}
}

// MARK: - key4.db

/// NSS's key database, read side only.
///
/// `metadata` holds the global salt and `password-check` encrypted with the primary
/// password; `nssPrivate` holds the login key, encrypted the same way, under its `CKA_ID`.
/// Firefox 75 and later use PBES2 (PBKDF2-HMAC-SHA256 and AES-256-CBC); older profiles use
/// PKCS#12's SHA-1 and Triple DES scheme. Both are read.
internal enum MozillaKeyStore {
	/// Login keys by `CKA_ID`. Values are erased with `erase()`.
	internal struct Keys: Sendable {
		fileprivate var values: [Data: [UInt8]]

		internal init(_ values: [Data: [UInt8]]) {
			self.values = values
		}

		internal func key(for id: Data) -> [UInt8]? {
			values[id]
		}

		internal mutating func erase() {
			for id in values.keys {
				guard var bytes = values[id] else { continue }

				for index in bytes.indices { bytes[index] = 0 }
				values[id] = bytes
			}
			values = [:]
		}
	}

	internal static let passwordCheck: Data = Data("password-check".utf8)

	internal static let pbes2: String = "1.2.840.113549.1.5.13"
	internal static let pbkdf2: String = "1.2.840.113549.1.5.12"
	internal static let hmacSHA256: String = "1.2.840.113549.2.9"
	internal static let aes256CBC: String = "2.16.840.1.101.3.4.1.42"
	internal static let tripleDESCBC: String = "1.2.840.113549.3.7"

	/// `pbeWithSha1AndTripleDES-CBC`.
	internal static let pkcs12TripleDES: String = "1.2.840.113549.1.12.5.1.3"

	internal static func loginKeys(
		_ database: SQLiteDatabase,
		primaryPassword: Data = Data()
	) throws(MozillaCredentialStore.Failure) -> Keys {
		do {
			guard try database.hasTable("metadata"), try database.hasTable("nssPrivate")
			else { throw MozillaCredentialStore.Failure.unreadableKey }

			let metadata = try database.rows("SELECT item1, item2 FROM metadata WHERE id = 'password'") { row in
				(salt: row.blob(0), check: row.blob(1))
			}
			guard let metadata = metadata.first
			else { throw MozillaCredentialStore.Failure.unreadableKey }

			let check = try? decrypt(
				DERValue.parse(metadata.check),
				globalSalt: metadata.salt,
				password: primaryPassword
			)
			guard let check, Data(check).starts(with: passwordCheck)
			else { throw MozillaCredentialStore.Failure.primaryPassword }

			let rows = try database.rows("SELECT a11, a102 FROM nssPrivate") { row in
				(value: row.blob(0), id: row.blob(1))
			}
			var keys: [Data: [UInt8]] = [:]
			for row in rows where !row.value.isEmpty {
				guard
					let parsed = try? DERValue.parse(row.value),
					let key = try? decrypt(parsed, globalSalt: metadata.salt, password: primaryPassword)
				else { continue }

				keys[row.id] = key
			}
			guard !keys.isEmpty else { throw MozillaCredentialStore.Failure.unreadableKey }

			return .init(keys)
		} catch let failure as MozillaCredentialStore.Failure {
			throw failure
		} catch {
			throw .unreadableKey
		}
	}

	/// Decrypts a PBE-encrypted value from `key4.db`.
	internal static func decrypt(
		_ value: DERValue,
		globalSalt: Data,
		password: Data
	) throws(MozillaCipher.Failure) -> [UInt8] {
		let algorithm = value[0]
		let ciphertext = value[1].octets ?? Data()
		let base = Data(Insecure.SHA1.hash(data: globalSalt + password))

		switch algorithm[0].identifier {
		case pbes2:
			let parameters = algorithm[1]
			let derivation = parameters[0]
			let encryption = parameters[1]
			guard
				derivation[0].identifier == pbkdf2,
				let salt = derivation[1][0].octets,
				let iterations = derivation[1][1].intValue,
				let length = derivation[1][2].intValue,
				encryption[0].identifier == aes256CBC,
				let iv = encryption[1].octets
			else { throw .unsupported }

			// NSS stores the IV without its own DER header (04 0E), which is part of the IV.
			let fullIV: Data
			switch iv.count {
			case kCCBlockSizeAES128: fullIV = iv
			case kCCBlockSizeAES128 - 2: fullIV = Data([0x04, UInt8(iv.count)]) + iv
			default: throw .unsupported
			}
			var key = try MozillaCipher.pbkdf2SHA256(password: base, salt: salt, iterations: iterations, length: length)
			defer { MozillaCipher.erase(&key) }

			return try MozillaCipher.crypt(.decrypt, .aes, key: key, iv: [UInt8](fullIV), ciphertext)

		case pkcs12TripleDES:
			guard let salt = algorithm[1][0].octets else { throw .unsupported }

			var derived = MozillaCipher.pkcs12TripleDESKey(base: base, salt: salt)
			defer { MozillaCipher.erase(&derived.key) }

			return try MozillaCipher.crypt(.decrypt, .tripleDES, key: derived.key, iv: derived.iv, ciphertext)

		default:
			throw .unsupported
		}
	}
}

/// NSS's ciphers through CommonCrypto.
internal enum MozillaCipher {
	internal enum Failure: Error, Equatable, Sendable {
		case unsupported
		case undecryptable
	}

	internal enum Operation {
		case encrypt
		case decrypt
	}

	internal enum Algorithm {
		case aes
		case tripleDES

		fileprivate var keySize: Int {
			switch self {
			case .aes: kCCKeySizeAES256
			case .tripleDES: kCCKeySize3DES
			}
		}

		fileprivate var blockSize: Int {
			switch self {
			case .aes: kCCBlockSizeAES128
			case .tripleDES: kCCBlockSize3DES
			}
		}
	}

	/// CBC with PKCS#7 padding. `key` may be longer than the algorithm's key; NSS pads the
	/// stored login key, and only its first bytes are the key.
	internal static func crypt(
		_ operation: Operation,
		_ algorithm: Algorithm,
		key: [UInt8],
		iv: [UInt8],
		_ input: Data
	) throws(Failure) -> [UInt8] {
		guard
			key.count >= algorithm.keySize,
			iv.count == algorithm.blockSize
		else { throw .undecryptable }

		var output: [UInt8] = .init(repeating: 0, count: input.count + algorithm.blockSize)
		var written: Int = 0
		let status = input.withUnsafeBytes { bytes in
			CCCrypt(
				operation == .encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
				algorithm == .aes ? CCAlgorithm(kCCAlgorithmAES) : CCAlgorithm(kCCAlgorithm3DES),
				CCOptions(kCCOptionPKCS7Padding),
				Array(key.prefix(algorithm.keySize)),
				algorithm.keySize,
				iv,
				bytes.baseAddress,
				input.count,
				&output,
				output.count,
				&written
			)
		}
		guard status == kCCSuccess else {
			erase(&output)
			throw .undecryptable
		}

		let result = Array(output.prefix(written))
		erase(&output)
		return result
	}

	internal static func pbkdf2SHA256(
		password: Data,
		salt: Data,
		iterations: Int,
		length: Int
	) throws(Failure) -> [UInt8] {
		guard
			(1...64).contains(length),
			iterations > 0,
			iterations <= 10_000_000
		else { throw .unsupported }

		var derived: [UInt8] = .init(repeating: 0, count: length)
		let status = password.withUnsafeBytes { passwordBytes in
			salt.withUnsafeBytes { saltBytes in
				CCKeyDerivationPBKDF(
					CCPBKDFAlgorithm(kCCPBKDF2),
					passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
					password.count,
					saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
					salt.count,
					CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
					UInt32(iterations),
					&derived,
					length
				)
			}
		}
		guard status == kCCSuccess else { throw .undecryptable }

		return derived
	}

	/// PKCS#12's SHA-1 key derivation as NSS applies it to `key4.db` before Firefox 75.
	internal static func pkcs12TripleDESKey(
		base: Data,
		salt: Data
	) -> (key: [UInt8], iv: [UInt8]) {
		let paddedSalt = salt + Data(repeating: 0, count: max(0, 20 - salt.count))
		let combined = Data(Insecure.SHA1.hash(data: base + salt))
		let key = SymmetricKey(data: combined)
		func hmac(_ data: Data) -> Data {
			Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
		}

		let first = hmac(paddedSalt + salt)
		let second = hmac(hmac(paddedSalt) + salt)
		let bytes = [UInt8](first + second)
		return (Array(bytes.prefix(24)), Array(bytes.suffix(8)))
	}

	internal static func erase(_ bytes: inout [UInt8]) {
		for index in bytes.indices { bytes[index] = 0 }
	}
}

// MARK: - logins.json

internal enum MozillaLogins {
	internal struct Entry: Equatable, Sendable {
		internal var hostname: String
		internal var httpRealm: String?
		internal var formSubmitURL: String?
		internal var encryptedUsername: String
		internal var encryptedPassword: String
	}

	internal static func entries(_ data: Data) throws -> [Entry] {
		let object = try JSONSerialization.jsonObject(with: data)
		guard let logins = (object as? [String: Any])?["logins"] as? [[String: Any]]
		else { return [] }

		return logins.compactMap { login in
			guard
				let hostname = login["hostname"] as? String,
				let username = login["encryptedUsername"] as? String,
				let password = login["encryptedPassword"] as? String
			else { return nil }

			return .init(
				hostname: hostname,
				httpRealm: login["httpRealm"] as? String,
				formSubmitURL: login["formSubmitURL"] as? String,
				encryptedUsername: username,
				encryptedPassword: password
			)
		}
	}

	/// Chromium's `signon_realm` for a Firefox form login: the login's origin with a trailing
	/// slash, as `GetSignonRealm` gives it for the origin, which is also the record's URL, so
	/// the engine accepts the pair whatever page the form submitted to.
	internal static func signonRealm(_ entry: Entry) -> String? {
		guard
			let url = URL(string: entry.hostname),
			let scheme = url.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			let host = url.host()?.lowercased(),
			!host.isEmpty
		else { return nil }

		let isDefaultPort = url.port == nil || url.port == (scheme == "https" ? 443 : 80)
		let port = isDefaultPort ? "" : ":\(url.port!)"
		return "\(scheme)://\(host)\(port)/"
	}

	internal static func decrypt(
		_ entries: [Entry],
		with keys: MozillaKeyStore.Keys,
		into contents: inout ChromiumCredentialStore.Contents
	) {
		var seen: Set<CredentialUndoRecord.Password> = Set(contents.passwords.map(\.key))
		for entry in entries {
			// Firefox's own entries (`chrome://FirefoxAccounts`) aren't sites.
			guard let realm = signonRealm(entry) else { continue }

			// The engine imports form logins only; an HTTP sign-in prompt's login stays in the
			// browser, and the summary says how many did (Max, DEV-896).
			let host = URL(string: entry.hostname)?.host() ?? entry.hostname
			guard entry.httpRealm?.isEmpty ?? true else {
				contents.httpAuthPasswords += 1
				continue
			}

			guard
				let username = try? decryptValue(entry.encryptedUsername, with: keys),
				let password = try? decryptValue(entry.encryptedPassword, with: keys),
				!password.isEmpty
			else {
				contents.unreadablePasswords += 1
				contents.unreadablePasswordSites[host, default: 0] += 1
				continue
			}

			let record: CredentialPasswordRecord = .init(
				url: realm,
				signonRealm: realm,
				username: username,
				password: password
			)
			guard seen.insert(record.key).inserted else { continue }

			contents.passwords.append(record)
		}
	}

	/// A base64 DER value: the key's `CKA_ID`, the cipher and its IV, and the ciphertext.
	internal static func decryptValue(
		_ base64: String,
		with keys: MozillaKeyStore.Keys
	) throws(MozillaCipher.Failure) -> String {
		guard
			let data = Data(base64Encoded: base64),
			let value = try? DERValue.parse(data),
			let id = value[0].octets,
			let key = keys.key(for: id),
			let iv = value[1][1].octets,
			let ciphertext = value[2].octets
		else { throw .undecryptable }

		let algorithm: MozillaCipher.Algorithm
		switch value[1][0].identifier {
		case MozillaKeyStore.tripleDESCBC: algorithm = .tripleDES
		case MozillaKeyStore.aes256CBC: algorithm = .aes
		default: throw .unsupported
		}

		var plain = try MozillaCipher.crypt(.decrypt, algorithm, key: key, iv: [UInt8](iv), ciphertext)
		defer { MozillaCipher.erase(&plain) }

		guard let text = String(bytes: plain, encoding: .utf8) else { throw .undecryptable }

		return text
	}
}

// MARK: - cookies.sqlite

/// `moz_cookies(host, name, value, path, expiry, lastAccessed, creationTime, isSecure,
/// isHttpOnly, sameSite, schemeMap, originAttributes)`. Values are cleartext.
internal enum MozillaCookies {
	/// `schemeMap` bits: the schemes that set the cookie.
	private static let httpScheme: Int64 = 1 << 0
	private static let httpsScheme: Int64 = 1 << 1

	internal static func read(
		_ database: SQLiteDatabase,
		now: Date,
		into contents: inout ChromiumCredentialStore.Contents
	) throws {
		guard try database.hasTable("moz_cookies") else { return }

		let columns: Set<String> = Set(try database.rows("PRAGMA table_info(moz_cookies)") { $0.text(1) ?? "" })
		func column(
			_ name: String,
			or fallback: String
		) -> String {
			columns.contains(name) ? name : "\(fallback) AS \(name)"
		}

		let rows = try database.rows(
			"""
			SELECT host, name, value, path, expiry, lastAccessed, creationTime,
				isSecure, isHttpOnly, \(column("sameSite", or: "0")), \(column("schemeMap", or: "0")),
				\(column("originAttributes", or: "''"))
			FROM moz_cookies
			"""
		) { row in
			(
				host: row.text(0) ?? "",
				name: row.text(1) ?? "",
				value: row.text(2) ?? "",
				path: row.text(3) ?? "/",
				expiry: row.int(4),
				lastAccessed: row.int(5),
				created: row.int(6),
				isSecure: row.int(7) != 0,
				isHTTPOnly: row.int(8) != 0,
				sameSite: row.int(9),
				schemeMap: row.int(10),
				originAttributes: row.text(11) ?? ""
			)
		}
		for row in rows {
			// Containers, private browsing and partitioned cookies belong to an identity or a
			// top-level site Arx doesn't have.
			guard row.originAttributes.isEmpty, !row.host.isEmpty else { continue }

			let site = CredentialSiteGrouping.normalized(row.host)
			if row.host.hasPrefix(".") { contents.domainCookieHosts.insert(site) }
			let expires = expiryDate(row.expiry)
			guard expires > now else { continue }

			let sourceScheme: Int = switch row.schemeMap {
			case httpsScheme: 2
			case httpScheme: 1
			default: 0
			}
			contents.cookies.append(
				.init(
					domain: row.host,
					name: row.name,
					value: row.value,
					path: row.path.isEmpty ? "/" : row.path,
					created: Date(timeIntervalSince1970: Double(row.created) / 1_000_000),
					expires: expires,
					lastAccessed: Date(timeIntervalSince1970: Double(row.lastAccessed) / 1_000_000),
					isSecure: row.isSecure,
					isHTTPOnly: row.isHTTPOnly,
					sameSite: sameSite(row.sameSite, isSecure: row.isSecure),
					priority: 1,
					sourceScheme: sourceScheme,
					sourcePort: -1
				)
			)
		}
	}

	/// Older Firefox stores `expiry` in seconds, newer Firefox in milliseconds. A value past
	/// the year 5138 in seconds is read as milliseconds.
	internal static func expiryDate(_ value: Int64) -> Date {
		let seconds = value > 100_000_000_000 ? Double(value) / 1_000 : Double(value)
		return Date(timeIntervalSince1970: seconds)
	}

	/// Firefox's `nsICookie` values (0 none, 1 lax, 2 strict) to Chromium's. A None cookie
	/// must be secure in Chromium, so an insecure one becomes unspecified.
	internal static func sameSite(
		_ value: Int64,
		isSecure: Bool
	) -> Int {
		switch value {
		case 0: isSecure ? 0 : -1
		case 1: 1
		case 2: 2
		default: -1
		}
	}
}
