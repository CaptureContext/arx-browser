import Foundation

/// Asks Arx to sign in to the tab's site with a password saved in the tab's
/// own profile (DEV-708). Arx fills and submits it inside the engine; the
/// agent never receives the password, the account name or a code.
///
/// The request binds an explicit tab, its inventory revision and the exact
/// top-level origin the agent expects. `frameID` names the frame holding the
/// sign-in form, from a snapshot node's `frame`; nil is the main frame.
public struct AutomationPasswordSignInRequest: Codable, Equatable, Sendable {
	public var operationID: UUID
	public var targetID: UUID
	public var expectedRevision: String
	public var origin: String
	public var frameID: String?

	public init(
		operationID: UUID,
		targetID: UUID,
		expectedRevision: String,
		origin: String,
		frameID: String? = nil
	) {
		self.operationID = operationID
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.origin = origin
		self.frameID = frameID
	}

	public func validate() throws {
		guard
			expectedRevision.utf8.count == 64,
			expectedRevision.allSatisfy(\.isHexDigit),
			AutomationSignInRequest.canonicalOrigin(origin) == origin,
			frameID.map(Self.isFrameID) ?? true
		else { throw AutomationFailure.invalidRequest }
	}

	private static func isFrameID(_ value: String) -> Bool {
		!value.isEmpty
		&& value.utf8.count <= 64
		&& value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
	}
}

/// Deliberately contains no URL, account, field, password, code or token.
public struct AutomationPasswordSignInResult: Codable, Equatable, Sendable {
	public var operationID: UUID
	public var outcome: Outcome
	public var reason: Reason

	public init(
		operationID: UUID,
		outcome: Outcome,
		reason: Reason
	) {
		self.operationID = operationID
		self.outcome = outcome
		self.reason = reason
	}

	public enum Outcome: String, Codable, Sendable {
		/// Arx filled and submitted the form, and the page no longer asks for a password.
		case signedIn

		/// Only the user can go on: a code, a passkey, a reauthentication, an approval
		/// or a choice of account. Hand off with `browser_sign_in`.
		case needsUser
		case failed
	}

	public enum Reason: String, Codable, Sendable {
		case signedIn

		/// The page asks for a one-time code.
		case twoFactor

		/// macOS asks the user to confirm before filling.
		case reauthentication

		/// Nobody approved it, or the user declined.
		case approval

		/// More than one account is saved and nobody chose one.
		case chooseAccount

		/// No password is saved in this profile for this exact origin.
		case noSavedPassword

		/// The page shows no sign-in form Arx can fill.
		case noForm

		/// The site still asks for a password after submitting.
		case rejected

		/// The form wasn't in the frame the request named.
		case frame

		/// The page navigated or its frame changed before submitting.
		case navigation
		case submit
		case timedOut
		case unsupported
	}
}

/// A site where agents may sign in with a saved password without asking, in one profile.
public struct AgentSignInSite: Codable, Equatable, Hashable, Sendable {
	public var profileID: Profile.ID

	/// An exact origin, as `AutomationSignInRequest.canonicalOrigin` writes it.
	public var origin: String

	public init(
		profileID: Profile.ID,
		origin: String
	) {
		self.profileID = profileID
		self.origin = origin
	}
}

extension AutomationOperation {
	/// Tabs whose page this operation reads, captures or acts in. A tab whose
	/// document holds a filled password that didn't sign in is closed to them.
	public var pageTargets: [UUID] {
		switch self {
		case let .capture(request): [request.targetID]
		case let .inspect(request): [request.targetID]
		case let .wait(request): [request.targetID]
		case let .pdf(request): [request.targetID]
		case let .findInPage(request): [request.targetID]
		case let .dialog(request): [request.targetID]
		case let .script(request): [request.targetID]
		case let .click(request): [request.targetID]
		case let .form(request): [request.target.targetID]
		case let .scroll(request): [request.target.targetID]
		case let .batch(plan): plan.steps.flatMap(\.pageTargets)
		case .inventory, .command, .signIn, .data, .link, .load, .media, .settings, .logs, .passwordSignIn: []
		}
	}
}
