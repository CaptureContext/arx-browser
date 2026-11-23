import CommonCrypto
import CryptoKit
import Foundation

/// Chromium's macOS storage encryption, read side only (DEV-650).
///
/// - Key: PBKDF2-HMAC-SHA1 over the Keychain secret, salt `saltysalt`, 1003 rounds, 16 bytes
///   (`components/os_crypt/async/browser/keychain_key_provider.mm`).
/// - Value: `v10` + AES-128-CBC with an IV of 16 spaces and PKCS#7 padding
///   (`components/os_crypt/async/common/encryptor.cc`).
/// - Cookies since database version 24 prefix the plaintext with SHA-256 of `host_key`
///   (`net/extras/sqlite/sqlite_persistent_cookie_store.cc`).
///
/// Everything happens in memory. The key is a value type the caller drops right after use;
/// `ChromiumCipher.Key.erase()` overwrites its bytes.
internal enum ChromiumCipher {
	internal struct Key: Sendable {
		fileprivate var bytes: [UInt8]

		/// Derives the key from the source browser's Keychain secret.
		internal init(secret: Data) {
			let salt: [UInt8] = Array("saltysalt".utf8)
			var derived: [UInt8] = .init(repeating: 0, count: kCCKeySizeAES128)
			let status = secret.withUnsafeBytes { secretBytes in
				CCKeyDerivationPBKDF(
					CCPBKDFAlgorithm(kCCPBKDF2),
					secretBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
					secret.count,
					salt,
					salt.count,
					CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
					1003,
					&derived,
					derived.count
				)
			}
			self.bytes = status == kCCSuccess ? derived : []
		}

		/// For fixtures that already hold a derived key.
		internal init(derived: [UInt8]) {
			self.bytes = derived
		}

		internal var isValid: Bool { bytes.count == kCCKeySizeAES128 }

		internal mutating func erase() {
			for index in bytes.indices { bytes[index] = 0 }
			bytes = []
		}
	}

	internal enum Failure: Error, Equatable, Sendable {
		/// Not `v10`: an older or another browser's scheme. The row is skipped.
		case unknownVersion

		/// Wrong key or damaged data.
		case undecryptable

		/// The cookie's host hash doesn't match its `host_key`; Chromium would drop it too.
		case hostMismatch
	}

	private static let prefix: [UInt8] = Array("v10".utf8)
	private static let iv: [UInt8] = .init(repeating: 0x20, count: kCCBlockSizeAES128)

	/// Decrypts a password value from `Login Data`.
	internal static func decrypt(
		_ blob: Data,
		with key: Key
	) throws(Failure) -> Data {
		guard blob.starts(with: prefix) else { throw .unknownVersion }
		guard key.isValid else { throw .undecryptable }

		return try aes(CCOperation(kCCDecrypt), blob.dropFirst(prefix.count), key: key)
	}

	/// Decrypts a cookie value and checks its host hash. Databases older than version 24
	/// have no hash, so `hashesHost` is false for them.
	internal static func decryptCookie(
		_ blob: Data,
		host: String,
		hashesHost: Bool,
		with key: Key
	) throws(Failure) -> Data {
		let plain = try decrypt(blob, with: key)
		guard hashesHost else { return plain }

		let digest = Data(SHA256.hash(data: Data(host.utf8)))
		guard plain.starts(with: digest) else { throw .hostMismatch }

		return plain.dropFirst(digest.count)
	}

	/// The inverse of `decrypt`, for building fixtures in tests only.
	internal static func encrypt(
		_ plain: Data,
		with key: Key
	) throws(Failure) -> Data {
		Data(prefix) + (try aes(CCOperation(kCCEncrypt), plain, key: key))
	}

	private static func aes(
		_ operation: CCOperation,
		_ input: Data,
		key: Key
	) throws(Failure) -> Data {
		var output: [UInt8] = .init(repeating: 0, count: input.count + kCCBlockSizeAES128)
		var written: Int = 0
		let status = input.withUnsafeBytes { inputBytes in
			CCCrypt(
				operation,
				CCAlgorithm(kCCAlgorithmAES),
				CCOptions(kCCOptionPKCS7Padding),
				key.bytes,
				key.bytes.count,
				iv,
				inputBytes.baseAddress,
				input.count,
				&output,
				output.count,
				&written
			)
		}
		defer {
			for index in output.indices { output[index] = 0 }
		}
		guard status == kCCSuccess else { throw .undecryptable }

		return Data(output.prefix(written))
	}
}
