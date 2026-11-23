import CloudKit
import ConcurrencyExtras
import Foundation
@testable import SQLiteData
import Testing
import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

@Suite(.dependency(\.uuid, .incrementing), .timeLimit(.minutes(1)))
struct WorkspaceSyncTests {
	private let profileID: UUID = UUID(1)
	private let spaceID: UUID = UUID(2)
	private let otherSpaceID: UUID = UUID(3)
	private let folderID: UUID = UUID(10)
	private let otherFolderID: UUID = UUID(11)
	private let tabID: UUID = UUID(20)
	private let otherTabID: UUID = UUID(21)

	private func seed(_ mac: TestMac) throws {
		try edit(mac.organization) { db in
			try db.seed {
				ProfileRecord(id: profileID, name: "Personal", position: "V")
				SpaceRecord(id: spaceID, profileID: profileID, name: "Home", position: "V")
				SpaceRecord(id: otherSpaceID, profileID: profileID, name: "Work", position: "W")
				FolderRecord(id: folderID, spaceID: spaceID, name: "Reading", position: "V")
				FolderRecord(id: otherFolderID, spaceID: spaceID, name: "Later", position: "W")
				PinnedTabRecord(id: tabID, spaceID: spaceID, title: "Arx", url: "https://arx.example", position: "X")
				PinnedTabRecord(id: otherTabID, spaceID: spaceID, title: "Docs", url: "https://docs.example", position: "Y")
			}
		}
		try edit(mac.preferences) { db in
			try db.seed {
				PreferenceRecord(id: "appearance", value: #"{"grain":0}"#)
				SearchShortcutRecord(id: "w", keyword: "w", name: "Wikipedia", template: "https://w.example/%s", position: "V")
			}
		}
	}

	// MARK: - Onboarding (DEV-1215)

	private func join(_ mac: TestMac, turningSyncOn: Bool = true) async -> [OnboardingSyncEvent] {
		var events: [OnboardingSyncEvent] = []
		for await event in await mac.sync.joinFromOnboarding(turningSyncOn: turningSyncOn) {
			events.append(event)
		}
		return events
	}

	@Test
	func onboardingFindsTheWorkspaceAnotherMacSyncedAndTheSpaceUsedLast() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		let b: TestMac = try .init(cloud: cloud)
		defer {
			a.remove()
			b.remove()
		}
		try seed(a)
		try edit(a.organization) { db in
			try db.seed {
				UsageRecord(id: UUID(90), itemID: spaceID, itemTable: SpaceRecord.tableName, deviceID: UUID(80), lastUsed: 10)
				UsageRecord(id: UUID(91), itemID: otherSpaceID, itemTable: SpaceRecord.tableName, deviceID: UUID(81), lastUsed: 20)

				// Newer, but not a space.
				UsageRecord(id: UUID(92), itemID: tabID, itemTable: PinnedTabRecord.tableName, deviceID: UUID(80), lastUsed: 30)
			}
		}
		await a.sync.setEnabled(true)
		try await a.send()

		#expect(await b.sync.accountIsAvailable())
		let events: [OnboardingSyncEvent] = await join(b)

		#expect(events.first == .fetching(.organization))
		#expect(events.contains(.fetching(.preferences)))
		#expect(events.last == .finished(.init(hasWorkspace: true, lastUsedSpaceID: otherSpaceID)))
		#expect(await b.sync.currentSettings.isEnabled)
		#expect(try OrganizationRows(b.organization).spaces.count == 2)
	}

	@Test
	func onboardingFindsAnEmptyICloud() async throws {
		let b: TestMac = try .init(cloud: .init())
		defer { b.remove() }

		let events: [OnboardingSyncEvent] = await join(b)

		#expect(events.last == .finished(.init(hasWorkspace: false)))
		#expect(await b.sync.currentSettings.isEnabled)
	}

	@Test
	func onboardingWithoutAnAccountKeepsTheRequestToSync() async throws {
		let b: TestMac = try .init(cloud: .init())
		defer { b.remove() }
		b.account.setValue(.noAccount)

		#expect(await !b.sync.accountIsAvailable())
		// iCloud went away after the step checked: sync stays on, and starts once it's back, so
		// onboarding's background wait goes on asking instead of hearing it was turned off.
		#expect(await join(b) == [.unavailable])
		#expect(await b.sync.currentSettings.isEnabled)
		#expect(await join(b, turningSyncOn: false) == [.unavailable])
	}

