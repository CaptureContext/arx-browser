import BrowserCore
import Foundation

/// Reads one source.
///
/// An adapter must leave source data unchanged. It reads exported files or
/// copy-on-read copies of individual files it needs and never copies, locks or
/// opens another browser's live profile directory as an Arx profile.
public struct MigrationSourceAdapter: Sendable {
	public var source: MigrationSource
	public var snapshot: @Sendable () async throws -> MigrationSnapshot

	public init(
		source: MigrationSource,
		snapshot: @escaping @Sendable () async throws -> MigrationSnapshot
	) {
		self.source = source
		self.snapshot = snapshot
	}
}

/// One category's validated items, committed as a single transaction.
public struct MigrationBatch: Equatable, Sendable {
	public var planID: MigrationPlan.ID
	public var destination: MigrationDestination
	public var sourceName: String
	public var category: MigrationCategory
	public var items: [MigrationItem]

	/// Set when this batch is the preferences category, with the key to record.
	public var preferences: MigrationPortablePreferences?
	public var preferencesKey: MigrationItemKey?

	public init(
		planID: MigrationPlan.ID,
		destination: MigrationDestination,
		sourceName: String,
		category: MigrationCategory,
		items: [MigrationItem],
		preferences: MigrationPortablePreferences? = nil,
		preferencesKey: MigrationItemKey? = nil
	) {
		self.planID = planID
		self.destination = destination
		self.sourceName = sourceName
		self.category = category
		self.items = items
		self.preferences = preferences
		self.preferencesKey = preferencesKey
	}
}

public struct MigrationDestinationState: Equatable, Sendable {
	public var organization: BrowserOrganization
	public var ledger: MigrationLedger

	public init(
		organization: BrowserOrganization,
		ledger: MigrationLedger
	) {
		self.organization = organization
		self.ledger = ledger
	}
}

/// The destination side of an import.
///
/// `commit` applies the whole batch and records its keys in the destination's
/// idempotence ledger in the same write, or throws having changed nothing.
public struct MigrationDestinationWriter: Sendable {
	/// The current organization and ledger, read together so they agree.
	public var state: @Sendable () async throws -> MigrationDestinationState
	public var commit: @Sendable (MigrationBatch) async throws -> Void

	public init(
		state: @escaping @Sendable () async throws -> MigrationDestinationState,
		commit: @escaping @Sendable (MigrationBatch) async throws -> Void
	) {
		self.state = state
		self.commit = commit
	}
}
