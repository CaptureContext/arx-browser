import BrowserCore
import Foundation
import _ComposableArchitecture

public struct AutomationSignInState: Equatable, Sendable {
	internal var records: [UUID: Record]
	internal var resumingLockID: UUID?
	internal var resumeTransitionID: UUID?

	/// Clients the user will keep when the lock ends. Not saved, so a lock that
	/// survives a restart starts with nobody selected.
	internal var keptClientIDs: Set<UUID>

	public init() {
		self.records = [:]
		self.resumingLockID = nil
		self.resumeTransitionID = nil
		self.keptClientIDs = []
	}

	/// Native identities stay in the app and are never exported as MCP authority.
	internal struct Record: Equatable, Sendable {
		internal var request: AutomationSignInRequest
		internal var clientID: UUID
		internal var sessionID: UUID
		internal var grantRevision: UUID
		internal var profileID: Profile.ID
		internal var tabID: BrowserCore.Tab.ID
		internal var nativePageID: UInt64
		internal var documentRevision: UInt64
		internal var sessionRevision: UInt64
		internal var status: AutomationSignInResult.Status
		internal var expiresAt: Date
		internal var lockID: UUID?

		internal init(
			request: AutomationSignInRequest,
			clientID: UUID,
			sessionID: UUID,
			grantRevision: UUID,
			profileID: Profile.ID,
			tabID: BrowserCore.Tab.ID,
			nativePageID: UInt64,
			documentRevision: UInt64,
			sessionRevision: UInt64,
			status: AutomationSignInResult.Status,
			expiresAt: Date,
			lockID: UUID? = nil
		) {
			self.request = request
			self.clientID = clientID
			self.sessionID = sessionID
			self.grantRevision = grantRevision
			self.profileID = profileID
			self.tabID = tabID
			self.nativePageID = nativePageID
			self.documentRevision = documentRevision
			self.sessionRevision = sessionRevision
			self.status = status
			self.expiresAt = expiresAt
			self.lockID = lockID
		}

		internal var isActive: Bool {
			switch status {
			case .approvalRequired, .securingPrivacy, .userActionRequired: true
			case .userConfirmed, .cancelled, .expired, .blocked: false
			}
		}
	}
}

@CasePathable
public enum AutomationSignInAction: Sendable {
	case ui(UI)
	case event(Event)
	case delegate(Delegate)
	case observation(ObservationAction<Observation>)

	@CasePathable
	public enum UI: Sendable {
		case approve(UUID)
		case confirm(UUID)
		case cancel(UUID)
		case keepClient(UUID, Bool)
		case resume
	}

	@CasePathable
	public enum Event: Sendable {
		case tick(UUID)
	}

	@CasePathable
	public enum Delegate: Sendable {}

	@CasePathable
	public enum Observation: Equatable, Sendable {}
}

extension AppFeature.State {
	internal var automationPrivacyIsLocked: Bool {
		automationPreferences.authenticationLockID != nil
		|| automation.signIn.resumingLockID != nil
	}

	/// The pending durable-resume interval remains closed at the service gate,
	/// even while the canonical preferences being written contain the clear.
	internal var automationHostPreferences: AutomationPreferences {
		var preferences = automationPreferences
		if let lock = automation.signIn.resumingLockID { preferences.authenticationLockID = lock }
		return preferences
	}
}