	@Test
	func onboardingsBackgroundWaitNeverTurnsSyncOn() async throws {
		let b: TestMac = try .init(cloud: .init())
		defer { b.remove() }

		#expect(await join(b, turningSyncOn: false) == [.turnedOff])
		#expect(await !b.sync.currentSettings.isEnabled)

		// With sync on, it waits for the fetch like the step does.
		await b.sync.setEnabled(true)
		#expect(await join(b, turningSyncOn: false).last == .finished(.init(hasWorkspace: false)))

		// Try again with sync already on fetches again.
		#expect(await join(b).last == .finished(.init(hasWorkspace: false)))
	}

	// MARK: - Feature flag

	@Test
	func featureFlagReadsTheEnvironmentThenDefaults() throws {
		let defaults: UserDefaults = try #require(UserDefaults(suiteName: "WorkspaceSyncTests-\(UUID().uuidString)"))

		// On by default (DEV-1143).
		#expect(ICloudSyncFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(ICloudSyncFeatureFlag.isOn(environment: ["ARX_ICLOUD_SYNC": "1"], defaults: defaults))
		#expect(!ICloudSyncFeatureFlag.isOn(environment: ["ARX_ICLOUD_SYNC": "0"], defaults: defaults))
		defaults.set("no", forKey: "ARX_ICLOUD_SYNC")
		#expect(!ICloudSyncFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(ICloudSyncFeatureFlag.isOn(environment: ["ARX_ICLOUD_SYNC": "yes"], defaults: defaults))
	}

	@Test
	func featureFlagOffMakesNoSyncAndTouchesNoFiles() async throws {
		let mac: TestMac = try .init(cloud: .init())
		defer { mac.remove() }
		let before: Set<String> = try Set(FileManager.default.contentsOfDirectory(atPath: mac.directory.path))

		let sync: WorkspaceSync? = try WorkspaceSync.make(
			isFeatureFlagOn: false,
			organization: mac.organization,
			preferences: mac.preferences,
			directory: mac.directory
		)

		#expect(sync == nil)
		let after: Set<String> = try Set(FileManager.default.contentsOfDirectory(atPath: mac.directory.path))
		#expect(after == before)
	}

	@Test
	func aBuildWithoutTheContainerEntitlementMakesNoSync() async throws {
		// A signed Arx Dev without its provisioning profile has no iCloud (DEV-1013).
		let mac: TestMac = try .init(cloud: .init())
		defer { mac.remove() }
		var asked: [String] = []

		let sync: WorkspaceSync? = try WorkspaceSync.make(
			isFeatureFlagOn: true,
			organization: mac.organization,
			preferences: mac.preferences,
			directory: mac.directory,
			isEntitled: { container in
				asked.append(container)
				return false
			}
		)

		#expect(sync == nil)
		#expect(asked == [WorkspaceSync.containerIdentifier])
		// The test runner is unsigned, so it has no iCloud entitlement either.
		#expect(!ICloudEntitlement.grants(WorkspaceSync.containerIdentifier))
	}

	@Test
	func syncDoesntStartUntilTheToggleIsSaved() async throws {
		let mac: TestMac = try .init(cloud: .init())
		defer { mac.remove() }

		// A folder where the settings file goes makes every save fail.
		try FileManager.default.createDirectory(
			at: mac.directory.appendingPathComponent(SyncSettingsStore.fileName),
			withIntermediateDirectories: false
		)
		await mac.sync.setEnabled(true)

		#expect(await mac.sync.currentSettings.isEnabled == false)
		#expect(await mac.sync.engine(.organization) == nil)
		#expect(mac.accountReads.value == 0)
		#expect(await mac.sync.status.overall.isError)

		// Once saving works again, the same toggle saves and starts.
		try FileManager.default.removeItem(at: mac.directory.appendingPathComponent(SyncSettingsStore.fileName))
		await mac.sync.setEnabled(true)
		#expect(try SyncSettingsStore(directory: mac.directory).load().isEnabled)
		#expect(await mac.sync.status.overall.isError == false)
		try await mac.send()
	}

	@Test
	func syncNeverTurnedOnMakesNoEngineAndReadsNoAccount() async throws {
		let mac: TestMac = try .init(cloud: .init())
		defer { mac.remove() }

		await mac.sync.launch()

		#expect(await mac.sync.engine(.organization) == nil)
		#expect(await mac.sync.engine(.preferences) == nil)
		#expect(mac.accountReads.value == 0)
		#expect(await mac.sync.status.overall == .off)
	}

	// MARK: - Two Macs

