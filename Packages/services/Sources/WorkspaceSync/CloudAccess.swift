import CloudKit
import Foundation
import WorkspaceDatabase

/// What ``WorkspaceSync`` asks CloudKit directly, outside the sync engines: the signed-in account
/// and deleting a category's zone. Tests replace it; the live value makes its `CKContainer` only
/// when first called, so nothing reaches CloudKit until sync is used.
public struct CloudAccess: Sendable {
	public enum Account: Equatable, Sendable {
		/// Signed in, with the account's user record name.
		case available(String)
		case noAccount

		/// Restricted, temporarily unavailable, or unknown.
		case unavailable
	}

	public var account: @Sendable () async throws -> Account
	public var deleteZone: @Sendable (_ zoneName: String) async throws -> Void

	/// Yields when the device's iCloud account may have changed. A stopped engine reports no account
	/// events, so this is how sync notices a sign-in after it paused for a sign-out.
	public var accountChanges: @Sendable () -> AsyncStream<Void>

	/// Where iCloud has these folders and pinned tabs of the organization zone. Throws when it can't
	/// tell, such as offline, so nothing is repaired on a guess.
	public var placements: @Sendable (
		_ records: Set<WorkspaceRepair.PlacementRecord>
	) async throws -> [WorkspaceRepair.PlacementRecord: WorkspaceRepair.Placement]

	/// The fields of these records in the zone, as text (numbers as their digits), keyed by record
	/// name; a record iCloud doesn't have is left out. Throws when iCloud can't say.
	public var recordValues: @Sendable (
		_ zoneName: String,
		_ recordNames: [String]
	) async throws -> [String: [String: String]]

	/// Every record in the zone, with only the fields named, read from iCloud rather than what this
	/// Mac fetched, so a record a fetch hasn't brought yet counts too. Throws when iCloud can't say,
	/// or can't read one of them.
	public var zoneRecords: @Sendable (
		_ zoneName: String,
		_ fields: [String]
	) async throws -> [ZoneRecord]

	/// A record's name (SQLiteData's: the lowercased ID and the table), type (the table) and the
	/// fields asked for, as text.
	public struct ZoneRecord: Equatable, Sendable {
		public var name: String
		public var type: String
		public var fields: [String: String]

		public init(
			name: String,
			type: String,
			fields: [String: String]
		) {
			self.name = name
			self.type = type
			self.fields = fields
		}

		/// The row's ID, from the record name.
		public var id: UUID? {
			name.split(separator: ":").first.flatMap { UUID(uuidString: String($0)) }
		}
	}

