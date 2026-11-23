import Foundation

/// Requests user participation, never a credential or a reusable provider handle.
///
/// `begin` binds one explicit loaded tab, its inventory revision and the exact
/// top-level origin. `status` and `cancel` carry only the opaque operation ID;
/// the app binds them to the original client, connection and grant revision.
public struct AutomationSignInRequest: Codable, Equatable, Sendable {
	public var operationID: UUID
	public var action: Action
	public var targetID: UUID?
	public var expectedRevision: String?
	public var origin: String?

	public init(
		operationID: UUID,
		action: Action,
		targetID: UUID? = nil,
		expectedRevision: String? = nil,
		origin: String? = nil
	) {
		self.operationID = operationID
		self.action = action
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.origin = origin
	}

	public func validate() throws {
		switch action {
		case .begin:
			guard
				targetID != nil,
				let expectedRevision,
				expectedRevision.utf8.count == 64,
				expectedRevision.allSatisfy(\.isHexDigit),
				let origin,
				Self.canonicalOrigin(origin) == origin
			else { throw AutomationFailure.invalidRequest }

		case .status, .cancel:
			guard targetID == nil, expectedRevision == nil, origin == nil
			else { throw AutomationFailure.invalidRequest }
		}
	}

	/// An exact `https` origin, or an `http` loopback origin with an explicit port.
	/// Credentials, paths, queries, fragments, escapes and numeric host aliases are rejected.
	public static func canonicalOrigin(_ value: String) -> String? {
		guard
			value.utf8.count <= 512,
			!value.contains("%"),
			let parts = URLComponents(string: value),
			let host = parts.host,
			!host.isEmpty,
			parts.user == nil,
			parts.password == nil,
			parts.query == nil,
			parts.fragment == nil,
			parts.path.isEmpty || parts.path == "/"
		else { return nil }

		switch parts.scheme {
		case "https":
			guard parts.port == nil || parts.port == 443
			else { return nil }

		case "http":
			guard
				["127.0.0.1", "localhost"].contains(host),
				(1...65_535).contains(parts.port ?? 0)
			else { return nil }

		default:
			return nil
		}

		var origin: URLComponents = .init()
		origin.scheme = parts.scheme
		origin.host = host.lowercased()
		if parts.scheme == "http" { origin.port = parts.port }
		return origin.string
	}

	public enum Action: String, Codable, Sendable {
		case begin
		case status
		case cancel
	}
}

/// Deliberately contains no URL, title, account, field, token or provider data.
public struct AutomationSignInResult: Codable, Equatable, Sendable {
	public var operationID: UUID
	public var status: Status

	public init(
		operationID: UUID,
		status: Status
	) {
		self.operationID = operationID
		self.status = status
	}

	public enum Status: String, Codable, Sendable {
		/// The user has not yet approved pausing every assistant.
		case approvalRequired

		/// The privacy lock is active but not yet durably stored.
		case securingPrivacy

		/// Every assistant is paused; the user is completing sign-in.
		case userActionRequired

		/// A trusted user assertion; Arx has not verified website authentication.
		case userConfirmed
		case cancelled
		case expired

		/// An earlier page action has no confirmed completion; sensitive input is refused.
		case blocked
	}
}

extension AutomationOperation {
	/// The only operations a client may perform while the sign-in privacy lock is active.
	public var isSignInStatusOrCancel: Bool {
		guard case let .signIn(request) = self
		else { return false }

		return request.action != .begin
	}
}