	@Test
	func twoMacsConvergeAfterConcurrentEditsMovesAndDeletes() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		let b: TestMac = try .init(cloud: cloud)
		defer {
			a.remove()
			b.remove()
		}

		try seed(a)
		await a.sync.setEnabled(true)
		await b.sync.setEnabled(true)
		try await converge(a, b)
		#expect(try OrganizationRows(b.organization) == OrganizationRows(a.organization))
		#expect(try PreferenceRows(b.preferences) == PreferenceRows(a.preferences))
		#expect(try OrganizationRows(b.organization).pinnedTabs.count == 2)

		// Offline on both: A renames the tab and the folder; B moves the same tab into a folder and
		// renames the same folder later; B deletes the other tab; A edits a preference, B another.
		try edit(a.organization) { db in
			try PinnedTabRecord.find(tabID).update { $0.title = "Arx Browser" }.execute(db)
			try FolderRecord.find(folderID).update { $0.name = "Read soon" }.execute(db)
		}
		try edit(b.organization) { db in
			try PinnedTabRecord.find(tabID).update {
				$0.folderID = #bind(folderID)
				$0.position = "a"
			}
			.execute(db)
			try FolderRecord.find(folderID).update { $0.name = "Reading list" }.execute(db)
			try PinnedTabRecord.find(otherTabID).delete().execute(db)
		}
		try edit(a.preferences) { db in
			try PreferenceRecord.find("appearance").update { $0.value = #"{"grain":1}"# }.execute(db)
		}
		try edit(b.preferences) { db in
			try SearchShortcutRecord.insert {
				SearchShortcutRecord(id: "gh", keyword: "gh", name: "GitHub", template: "https://gh.example/%s", position: "W")
			}
			.execute(db)
		}

		try await converge(a, b)

		let rowsA: OrganizationRows = try .init(a.organization)
		let rowsB: OrganizationRows = try .init(b.organization)
		#expect(rowsA == rowsB)
		let tab: PinnedTabRecord = try #require(rowsA.pinnedTabs.first { $0.id == tabID })
		#expect(tab.title == "Arx Browser")
		#expect(tab.folderID == folderID)
		#expect(rowsA.folders.first { $0.id == folderID }?.name == "Reading list")
		#expect(!rowsA.pinnedTabs.contains { $0.id == otherTabID })

		let preferencesA: PreferenceRows = try .init(a.preferences)
		#expect(preferencesA == (try PreferenceRows(b.preferences)))
		#expect(preferencesA.preferences.first?.value == #"{"grain":1}"#)
		#expect(preferencesA.searchShortcuts.map(\.id) == ["gh", "w"])
	}

	@Test
	func concurrentFolderMovesThatMakeACycleConvergeToOneTree() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		let b: TestMac = try .init(cloud: cloud)
		defer {
			a.remove()
			b.remove()
		}

		try seed(a)
		await a.sync.setEnabled(true)
		await b.sync.setEnabled(true)
		try await converge(a, b)

