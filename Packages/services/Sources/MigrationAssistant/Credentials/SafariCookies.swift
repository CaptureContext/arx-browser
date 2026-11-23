import Foundation

/// Reads Safari's `Cookies.binarycookies` (DEV-896), which needs Full Disk Access like the
/// rest of Safari's data. Values are cleartext; Safari keeps no session cookies on disk.
///
/// The format is Apple's own and undocumented: the magic `cook`, a big-endian page count and
/// page sizes, then pages of little-endian cookie records. Each record has its flags, the
/// offsets of its domain, name, path and value strings, and its expiry and creation times
/// as seconds since 2001. Anything that doesn't fit is skipped, never guessed at.
internal enum SafariCookies {
	internal enum Failure: Error, Equatable, Sendable {
		case notBinaryCookies
	}

	internal struct Cookie: Equatable, Sendable {
		internal var domain: String
		internal var name: String
		internal var path: String
		internal var value: String
		internal var expires: Date
		internal var created: Date
		internal var isSecure: Bool
		internal var isHTTPOnly: Bool
	}

	private static let magic: [UInt8] = Array("cook".utf8)
	private static let pageMagic: UInt32 = 0x0000_0100
	private static let secureFlag: UInt32 = 1 << 0
	private static let httpOnlyFlag: UInt32 = 1 << 2

	/// The fixed part of a record, before its strings.
	private static let headerSize: Int = 56

	/// Newer Safari keeps cookies in its container; older ones in `~/Library/Cookies`.
	internal static func files(home: URL) -> [URL] {
		[
			home.appending(path: "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
			home.appending(path: "Library/Cookies/Cookies.binarycookies"),
		]
	}

	internal static func cookies(_ data: Data) throws(Failure) -> [Cookie] {
		let bytes: [UInt8] = .init(data)
		guard bytes.count >= 8, Array(bytes.prefix(4)) == magic else { throw .notBinaryCookies }

		let pageCount = Int(bigEndian(bytes, at: 4))
		guard pageCount <= (bytes.count - 8) / 4 else { throw .notBinaryCookies }

		var offset = 8 + pageCount * 4
		var cookies: [Cookie] = []
		for index in 0..<pageCount {
			let size = Int(bigEndian(bytes, at: 8 + index * 4))
			guard size <= bytes.count - offset else { break }

			cookies += page(Array(bytes[offset..<offset + size]))
			offset += size
		}
		return cookies
	}

	internal static func read(
		_ data: Data,
		now: Date,
		into contents: inout ChromiumCredentialStore.Contents
	) throws(Failure) {
		for cookie in try cookies(data) where !cookie.domain.isEmpty {
			let site = CredentialSiteGrouping.normalized(cookie.domain)
			if cookie.domain.hasPrefix(".") { contents.domainCookieHosts.insert(site) }
			guard cookie.expires > now else { continue }

			contents.cookies.append(
				.init(
					domain: cookie.domain,
					name: cookie.name,
					value: cookie.value,
					path: cookie.path.isEmpty ? "/" : cookie.path,
					created: cookie.created,
					expires: cookie.expires,
					lastAccessed: cookie.created,
					isSecure: cookie.isSecure,
					isHTTPOnly: cookie.isHTTPOnly,
					// The file doesn't say; Chromium treats unspecified as Lax by default.
					sameSite: -1,
					priority: 1,
					sourceScheme: cookie.isSecure ? 2 : 0,
					sourcePort: -1
				)
			)
		}
	}

	private static func page(_ bytes: [UInt8]) -> [Cookie] {
		guard bytes.count >= 8, bigEndian(bytes, at: 0) == pageMagic else { return [] }

		let count = Int(littleEndian(bytes, at: 4))
		guard count <= (bytes.count - 8) / 4 else { return [] }

		return (0..<count).compactMap { index in
			let start = Int(littleEndian(bytes, at: 8 + index * 4))
			guard start >= 0, start <= bytes.count - headerSize else { return nil }

			let size = Int(littleEndian(bytes, at: start))
			guard size >= headerSize, size <= bytes.count - start else { return nil }

			return cookie(Array(bytes[start..<start + size]))
		}
	}

	private static func cookie(_ record: [UInt8]) -> Cookie? {
		let flags = littleEndian(record, at: 8)
		func string(at field: Int) -> String? {
			let start = Int(littleEndian(record, at: field))
			guard start >= headerSize, start < record.count else { return nil }

			let end = record[start...].firstIndex(of: 0) ?? record.count
			return String(bytes: record[start..<end], encoding: .utf8)
		}

		guard
			let domain = string(at: 16),
			let name = string(at: 20),
			let path = string(at: 24),
			let value = string(at: 28)
		else { return nil }

		return .init(
			domain: domain,
			name: name,
			path: path,
			value: value,
			expires: Date(timeIntervalSinceReferenceDate: double(record, at: 40)),
			created: Date(timeIntervalSinceReferenceDate: double(record, at: 48)),
			isSecure: flags & secureFlag != 0,
			isHTTPOnly: flags & httpOnlyFlag != 0
		)
	}

	private static func bigEndian(
		_ bytes: [UInt8],
		at offset: Int
	) -> UInt32 {
		guard offset >= 0, offset + 4 <= bytes.count else { return 0 }

		return bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
	}

	private static func littleEndian(
		_ bytes: [UInt8],
		at offset: Int
	) -> UInt32 {
		guard offset >= 0, offset + 4 <= bytes.count else { return 0 }

		return bytes[offset..<offset + 4].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
	}

	private static func double(
		_ bytes: [UInt8],
		at offset: Int
	) -> Double {
		guard offset >= 0, offset + 8 <= bytes.count else { return 0 }

		let bits = bytes[offset..<offset + 8].reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
		return Double(bitPattern: bits)
	}
}
