import CloudKit
import Foundation
import _SQLiteData

/// An account event, as ``WorkspaceSync`` needs it.
public enum AccountChange: Equatable, Sendable {
	case signIn(String)
	case signOut
	case switchAccounts(String)
}

/// Each category engine's delegate. It never deletes local data: the library's default delegate
/// calls `deleteLocalData()` on sign-out and account switch, which the 4 November resolution rules
/// out. It hands account and quota events to ``WorkspaceSync``, which pauses and asks.
internal final class WorkspaceSyncDelegate: SyncEngineDelegate {
	private let category: SyncCategory
	private let onAccountChange: @Sendable (SyncCategory, AccountChange) async -> Void
	private let onQuotaExceeded: @Sendable (SyncCategory, Bool) async -> Void

	internal init(
		category: SyncCategory,
		onAccountChange: @escaping @Sendable (SyncCategory, AccountChange) async -> Void,
		onQuotaExceeded: @escaping @Sendable (SyncCategory, Bool) async -> Void
	) {
		self.category = category
		self.onAccountChange = onAccountChange
		self.onQuotaExceeded = onQuotaExceeded
	}

	internal func syncEngine(
		_ syncEngine: SyncEngine,
		accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
	) async {
		await onAccountChange(category, AccountChange(changeType))
	}

	internal func syncEngine(
		_ syncEngine: SyncEngine,
		quotaExceeded: Bool,
		scope: CKDatabase.Scope
	) {
		// Arx only uses the private database; a shared database's quota is someone else's.
		guard scope == .private else { return }

		let category: SyncCategory = category
		let onQuotaExceeded = onQuotaExceeded
		Task { await onQuotaExceeded(category, quotaExceeded) }
	}
}

extension AccountChange {
	internal init(_ changeType: CKSyncEngine.Event.AccountChange.ChangeType) {
		switch changeType {
		case let .signIn(currentUser):
			self = .signIn(currentUser.recordName)

		case .signOut:
			self = .signOut

		case let .switchAccounts(_, currentUser):
			self = .switchAccounts(currentUser.recordName)

		@unknown default:
			// An unknown kind of change is treated as a switch to an unknown account: pause and ask.
			self = .switchAccounts("")
		}
	}
}

/// The device directory's engine delegate (DEV-979). It hands account events to ``WorkspaceSync``
/// as the category engines' delegates do: with every category paused, the directory may be the only
/// engine that hears of a switch. Nothing is deleted here on a sign-out or an account switch either.
internal final class DeviceDirectoryDelegate: SyncEngineDelegate {
	private let onAccountChange: @Sendable (AccountChange) async -> Void

	internal init(onAccountChange: @escaping @Sendable (AccountChange) async -> Void) {
		self.onAccountChange = onAccountChange
	}

	internal func syncEngine(
		_ syncEngine: SyncEngine,
		accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
	) async {
		await onAccountChange(AccountChange(changeType))
	}

	internal func syncEngine(
		_ syncEngine: SyncEngine,
		quotaExceeded: Bool,
		scope: CKDatabase.Scope
	) {}
}
