import BrowserCore
import Foundation

/// An account saved in the tab's own profile for exactly the tab's origin
/// (DEV-708). The password stays in the engine.
public struct BrowserSavedAccount: Equatable, Identifiable, Sendable {
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
}

/// The accounts listed for one document of a tab. `document` binds a sign-in
/// to that document; a navigation makes it stale.
public struct BrowserSavedAccounts: Equatable, Sendable {
	public var document: String
	public var origin: String
	public var accounts: [BrowserSavedAccount]

	public init(
		document: String,
		origin: String,
		accounts: [BrowserSavedAccount]
	) {
		self.document = document
		self.origin = origin
		self.accounts = accounts
	}
}

/// How a password sign-in ended. Never a password, code or token.
public struct BrowserPasswordSignInResult: Equatable, Sendable {
	public var outcome: AutomationPasswordSignInResult.Outcome
	public var reason: AutomationPasswordSignInResult.Reason

	/// A saved value went into the page.
	public var filled: Bool

	/// The page still shows a password field after the attempt.
	public var passwordVisible: Bool

	public init(
		outcome: AutomationPasswordSignInResult.Outcome,
		reason: AutomationPasswordSignInResult.Reason,
		filled: Bool,
		passwordVisible: Bool
	) {
		self.outcome = outcome
		self.reason = reason
		self.filled = filled
		self.passwordVisible = passwordVisible
	}
}

public enum BrowserPasswordFailure: Error, Equatable, Sendable {
	/// No password manager in this engine, or a private page.
	case unavailable

	/// The tab navigated or its bound frame changed; nothing was submitted.
	case stale(filled: Bool)
	case busy
	case invalid
	case timedOut(filled: Bool)

	/// The final authorization failed.
	case denied
}

/// A submitted sign-in form the user can save to the tab's profile.
public struct BrowserPasswordSaveOffer: Equatable, Sendable {
	public var tabID: Tab.ID
	public var token: UInt64
	public var origin: String

	/// Shown so the user knows which account; may be empty.
	public var username: String
	public var isUpdate: Bool

	public init(
		tabID: Tab.ID,
		token: UInt64,
		origin: String,
		username: String,
		isUpdate: Bool
	) {
		self.tabID = tabID
		self.token = token
		self.origin = origin
		self.username = username
		self.isUpdate = isUpdate
	}
}

public enum BrowserPasswordSaveAnswer: Equatable, Sendable {
	case save

	/// Never for this site (for an update: keep the old password).
	case never
	case notNow
}

extension BrowserEngineClient {
	public typealias SavedAccounts = @MainActor @Sendable (
		Tab.ID
	) async throws(BrowserPasswordFailure) -> BrowserSavedAccounts

	public typealias SignInWithPassword = @MainActor @Sendable (
		Tab.ID,
		_ document: String,
		_ frame: String?,
		_ account: UInt32,
		@escaping @MainActor @Sendable () -> Bool
	) async throws(BrowserPasswordFailure) -> BrowserPasswordSignInResult
}
