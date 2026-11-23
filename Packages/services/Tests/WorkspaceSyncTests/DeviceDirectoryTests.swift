import CloudKit
import Foundation
@testable import SQLiteData
import Testing
import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

/// The device directory and "Stop syncing this Mac" (DEV-979): each Mac lists what it syncs, a Mac
/// that stops keeps its data and every other Mac keeps theirs, and turning sync on again rejoins.
@Suite(.dependency(\.uuid, .incrementing), .timeLimit(.minutes(1)))
struct DeviceDirectoryTests {
	private let profileID: UUID = UUID(1)
	private let spaceID: UUID = UUID(2)
	private let laterSpaceID: UUID = UUID(3)
	private let ownSpaceID: UUID = UUID(4)

	private func seed(_ mac: TestMac) throws {
		try edit(mac.organization) { db in
			try db.seed {
				ProfileRecord(id: profileID, name: "Personal", position: "V")
				SpaceRecord(id: spaceID, profileID: profileID, name: "Home", position: "V")
			}
		}
	}

	private func devices(_ mac: TestMac) throws -> [UUID: DeviceDirectoryRecord] {
		try mac.devices.read { db in
			Dictionary(uniqueKeysWithValues: try DeviceDirectoryRecord.all.fetchAll(db).map { ($0.id, $0) })
		}
	}

	private func deviceID(_ mac: TestMac) throws -> UUID {
		try mac.organization.write { db in try LocalDeletion.deviceID(db) }
	}

	private func spaces(_ mac: TestMac) throws -> Set<UUID> {
		try mac.organization.read { db in Set(try SpaceRecord.all.fetchAll(db).map(\.id)) }
	}

	/// Two Macs syncing the same workspace.
	private func twoMacs(_ cloud: TestCloud) async throws -> (TestMac, TestMac) {
		let a: TestMac = try .init(cloud: cloud, name: "Mac A")
		let b: TestMac = try .init(cloud: cloud, name: "Mac B")
		try seed(a)
		await a.sync.setEnabled(true)
		await b.sync.setEnabled(true)
		try await converge(a, b)
		return (a, b)
	}

	@Test
	func eachMacListsWhatItSyncs() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		let listed: [UUID: DeviceDirectoryRecord] = try devices(b)
		let aRow: DeviceDirectoryRecord = try #require(listed[try deviceID(a)])
		#expect(aRow.name == "Mac A")
		#expect(aRow.stoppedAt == nil)
		#expect(listed[try deviceID(b)]?.name == "Mac B")

		// Turning a category off lists it as paused there.
		await a.sync.setCategory(.preferences, isEnabled: false)
		try await converge(a, b)
		let status: WorkspaceSyncStatus = await b.sync.status
		#expect(status.devices(syncing: .organization).map(\.name).sorted() == ["Mac A", "Mac B"])
		#expect(status.devices(syncing: .preferences).map(\.name) == ["Mac B"])
		#expect(status.devices.first?.isThisMac == true)

