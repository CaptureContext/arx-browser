import ChromiumBridge
import Foundation

/// ABI35. A password saved in the page's own profile for exactly the page's origin.
/// It names an account; it never carries the password.
public struct ChromiumSavedCredential: Decodable, Equatable, Sendable {
	public var id: UInt32
	public var username: String

	/// A sign-in form for it is on the page now.
	public var hasForm: Bool

	public init(
		id: UInt32,
		username: String,
		hasForm: Bool
	) {
		self.id = id
		self.username = username
		self.hasForm = hasForm
	}

	private enum CodingKeys: String, CodingKey {
		case id, username
		case hasForm = "form"
	}
}

/// The credentials listed for one main-frame document. `document` binds a
/// sign-in attempt to that document; a navigation makes it stale.
public struct ChromiumSignInCredentials: Decodable, Equatable, Sendable {
	public var document: String
	public var origin: String
	public var credentials: [ChromiumSavedCredential]

	public init(
		document: String,
		origin: String,
		credentials: [ChromiumSavedCredential]
	) {
		self.document = document
		self.origin = origin
		self.credentials = credentials
	}
}

/// What a sign-in attempt ended with. Never a password, code or token.
public struct ChromiumSignInResult: Equatable, Sendable {
	public enum Outcome: Equatable, Sendable {
		/// The form was filled and submitted, and the page no longer asks for a password.
		case signedIn

		/// A one-time code, a device reauthentication or another step only the user can do.
		case needsUser
		case failed
	}

	public var outcome: Outcome

	/// Native's short, fixed reason: `signedIn`, `twoFactor`, `reauthentication`,
	/// `rejected`, `noForm`, `credential`, `frame`, `submit`, `notAllowed`, `unsupported`...
	public var reason: String

	/// A saved value went into the page.
	public var filled: Bool

	/// The page still shows a password field, so its value could be revealed.
	public var passwordVisible: Bool

	public init(
		outcome: Outcome,
		reason: String,
		filled: Bool,
		passwordVisible: Bool
	) {
		self.outcome = outcome
		self.reason = reason
		self.filled = filled
		self.passwordVisible = passwordVisible
	}
}

public enum ChromiumSignInFailure: Error, Equatable, Sendable {
	case unavailable

	/// The listed document or the bound frame changed; nothing was submitted.
	case staleDocument(filled: Bool)
	case busy
	case invalidRequest
	case timedOut(filled: Bool)
}

/// A page's submitted sign-in form that the user can save to the page's profile.
public struct ChromiumPasswordSaveOffer: Equatable, Sendable {
	public var page: UInt64
	public var token: UInt64
	public var origin: String

	/// Shown to the user so they know which account; may be empty.
	public var username: String

	/// The site's saved password changed, rather than a new one.
	public var isUpdate: Bool

	public init(
		page: UInt64,
		token: UInt64,
		origin: String,
		username: String,
		isUpdate: Bool
	) {
		self.page = page
		self.token = token
		self.origin = origin
		self.username = username
		self.isUpdate = isUpdate
	}
}

public enum ChromiumPasswordSaveAnswer: Sendable {
	case save

	/// Never for this site (for an update: keep the old password).
	case never
	case notNow

	internal var native: ArxPasswordSaveAnswer {
		switch self {
		case .save: ARX_PASSWORD_SAVE
		case .never: ARX_PASSWORD_NEVER
		case .notNow: ARX_PASSWORD_NOT_NOW
		}
	}
}