	public init(
		account: @escaping @Sendable () async throws -> Account,
		deleteZone: @escaping @Sendable (_ zoneName: String) async throws -> Void,
		accountChanges: @escaping @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } },
		placements: @escaping @Sendable (
			_ records: Set<WorkspaceRepair.PlacementRecord>
		) async throws -> [WorkspaceRepair.PlacementRecord: WorkspaceRepair.Placement],
		recordValues: @escaping @Sendable (
			_ zoneName: String,
			_ recordNames: [String]
		) async throws -> [String: [String: String]],
		zoneRecords: @escaping @Sendable (
			_ zoneName: String,
			_ fields: [String]
		) async throws -> [ZoneRecord] = { _, _ in throw CKError(.operationCancelled) }
	) {
		self.account = account
		self.deleteZone = deleteZone
		self.accountChanges = accountChanges
		self.placements = placements
		self.recordValues = recordValues
		self.zoneRecords = zoneRecords
	}

	/// The private database of `containerIdentifier`.
	public static func live(containerIdentifier: String) -> Self {
		.init(
			account: {
				let container: CKContainer = .init(identifier: containerIdentifier)
				switch try await container.accountStatus() {
				case .available:
					return .available(try await container.userRecordID().recordName)
				case .noAccount:
					return .noAccount
				case .restricted, .couldNotDetermine, .temporarilyUnavailable:
					return .unavailable
				@unknown default:
					return .unavailable
				}
			},
			deleteZone: { zoneName in
				let container: CKContainer = .init(identifier: containerIdentifier)
				do {
					_ = try await container.privateCloudDatabase.deleteRecordZone(
						withID: CKRecordZone.ID(zoneName: zoneName)
					)
				} catch let error as CKError where error.code == .zoneNotFound {
					// Already gone, as another Mac may have deleted it: done.
				}
			},
			accountChanges: {
				AsyncStream { continuation in
					let task: Task<Void, Never> = Task {
						for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
							continuation.yield()
						}
						continuation.finish()
					}
					continuation.onTermination = { _ in task.cancel() }
				}
			},
			placements: { records in
				let container: CKContainer = .init(identifier: containerIdentifier)
				let zoneID: CKRecordZone.ID = .init(zoneName: SyncCategory.organization.zoneName)
				let ids: [CKRecord.ID: WorkspaceRepair.PlacementRecord] = .init(
					uniqueKeysWithValues: records.map { (CKRecord.ID(recordName: $0.recordName, zoneID: zoneID), $0) }
				)

				// CloudKit limits how many records one request fetches.
				let recordIDs: [CKRecord.ID] = Array(ids.keys)
				var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
				for start in stride(from: 0, to: recordIDs.count, by: 200) {
					let batch: [CKRecord.ID] = Array(recordIDs[start ..< min(start + 200, recordIDs.count)])
					results.merge(
						try await container.privateCloudDatabase.records(
							for: batch,
							desiredKeys: ["spaceID", "parentFolderID", "folderID"]
						),
						uniquingKeysWith: { first, _ in first }
					)
				}
				var placements: [WorkspaceRepair.PlacementRecord: WorkspaceRepair.Placement] = [:]
				for (recordID, result) in results {
					guard let record = ids[recordID] else { continue }

					switch result {
					case let .success(ckRecord):
						placements[record] = record.placement(of: ckRecord)
					case let .failure(error as CKError) where error.code == .unknownItem:
						placements[record] = .missing
					case let .failure(error):
						throw error
					}
				}
				return placements
			},
			recordValues: { zoneName, recordNames in
				let container: CKContainer = .init(identifier: containerIdentifier)
				let zoneID: CKRecordZone.ID = .init(zoneName: zoneName)
				let recordIDs: [CKRecord.ID] = recordNames.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
				var values: [String: [String: String]] = [:]
				for start in stride(from: 0, to: recordIDs.count, by: 200) {
					let batch: [CKRecord.ID] = Array(recordIDs[start ..< min(start + 200, recordIDs.count)])
					for (recordID, result) in try await container.privateCloudDatabase.records(for: batch) {
						switch result {
						case let .success(record):
							values[recordID.recordName] = record.textValues()
						case let .failure(error as CKError) where error.code == .unknownItem:
							continue
						case let .failure(error):
							throw error
						}
					}
				}
				return values
			},
			zoneRecords: { zoneName, fields in
				let container: CKContainer = .init(identifier: containerIdentifier)
				let zoneID: CKRecordZone.ID = .init(zoneName: zoneName)

				// Every change since the zone began: what's there now, with only these fields.
				var token: CKServerChangeToken?
				var records: [String: ZoneRecord] = [:]
				var moreComing: Bool = true
				while moreComing {
					let changes = try await container.privateCloudDatabase.recordZoneChanges(
						inZoneWith: zoneID,
						since: token,
						desiredKeys: fields
					)
					for (recordID, result) in changes.modificationResultsByID {
						// A record that can't be read could be the one that matters: nothing is decided.
						let record: CKRecord = try result.get().record
						records[recordID.recordName] = .init(
							name: recordID.recordName,
							type: record.recordType,
							fields: record.textValues()
						)
					}
					for deletion in changes.deletions {
						records[deletion.recordID.recordName] = nil
					}
					token = changes.changeToken
					moreComing = changes.moreComing
				}
				return Array(records.values)
			}
		)
	}
}

extension WorkspaceRepair.PlacementRecord {
	/// SQLiteData's record name: the lowercased ID and the table.
	public var recordName: String {
		switch self {
		case let .folder(id): "\(id.uuidString.lowercased()):\(FolderRecord.tableName)"
		case let .pinnedTab(id): "\(id.uuidString.lowercased()):\(PinnedTabRecord.tableName)"
		case let .favorite(id): "\(id.uuidString.lowercased()):\(FavoriteRecord.tableName)"
		}
	}

