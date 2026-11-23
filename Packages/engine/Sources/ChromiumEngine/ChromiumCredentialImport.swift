import ChromiumBridge
import Darwin
import Foundation

/// ABI46. One decrypted saved password from another Chromium browser. Its
/// descriptions never show the password.
public struct ChromiumImportedPassword: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
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

	public var description: String { "ChromiumImportedPassword(\(signonRealm), \(username), <redacted>)" }
	public var debugDescription: String { description }
}

/// ABI46. One decrypted persistent cookie, with times as Chromium stores them:
/// microseconds since 1601-01-01 UTC. Its descriptions never show the value.
public struct ChromiumImportedCookie: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
	public var domain: String
	public var name: String
	public var value: String
	public var path: String
	public var topFrameSiteKey: String
	public var creationUTC: Int64
	public var expiresUTC: Int64
	public var lastAccessUTC: Int64
	public var isSecure: Bool
	public var isHTTPOnly: Bool
	public var hasCrossSiteAncestor: Bool
	public var sameSite: Int32
	public var priority: Int32
	public var sourceScheme: Int32
	public var sourcePort: Int32

	public init(
		domain: String,
		name: String,
		value: String,
		path: String,
		topFrameSiteKey: String,
		creationUTC: Int64,
		expiresUTC: Int64,
		lastAccessUTC: Int64,
		isSecure: Bool,
		isHTTPOnly: Bool,
		hasCrossSiteAncestor: Bool,
		sameSite: Int32,
		priority: Int32,
		sourceScheme: Int32,
		sourcePort: Int32
	) {
		self.domain = domain
		self.name = name
		self.value = value
		self.path = path
		self.topFrameSiteKey = topFrameSiteKey
		self.creationUTC = creationUTC
		self.expiresUTC = expiresUTC
		self.lastAccessUTC = lastAccessUTC
		self.isSecure = isSecure
		self.isHTTPOnly = isHTTPOnly
		self.hasCrossSiteAncestor = hasCrossSiteAncestor
		self.sameSite = sameSite
		self.priority = priority
		self.sourceScheme = sourceScheme
		self.sourcePort = sourcePort
	}

	public var description: String { "ChromiumImportedCookie(\(domain), \(name), <redacted>)" }
	public var debugDescription: String { description }
}

/// ABI46. A password the engine imported, as the store keeps it. `dateCreated`
/// is the store's creation time (decimal microseconds since 1601); undo removes
/// the entry only while it still has that time.
public struct ChromiumPasswordKey: Codable, Hashable, Sendable {
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

/// ABI46. A cookie's full identity. Unpartitioned cookies always carry
/// `hasCrossSiteAncestor` false.
public struct ChromiumCookieKey: Codable, Hashable, Sendable {
	public var domain: String
	public var name: String
	public var path: String
	public var topFrameSiteKey: String
	public var hasCrossSiteAncestor: Bool
	public var sourceScheme: Int32
	public var sourcePort: Int32

