import CloudKit
import ConcurrencyExtras
import Foundation
@testable import SQLiteData
import Testing
import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

/// Turning one category off as a leave (DEV-1148): the Mac stops counting for that category's
/// purges once its engine went quiet and the device directory says so, keeps its rows, and turning
/// the category on again merges them with iCloud's, bringing back what was purged without it.
@Suite(.dependency(\.uuid, .incrementing), .timeLimit(.minutes(1)))
struct CategoryLeaveTests {
	private let profileID: UUID = UUID(1)
	private let keptSpaceID: UUID = UUID(2)
	private let deletedSpaceID: UUID = UUID(3)
	private let entryID: UUID = UUID(4)

	private func seed(_ mac: TestMac) throws {
		try edit(mac.organization) { db in
			try db.seed {
				ProfileRecord(id: profileID, name: "Personal", position: "V")
				SpaceRecord(id: keptSpaceID, profileID: profileID, name: "Kept", position: "V")
				SpaceRecord(id: deletedSpaceID, profileID: profileID, name: "Deleted", position: "W")
			}
		}
	}

	private func deviceID(_ mac: TestMac) throws -> UUID {
		try mac.organization.write { db in try LocalDeletion.deviceID(db) }
	}

	private func devices(_ mac: TestMac) throws -> [UUID: DeviceDirectoryRecord] {
		try mac.devices.read { db in
			Dictionary(uniqueKeysWithValues: try DeviceDirectoryRecord.all.fetchAll(db).map { ($0.id, $0) })
		}
	}

	private func spaces(_ mac: TestMac) throws -> Set<UUID> {
		try mac.organization.read { db in Set(try SpaceRecord.all.fetchAll(db).map(\.id)) }
	}

	/// This Mac's deletion of a space, as the store's diff writer records it (DEV-980).
	private func delete(_ spaceID: UUID, on mac: TestMac) throws {
		let device: UUID = try deviceID(mac)
		try edit(mac.organization) { db in
			try DeletionRecord.insert {
				DeletionRecord(
					id: LocalDeletion.rowID(item: spaceID, table: SpaceRecord.tableName, device: device),
					itemID: spaceID,
					itemTable: SpaceRecord.tableName,
					deviceID: device,
					deletedAt: Date().timeIntervalSince1970
				)
			}
			.execute(db)
		}
	}

	/// Two Macs syncing the same workspace, with Tab Archive on when `archive`.
	private func twoMacs(
		_ cloud: TestCloud,
		archive: Bool = false
	) async throws -> (TestMac, TestMac) {
		let a: TestMac = try .init(cloud: cloud, syncsArchive: archive, name: "Mac A")
		let b: TestMac = try .init(cloud: cloud, syncsArchive: archive, name: "Mac B")
		try seed(a)
		for mac in [a, b] {
			await mac.sync.setEnabled(true)
			if archive {
				await mac.sync.setCategory(.archive, isEnabled: true)
			}
		}
		try await converge(a, b)
		return (a, b)
	}

	/// Waits up to a few seconds for `condition`, which the account retry makes true.
	private func wait(
		for condition: @Sendable () async throws -> Bool
	) async throws {
		let clock: ContinuousClock = .init()
		let deadline: ContinuousClock.Instant = clock.now.advanced(by: .seconds(10))
		while try await !condition() {
			try #require(clock.now < deadline, "The account retry never made it true")
			try await Task.sleep(for: .milliseconds(20))
		}
	}

	/// B purges `spaceIDs`, which only B deleted (and A, before it left, for those A deleted): A is
	/// out of the organization's purges. The purge's deletions are sent, and no Mac fetches them yet.
	private func purge(
		_ spaceIDs: [UUID],
		on b: TestMac
	) async throws {
		// B hears of A's leave first: the directory fetches after the categories.
		try await b.fetch()
		for spaceID in spaceIDs {
			try delete(spaceID, on: b)
		}
		try await b.send()
		try await b.sync.repair(.organization)
		try await b.send()
	}

	@Test
	func turningACategoryOffLeavesIt() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		let aID: UUID = try deviceID(a)

		await a.sync.setCategory(.organization, isEnabled: false)
		let settings: SyncSettings = await a.sync.currentSettings
		#expect(settings.leftCategories == [.organization])
		#expect(settings.unpublishedLeaves.isEmpty)
		#expect(await a.sync.engine(.organization)?.isRunning != true)