		// A puts Reading in Later; B puts Later in Reading. Together they're a cycle.
		try edit(a.organization) { db in
			try FolderRecord.find(folderID).update { $0.parentFolderID = #bind(otherFolderID) }.execute(db)
		}
		try edit(b.organization) { db in
			try FolderRecord.find(otherFolderID).update { $0.parentFolderID = #bind(folderID) }.execute(db)
		}
		try await converge(a, b)

		let rowsA: OrganizationRows = try .init(a.organization)
		#expect(rowsA == (try OrganizationRows(b.organization)))
		let reading: FolderRecord = try #require(rowsA.folders.first { $0.id == folderID })
		let later: FolderRecord = try #require(rowsA.folders.first { $0.id == otherFolderID })

		// The lowest ID in the cycle, Reading, goes to the root, at the end; Later stays inside it.
		#expect(reading.parentFolderID == nil)
		#expect(later.parentFolderID == folderID)
		#expect(reading.position > "Y")
	}

	@Test
	func aFetchedBatchRunsTheRepairPassAndReportsTheChange() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		let b: TestMac = try .init(cloud: cloud)
		defer {
			a.remove()
			b.remove()
		}

		try seed(a)
		await a.sync.setEnabled(true)
		await b.sync.setEnabled(true)
		try await converge(a, b)

		let changes: AsyncStream<SyncCategory> = await b.sync.remoteChanges()

		// A pins a tab into a folder of another space, which only a buggy or racing Mac would write.
		try edit(a.organization) { db in
			try FolderRecord.insert {
				FolderRecord(id: UUID(12), spaceID: otherSpaceID, name: "Elsewhere", position: "V")
			}
			.execute(db)
			try PinnedTabRecord.find(otherTabID).update { $0.folderID = #bind(UUID(12)) }.execute(db)
		}
		try await a.send()
		let engine: SyncEngine = try #require(await b.sync.engine(.organization))
		try await engine.fetchChanges()

		// The batch observer repairs B's rows on its own; wait for the event that follows it.
		var repairedTab: PinnedTabRecord?
		for await category in changes {
			#expect(category == .organization)
			repairedTab = try await b.organization.read { db in
				try PinnedTabRecord.find(otherTabID).fetchOne(db)
			}
			if repairedTab?.folderID == nil { break }
		}
		#expect(repairedTab?.folderID == nil)
		#expect(repairedTab?.position == "Y")
	}

	@Test
	func aJoiningMacEmptiesItsUntouchedStarterProfileAtItsFirstMerge() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		let b: TestMac = try .init(cloud: cloud)
		defer {
			a.remove()
			b.remove()
		}

		for (mac, profile, space) in [(a, UUID(4), UUID(40)), (b, UUID(5), UUID(50))] {
			try edit(mac.organization) { db in
				try db.seed {
					ProfileRecord(id: profile, name: "Personal", position: "V", isStarter: true)
					SpaceRecord(id: space, profileID: profile, name: "Home", position: "V", isStarter: true)
				}
			}
		}
		await a.sync.setEnabled(true)
		try await a.send()

		await b.sync.setEnabled(true)

		// B's copy loses its space and stays, for B to offer removing it with its data (DEV-989).
		#expect(try Set(OrganizationRows(b.organization).profiles.map(\.id)) == [UUID(4), UUID(5)])
		#expect(try OrganizationRows(b.organization).spaces.map(\.id) == [UUID(40)])
		try await converge(a, b)
		#expect(try OrganizationRows(a.organization) == OrganizationRows(b.organization))
		#expect(try OrganizationRows(a.organization).spaces.map(\.id) == [UUID(40)])
		#expect(await b.sync.currentSettings.starterProfileIDs.isEmpty)
		#expect(await b.sync.duplicateStarterProfiles() == [UUID(5)])
		#expect(await a.sync.duplicateStarterProfiles().isEmpty)

		// Offered once, it isn't listed again, even after a relaunch.
		await b.sync.forgetDuplicateStarterProfile(UUID(5))
		#expect(await b.sync.duplicateStarterProfiles().isEmpty)
		#expect(await b.sync.currentSettings.duplicateStarterProfileIDs.isEmpty)
	}

	@Test
	func aJoiningMacWithTheLowerIDStillEmptiesItsOwnStarterProfile() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		let b: TestMac = try .init(cloud: cloud)
		defer {
			a.remove()
			b.remove()
		}

		// B's starter sorts first, but A's is the one already in iCloud.
		for (mac, profile, space) in [(a, UUID(5), UUID(50)), (b, UUID(4), UUID(40))] {
			try edit(mac.organization) { db in
				try db.seed {
					ProfileRecord(id: profile, name: "Personal", position: "V", isStarter: true)
					SpaceRecord(id: space, profileID: profile, name: "Home", position: "V", isStarter: true)
				}
			}
		}
		await a.sync.setEnabled(true)
		try await a.send()