	public init(
		domain: String,
		name: String,
		path: String,
		topFrameSiteKey: String,
		hasCrossSiteAncestor: Bool,
		sourceScheme: Int32,
		sourcePort: Int32
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

/// ABI46. What `import_password_records` did.
public struct ChromiumPasswordRecordImport: Decodable, Equatable, Sendable {
	/// Read back from the store after the write.
	public var imported: [ChromiumPasswordKey]

	/// Written, but the request failed before the read-back proved them stored or
	/// absent. Also counted as skipped. Keep them for undo: it removes only
	/// entries that carry the import's stamp.
	public var unconfirmed: [ChromiumPasswordKey]

	/// Rows whose site and username were already saved; the saved password was kept.
	public var conflicts: Int
	public var skipped: Int

	public init(
		imported: [ChromiumPasswordKey],
		unconfirmed: [ChromiumPasswordKey] = [],
		conflicts: Int,
		skipped: Int
	) {
		self.imported = imported
		self.unconfirmed = unconfirmed
		self.conflicts = conflicts
		self.skipped = skipped
	}

	private enum CodingKeys: String, CodingKey {
		case imported, unconfirmed, conflicts, skipped
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.imported = try container.decode([ChromiumPasswordKey].self, forKey: .imported)
		self.unconfirmed = try container.decodeIfPresent([ChromiumPasswordKey].self, forKey: .unconfirmed) ?? []
		self.conflicts = try container.decode(Int.self, forKey: .conflicts)
		self.skipped = try container.decode(Int.self, forKey: .skipped)
	}
}

/// ABI46. What `import_cookies` did, every input cookie in exactly one list.
public struct ChromiumCookieImport: Decodable, Equatable, Sendable {
	public var accepted: [ChromiumCookieKey]

	/// The profile already had that cookie; it was kept.
	public var existing: [ChromiumCookieKey]
	public var rejected: [ChromiumCookieKey]

	/// Also in `rejected`: a set whose reply never came, which may be stored.
	/// Keep them for undo.
	public var unconfirmed: [ChromiumCookieKey]

	public init(
		accepted: [ChromiumCookieKey],
		existing: [ChromiumCookieKey],
		rejected: [ChromiumCookieKey],
		unconfirmed: [ChromiumCookieKey] = []
	) {
		self.accepted = accepted
		self.existing = existing
		self.rejected = rejected
		self.unconfirmed = unconfirmed
	}

	private enum CodingKeys: String, CodingKey {
		case accepted, existing, rejected, unconfirmed
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.accepted = try container.decode([ChromiumCookieKey].self, forKey: .accepted)
		self.existing = try container.decode([ChromiumCookieKey].self, forKey: .existing)
		self.rejected = try container.decode([ChromiumCookieKey].self, forKey: .rejected)
		self.unconfirmed = try container.decodeIfPresent([ChromiumCookieKey].self, forKey: .unconfirmed) ?? []
	}
}

public enum ChromiumCredentialImportFailure: Error, Equatable, Sendable {
	/// An engine without ABI46, or a private, unknown or stopped profile.
	case unavailable
	case invalid(reason: String?)

	/// Another credential import is running for that profile.
	case busy
	case failed(reason: String?)
}

/// Pending ABI46 credential import requests. Each native request replies once.
@MainActor
internal final class ChromiumCredentialImport {
	internal static let maximumPasswords: Int = 10_000
	internal static let maximumCookies: Int = 20_000

	/// The longest string sent to native. Longer rows are skipped or rejected here,
	/// so native never refuses a whole call over one row and every key fits in a
	/// keys argument on its own.
	internal static let maximumFieldBytes: Int = 256 * 1024

	private let api: ArxEngineAPI
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: CheckedContinuation<(ArxCredentialImportStatus, Data), any Error>] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool {
		api.import_password_records != nil
		&& api.import_cookies != nil
		&& api.check_cookies != nil
		&& api.undo_credential_import != nil
	}

	internal func importPasswords(
		profileKey: String,
		records: [ChromiumImportedPassword]
	) async throws(ChromiumCredentialImportFailure) -> ChromiumPasswordRecordImport {
		guard records.count <= Self.maximumPasswords else { throw .invalid(reason: "count") }

		// Native reads C strings, so a NUL inside a value would cut it short and
		// import something else. Such a row, or one with a field over
		// `maximumFieldBytes`, is skipped here and never sent.
		let unrepresentable = records.count { !Self.isRepresentable([$0.url, $0.signonRealm, $0.username, $0.password]) }
		let records = records.filter { Self.isRepresentable([$0.url, $0.signonRealm, $0.username, $0.password]) }
		let body = try await request(waitsForNative: true) { [api] id in
			let arena = Arena(strings: records.flatMap { [$0.url, $0.signonRealm, $0.username, $0.password] })
			arena.withPointers { strings in
				let natives = records.indices.map { index in
					ArxImportedPassword(
						url: strings[index * 4],
						signon_realm: strings[index * 4 + 1],
						username: strings[index * 4 + 2],
						password: strings[index * 4 + 3]
					)
				}
				profileKey.withCString { key in
					natives.withUnsafeBufferPointer {
						api.import_password_records?(id, key, $0.baseAddress, $0.count)
					}
				}
			}
		}
		var result = try Self.decode(ChromiumPasswordRecordImport.self, from: body)
		result.skipped += unrepresentable
		return result
	}

	internal func importCookies(
		profileKey: String,
		cookies: [ChromiumImportedCookie]
	) async throws(ChromiumCredentialImportFailure) -> ChromiumCookieImport {
		guard cookies.count <= Self.maximumCookies else { throw .invalid(reason: "count") }

		// As for passwords: a cookie with a NUL inside a string, or a field over
		// `maximumFieldBytes`, is rejected here.
		let unrepresentable = cookies
			.filter { !Self.isRepresentable([$0.domain, $0.name, $0.value, $0.path, $0.topFrameSiteKey]) }
			.map(Self.key)
		let cookies = cookies.filter { Self.isRepresentable([$0.domain, $0.name, $0.value, $0.path, $0.topFrameSiteKey]) }
		let body = try await request(waitsForNative: true) { [api] id in
			let arena = Arena(strings: cookies.flatMap { [$0.domain, $0.name, $0.value, $0.path, $0.topFrameSiteKey] })
			arena.withPointers { strings in
				let natives = cookies.indices.map { index in
					let cookie = cookies[index]
					return ArxImportedCookie(
						domain: strings[index * 5],
						name: strings[index * 5 + 1],
						value: strings[index * 5 + 2],
						path: strings[index * 5 + 3],
						top_frame_site_key: strings[index * 5 + 4],
						creation_utc: cookie.creationUTC,
						expires_utc: cookie.expiresUTC,
						last_access_utc: cookie.lastAccessUTC,
						secure: cookie.isSecure,
						http_only: cookie.isHTTPOnly,
						has_cross_site_ancestor: cookie.hasCrossSiteAncestor,
						same_site: cookie.sameSite,
						priority: cookie.priority,
						source_scheme: cookie.sourceScheme,
						source_port: cookie.sourcePort
					)
				}
				profileKey.withCString { key in
					natives.withUnsafeBufferPointer {
						api.import_cookies?(id, key, $0.baseAddress, $0.count)
					}
				}
			}
		}
		var result = try Self.decode(ChromiumCookieImport.self, from: body)
		result.rejected += unrepresentable
		return result
	}

	internal func checkCookies(
		profileKey: String,
		keys: [ChromiumCookieKey]
	) async throws(ChromiumCredentialImportFailure) -> Set<ChromiumCookieKey> {
		struct Present: Decodable {
			var present: [ChromiumCookieKey]
		}
		let json = try Self.encode(keys)
		let body = try await request { [api] id in
			profileKey.withCString { key in
				json.withCString { api.check_cookies?(id, key, $0) }
			}
		}
		return Set(try Self.decode(Present.self, from: body).present)
	}

	internal func undo(
		profileKey: String,
		passwords: [ChromiumPasswordKey],
		cookies: [ChromiumCookieKey]
	) async throws(ChromiumCredentialImportFailure) -> Int {
		struct Keys: Encodable {
			var passwords: [ChromiumPasswordKey]
			var cookies: [ChromiumCookieKey]
		}
		struct Removed: Decodable {
			var removed: Int
		}
		let json = try Self.encode(Keys(passwords: passwords, cookies: cookies))
		let body = try await request { [api] id in
			profileKey.withCString { key in
				json.withCString { api.undo_credential_import?(id, key, $0) }
			}
		}
		return try Self.decode(Removed.self, from: body).removed
	}

	internal func complete(
		_ id: UInt64,
		status: ArxCredentialImportStatus,
		json: UnsafePointer<UInt8>?,
		count: Int
	) {
		guard let continuation = requests.removeValue(forKey: id)
		else { return }

		if status == ARX_CREDENTIAL_IMPORT_CANCELLED {
			return continuation.resume(throwing: CancellationError())
		}
		let body = json.map { Data(bytes: $0, count: count) } ?? Data()
		continuation.resume(returning: (status, body))
	}

	internal func stop() {
		for id in Array(requests.keys) {
			requests.removeValue(forKey: id)?.resume(throwing: ChromiumCredentialImportFailure.unavailable)
		}
	}

	/// Replies OK's body. Native has no cancel. A read or undo whose task is
	/// cancelled stops waiting, and native's later reply is dropped; cancellation
	/// surfaces as `.unavailable`, which the cancelled caller never shows. An
	/// import (`waitsForNative`) that has reached native always waits for its
	/// reply, because only the reply names what to undo.
	private func request(
		waitsForNative: Bool = false,
		start: @escaping (UInt64) -> Void
	) async throws(ChromiumCredentialImportFailure) -> Data {
		guard isAvailable, requests.count < 16, nextRequest < UInt64.max
		else { throw .unavailable }

		let id = nextRequest
		nextRequest += 1
		let result: (ArxCredentialImportStatus, Data)
		do {
			result = try await withTaskCancellationHandler {
				try await withCheckedThrowingContinuation { continuation in
					guard !Task.isCancelled else {
						continuation.resume(throwing: CancellationError())
						return
					}

					requests[id] = continuation
					start(id)
				}
			} onCancel: {
				guard !waitsForNative else { return }

				Task { @MainActor [weak self] in
					self?.requests.removeValue(forKey: id)?.resume(throwing: CancellationError())
				}
			}
		} catch let failure as ChromiumCredentialImportFailure {
			throw failure
		} catch {
			throw .unavailable
		}
		guard result.0 == ARX_CREDENTIAL_IMPORT_OK
		else { throw Self.failure(result.0, body: result.1) }

		return result.1
	}

	private static func isRepresentable(_ strings: [String]) -> Bool {
		strings.allSatisfy { $0.utf8.count <= maximumFieldBytes && !$0.utf8.contains(0) }
	}

	/// The key native would report, with the ancestor bit cleared when unpartitioned.
	private static func key(_ cookie: ChromiumImportedCookie) -> ChromiumCookieKey {
		.init(
			domain: cookie.domain,
			name: cookie.name,
			path: cookie.path,
			topFrameSiteKey: cookie.topFrameSiteKey,
			hasCrossSiteAncestor: cookie.topFrameSiteKey.isEmpty ? false : cookie.hasCrossSiteAncestor,
			sourceScheme: cookie.sourceScheme,
			sourcePort: cookie.sourcePort
		)
	}

	private static func encode(_ value: some Encodable) throws(ChromiumCredentialImportFailure) -> String {
		guard
			let data = ChromiumReply.encode(value),
			let text = String(data: data, encoding: .utf8)
		else { throw .invalid(reason: "keys") }

		return text
	}

	private static func decode<Value: Decodable>(
		_ type: Value.Type,
		from body: Data
	) throws(ChromiumCredentialImportFailure) -> Value {
		guard let value = ChromiumReply.decode(type, from: body)
		else { throw .failed(reason: nil) }

		return value
	}

	internal static func failure(
		_ status: ArxCredentialImportStatus,
		body: Data
	) -> ChromiumCredentialImportFailure {
		let reason = ChromiumReply.failureReason(from: body)
		return switch status {
		case ARX_CREDENTIAL_IMPORT_INVALID: .invalid(reason: reason)
		case ARX_CREDENTIAL_IMPORT_BUSY: .busy
		case ARX_CREDENTIAL_IMPORT_FAILED: .failed(reason: reason)
		default: .unavailable
		}
	}
}

/// NUL-terminated UTF-8 copies of the strings in one allocation, lent to native
/// for one call and zeroed with `memset_s` (which the optimizer keeps) before
/// it's freed. The allocation is sized up front, so it never reallocates and
/// leaves no stray copy behind.
internal struct Arena: ~Copyable {
	private let buffer: UnsafeMutableBufferPointer<CChar>
	private let offsets: [Int]

	internal init(strings: [String]) {
		let total = strings.reduce(0) { $0 + $1.utf8.count + 1 }
		let buffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: max(total, 1))
		var offsets: [Int] = []
		offsets.reserveCapacity(strings.count)
		var position = 0
		for string in strings {
			offsets.append(position)
			for byte in string.utf8 {
				buffer[position] = CChar(bitPattern: byte)
				position += 1
			}
			buffer[position] = 0
			position += 1
		}
		self.buffer = buffer
		self.offsets = offsets
	}

	internal var count: Int { offsets.count }

	/// One pointer per string, valid only inside `body`.
	internal func withPointers<Result>(
		_ body: ([UnsafePointer<CChar>]) throws -> Result
	) rethrows -> Result {
		let base = UnsafePointer(buffer.baseAddress!)
		return try body(offsets.map { base + $0 })
	}

	deinit {
		_ = memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
		buffer.deallocate()
	}
}