		// Turning sync off lists nothing there.
		await a.sync.setEnabled(false)
		#expect(await a.sync.engine(.organization)?.isRunning != true)
		try await b.fetch()
		let aPaused: DeviceDirectoryRecord = try #require(try devices(b)[try deviceID(a)])
		#expect(aPaused.categories == "[]")
		#expect(aPaused.stoppedAt == nil)
		await b.sync.refreshStatus()
		let paused: WorkspaceSyncStatus = await b.sync.status
		#expect(paused.devices(syncing: .organization).map(\.name) == ["Mac B"])
	}

	@Test
	func stoppingKeepsEveryMacsDataAndTellsTheOthers() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		await a.sync.stopSyncingThisMac()

		let settings: SyncSettings = await a.sync.currentSettings
		#expect(settings.isStopped)
		#expect(!settings.isEnabled)
		#expect(!settings.stopIsUnpublished)
		// The account stays connected, as with Keep on This Mac.
		#expect(settings.account == "account-a")
		#expect(await a.sync.engine(.organization)?.isRunning != true)

		// B hears of it, and A keeps what B changes afterwards out.
		try await b.fetch()
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt != nil)
		try edit(b.organization) { db in
			try SpaceRecord.find(spaceID).delete().execute(db)
			try SpaceRecord.insert { SpaceRecord(id: laterSpaceID, profileID: profileID, name: "Later", position: "W") }.execute(db)
		}
		try await b.send()
		try await a.fetch()
		#expect(try spaces(a) == [spaceID])
		#expect(try spaces(b) == [laterSpaceID])
	}

	@Test
	func aStoppedMacDoesntCountForPurges() throws {
		let now: Date = .init()
		let a: UUID = UUID(-1)
		let b: UUID = UUID(-2)
		var snapshot: WorkspaceRepair.PurgeSnapshot = .init()
		snapshot.itemTables = [SpaceRecord.tableName]
		snapshot.items = [SpaceRecord.tableName: [spaceID]]
		snapshot.sightings = [a: now.timeIntervalSince1970, b: now.timeIntervalSince1970]
		snapshot.deletions = [.init(itemID: spaceID, itemTable: SpaceRecord.tableName, deviceID: b, deletedAt: now.timeIntervalSince1970)]

		#expect(WorkspaceRepair.purgeCandidates(snapshot, policy: .init(now: now, syncDeletionsAfter: nil)).isEmpty)
		let stopped: WorkspaceRepair.DeletionPolicy = .init(now: now, syncDeletionsAfter: nil, departedDevices: [a])
		#expect(WorkspaceRepair.purgeCandidates(snapshot, policy: stopped) == [.init(table: SpaceRecord.tableName, id: spaceID)])
	}

	@Test
	func aStopWaitsForTheAccountToReachTheOthers() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		a.accountFails.setValue(true)
		await a.sync.stopSyncingThisMac()
		#expect(await a.sync.currentSettings.isStopped)
		#expect(await a.sync.currentSettings.stopIsUnpublished)
		#expect(await a.sync.directoryEngineForDiagnostics()?.isRunning != true)
		try await b.fetch()
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt == nil)

		// The next launch with the account reachable sends it, with sync still off.
		a.accountFails.setValue(false)
		await a.sync.launch()
		#expect(await !a.sync.currentSettings.stopIsUnpublished)
		#expect(await !a.sync.currentSettings.isEnabled)
		try await b.fetch()
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt != nil)
	}

	@Test
	func aStopIsSentOnceTheAccountIsBackWithoutALaunch() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		a.accountFails.setValue(true)
		await a.sync.stopSyncingThisMac()
		#expect(await a.sync.currentSettings.stopIsUnpublished)

		// The account retry sends it, though sync is off.
		a.accountFails.setValue(false)
		let clock: ContinuousClock = .init()
		let deadline: ContinuousClock.Instant = clock.now.advanced(by: .seconds(10))
		while await a.sync.currentSettings.stopIsUnpublished, clock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		#expect(await !a.sync.currentSettings.stopIsUnpublished)
		try await b.fetch()
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt != nil)
	}

	@Test
	func anotherAccountStartsWithAnEmptyDirectory() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		#expect(await a.sync.status.devices.count == 2)

		a.account.setValue(.available("account-b"))
		await a.sync.accountDidChange()
		#expect(await a.sync.status.review == .accountChanged)
		await a.sync.resolve(.useWithThisAccount)

		// Account A's Macs are forgotten; this Mac's row is written again for account B.
		#expect(await a.sync.currentSettings.directoryAccount == "account-b")
		let listed: [UUID: DeviceDirectoryRecord] = try devices(a)
		#expect(Set(listed.keys) == [try deviceID(a)])
		#expect(await a.sync.status.devices.map(\.isThisMac) == [true])
	}

	@Test
	func theDirectoryPausesForAnAccountSwitchWithEveryCategoryOff() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		for category in SyncCategory.allCases {
			await a.sync.setCategory(category, isEnabled: false)
		}
		#expect(await a.sync.directoryEngineForDiagnostics()?.isRunning == true)

		a.account.setValue(.available("account-b"))
		await a.directoryAccountEvent(
			.switchAccounts(
				previousUser: CKRecord.ID(recordName: "account-a"),
				currentUser: CKRecord.ID(recordName: "account-b")
			)
		)
		#expect(await a.sync.status.review == .accountChanged)
		#expect(await a.sync.directoryEngineForDiagnostics()?.isRunning == false)
	}

	/// A stop chosen during an account decision that can't be saved changes nothing: the decision
	/// stays the person's to make.
	@Test
	func aStopThatIsntSavedKeepsTheAccountDecision() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		a.account.setValue(.available("account-b"))
		await a.sync.accountDidChange()
		#expect(await a.sync.status.review == .accountChanged)

		// A folder where the settings file goes makes saving it fail.
		let settingsFile: URL = a.directory.appendingPathComponent(SyncSettingsStore.fileName)
		try? FileManager.default.removeItem(at: settingsFile)
		try FileManager.default.createDirectory(at: settingsFile, withIntermediateDirectories: false)
		await a.sync.stopSyncingThisMac()

		let settings: SyncSettings = await a.sync.currentSettings
		#expect(!settings.isStopped)
		#expect(!settings.stopIsUnpublished)
		#expect(settings.review == .accountChanged)
		#expect(await a.sync.status.review == .accountChanged)
		#expect(await a.sync.status.saveError != nil)
	}

	/// Over quota, CloudKit refuses the stop and sending still succeeds: it stays unsent, and the
	/// account retry sends it once there's room.
	@Test
	func aStopRefusedOverQuotaIsSentLater() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}

		cloud.container.privateCloudDatabase.state.withValue { $0.quota = 0 }
		await a.sync.stopSyncingThisMac()
		#expect(await a.sync.currentSettings.stopIsUnpublished)
		try await b.fetch()
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt == nil)

		cloud.container.privateCloudDatabase.state.withValue { $0.quota = .max }
		let clock: ContinuousClock = .init()
		let deadline: ContinuousClock.Instant = clock.now.advanced(by: .seconds(10))
		while await a.sync.currentSettings.stopIsUnpublished, clock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		#expect(await !a.sync.currentSettings.stopIsUnpublished)
		try await b.fetch()
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt != nil)
	}

	/// Waits up to a few seconds for the account retry to finish `a`'s rejoin.
	private func waitForTheRejoin(_ mac: TestMac) async throws {
		let clock: ContinuousClock = .init()
		let deadline: ContinuousClock.Instant = clock.now.advanced(by: .seconds(10))
		while await !mac.sync.currentSettings.pendingRejoins.isEmpty {
			try #require(clock.now < deadline, "The account retry never finished the rejoin")
			try await Task.sleep(for: .milliseconds(20))
		}
	}

	/// Until iCloud has a rejoin, the other Macs still leave this Mac out of purges: its categories
	/// wait, and the rejoin stays pending, while CloudKit refuses the directory row.
	@Test
	func aRejoinWaitsUntilICloudSavesTheDirectoryRow() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		await a.sync.stopSyncingThisMac()
		try await b.fetch()
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt != nil)

		// Over quota, CloudKit refuses the row and sending still succeeds.
		cloud.container.privateCloudDatabase.state.withValue { $0.quota = 0 }
		await a.sync.setEnabled(true)
		#expect(await !a.sync.currentSettings.pendingRejoins.isEmpty)
		#expect(await a.sync.engine(.organization)?.isRunning != true)
		try await b.fetch()
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt != nil)

		// The account retry sends it once there's room.
		cloud.container.privateCloudDatabase.state.withValue { $0.quota = .max }
		try await waitForTheRejoin(a)
		#expect(await a.sync.currentSettings.pendingRejoins.isEmpty)
		#expect(await a.sync.engine(.organization)?.isRunning == true)
		try await b.fetch()
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt == nil)
	}

	@Test
	func aRejoinWaitsForASendThatThrew() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		await a.sync.stopSyncingThisMac()

		a.directorySendFails.setValue(true)
		await a.sync.setEnabled(true)
		#expect(await !a.sync.currentSettings.pendingRejoins.isEmpty)
		#expect(await a.sync.engine(.organization)?.isRunning != true)
		try await b.fetch()
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt != nil)

		a.directorySendFails.setValue(false)
		try await waitForTheRejoin(a)
		#expect(await a.sync.currentSettings.pendingRejoins.isEmpty)
		#expect(await a.sync.engine(.organization)?.isRunning == true)
		try await b.fetch()
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt == nil)
	}

	@Test
	func turningSyncOnAfterAStopRejoinsAndMerges() async throws {
		let cloud: TestCloud = .init()
		let (a, b): (TestMac, TestMac) = try await twoMacs(cloud)
		defer {
			a.remove()
			b.remove()
		}
		let bID: UUID = try deviceID(b)
		await a.sync.stopSyncingThisMac()

		// Each changes something while A is stopped. A's copy of B's device row is from before.
		try edit(b.organization) { db in
			try SpaceRecord.insert { SpaceRecord(id: laterSpaceID, profileID: profileID, name: "Later", position: "W") }.execute(db)
		}
		try await b.send()
		try edit(a.organization) { db in
			try SpaceRecord.insert { SpaceRecord(id: ownSpaceID, profileID: profileID, name: "Own", position: "X") }.execute(db)
			try SyncDeviceRecord.find(bID).update { $0.lastSeen = 1 }.execute(db)
		}

		await a.sync.setEnabled(true)
		#expect(await a.sync.currentSettings.pendingRejoins.isEmpty)
		#expect(await !a.sync.currentSettings.isStopped)
		try await converge(a, b)

		#expect(try spaces(a) == [spaceID, laterSpaceID, ownSpaceID])
		#expect(try spaces(b) == [spaceID, laterSpaceID, ownSpaceID])
		// B's device row came back from iCloud rather than going out as A last saw it.
		let bSeen: Double? = try await b.organization.read { db in try SyncDeviceRecord.find(bID).fetchOne(db)?.lastSeen }
		#expect((bSeen ?? 0) > 1)
		#expect(try devices(b)[try deviceID(a)]?.stoppedAt == nil)
	}
}
