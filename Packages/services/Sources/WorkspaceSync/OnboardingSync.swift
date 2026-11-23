import Foundation

/// What onboarding's "Sync with iCloud" hears while sync turns on and fetches for the first time
/// (DEV-1215, ``WorkspaceSync/joinFromOnboarding()``).
public enum OnboardingSyncEvent: Equatable, Sendable {
	/// The category's first fetch started.
	case fetching(SyncCategory)

	/// Every category that's on fetched once and its repair pass ran: what iCloud had.
	case finished(OnboardingSyncResult)

	/// No iCloud account, or it can't be reached now: nothing was fetched.
	case unavailable

	/// Sync couldn't turn on or a fetch failed; the text is for the person to read.
	case failed(String)

	/// Sync is off, and this join wasn't asked to turn it on: the person turned it off meanwhile.
	case turnedOff
}

/// What iCloud had once onboarding's first fetch landed.
public struct OnboardingSyncResult: Equatable, Sendable {
	/// iCloud has a workspace: at least one synced profile with a space.
	public var hasWorkspace: Bool

	/// The space any Mac used last, from the synced `usage` rows (DEV-980), when it's still there.
	public var lastUsedSpaceID: UUID?

	public init(
		hasWorkspace: Bool,
		lastUsedSpaceID: UUID? = nil
	) {
		self.hasWorkspace = hasWorkspace
		self.lastUsedSpaceID = lastUsedSpaceID
	}
}