		try await b.fetch()
		let aRow: DeviceDirectoryRecord = try #require(try devices(b)[aID])
		#expect(DeviceDirectory.leftCategories(aRow) == [.organization])
		let departed: (Set<UUID>, Set<UUID>) = try await b.devices.read { db in
			(
				try DeviceDirectory.departedDevices(db, from: .organization),
				try DeviceDirectory.departedDevices(db, from: .preferences)
			)
		}
		#expect(departed.0 == [aID])
		#expect(departed.1.isEmpty)
		await b.sync.refreshStatus()
		#expect(await b.sync.status.devices(syncing: .organization).map(\.name) == ["Mac B"])

		// Preferences still pauses until its own rejoin is built.
		await a.sync.setCategory(.preferences, isEnabled: false)
		#expect(await a.sync.currentSettings.leftCategories == [.organization])

		// Back on, A counts again once iCloud has its row.
		await a.sync.setCategory(.organization, isEnabled: true)
		let back: SyncSettings = await a.sync.currentSettings
		#expect(back.leftCategories.isEmpty)
		#expect(back.pendingMerges.isEmpty)
		#expect(await a.sync.engine(.organization)?.isRunning == true)
		try await b.fetch()
		#expect(try devices(b)[aID].map(DeviceDirectory.leftCategories) == [])
	}

	@Test
	func aCategoryThisMacNeverSyncedIsntLeft() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud, syncsArchive: true)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		await a.sync.setCategory(.archive, isEnabled: false)
		#expect(await a.sync.currentSettings.leftCategories.isEmpty)
	}

	/// What every other Mac deleted goes for good while this Mac is out, and comes back from this
	/// Mac when it rejoins; what this Mac deleted too stays gone.
	@Test
	func aRejoinBringsBackWhatWasPurgedWithoutThisMac() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		try delete(deletedSpaceID, on: a)
		try await a.send()
		await a.sync.setCategory(.organization, isEnabled: false)

		try await purge([keptSpaceID, deletedSpaceID], on: b)
		#expect(try spaces(b).isDisjoint(with: [keptSpaceID, deletedSpaceID]))
		// A keeps both while it's out.
		#expect(try spaces(a).isSuperset(of: [keptSpaceID, deletedSpaceID]))

		await a.sync.setCategory(.organization, isEnabled: true)
		#expect(await a.sync.currentSettings.pendingMerges.isEmpty)
		#expect(try spaces(a).contains(keptSpaceID))
		#expect(try !spaces(a).contains(deletedSpaceID))

		try await converge(a, b)
		#expect(try spaces(b).contains(keptSpaceID))
		#expect(try !spaces(b).contains(deletedSpaceID))
		// The copy the merge read is gone.
		let copies: URL = a.directory.appendingPathComponent(WorkspaceSync.keptCopyDirectoryName)
		#expect((try? FileManager.default.contentsOfDirectory(atPath: copies.path))?.isEmpty ?? true)
	}

	/// Edits made on both sides while this Mac was out merge as any sync does, by their own times:
	/// nothing this Mac kept unchanged goes back over a newer value.
	@Test
	func aRejoinKeepsNewerEditsFromEitherSide() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		await a.sync.setCategory(.organization, isEnabled: false)

		try edit(a.organization) { db in
			try SpaceRecord.find(deletedSpaceID).update { $0.name = "Renamed on A" }.execute(db)
		}
		try edit(b.organization) { db in
			try SpaceRecord.find(keptSpaceID).update { $0.name = "Renamed on B" }.execute(db)
		}
		try await b.send()

		await a.sync.setCategory(.organization, isEnabled: true)
		try await converge(a, b)
		for mac in [a, b] {
			let names: [UUID: String] = try await mac.organization.read { db in
				Dictionary(uniqueKeysWithValues: try SpaceRecord.all.fetchAll(db).map { ($0.id, $0.name) })
			}
			#expect(names[keptSpaceID] == "Renamed on B")
			#expect(names[deletedSpaceID] == "Renamed on A")
		}
	}

	@Test
	func aLeaveWaitsForTheAccountToReachTheOthers() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		let aID: UUID = try deviceID(a)

		a.directorySendFails.setValue(true)
		await a.sync.setCategory(.organization, isEnabled: false)
		#expect(await a.sync.currentSettings.unpublishedLeaves == [.organization])
		try await b.fetch()
		#expect(try devices(b)[aID].map(DeviceDirectory.leftCategories) == [])

		// The account retry sends it once the connection is back.
		a.directorySendFails.setValue(false)
		try await wait { await a.sync.currentSettings.unpublishedLeaves.isEmpty }
		#expect(await a.sync.currentSettings.unpublishedLeaves.isEmpty)
		try await b.fetch()
		#expect(try devices(b)[aID].map(DeviceDirectory.leftCategories) == [.organization])
	}

	/// A stop and the rejoin after it keep a category left: it's still off, so this Mac stays out of
	/// its purges.
	@Test
	func aStopAndItsRejoinKeepACategoryLeft() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		let aID: UUID = try deviceID(a)
		await a.sync.setCategory(.organization, isEnabled: false)

		await a.sync.stopSyncingThisMac()
		try await b.fetch()
		let stopped: DeviceDirectoryRecord = try #require(try devices(b)[aID])
		#expect(stopped.stoppedAt != nil)
		#expect(DeviceDirectory.leftCategories(stopped) == [.organization])

		await a.sync.setEnabled(true)
		#expect(await a.sync.engine(.organization)?.isRunning != true)
		#expect(await a.sync.engine(.preferences)?.isRunning == true)
		try await b.fetch()
		let rejoined: DeviceDirectoryRecord = try #require(try devices(b)[aID])
		#expect(rejoined.stoppedAt == nil)
		#expect(DeviceDirectory.leftCategories(rejoined) == [.organization])
		let departed: Set<UUID> = try await b.devices.read { db in try DeviceDirectory.departedDevices(db, from: .organization) }
		#expect(departed == [aID])
	}

	/// Over quota, CloudKit refuses the row and sending still succeeds: the leave stays unsent.
	@Test
	func aLeaveRefusedOverQuotaIsSentLater() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		let aID: UUID = try deviceID(a)

		cloud.container.privateCloudDatabase.state.withValue { $0.quota = 0 }
		await a.sync.setCategory(.organization, isEnabled: false)
		#expect(await a.sync.currentSettings.unpublishedLeaves == [.organization])

		cloud.container.privateCloudDatabase.state.withValue { $0.quota = .max }
		try await wait { await a.sync.currentSettings.unpublishedLeaves.isEmpty }
		#expect(await a.sync.currentSettings.unpublishedLeaves.isEmpty)
		try await b.fetch()
		#expect(try devices(b)[aID].map(DeviceDirectory.leftCategories) == [.organization])
	}

	/// Until iCloud has the rejoin, the other Macs still leave this Mac out: the category waits.
	@Test
	func aRejoinWaitsUntilICloudHasIt() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		let aID: UUID = try deviceID(a)
		await a.sync.setCategory(.organization, isEnabled: false)

		a.directorySendFails.setValue(true)
		await a.sync.setCategory(.organization, isEnabled: true)
		#expect(await a.sync.currentSettings.pendingMerges == [.organization])
		#expect(await a.sync.engine(.organization)?.isRunning != true)
		try await b.fetch()
		#expect(try devices(b)[aID].map(DeviceDirectory.leftCategories) == [.organization])

		a.directorySendFails.setValue(false)
		try await wait { await a.sync.currentSettings.pendingMerges.isEmpty }
		#expect(await a.sync.engine(.organization)?.isRunning == true)
		try await b.fetch()
		#expect(try devices(b)[aID].map(DeviceDirectory.leftCategories) == [])
	}

	/// A rejoin whose fetch applied the purge and then failed, as when the connection drops: what it
	/// deleted comes back at once, and the rejoin finishes with the account retry.
	@Test
	func aRejoinWhoseFetchFailsKeepsWhatWasPurged() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		await a.sync.setCategory(.organization, isEnabled: false)
		try await purge([keptSpaceID], on: b)

		a.rejoinFetchFails.setValue(true)
		await a.sync.setCategory(.organization, isEnabled: true)

		// The account retry keeps trying meanwhile.
		#expect(await a.sync.currentSettings.pendingMerges == [.organization])
		#expect(try spaces(a).contains(keptSpaceID))

		a.rejoinFetchFails.setValue(false)
		try await wait { await a.sync.currentSettings.pendingMerges.isEmpty }
		#expect(await a.sync.currentSettings.pendingMerges.isEmpty)
		#expect(await a.sync.engine(.organization)?.isRunning == true)
		try await converge(a, b)
		#expect(try spaces(b).contains(keptSpaceID))
	}

	/// Turning the category off again before a rejoin's merge settles it: what its fetch deleted comes
	/// back, and its copy goes, so the next rejoin copies this Mac's rows as they are then.
	@Test
	func turningOffBeforeTheMergeSettlesIt() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		await a.sync.setCategory(.organization, isEnabled: false)
		try await purge([keptSpaceID], on: b)

		a.rejoinFetchHangs.setValue(true)
		let rejoining: Task<Void, Never> = Task { await a.sync.setCategory(.organization, isEnabled: true) }
		try await wait { try !spaces(a).contains(keptSpaceID) }
		await a.sync.setCategory(.organization, isEnabled: false)
		a.rejoinFetchHangs.setValue(false)
		await rejoining.value

		let copies: URL = a.directory.appendingPathComponent(WorkspaceSync.keptCopyDirectoryName)
		#expect((try? FileManager.default.contentsOfDirectory(atPath: copies.path))?.isEmpty ?? true)
		#expect(try spaces(a).contains(keptSpaceID))
		#expect(await a.sync.currentSettings.pendingMerges == [.organization])
		try edit(a.organization) { db in
			try SpaceRecord.find(keptSpaceID).update { $0.name = "Renamed while out" }.execute(db)
		}

		await a.sync.setCategory(.organization, isEnabled: true)
		#expect(await a.sync.currentSettings.pendingMerges.isEmpty)
		try await converge(a, b)
		let name: String? = try await b.organization.read { db in try SpaceRecord.find(keptSpaceID).fetchOne(db)?.name }
		#expect(name == "Renamed while out")
	}

	/// A rejoin whose fetch applied the purge when Arx quit: the next launch merges from the copy taken
	/// before the engine ran, which still has what the purge deleted.
	@Test
	func aRejoinCutShortByQuittingMergesAtTheNextLaunch() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		await a.sync.setCategory(.organization, isEnabled: false)
		try await purge([keptSpaceID], on: b)

		a.rejoinFetchHangs.setValue(true)
		let quitting: Task<Void, Never> = Task { await a.sync.setCategory(.organization, isEnabled: true) }
		try await wait { try !spaces(a).contains(keptSpaceID) }
		#expect(try !spaces(a).contains(keptSpaceID))
		#expect(try SyncSettingsStore(directory: a.directory).load().pendingMerges == [.organization])

		// The next launch reads the same files. This run never gets further, though work it started
		// before can still hold a database for a moment.
		let relaunched: LockIsolated<TestMac?> = .init(nil)
		try await wait {
			relaunched.setValue(try? TestMac(cloud: cloud, directory: a.directory, name: "Mac A"))
			return relaunched.value != nil
		}
		let next: TestMac = try #require(relaunched.value)
		await next.sync.launch()
		#expect(await next.sync.currentSettings.pendingMerges.isEmpty)
		#expect(try spaces(next).contains(keptSpaceID))
		try await converge(next, b)
		#expect(try spaces(b).contains(keptSpaceID))

		// The run that quit ends without retrying.
		a.accountFails.setValue(true)
		a.rejoinFetchFails.setValue(true)
		a.rejoinFetchHangs.setValue(false)
		await quitting.value
	}

	/// Sync turned off while a rejoin's fetch applies a purge: what it deleted comes back at once, and
	/// the rejoin finishes when sync is on again.
	@Test
	func turningSyncOffDuringARejoinSettlesIt() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		await a.sync.setCategory(.organization, isEnabled: false)
		try await purge([keptSpaceID], on: b)

		a.rejoinFetchHangs.setValue(true)
		let rejoining: Task<Void, Never> = Task { await a.sync.setCategory(.organization, isEnabled: true) }
		try await wait { try !spaces(a).contains(keptSpaceID) }
		await a.sync.setEnabled(false)
		a.rejoinFetchHangs.setValue(false)
		await rejoining.value

		#expect(try spaces(a).contains(keptSpaceID))
		#expect(await a.sync.currentSettings.pendingMerges == [.organization])
		let copies: URL = a.directory.appendingPathComponent(WorkspaceSync.keptCopyDirectoryName)
		#expect((try? FileManager.default.contentsOfDirectory(atPath: copies.path))?.isEmpty ?? true)

		await a.sync.setEnabled(true)
		#expect(await a.sync.currentSettings.pendingMerges.isEmpty)
		try await converge(a, b)
		#expect(try spaces(b).contains(keptSpaceID))
	}

	/// A rejoin iCloud doesn't have yet holds back only the category rejoining.
	@Test
	func aWaitingRejoinHoldsBackOnlyItsCategory() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud, archive: true)
		defer {
			a.remove()
			b.remove()
		}
		await a.sync.setCategory(.archive, isEnabled: false)
		await a.sync.setEnabled(false)

		a.directorySendFails.setValue(true)
		await a.sync.setCategory(.archive, isEnabled: true)
		await a.sync.setEnabled(true)
		#expect(await a.sync.currentSettings.pendingMerges == [.archive])
		#expect(await a.sync.engine(.archive)?.isRunning != true)
		#expect(await a.sync.engine(.organization)?.isRunning == true)
		#expect(await a.sync.engine(.preferences)?.isRunning == true)

		a.directorySendFails.setValue(false)
		try await wait { await a.sync.currentSettings.pendingMerges.isEmpty }
		#expect(await a.sync.engine(.archive)?.isRunning == true)
	}

	/// An undo of this Mac's deletion made while a rejoin starts, before its fetch applies the purge of
	/// the item, stands: the item comes back though the copy still has the deletion.
	@Test
	func anUndoDuringARejoinStands() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		try delete(keptSpaceID, on: a)
		try await a.send()
		await a.sync.setCategory(.organization, isEnabled: false)
		try await purge([keptSpaceID], on: b)

		let aID: UUID = try deviceID(a)
		let organization: DatabaseQueue = a.organization
		let undone: UUID = keptSpaceID
		a.beforeRejoinFetch.setValue {
			try organization.write { db in
				try DeletionRecord.find(LocalDeletion.rowID(item: undone, table: SpaceRecord.tableName, device: aID)).delete().execute(db)
			}
		}
		await a.sync.setCategory(.organization, isEnabled: true)
		a.beforeRejoinFetch.setValue(nil)

		#expect(await a.sync.currentSettings.pendingMerges.isEmpty)
		#expect(try spaces(a).contains(keptSpaceID))
		try await converge(a, b)
		#expect(try spaces(b).contains(keptSpaceID))
	}

	/// Turned off and on again while its rejoin's fetch runs: that attempt ends, and the start the
	/// second toggle asked for runs once it has, so the category syncs again.
	@Test
	func turningOffAndOnDuringARejoinStartsItAgain() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		await a.sync.setCategory(.organization, isEnabled: false)
		try await purge([keptSpaceID], on: b)

		a.rejoinFetchHangs.setValue(true)
		let rejoining: Task<Void, Never> = Task { await a.sync.setCategory(.organization, isEnabled: true) }
		try await wait { try !spaces(a).contains(keptSpaceID) }
		await a.sync.setCategory(.organization, isEnabled: false)
		await a.sync.setCategory(.organization, isEnabled: true)
		a.rejoinFetchHangs.setValue(false)
		await rejoining.value

		try await wait { await a.sync.currentSettings.pendingMerges.isEmpty }
		#expect(await a.sync.currentSettings.pendingMerges.isEmpty)
		try await wait { await a.sync.engine(.organization)?.isRunning == true }
		#expect(await a.sync.engine(.organization)?.isRunning == true)
		#expect(try spaces(a).contains(keptSpaceID))
		try await converge(a, b)
		#expect(try spaces(b).contains(keptSpaceID))
	}

	/// Tab Archive's purges follow its own membership: an entry the other Macs removed while this Mac
	/// was out of Tab Archive goes for good there, and comes back when this Mac rejoins.
	@Test
	func aRejoinBringsBackAnArchiveEntryPurgedWithoutThisMac() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud, archive: true)
		defer {
			a.remove()
			b.remove()
		}
		try edit(a.archive) { db in
			try ArchiveEntryRecord.insert {
				ArchiveEntryRecord(
					id: entryID,
					groupID: UUID(10),
					closedAt: 800_000_000,
					spaceID: keptSpaceID,
					spaceName: "Kept",
					originalIndex: 0,
					tabID: UUID(11),
					profileID: profileID,
					title: "Read",
					url: "https://read.example",
					position: "V"
				)
			}
			.execute(db)
		}
		try await converge(a, b)
		let entries: @Sendable (TestMac) throws -> Set<UUID> = { mac in
			try mac.archive.read { db in Set(try ArchiveEntryRecord.select(\.id).fetchAll(db)) }
		}
		#expect(try entries(b) == [entryID])

		await a.sync.setCategory(.archive, isEnabled: false)

		// A stays a member of Profiles and spaces.
		try await b.fetch()
		let departed: (Set<UUID>, Set<UUID>) = try await b.devices.read { db in
			(
				try DeviceDirectory.departedDevices(db, from: .archive),
				try DeviceDirectory.departedDevices(db, from: .organization)
			)
		}
		#expect(departed.0 == [try deviceID(a)])
		#expect(departed.1.isEmpty)

		let bID: UUID = try deviceID(b)
		try edit(b.archive) { db in
			try ArchiveDeletionRecord.insert {
				ArchiveDeletionRecord(id: UUID(12), itemID: entryID, deviceID: bID, deletedAt: Date().timeIntervalSince1970)
			}
			.execute(db)
		}
		try await b.send()
		try await b.sync.repair(.archive)
		try await b.send()
		#expect(try entries(b).isEmpty)
		#expect(try entries(a) == [entryID])

		await a.sync.setCategory(.archive, isEnabled: true)
		#expect(await a.sync.currentSettings.pendingMerges.isEmpty)
		#expect(try entries(a) == [entryID])
		try await converge(a, b)
		#expect(try entries(b) == [entryID])
	}

	/// What the merge brings back: items this Mac didn't delete, each only where its parent is, and the
	/// rows only this Mac has that a cascade took with them, as they were then, under a space the fetch
	/// brought back too, while a tab closed meanwhile stays closed.
	@Test
	func keptRowsComeBackWhereTheirParentIs() throws {
		let directory: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent("CategoryLeaveTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { TestFolders.removeAtExit(directory) }

		let device: UUID = UUID(-1)
		let deletedSpace: UUID = UUID(20)
		let keptSpace: UUID = UUID(21)
		let outer: UUID = UUID(22)
		let inner: UUID = UUID(23)
		let pinInDeleted: UUID = UUID(24)
		let pinInInner: UUID = UUID(25)
		let regularTab: UUID = UUID(26)
		let recreatedSpace: UUID = UUID(27)
		let recreatedTab: UUID = UUID(28)
		let closedTab: UUID = UUID(29)
		let openedTab: UUID = UUID(31)
		let closedAfterTab: UUID = UUID(32)
		let movedTab: UUID = UUID(33)
		let copy: DatabaseQueue = try .init(path: directory.appendingPathComponent("copy.sqlite").path)
		try WorkspaceSchema.organizationMigrator().migrate(copy)
		try copy.write { db in
			try db.seed {
				ProfileRecord(id: profileID, name: "Personal", position: "V")
				SpaceRecord(id: deletedSpace, profileID: profileID, name: "Deleted", position: "V")
				SpaceRecord(id: keptSpace, profileID: profileID, name: "Kept", position: "W")

				// The inner folder before its parent: the merge orders them.
				FolderRecord(id: inner, spaceID: keptSpace, parentFolderID: outer, name: "Inner", position: "V")
				FolderRecord(id: outer, spaceID: keptSpace, name: "Outer", position: "V")
				PinnedTabRecord(id: pinInDeleted, spaceID: deletedSpace, title: "A", url: "https://a.example", position: "V")
				PinnedTabRecord(id: pinInInner, spaceID: keptSpace, folderID: inner, title: "B", url: "https://b.example", position: "V")
				DeletionRecord(
					id: UUID(30),
					itemID: deletedSpace,
					itemTable: SpaceRecord.tableName,
					deviceID: device,
					deletedAt: 1
				)
				RegularTabRecord(id: regularTab, spaceID: keptSpace, position: "V")
				SpaceRecord(id: recreatedSpace, profileID: profileID, name: "Recreated", position: "X")
				RegularTabRecord(id: recreatedTab, spaceID: recreatedSpace, position: "W")
				RegularTabRecord(id: closedTab, spaceID: recreatedSpace, position: "X")
				FavoriteRecord(id: movedTab, profileID: profileID, title: "Moved", url: "https://moved.example", position: "V")
			}
		}

		// What the fetch's cascade took, as the rejoin logged it while the copy was attached.
		let live: DatabaseQueue = try .init(path: directory.appendingPathComponent("live.sqlite").path)
		try WorkspaceSchema.organizationMigrator().migrate(live)
		try live.write { db in
			try db.seed {
				ProfileRecord(id: profileID, name: "Personal", position: "V")
				SpaceRecord(id: deletedSpace, profileID: profileID, name: "Deleted", position: "V")
				SpaceRecord(id: keptSpace, profileID: profileID, name: "Kept", position: "W")
				SpaceRecord(id: recreatedSpace, profileID: profileID, name: "Recreated", position: "X")
				RegularTabRecord(id: regularTab, spaceID: keptSpace, position: "V")
				RegularTabRecord(id: recreatedTab, spaceID: recreatedSpace, position: "W")
				RegularTabRecord(id: closedTab, spaceID: recreatedSpace, position: "X")

				// Opened after the copy was taken.
				RegularTabRecord(id: openedTab, spaceID: recreatedSpace, customTitle: "Opened since", position: "Y")
				RegularTabRecord(id: closedAfterTab, spaceID: recreatedSpace, position: "Z")
				FavoriteRecord(id: movedTab, profileID: profileID, title: "Moved", url: "https://moved.example", position: "V")
			}
			for tab in [regularTab, recreatedTab, closedTab, openedTab, closedAfterTab] {
				try TabStateRecord.insert {
					TabStateRecord(id: tab, restorationTitle: "Tab", restorationURL: "https://tab.example", ordinal: "V")
				}
				.execute(db)
			}
		}
		try live.writeWithoutTransaction { db in
			try db.execute(sql: #"ATTACH DATABASE ? AS "\#(KeptRows.schema)""#, arguments: [directory.appendingPathComponent("copy.sqlite").path])
			try KeptRows.watchCascades(db)
			try db.inTransaction {
				// The person closes a tab and renames a space; then a fetch deletes three spaces and brings
				// one back, and moves a Favorite to the pins.
				try RegularTabRecord.find(closedTab).delete().execute(db)
				try TabStateRecord.find(closedTab).delete().execute(db)
				try SpaceRecord.find(keptSpace).update { $0.name = "Kept, renamed" }.execute(db)
				try SpaceRecord.where { $0.id.in([deletedSpace, keptSpace, recreatedSpace]) }.delete().execute(db)
				try SpaceRecord.insert { SpaceRecord(id: recreatedSpace, profileID: profileID, name: "Recreated", position: "X") }.execute(db)
				try FavoriteRecord.find(movedTab).delete().execute(db)
				try PinnedTabRecord.insert {
					PinnedTabRecord(id: movedTab, spaceID: recreatedSpace, title: "Moved", url: "https://moved.example", position: "V")
				}
				.execute(db)

				// The person closes a tab the cascade took, still on screen until the merge.
				try TabStateRecord.find(closedAfterTab).delete().execute(db)
				return .commit
			}
			try KeptRows.unwatchCascades(db)
			try db.execute(sql: #"DETACH DATABASE "\#(KeptRows.schema)""#)
		}

		let kept: any KeptCategoryRows = try #require(
			try KeptRows.read(.organization, from: directory.appendingPathComponent("copy.sqlite"), deviceID: device)
		)
		let restored: Int = try live.write { db in try kept.restore(db) }
		#expect(restored == 4)
		let spaces: Set<UUID> = try live.read { db in Set(try SpaceRecord.select(\.id).fetchAll(db)) }
		let folders: Set<UUID> = try live.read { db in Set(try FolderRecord.select(\.id).fetchAll(db)) }
		let pins: Set<UUID> = try live.read { db in Set(try PinnedTabRecord.select(\.id).fetchAll(db)) }
		let tabs: Set<UUID> = try live.read { db in Set(try RegularTabRecord.select(\.id).fetchAll(db)) }
		#expect(spaces == [keptSpace, recreatedSpace])
		#expect(folders == [outer, inner])
		#expect(pins == [pinInInner, movedTab])
		#expect(tabs == [regularTab, recreatedTab, openedTab])
		let favorites: Set<UUID> = try live.read { db in Set(try FavoriteRecord.select(\.id).fetchAll(db)) }
		#expect(favorites.isEmpty)
		let keptName: String? = try live.read { db in try SpaceRecord.find(keptSpace).fetchOne(db)?.name }
		#expect(keptName == "Kept, renamed")
		let opened: RegularTabRecord? = try live.read { db in try RegularTabRecord.find(openedTab).fetchOne(db) }
		#expect(opened?.customTitle == "Opened since")
	}
}
