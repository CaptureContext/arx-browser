import AppKit
import ChromiumBridge

/// ABI36. A password saved in an ordinary profile, as Settings lists it: a site
/// and a username. The password stays in Chromium.
public struct ChromiumSavedPassword: Decodable, Equatable, Sendable {
	public var id: UInt32

	/// The host the password was saved for.
	public var site: String
	public var origin: String
	public var username: String

	public init(
		id: UInt32,
		site: String,
		origin: String,
		username: String
	) {
		self.id = id
		self.site = site
		self.origin = origin
		self.username = username
	}
}

/// ABI36. A site the user chose never to save a password for.
public struct ChromiumBlockedPasswordSite: Decodable, Equatable, Sendable {
	public var id: UInt32
	public var site: String
	public var origin: String

	public init(
		id: UInt32,
		site: String,
		origin: String
	) {
		self.id = id
		self.site = site
		self.origin = origin
	}
}

/// ABI36. One profile's saved passwords and "never saved" sites. IDs belong to
/// `listing`; a newer listing makes them stale.
public struct ChromiumSavedPasswordList: Decodable, Equatable, Sendable {
	public var listing: String
	public var passwords: [ChromiumSavedPassword]
	public var blocked: [ChromiumBlockedPasswordSite]

	public init(
		listing: String,
		passwords: [ChromiumSavedPassword],
		blocked: [ChromiumBlockedPasswordSite]
	) {
		self.listing = listing
		self.passwords = passwords
		self.blocked = blocked
	}
}

/// ABI36. What a CSV import did. Rows name a site and a username, never a password.
public struct ChromiumPasswordImport: Decodable, Equatable, Sendable {
	public struct Row: Decodable, Equatable, Sendable {
		public var site: String
		public var username: String

		/// Why a row was skipped: `missingPassword`, `missingURL`, `invalidURL`, `tooLong` or `unknown`.
		public var reason: String?

		public init(
			site: String,
			username: String,
			reason: String? = nil
		) {
			self.site = site
			self.username = username
			self.reason = reason
		}
	}

	public var imported: Int

	/// Rows whose site and username were already saved; the saved password was kept.
	public var conflicts: [Row]
	public var conflictCount: Int
	public var skipped: [Row]
	public var skippedCount: Int

	public init(
		imported: Int,
		conflicts: [Row],
		conflictCount: Int,
		skipped: [Row],
		skippedCount: Int
	) {
		self.imported = imported
		self.conflicts = conflicts
		self.conflictCount = conflictCount
		self.skipped = skipped
		self.skippedCount = skippedCount
	}
}

public enum ChromiumSavedPasswordFailure: Error, Equatable, Sendable {
	/// No password manager in this engine, or a private, unknown or stopped profile.
	case unavailable
	case invalid(reason: String?)

	/// The listing changed since it was shown.
	case stale
	case notFound

	/// The site already has a password saved for that username.
	case exists

	/// The device owner didn't authenticate.
	case denied
	case busy
	case failed(reason: String?)
}

public enum ChromiumPasswordReveal {
	/// Onto the general pasteboard, concealed, cleared after 60 seconds unless it changed.
	case copy

	/// Into the field. It must stay in a window until the reveal finishes.
	case show(NSTextField)
}

