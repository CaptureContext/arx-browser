import Foundation
import GRDB
import _SQLiteData

/// Notices transactions in which a sync engine changed a category's synced tables: a batch fetched
/// from iCloud, a deleted zone, or an account reset. ``WorkspaceSync`` runs the repair pass after
/// each one and tells the app the rows changed.
///
/// The library has no hook inside its write, so the repair runs in its own transaction right after
/// the batch commits, not in the same one as ADR 0001 section 6 says. The difference is a moment in
/// which another reader can see the unrepaired rows; the result is the same.
internal final class SyncBatchObserver: TransactionObserver, @unchecked Sendable {
	private let tables: Set<String>
	private let onCommit: @Sendable () -> Void

	/// Only touched on the writer's queue, where GRDB calls every method.
	private var sawSyncChange: Bool = false

	internal init(
		tables: Set<String>,
		onCommit: @escaping @Sendable () -> Void
	) {
		self.tables = tables
		self.onCommit = onCommit
	}

	internal func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
		tables.contains(eventKind.tableName)
	}

	internal func databaseDidChange(with event: DatabaseEvent) {
		// The library writes fetched records with its task-local "synchronizing" flag set; edits made
		// on this Mac, the repair pass's included, don't have it.
		guard SyncEngine.isSynchronizing else { return }

		sawSyncChange = true
		stopObservingDatabaseChangesUntilNextTransaction()
	}

	internal func databaseDidCommit(_ db: Database) {
		guard sawSyncChange else { return }

		sawSyncChange = false
		onCommit()
	}

	internal func databaseDidRollback(_ db: Database) {
		sawSyncChange = false
	}
}