		await b.sync.setEnabled(true)
		try await converge(a, b)
		#expect(try OrganizationRows(a.organization) == OrganizationRows(b.organization))
		#expect(try OrganizationRows(a.organization).spaces.map(\.id) == [UUID(50)])
		#expect(await b.sync.duplicateStarterProfiles() == [UUID(4)])
	}

	@Test
	func starterProfilesAreNeverDroppedAfterTheFirstMerge() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		let b: TestMac = try .init(cloud: cloud)
		defer {
			a.remove()
			b.remove()
		}

		// Each install's starter profile, with a pin that keeps it at first.
		try edit(a.organization) { db in
			try db.seed {
				ProfileRecord(id: UUID(4), name: "Personal", position: "V", isStarter: true)
				SpaceRecord(id: UUID(40), profileID: UUID(4), name: "Home", position: "V", isStarter: true)
				PinnedTabRecord(id: UUID(41), spaceID: UUID(40), title: "A", url: "https://a.example", position: "V")
			}
		}
		try edit(b.organization) { db in
			try db.seed {
				ProfileRecord(id: UUID(5), name: "Personal", position: "V", isStarter: true)
				SpaceRecord(id: UUID(50), profileID: UUID(5), name: "Home", position: "V", isStarter: true)
				PinnedTabRecord(id: UUID(51), spaceID: UUID(50), title: "B", url: "https://b.example", position: "V")
			}
		}
		await a.sync.setEnabled(true)
		await b.sync.setEnabled(true)
		try await converge(a, b)
		#expect(try OrganizationRows(a.organization).profiles.count == 2)

		// Later, offline, each unpins its own last tab: both starters look untouched now, but either
		// may already be another Mac's profile, so neither is dropped.
		try edit(a.organization) { db in try PinnedTabRecord.find(UUID(41)).delete().execute(db) }
		try edit(b.organization) { db in try PinnedTabRecord.find(UUID(51)).delete().execute(db) }
		try await a.sync.repair(.organization)
		try await b.sync.repair(.organization)
		try await converge(a, b)

		let rows: OrganizationRows = try .init(a.organization)
		#expect(rows == (try OrganizationRows(b.organization)))
		#expect(rows.profiles.map(\.id) == [UUID(4), UUID(5)])
	}

	@Test
	func aFolderMissingOnlyHereKeepsItsChildrenWhileICloudCantConfirm() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		try await a.send()

		// The folder is in iCloud but gone here, as if its page hadn't arrived yet.
		try edit(a.organization) { db in
			try PinnedTabRecord.find(tabID).update { $0.folderID = #bind(folderID) }.execute(db)
		}
		try await a.send()
		try await a.organization.write { db in
			try db.execute(sql: "PRAGMA foreign_keys = OFF")
			try db.execute(sql: "DROP TRIGGER IF EXISTS temp.\"sqlitedata_icloud_after_delete_on_folder_from_user\"")
		}
		try await a.organization.write { db in try FolderRecord.find(folderID).delete().execute(db) }

		cloud.isOffline.setValue(true)
		try await a.sync.repair(.organization)
		cloud.isOffline.setValue(false)
		try await a.sync.repair(.organization)
		let tab: PinnedTabRecord? = try await a.organization.read { db in try PinnedTabRecord.find(tabID).fetchOne(db) }
		#expect(tab?.folderID == folderID)
	}

	@Test
	func anUnconfirmedRepairIsRetriedOnceICloudAnswers() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		try await a.send()

		// A tab names a folder that's in neither place, while CloudKit can't be asked.
		try edit(a.organization) { db in
			try PinnedTabRecord.find(tabID).update { $0.folderID = #bind(UUID(99)) }.execute(db)
		}
		try await a.send()
		cloud.isOffline.setValue(true)
		let changes: AsyncStream<SyncCategory> = await a.sync.remoteChanges()
		try await a.sync.repair(.organization)
		cloud.isOffline.setValue(false)

		// The scheduled retry repairs it with no new fetch.
		for await _ in changes {
			let tab: PinnedTabRecord? = try await a.organization.read { db in
				try PinnedTabRecord.find(tabID).fetchOne(db)
			}
			if tab?.folderID == nil { break }
		}
		try await a.send()
	}

	@Test
	func aPreferenceConflictIsRepairedOnlyOnceICloudHasIt() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		try await a.send()

		// A keyword that clashes with "w", not in iCloud yet.
		try edit(a.preferences) { db in
			try SearchShortcutRecord.insert {
				SearchShortcutRecord(id: "w-legacy", keyword: "W", name: "Old", template: "https://o.example/?q={query}", position: "U")
			}
			.execute(db)
		}
		#expect(try await a.sync.repair(.preferences).isEmpty)
		#expect(try await a.preferences.read { db in try SearchShortcutRecord.find("w").fetchOne(db) }?.keyword == "w")

		// In iCloud now: repaired, by this pass or the retry the first one scheduled.
		try await a.send()
		try await a.sync.repair(.preferences)
		let w: SearchShortcutRecord? = try await a.preferences.read { db in
			try SearchShortcutRecord.find("w").fetchOne(db)
		}
		#expect(w?.keyword == "w-2")
		#expect(w?.isEnabled == false)
		try await a.send()
	}

	// MARK: - Accounts

	@Test
	func signingOutPausesAndKeepsLocalData() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		try await a.send()
		let before: OrganizationRows = try .init(a.organization)

		a.account.setValue(.noAccount)
		await a.accountEvent(.signOut(previousUser: CKRecord.ID(recordName: "account-a")))

		#expect(try OrganizationRows(a.organization) == before)
		#expect(await a.sync.engine(.organization)?.isRunning == false)
		#expect(await a.sync.status.review == .signedOut)
		#expect(await a.sync.status[.organization] == .paused(.noAccount))

		// Signing in to the same account resumes without asking.
		a.account.setValue(.available("account-a"))
		await a.sync.accountDidChange()
		#expect(await a.sync.status.review == nil)
		#expect(await a.sync.engine(.organization)?.isRunning == true)
		#expect(try OrganizationRows(a.organization) == before)
	}

	@Test
	func aFailedAccountReadIsRetried() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		a.accountFails.setValue(true)
		await a.sync.setEnabled(true)
		#expect(await a.sync.status[.organization] == .paused(.accountUnavailable))

		// Back online: no account change is posted, and sync resumes on its own.
		a.accountFails.setValue(false)
		for await status in await a.sync.statusUpdates() where status[.organization] == .synced {
			break
		}
		#expect(await a.sync.engine(.organization)?.isRunning == true)
		// Lets the restarted engines finish starting before the folder goes.
		try await a.send()
		while await a.sync.status[.preferences] != .synced {
			await Task.yield()
		}
		try await a.send()
	}

	@Test
	func anotherAccountPausesWithoutUploadingUntilThePersonDecides() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		try await a.send()
		let uploaded: Int = cloud.records(.organization).count

		// A row made just before the switch, which the library queues for the new account at sign-in.
		try edit(a.organization) { db in
			try FavoriteRecord.insert {
				FavoriteRecord(id: UUID(30), profileID: profileID, title: "Mail", url: "https://mail.example", position: "V")
			}
			.execute(db)
		}
		a.account.setValue(.available("account-b"))
		await a.accountEvent(.signIn(currentUser: CKRecord.ID(recordName: "account-b")))
		try await a.send()

		#expect(await a.sync.status.review == .accountChanged)
		#expect(await a.sync.status.overall == .accountChanged)
		#expect(await a.sync.engine(.organization)?.isRunning == false)
		#expect(cloud.records(.organization).count == uploaded)
		#expect(try OrganizationRows(a.organization).favorites.count == 1)

		// A launch while the review is open stays paused.
		await a.sync.launch()
		#expect(await a.sync.engine(.organization)?.isRunning == false)

		await a.sync.resolve(.useWithThisAccount)
		try await a.send()
		try await a.fetch()
		try await a.send()
		#expect(await a.sync.status.review == nil)
		#expect(await a.sync.currentSettings.account == "account-b")
		#expect(cloud.records(.organization).count == uploaded + 1)
	}

	@Test
	func switchingAccountsThenKeepingOnThisMacTurnsSyncOff() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		let before: OrganizationRows = try .init(a.organization)

		a.account.setValue(.available("account-b"))
		await a.accountEvent(
			.switchAccounts(
				previousUser: CKRecord.ID(recordName: "account-a"),
				currentUser: CKRecord.ID(recordName: "account-b")
			)
		)
		#expect(await a.sync.status.review == .accountChanged)

		// Switching back to account A resumes without asking.
		a.account.setValue(.available("account-a"))
		await a.sync.accountDidChange()
		#expect(await a.sync.status.review == nil)
		#expect(await a.sync.engine(.organization)?.isRunning == true)
		await a.accountEvent(
			.switchAccounts(
				previousUser: CKRecord.ID(recordName: "account-b"),
				currentUser: CKRecord.ID(recordName: "account-a")
			)
		)
		#expect(await a.sync.status.review == nil)
		#expect(await a.sync.engine(.organization)?.isRunning == true)

		a.account.setValue(.available("account-b"))
		await a.accountEvent(
			.switchAccounts(
				previousUser: CKRecord.ID(recordName: "account-a"),
				currentUser: CKRecord.ID(recordName: "account-b")
			)
		)
		await a.sync.resolve(.keepOnThisMac)
		let settings: SyncSettings = await a.sync.currentSettings
		#expect(!settings.isEnabled)
		#expect(settings.review == nil)
		// The engines' state is still account A's, so the binding stays.
		#expect(settings.account == "account-a")
		#expect(try OrganizationRows(a.organization) == before)
		#expect(await a.sync.status.overall == .off)

		// Turning sync on again with account B asks again instead of skipping rows B never got.
		await a.sync.setEnabled(true)
		#expect(await a.sync.status.review == .accountChanged)
		#expect(await a.sync.engine(.organization)?.isRunning == false)
	}

	@Test
	func launchResumesASignedOutPauseWhenTheSameAccountIsBack() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		a.account.setValue(.noAccount)
		await a.accountEvent(.signOut(previousUser: CKRecord.ID(recordName: "account-a")))
		#expect(await a.sync.status.review == .signedOut)

		// Signed back in while Arx was closed: no engine or notification reports it.
		a.account.setValue(.available("account-a"))
		await a.sync.launch()
		#expect(await a.sync.status.review == nil)
		#expect(await a.sync.engine(.organization)?.isRunning == true)
	}

	@Test
	func replacingWithTheAccountsDataBacksUpFirst() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		try await a.send()
		a.account.setValue(.available("account-b"))
		await a.accountEvent(.signIn(currentUser: CKRecord.ID(recordName: "account-b")))

		// Made while paused, so iCloud never got it.
		try edit(a.organization) { db in
			try FavoriteRecord.insert {
				FavoriteRecord(id: UUID(30), profileID: profileID, title: "Mail", url: "https://mail.example", position: "V")
			}
			.execute(db)
		}

		await a.sync.resolve(.replaceWithAccountData)
		try await a.fetch()

		let backups: URL = a.directory.appendingPathComponent(WorkspaceSync.backupDirectoryName)

		// Replace's copies, beside those of the first sync (DEV-1207).
		let files: [String] = try FileManager.default.contentsOfDirectory(atPath: backups.path)
			.filter { !$0.contains("-first-sync-") }
			.sorted()
		#expect(files.count == 2)
		let backup: DatabaseQueue = try .init(
			path: backups.appendingPathComponent(try #require(files.first { $0.hasSuffix("-organization.sqlite") })).path
		)
		let backedUpFavorites: Int = try await backup.read { db in try FavoriteRecord.fetchCount(db) }
		#expect(backedUpFavorites == 1)

		let rows: OrganizationRows = try .init(a.organization)
		#expect(rows.favorites.isEmpty)
		#expect(rows.pinnedTabs.count == 2)
		#expect(await a.sync.status.review == nil)
		#expect(await a.sync.currentSettings.account == "account-b")
	}

	// MARK: - Categories

	/// Turning Profiles and spaces off is a leave (DEV-1148): both copies stay, and turning it on again
	/// merges the edits each side made meanwhile.
	@Test
	func aCategoryTurnedOffKeepsBothCopiesAndMergesEditsWhenBackOn() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		let b: TestMac = try .init(cloud: cloud)
		defer {
			a.remove()
			b.remove()
		}

		try seed(a)
		await a.sync.setEnabled(true)
		await b.sync.setEnabled(true)
		try await converge(a, b)
		let cloudRecords: Int = cloud.records(.organization).count

		await a.sync.setCategory(.organization, isEnabled: false)
		#expect(await a.sync.status[.organization] == .off)
		#expect(await a.sync.engine(.organization)?.isRunning == false)
		#expect(cloud.records(.organization).count == cloudRecords)

		// While A is out: A renames a space, B renames a tab. Preferences keep syncing on A.
		try edit(a.organization) { db in
			try SpaceRecord.find(otherSpaceID).update { $0.name = "Office" }.execute(db)
		}
		try edit(b.organization) { db in
			try PinnedTabRecord.find(tabID).update { $0.title = "Arx from B" }.execute(db)
		}
		try edit(b.preferences) { db in
			try PreferenceRecord.find("appearance").update { $0.value = #"{"grain":2}"# }.execute(db)
		}
		try await converge(a, b, rounds: 1)
		#expect(try OrganizationRows(a.organization).pinnedTabs.first { $0.id == tabID }?.title == "Arx")
		#expect(try OrganizationRows(b.organization).spaces.first { $0.id == otherSpaceID }?.name == "Work")
		#expect(try PreferenceRows(a.preferences).preferences.first?.value == #"{"grain":2}"#)

		await a.sync.setCategory(.organization, isEnabled: true)
		try await converge(a, b)
		let rowsA: OrganizationRows = try .init(a.organization)
		#expect(rowsA == (try OrganizationRows(b.organization)))
		#expect(rowsA.spaces.first { $0.id == otherSpaceID }?.name == "Office")
		#expect(rowsA.pinnedTabs.first { $0.id == tabID }?.title == "Arx from B")
	}

	// MARK: - Delete from iCloud

	@Test
	func deleteFromICloudKeepsThisMacsRows() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		try await a.send()
		let before: OrganizationRows = try .init(a.organization)
		#expect(cloud.hasZone(.organization))

		try await a.sync.deleteFromICloud(.organization)
		#expect(!cloud.hasZone(.organization))
		#expect(cloud.hasZone(.preferences))
		#expect(try OrganizationRows(a.organization) == before)
		#expect(await a.sync.status[.organization] == .off)

		// On again, the next start uploads every row as new, and the zone's deletion never reaches
		// this Mac's rows.
		await a.sync.setCategory(.organization, isEnabled: true)
		try await a.send()
		try await a.fetch()
		#expect(try OrganizationRows(a.organization) == before)
		// The workspace's 7 rows and this Mac's device row (DEV-980).
		#expect(cloud.records(.organization).count == 8)
	}

	@Test
	func deleteFromICloudRefusesAnotherAccount() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		try await a.send()

		// Account B signed in while the confirmation was open.
		a.account.setValue(.available("account-b"))

		await #expect(throws: WorkspaceSync.DeleteFailure.self) {
			try await a.sync.deleteFromICloud(.organization)
		}
		#expect(cloud.hasZone(.organization))
		#expect(await a.sync.currentSettings.pendingResets.isEmpty)
	}

	@Test
	func aFailedDeleteFromICloudKeepsSyncing() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		try await a.send()
		cloud.failsZoneDeletion.setValue(true)

		await #expect(throws: (any Error).self) {
			try await a.sync.deleteFromICloud(.organization)
		}
		#expect(cloud.hasZone(.organization))
		#expect(await a.sync.engine(.organization)?.isRunning == true)
		#expect(await a.sync.status[.organization] == .synced)
	}

	@Test
	func aDeletedCategoryIsResetBeforeItCanStartAgain() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		try await a.send()

		try await a.sync.deleteFromICloud(.organization)
		let settings: SyncSettings = try SyncSettingsStore(directory: a.directory).load()
		#expect(settings.disabledCategories.contains(.organization))
		#expect(settings.pendingResets.isEmpty)

		// Turning the other category off and on mid-way never restarts the deleted one.
		await a.sync.setCategory(.preferences, isEnabled: false)
		await a.sync.setCategory(.preferences, isEnabled: true)
		#expect(await a.sync.engine(.organization)?.isRunning == false)
		#expect(!cloud.hasZone(.organization))
	}

	@Test
	func aDeleteWhoseReplyIsLostNeverDeletesThisMacsRows() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		defer { a.remove() }

		try seed(a)
		await a.sync.setEnabled(true)
		try await a.send()
		let before: OrganizationRows = try .init(a.organization)
		cloud.losesZoneDeletionReply.setValue(true)

		await #expect(throws: (any Error).self) {
			try await a.sync.deleteFromICloud(.organization)
		}
		#expect(!cloud.hasZone(.organization))
		// The engine restarted with nothing it knew of the zone, so it has no change token from which
		// CloudKit would report the deletion: it uploads every row again and this Mac's rows stay.
		try await a.send()
		try await a.fetch()
		#expect(try OrganizationRows(a.organization) == before)
		// The workspace's 7 rows and this Mac's device row (DEV-980).
		#expect(cloud.records(.organization).count == 8)
		#expect(try SyncSettingsStore(directory: a.directory).load().pendingResets.isEmpty)
	}

	/// The library's documented gap (ADR 0001, open question 1): a Mac that learns another deleted the
	/// zone deletes every row it got from it. Settings says so before Delete from iCloud.
	@Test
	func otherMacsDeleteTheRowsOfADeletedZone() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud)
		let b: TestMac = try .init(cloud: cloud)
		defer {
			a.remove()
			b.remove()
		}

		try seed(a)
		await a.sync.setEnabled(true)
		await b.sync.setEnabled(true)
		try await converge(a, b)
		#expect(try OrganizationRows(b.organization).profiles.count == 1)

		try await a.sync.deleteFromICloud(.organization)
		await b.zoneDeletedElsewhere(.organization)

		#expect(try OrganizationRows(b.organization).profiles.isEmpty)
		#expect(try PreferenceRows(b.preferences).preferences.count == 1)
	}

	// MARK: - Status

	@Test
	func overallStatusShowsTheMostPressingCategory() {
		var status: WorkspaceSyncStatus = .init(
			isEnabled: true,
			categories: [.organization: .synced, .preferences: .syncing]
		)
		#expect(status.overall == .syncing)
		status.categories[.preferences] = .paused(.quotaExceeded)
		#expect(status.overall == .paused(.quotaExceeded))
		status.categories[.organization] = .error("Offline")
		#expect(status.overall == .error("Offline"))
		status.review = .signedOut
		#expect(status.overall == .paused(.noAccount))
		status.review = .accountChanged
		#expect(status.overall == .accountChanged)
		status.isEnabled = false
		#expect(status.overall == .off)
	}
}