/// Pending saved-password requests. Each native request replies once.
@MainActor
internal final class ChromiumSavedPasswords {
	private let api: ArxEngineAPI
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: CheckedContinuation<(ArxSavedPasswordsStatus, Data), any Error>] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool {
		api.list_saved_passwords != nil
		&& api.save_saved_password != nil
		&& api.remove_saved_password != nil
		&& api.reveal_saved_password != nil
		&& api.import_saved_passwords != nil
		&& api.cancel_saved_passwords != nil
	}

	internal func list(profileKey: String) async throws(ChromiumSavedPasswordFailure) -> ChromiumSavedPasswordList {
		let body = try await request { [api] id in
			profileKey.withCString { api.list_saved_passwords?(id, $0) }
		}
		return try Self.listing(body)
	}

	internal func save(
		profileKey: String,
		listing: String?,
		credential: UInt32,
		url: String?,
		username: String,
		passwordField: NSTextField?
	) async throws(ChromiumSavedPasswordFailure) -> ChromiumSavedPasswordList {
		guard credential == 0 ? (url?.isEmpty == false) : listing.map(Self.isToken) == true
		else { throw .invalid(reason: nil) }

		let field = passwordField.map { Unmanaged.passUnretained($0).toOpaque() }
		let body = try await request { [api] id in
			profileKey.withCString { key in
				(listing ?? "").withCString { listing in
					(url ?? "").withCString { url in
						username.withCString { username in
							api.save_saved_password?(id, key, listing, credential, url, username, field)
						}
					}
				}
			}
		}
		return try Self.listing(body)
	}

	internal func remove(
		profileKey: String,
		listing: String,
		credential: UInt32
	) async throws(ChromiumSavedPasswordFailure) -> ChromiumSavedPasswordList {
		guard Self.isToken(listing), credential != 0
		else { throw .invalid(reason: nil) }

		let body = try await request { [api] id in
			profileKey.withCString { key in
				listing.withCString { api.remove_saved_password?(id, key, $0, credential) }
			}
		}
		return try Self.listing(body)
	}

	internal func reveal(
		profileKey: String,
		listing: String,
		credential: UInt32,
		reason: String,
		mode: ChromiumPasswordReveal
	) async throws(ChromiumSavedPasswordFailure) {
		guard Self.isToken(listing), credential != 0, !reason.isEmpty
		else { throw .invalid(reason: nil) }

		let native: ArxPasswordReveal
		let field: UnsafeMutableRawPointer?
		switch mode {
		case .copy:
			native = ARX_PASSWORD_REVEAL_COPY
			field = nil
		case let .show(target):
			native = ARX_PASSWORD_REVEAL_SHOW
			field = Unmanaged.passUnretained(target).toOpaque()
		}
		_ = try await request { [api] id in
			profileKey.withCString { key in
				listing.withCString { listing in
					reason.withCString { api.reveal_saved_password?(id, key, listing, credential, native, $0, field) }
				}
			}
		}
	}

	internal func importPasswords(
		profileKey: String,
		file: URL
	) async throws(ChromiumSavedPasswordFailure) -> ChromiumPasswordImport {
		guard file.isFileURL, file.path.hasPrefix("/")
		else { throw .invalid(reason: nil) }

		let body = try await request { [api] id in
			profileKey.withCString { key in
				file.path.withCString { api.import_saved_passwords?(id, key, $0) }
			}
		}
		guard let summary = ChromiumReply.decode(ChromiumPasswordImport.self, from: body)
		else { throw .failed(reason: nil) }

		return summary
	}

	internal func complete(
		_ id: UInt64,
		status: ArxSavedPasswordsStatus,
		json: UnsafePointer<UInt8>?,
		count: Int
	) {
		guard let continuation = requests.removeValue(forKey: id)
		else { return }

		if status == ARX_SAVED_PASSWORDS_CANCELLED {
			return continuation.resume(throwing: CancellationError())
		}
		let body = json.map { Data(bytes: $0, count: count) } ?? Data()
		continuation.resume(returning: (status, body))
	}

	internal func stop() {
		for id in Array(requests.keys) {
			requests.removeValue(forKey: id)?.resume(throwing: ChromiumSavedPasswordFailure.unavailable)
		}
	}

	/// Replies OK's body. Cancellation rethrows as `CancellationError` through `Task`.
	private func request(
		start: @escaping (UInt64) -> Void
	) async throws(ChromiumSavedPasswordFailure) -> Data {
		guard isAvailable, requests.count < 16, nextRequest < UInt64.max
		else { throw .unavailable }

		let id = nextRequest
		nextRequest += 1
		let result: (ArxSavedPasswordsStatus, Data)
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
				Task { @MainActor [weak self] in self?.cancel(id) }
			}
		} catch let failure as ChromiumSavedPasswordFailure {
			throw failure
		} catch {
			// Cancelled: the caller's task is cancelled, so this is never shown.
			throw .unavailable
		}
		guard result.0 == ARX_SAVED_PASSWORDS_OK
		else { throw Self.failure(result.0, body: result.1) }

		return result.1
	}

	private func cancel(_ id: UInt64) {
		guard requests[id] != nil
		else { return }

		api.cancel_saved_passwords?(id)
		requests.removeValue(forKey: id)?.resume(throwing: CancellationError())
	}

	private static func listing(_ body: Data) throws(ChromiumSavedPasswordFailure) -> ChromiumSavedPasswordList {
		guard let list = ChromiumReply.decode(ChromiumSavedPasswordList.self, from: body)
		else { throw .failed(reason: nil) }

		return list
	}

	private static func isToken(_ value: String) -> Bool {
		!value.isEmpty && value.utf8.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
	}

	internal static func failure(
		_ status: ArxSavedPasswordsStatus,
		body: Data
	) -> ChromiumSavedPasswordFailure {
		let reason = ChromiumReply.failureReason(from: body)
		return switch status {
		case ARX_SAVED_PASSWORDS_INVALID: .invalid(reason: reason)
		case ARX_SAVED_PASSWORDS_STALE: .stale
		case ARX_SAVED_PASSWORDS_NOT_FOUND: .notFound
		case ARX_SAVED_PASSWORDS_EXISTS: .exists
		case ARX_SAVED_PASSWORDS_DENIED: .denied
		case ARX_SAVED_PASSWORDS_BUSY: .busy
		case ARX_SAVED_PASSWORDS_FAILED: .failed(reason: reason)
		default: .unavailable
		}
	}
}