/// Pending sign-in requests and save offers. Each native request replies once.
@MainActor
internal final class ChromiumPasswords {
	private let api: ArxEngineAPI
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: Request] = [:]
	private var observers: [UUID: AsyncStream<ChromiumPasswordSaveOffer>.Continuation] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool {
		api.answer_password_save != nil
		&& api.sign_in_credentials != nil
		&& api.sign_in_attempt != nil
		&& api.cancel_sign_in != nil
	}

	internal func offers() -> AsyncStream<ChromiumPasswordSaveOffer> {
		let token = UUID()
		let (stream, continuation) = AsyncStream<ChromiumPasswordSaveOffer>.makeStream()
		observers[token] = continuation
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in self?.observers[token] = nil }
		}
		return stream
	}

	internal func offered(_ offer: ChromiumPasswordSaveOffer) {
		for continuation in observers.values { continuation.yield(offer) }
	}

	internal func answer(
		page: UInt64,
		token: UInt64,
		answer: ChromiumPasswordSaveAnswer
	) -> Bool {
		api.answer_password_save?(page, token, answer.native) ?? false
	}

	internal func credentials(page: UInt64) async throws -> ChromiumSignInCredentials {
		let (status, body) = try await request(page: page) { [api] id in
			guard let read = api.sign_in_credentials else { return false }
			read(page, id)
			return true
		}
		guard status == ARX_SIGN_IN_OK
		else { throw Self.failure(status, body: body) }
		guard let credentials = ChromiumReply.decode(ChromiumSignInCredentials.self, from: body)
		else { throw ChromiumSignInFailure.unavailable }

		return credentials
	}

	internal func attempt(
		page: UInt64,
		document: String,
		frame: String?,
		credential: UInt32,
		timeoutMilliseconds: Int
	) async throws -> ChromiumSignInResult {
		guard
			Self.isToken(document),
			frame.map(Self.isToken) ?? true,
			(5_000...60_000).contains(timeoutMilliseconds)
		else { throw ChromiumSignInFailure.invalidRequest }

		let (status, body) = try await request(page: page) { [api] id in
			guard let attempt = api.sign_in_attempt else { return false }
			document.withCString { document in
				if let frame {
					frame.withCString { attempt(page, id, document, $0, credential, UInt32(timeoutMilliseconds)) }
				} else {
					attempt(page, id, document, nil, credential, UInt32(timeoutMilliseconds))
				}
			}
			return true
		}
		let reply = Self.reply(body)
		switch status {
		case ARX_SIGN_IN_SIGNED_IN:
			return .init(
				outcome: .signedIn,
				reason: reply.reason,
				filled: reply.filled,
				passwordVisible: reply.passwordVisible
			)

		case ARX_SIGN_IN_NEEDS_USER:
			return .init(
				outcome: .needsUser,
				reason: reply.reason,
				filled: reply.filled,
				passwordVisible: reply.passwordVisible
			)

		case ARX_SIGN_IN_FAILED:
			return .init(
				outcome: .failed,
				reason: reply.reason,
				filled: reply.filled,
				passwordVisible: reply.passwordVisible
			)

		default:
			throw Self.failure(status, body: body)
		}
	}

	internal func complete(
		_ id: UInt64,
		page: UInt64,
		status: ArxSignInStatus,
		json: UnsafePointer<UInt8>?,
		count: Int
	) {
		guard let request = requests.removeValue(forKey: id)
		else { return }

		guard request.page == page
		else { return request.continuation.resume(throwing: ChromiumSignInFailure.staleDocument(filled: false)) }

		if status == ARX_SIGN_IN_CANCELLED {
			return request.continuation.resume(throwing: CancellationError())
		}
		let body = json.map { Data(bytes: $0, count: count) } ?? Data()
		request.continuation.resume(returning: (status, body))
	}

	internal func remove(page: UInt64) {
		for id in requests.keys.filter({ requests[$0]?.page == page }) {
			cancel(id, failure: ChromiumSignInFailure.staleDocument(filled: false))
		}
	}

	internal func stop() {
		for id in Array(requests.keys) {
			cancel(id, failure: ChromiumSignInFailure.unavailable)
		}
		for continuation in observers.values { continuation.finish() }
		observers.removeAll()
	}

	private func request(
		page: UInt64,
		start: @escaping (UInt64) -> Bool
	) async throws -> (ArxSignInStatus, Data) {
		try Task.checkCancellation()
		guard isAvailable, requests.count < 8, nextRequest < UInt64.max
		else { throw ChromiumSignInFailure.unavailable }

		let id = nextRequest
		nextRequest += 1
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				guard !Task.isCancelled else {
					continuation.resume(throwing: CancellationError())
					return
				}

				requests[id] = .init(page: page, continuation: continuation)
				if !start(id) {
					requests.removeValue(forKey: id)?.continuation.resume(throwing: ChromiumSignInFailure.unavailable)
				}
			}
		} onCancel: {
			Task { @MainActor [weak self] in self?.cancel(id) }
		}
	}

	private func cancel(
		_ id: UInt64,
		failure: any Error = CancellationError()
	) {
		guard let request = requests.removeValue(forKey: id)
		else { return }

		api.cancel_sign_in?(id)
		request.continuation.resume(throwing: failure)
	}

	private static func isToken(_ value: String) -> Bool {
		!value.isEmpty && value.utf8.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
	}

	private struct Reply {
		internal var reason: String
		internal var filled: Bool
		internal var passwordVisible: Bool

		internal init(
			reason: String,
			filled: Bool,
			passwordVisible: Bool
		) {
			self.reason = reason
			self.filled = filled
			self.passwordVisible = passwordVisible
		}
	}

	private static func reply(_ body: Data) -> Reply {
		struct Native: Decodable {
			var reason: String?
			var filled: Bool?
			var passwordVisible: Bool?
		}

		// Optional detail: a failure may come without a reason or fill state.
		let native = try? JSONDecoder().decode(Native.self, from: body)
		return .init(
			reason: native?.reason ?? "unknown",
			filled: native?.filled ?? false,
			// Unknown means it may still be there.
			passwordVisible: native?.passwordVisible ?? true
		)
	}

	internal static func failure(
		_ status: ArxSignInStatus,
		body: Data
	) -> ChromiumSignInFailure {
		let filled = reply(body).filled
		return switch status {
		case ARX_SIGN_IN_STALE: .staleDocument(filled: filled)
		case ARX_SIGN_IN_BUSY: .busy
		case ARX_SIGN_IN_INVALID: .invalidRequest
		case ARX_SIGN_IN_TIMEOUT: .timedOut(filled: filled)
		default: .unavailable
		}
	}

	private struct Request {
		internal let page: UInt64
		internal let continuation: CheckedContinuation<(ArxSignInStatus, Data), any Error>

		internal init(
			page: UInt64,
			continuation: CheckedContinuation<(ArxSignInStatus, Data), any Error>
		) {
			self.page = page
			self.continuation = continuation
		}
	}
}