	/// Where a fetched record of this folder or pinned tab is. SQLiteData writes every column to the
	/// record's encrypted values, IDs as text.
	public func placement(of record: CKRecord) -> WorkspaceRepair.Placement {
		func uuid(_ key: String) -> UUID? {
			(record.encryptedValues[key] as? String).flatMap(UUID.init(uuidString:))
		}

		switch self {
		case .folder: return .placed(spaceID: uuid("spaceID"), parentID: uuid("parentFolderID"))
		case .pinnedTab: return .placed(spaceID: uuid("spaceID"), parentID: uuid("folderID"))
		case .favorite: return .placed(spaceID: nil, parentID: nil)
		}
	}
}

extension CKRecord {
	/// The record's encrypted fields as text, as SQLiteData writes them: strings as they are, numbers
	/// as their digits.
	public func textValues() -> [String: String] {
		var values: [String: String] = [:]
		for key in encryptedValues.allKeys() {
			switch encryptedValues[key] {
			case let text as String: values[key] = text
			case let number as NSNumber: values[key] = number.stringValue
			case let number as Int64: values[key] = String(number)
			case let number as Int: values[key] = String(number)
			default: continue
			}
		}
		return values
	}
}

extension WorkspaceRepair.PurgeSnapshot {
	/// The fields a purge decision reads, as ``CloudAccess/zoneRecords`` asks for them.
	public static let fields: [String] = [
		"profileID", "spaceID", "parentFolderID", "folderID",
		"itemID", "itemTable", "deviceID", "deletedAt", "keepsElsewhere", "lastUsed", "lastSeen",
	]

	/// iCloud's rows, from the whole zone, whose `itemTables` hide on deletion.
	public init(
		_ records: [CloudAccess.ZoneRecord],
		itemTables: Set<String> = LocalDeletion.itemTables
	) {
		self.init()
		self.itemTables = itemTables
		for record in records {
			guard let id = record.id else { continue }

			func uuid(_ key: String) -> UUID? { record.fields[key].flatMap(UUID.init(uuidString:)) }
			func time(_ key: String) -> Double? { record.fields[key].flatMap(Double.init) }

			switch record.type {
			case DeletionRecord.tableName:
				guard
					let itemID = uuid("itemID"),
					let table = record.fields["itemTable"],
					let deviceID = uuid("deviceID"),
					let deletedAt = time("deletedAt")
				else { continue }

				deletions.append(.init(
					itemID: itemID,
					itemTable: table,
					deviceID: deviceID,
					deletedAt: deletedAt,
					keepsElsewhere: record.fields["keepsElsewhere"].flatMap(Int.init).map { $0 != 0 } ?? false
				))

			case ArchiveDeletionRecord.tableName:
				guard let itemID = uuid("itemID"), let deviceID = uuid("deviceID"), let deletedAt = time("deletedAt")
				else { continue }

				deletions.append(.init(itemID: itemID, itemTable: ArchiveEntryRecord.tableName, deviceID: deviceID, deletedAt: deletedAt))

			case ArchiveDeviceRecord.tableName:
				guard let lastSeen = time("lastSeen") else { continue }

				sightings[id] = max(sightings[id] ?? 0, lastSeen)

			case UsageRecord.tableName:
				guard let itemID = uuid("itemID"), let deviceID = uuid("deviceID"), let lastUsed = time("lastUsed")
				else { continue }

				use(itemID, by: deviceID, at: lastUsed)

			case SyncDeviceRecord.tableName:
				guard let lastSeen = time("lastSeen") else { continue }

				sightings[id] = max(sightings[id] ?? 0, lastSeen)

			case ProfileRecord.tableName, ArchiveEntryRecord.tableName:
				items[record.type, default: []].insert(id)

			case SpaceRecord.tableName, FavoriteRecord.tableName:
				items[record.type, default: []].insert(id)
				parents[id] = Set([uuid("profileID")].compactMap(\.self))

			case FolderRecord.tableName:
				items[record.type, default: []].insert(id)
				parents[id] = Set([uuid("spaceID"), uuid("parentFolderID")].compactMap(\.self))

			case PinnedTabRecord.tableName:
				items[record.type, default: []].insert(id)
				parents[id] = Set([uuid("spaceID"), uuid("folderID")].compactMap(\.self))

			default:
				continue
			}
		}
	}
}
