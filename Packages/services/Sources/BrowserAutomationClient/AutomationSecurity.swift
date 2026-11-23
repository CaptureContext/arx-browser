import BrowserCore
import CryptoKit
import Foundation
import Security

public struct AutomationCredential: Sendable {
	public let token: String
	public let digest: String

	public init(token: String) {
		self.token = token
		self.digest = AutomationSecurity.digest(Data(token.utf8))
	}
}

public enum AutomationSecurity {
	public static func credential() throws -> AutomationCredential {
		var bytes = [UInt8](repeating: 0, count: 32)
		guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
		else { throw AutomationFailure.appUnavailable }
		return .init(token: bytes.map { String(format: "%02x", $0) }.joined())
	}

	/// Lowercase hexadecimal SHA-256, written without a formatter per byte.
	public static func digest(_ data: Data) -> String {
		let hash = SHA256.hash(data: data)
		return String(unsafeUninitializedCapacity: SHA256.byteCount * 2) { buffer in
			var index = 0
			for byte in hash {
				buffer[index] = hexDigits[Int(byte >> 4)]
				buffer[index + 1] = hexDigits[Int(byte & 0x0f)]
				index += 2
			}
			return index
		}
	}

	private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

	public static func matches(
		token: String,
		digest: String
	) -> Bool {
		guard token.utf8.count == 64, digest.utf8.count == 64 else { return false }
		let supplied = Array(Self.digest(Data(token.utf8)).utf8)
		let expected = Array(digest.utf8)
		return zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
	}
}
