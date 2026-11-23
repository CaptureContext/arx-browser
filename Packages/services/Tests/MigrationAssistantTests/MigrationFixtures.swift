import BrowserCore
import Foundation
import MigrationAssistant
import _TestSupport

/// An in-memory destination that applies batches through the production mapping
/// and records the idempotence ledger in the same write.
internal final class FixtureDestination: Sendable {
	internal let organization: LockIsolated<BrowserOrganization>
	internal let ledger: LockIsolated<MigrationLedger> = .init(.init())
	internal let commits: LockIsolated<[MigrationBatch]> = .init([])

	/// History the app would write to each profile's history store.
	internal let history: LockIsolated<[Profile.ID: [BrowsingHistoryEntry]]> = .init([:])

	/// Categories whose next commits fail, consumed one per attempt.
	internal let failures: LockIsolated<[MigrationCategory: Int]> = .init([:])
	internal let nextID: LockIsolated<Int> = .init(100)

	internal init(_ organization: BrowserOrganization = MigrationFixtures.organization()) {
		self.organization = .init(organization)
	}

	internal var writer: MigrationDestinationWriter {
		.init(
			state: { .init(organization: self.organization.value, ledger: self.ledger.value) },
			commit: { batch in try self.commit(batch) }
		)
	}

	private func commit(_ batch: MigrationBatch) throws {
		let shouldFail = failures.withValue { failures -> Bool in
			guard let remaining = failures[batch.category], remaining > 0 else { return false }
			failures[batch.category] = remaining - 1
			return true
		}
		if shouldFail { throw FixtureError.diskFull }

		var updatedLedger = ledger.value
		let updated = try organization.value.applyingMigration(batch, ledger: &updatedLedger) {
			nextID.withValue { value in
				value += 1
				return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
			}
		}
		organization.setValue(updated)
		let committed = updatedLedger
		ledger.setValue(committed)
		history.withValue { history in
			for (profileID, entries) in updated.migrationHistory(batch, ledger: committed) {
				history[profileID, default: []] += entries
			}
		}
		commits.withValue { $0.append(batch) }
	}
}

internal enum FixtureError: Error, LocalizedError {
	case diskFull
	case unreadable

	internal var errorDescription: String? {
		switch self {
		case .diskFull: "The disk is full."
		case .unreadable: "The source file is unreadable."
		}
	}
}

internal enum MigrationFixtures {
	internal static let sourceID: MigrationSource.ID = .init(rawValue: "fixture:default")
	internal static let profileID: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
	internal static let spaceID: Space.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
	internal static let existingTabID: BrowserCore.Tab.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
	internal static let destination: MigrationDestination = .init(profileID: profileID, spaceID: spaceID)

	internal static let source: MigrationSource = .init(
		id: sourceID,
		kind: .externalBrowser,
		name: "Fixture Browser",
		version: "1.0",
		categories: [.bookmarks, .openTabs]
	)

	internal static let records: [MigrationRecord] = [
		.init(sourceItemID: "b1", category: .bookmarks, title: "Swift", url: "https://swift.org", folderPath: ["Dev"]),
		.init(sourceItemID: "b2", category: .bookmarks, title: "", url: "https://developer.apple.com", folderPath: ["Dev", "Apple"]),
		.init(sourceItemID: "b3", category: .bookmarks, title: "Existing", url: "https://capturecontext.dev"),
		.init(sourceItemID: "b4", category: .bookmarks, title: "Script", url: "javascript:alert(1)"),
		.init(sourceItemID: "b1", category: .bookmarks, title: "Repeated", url: "https://swift.org/repeated"),
		.init(sourceItemID: "t1", category: .openTabs, title: "News", url: "https://news.example.org"),
		.init(sourceItemID: "t2", category: .openTabs, title: "Swift again", url: "https://swift.org"),
		.init(sourceItemID: "t3", category: .openTabs, title: "Broken", url: "not a url"),
	]

	internal static func adapter(
		snapshotID: LockIsolated<String> = .init("snapshot-1"),
		records: [MigrationRecord] = MigrationFixtures.records,
		reads: LockIsolated<Int> = .init(0),
		fails: Bool = false
	) -> MigrationSourceAdapter {
		.init(source: source) {
			reads.withValue { $0 += 1 }
			if fails { throw FixtureError.unreadable }
			return .init(id: snapshotID.value, records: records)
		}
	}

	internal static func organization() -> BrowserOrganization {
		.init(
			profiles: [.init(id: profileID, name: "Default")],
			spaces: [.init(
				id: spaceID,
				profileID: profileID,
				name: "Home",
				unpinnedTabs: [existingTabID],
				selectedTabID: existingTabID
			)],
			tabs: [.init(
				id: existingTabID,
				profileID: profileID,
				restoration: .init(title: "Example", url: URL(string: "https://capturecontext.dev")!)
			)]
		)
	}

	internal static func key(
		_ category: MigrationCategory,
		_ id: String
	) -> MigrationItemKey {
		.init(sourceID: sourceID, category: category, sourceItemID: id)
	}
}
