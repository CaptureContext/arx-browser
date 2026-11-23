import BrowserCore
import CloudKit
import ConcurrencyExtras
import Foundation
@testable import SQLiteData
import Testing
import WorkspaceDatabase
@testable import WorkspaceSync
import _TestSupport

/// Two Macs over the test cloud merging what matches (DEV-1216): a Mac turning sync on with its own
/// workspace, and two synced profiles merged from Settings.
@Suite(.dependency(\.uuid, .incrementing), .timeLimit(.minutes(1)))
struct JoinMergeTests {
	// A's workspace, in iCloud first.
	private let aProfile: UUID = UUID(1)
	private let aHome: UUID = UUID(10)
	private let aWork: UUID = UUID(11)

	// B's own, touched: the same profile and spaces, with more in them.
	private let bProfile: UUID = UUID(101)
	private let bHome: UUID = UUID(110)
	private let bWork: UUID = UUID(111)
	private let bSide: UUID = UUID(112)

	private func seedA(_ mac: TestMac) throws {
		try edit(mac.organization) { db in
			try db.seed {
				ProfileRecord(id: aProfile, name: "Default", position: "V", isStarter: true)
				SpaceRecord(id: aHome, profileID: aProfile, name: "Home", position: "V", isStarter: true)
				SpaceRecord(id: aWork, profileID: aProfile, name: "Work", position: "W")
				PinnedTabRecord(id: UUID(20), spaceID: aHome, title: "Mail", url: "https://mail.example", position: "V")
				PinnedTabRecord(id: UUID(21), spaceID: aWork, title: "Tracker", url: "https://tracker.example", position: "V")
			}
		}
	}

	private func seedB(_ mac: TestMac) throws {
		try edit(mac.organization) { db in
			try db.seed {
				ProfileRecord(id: bProfile, name: "Default", position: "V", isStarter: true)
				SpaceRecord(id: bHome, profileID: bProfile, name: "Home", position: "V", isStarter: true)
				SpaceRecord(id: bWork, profileID: bProfile, name: "Work", position: "W")
				SpaceRecord(id: bSide, profileID: bProfile, name: "Side", position: "X")
				PinnedTabRecord(id: UUID(120), spaceID: bHome, title: "Mail", url: "https://Mail.example/", position: "V")
				PinnedTabRecord(id: UUID(121), spaceID: bWork, title: "Tracker", url: "https://tracker.example", position: "V")
				PinnedTabRecord(id: UUID(122), spaceID: bWork, title: "Board", url: "https://board.example", position: "W")
				RegularTabRecord(id: UUID(130), spaceID: bWork, position: "V")
			}
		}
	}

	/// The records iCloud has of these IDs.
	private func inCloud(
		_ cloud: TestCloud,
		_ ids: Set<UUID>
	) -> Set<UUID> {
		Set(cloud.records(.organization).compactMap { record in
			record.recordID.recordName.split(separator: ":").first.flatMap { UUID(uuidString: String($0)) }
		})
		.intersection(ids)
	}

	@Test
	func aJoiningMacMergesItsWorkspaceIntoICloudsAfterThePreview() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		let b: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		defer {
			a.remove()
			b.remove()
		}
		try seedA(a)
		try seedB(b)

		// The first Mac has nothing to merge with.
		await a.sync.setEnabled(true)
		#expect(await a.sync.status.mergePreview == nil)
		try await a.send()

		await b.sync.setEnabled(true)

		// B waits for the person, with nothing started and nothing sent.
		let preview: MergePreview? = await b.sync.status.mergePreview
		#expect(preview?.kind == .joining)
		#expect(await b.sync.status[.organization] == .paused(.mergeReview))
		#expect(await b.sync.engine(.organization)?.isRunning != true)
		#expect(inCloud(cloud, [bProfile, bHome, bWork, bSide]).isEmpty)

		let plan: WorkspaceMerge.Plan = try #require(preview?.plan)
		#expect(plan.profiles.map(\.keptID) == [aProfile])
		#expect(plan.profiles.first?.addedSpaces.map(\.name) == ["Side"])
		#expect(plan.profiles.first?.spaces.first { $0.keptID == aWork }?.pins == .init(total: 2, new: 1))

		await b.sync.confirmMerge(keepingSeparate: [])
		#expect(await b.sync.status.mergePreview == nil)
		try await converge(a, b)

		// One profile and one space each, pins united and none lost, on both Macs.
		let rows: OrganizationRows = try OrganizationRows(a.organization)
		#expect(try OrganizationRows(b.organization) == rows)
		#expect(rows.profiles.map(\.id) == [aProfile])
		#expect(Set(rows.spaces.map(\.id)) == [aHome, aWork, bSide])
		#expect(Set(rows.pinnedTabs.map(\.id)) == [UUID(20), UUID(21), UUID(122)])
		#expect(rows.pinnedTabs.first { $0.id == UUID(122) }?.spaceID == aWork)
		// B's own ever reached iCloud only as what it merged into.
		#expect(inCloud(cloud, [bProfile, bHome, bWork]).isEmpty)

		try await b.organization.read { (db: Database) throws in

			// B's open tab is in the merged space, and its website data under A's profile's ID.
			#expect(try RegularTabRecord.find(UUID(130)).fetchOne(db)?.spaceID == aWork)
			#expect(try ProfileStorageRecord.aliases(db) == [aProfile: bProfile])
		}
		try await a.organization.read { (db: Database) throws in
			#expect(try ProfileStorageRecord.aliases(db).isEmpty)
		}
	}

	@Test
	func aMatchKeptSeparateIsAddedWithTheMacsName() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		let b: TestMac = try .init(cloud: cloud, name: "MacBook Air", mergesWhenJoining: true)
		defer {
			a.remove()
			b.remove()
		}
		try seedA(a)
		try seedB(b)
		await a.sync.setEnabled(true)
		try await a.send()

		await b.sync.setEnabled(true)
		#expect(await b.sync.status.mergePreview?.plan.profiles.first?.spaces.first { $0.mergedID == bWork }?.separateName == "Work (MacBook Air)")
		await b.sync.confirmMerge(keepingSeparate: [bWork])
		try await converge(a, b)

		let rows: OrganizationRows = try OrganizationRows(a.organization)
		#expect(try OrganizationRows(b.organization) == rows)
		#expect(rows.profiles.map(\.id) == [aProfile])
		#expect(Set(rows.spaces.map(\.id)) == [aHome, aWork, bWork, bSide])
		#expect(rows.spaces.first { $0.id == bWork }?.name == "Work (MacBook Air)")
		#expect(rows.spaces.first { $0.id == bWork }?.profileID == aProfile)
		// Its pins stay in it.
		#expect(Set(rows.pinnedTabs.filter { $0.spaceID == bWork }.map(\.id)) == [UUID(121), UUID(122)])
	}

	@Test
	func cancelTurnsSyncOffWithNothingSent() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		let b: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		defer {
			a.remove()
			b.remove()
		}
		try seedA(a)
		try seedB(b)
		await a.sync.setEnabled(true)
		try await a.send()
		let before: OrganizationRows = try OrganizationRows(b.organization)

		await b.sync.setEnabled(true)
		#expect(await b.sync.status.mergePreview != nil)
		await b.sync.cancelMerge()

		#expect(await b.sync.status.isEnabled == false)
		#expect(await b.sync.status.mergePreview == nil)
		#expect(inCloud(cloud, [bProfile, bHome, bWork, bSide, UUID(122)]).isEmpty)
		#expect(try OrganizationRows(b.organization) == before)
	}

	@Test
	func anUntouchedStarterMergesWithoutAPreview() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		let b: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		defer {
			a.remove()
			b.remove()
		}
		try seedA(a)
		try edit(b.organization) { db in
			try db.seed {
				ProfileRecord(id: bProfile, name: "Default", position: "V", isStarter: true)
				SpaceRecord(id: bHome, profileID: bProfile, name: "Home", position: "V", isStarter: true)
			}
		}
		await a.sync.setEnabled(true)
		try await a.send()

		await b.sync.setEnabled(true)
		#expect(await b.sync.status.mergePreview == nil)
		try await converge(a, b)

		let rows: OrganizationRows = try OrganizationRows(b.organization)
		#expect(try OrganizationRows(a.organization) == rows)
		#expect(rows.profiles.map(\.id) == [aProfile])
		#expect(Set(rows.spaces.map(\.id)) == [aHome, aWork])
		// Nothing left for the app to offer removing (DEV-989).
		#expect(await b.sync.duplicateStarterProfiles().isEmpty)
	}

	@Test
	func offlineNothingStartsUntilICloudCanSayWhatItHas() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		let b: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		defer {
			a.remove()
			b.remove()
		}
		try seedA(a)
		try seedB(b)
		await a.sync.setEnabled(true)
		try await a.send()

		cloud.isOffline.setValue(true)
		await b.sync.setEnabled(true)
		#expect(await b.sync.status.mergePreview == nil)
		#expect(await b.sync.engine(.organization)?.isRunning != true)
		#expect(await b.sync.engine(.preferences)?.isRunning != true)
		#expect(inCloud(cloud, [bProfile, bHome, bWork, bSide]).isEmpty)

		// Online again, the account retry reads iCloud and shows the preview.
		cloud.isOffline.setValue(false)
		var preview: MergePreview?
		for _ in 0 ..< 200 where preview == nil {
			try await Task.sleep(for: .milliseconds(10))
			preview = await b.sync.status.mergePreview
		}
		#expect(preview?.kind == .joining)
	}

	@Test
	func syncedProfilesOfTheSameNameMergeFromSettingsOnEveryMac() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)

		// B turned sync on before merging existed: its Default was copied beside A's.
		let b: TestMac = try .init(cloud: cloud)
		defer {
			a.remove()
			b.remove()
		}
		try seedA(a)
		try edit(b.organization) { db in
			try db.seed {
				ProfileRecord(id: bProfile, name: "Default", position: "V")
				SpaceRecord(id: bHome, profileID: bProfile, name: "Home", position: "V")
				PinnedTabRecord(id: UUID(120), spaceID: bHome, title: "Mail", url: "https://mail.example/", position: "V")
				PinnedTabRecord(id: UUID(121), spaceID: bHome, title: "Chat", url: "https://chat.example", position: "W")
				RegularTabRecord(id: UUID(130), spaceID: bHome, position: "V")
			}
		}
		await a.sync.setEnabled(true)
		try await a.send()
		await b.sync.setEnabled(true)
		try await converge(a, b)
		#expect(try OrganizationRows(a.organization).profiles.map(\.id) == [aProfile, bProfile])

		await a.sync.refreshStatus()
		#expect(await a.sync.status.duplicateProfiles == [.init(name: "Default", profileIDs: [aProfile, bProfile])])
		await a.sync.previewProfileMerge([aProfile, bProfile])
		let preview: MergePreview? = await a.sync.status.mergePreview
		#expect(preview?.kind == .profiles)
		#expect(preview?.plan.profiles.map(\.keptID) == [aProfile])
		#expect(preview?.plan.profiles.first?.spaces.first?.pins == .init(total: 2, new: 1))

		await a.sync.confirmMerge(keepingSeparate: [])
		#expect(await a.sync.status.mergePreview == nil)
		try await converge(a, b)

		// Both Macs show one Default with every pin; B's tab followed, and B keeps its website data.
		for mac in [a, b] {
			let shown: WorkspaceMerge.Snapshot = try await mac.organization.read { db in try .init(db) }
			#expect(shown.profiles.map(\.id) == [aProfile])
			#expect(Set(shown.spaces.map(\.id)) == [aHome, aWork])
			#expect(Set(shown.pinnedTabs.map(\.id)) == [UUID(20), UUID(21), UUID(121)])
		}
		try await b.organization.read { (db: Database) throws in
			#expect(try RegularTabRecord.find(UUID(130)).fetchOne(db)?.spaceID == aHome)
			#expect(try ProfileStorageRecord.aliases(db) == [aProfile: bProfile])
		}
		try await a.organization.read { (db: Database) throws in
			#expect(try ProfileStorageRecord.aliases(db).isEmpty)
		}
		#expect(await a.sync.status.duplicateProfiles.isEmpty)
	}

	@Test
	internal func aPreviewICloudChangedSinceIsShownAgainInsteadOfApplied() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		let b: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		defer {
			a.remove()
			b.remove()
		}
		try seedA(a)
		try seedB(b)
		await a.sync.setEnabled(true)
		try await a.send()

		await b.sync.setEnabled(true)
		let first: WorkspaceMerge.Plan? = await b.sync.status.mergePreview?.plan
		#expect(first?.profiles.first?.addedSpaces.map(\.name) == ["Side"])

		// Meanwhile A renames Work: B's Work would be added, which the person didn't see.
		try edit(a.organization) { db in
			try SpaceRecord.find(aWork).update { $0.name = "Jobs" }.execute(db)
		}
		try await a.send()
		await b.sync.confirmMerge(keepingSeparate: [])

		let again: WorkspaceMerge.Plan? = await b.sync.status.mergePreview?.plan
		#expect(again != nil)
		#expect(again != first)
		#expect(again?.profiles.first?.addedSpaces.map(\.name).contains("Work") == true)
		// Nothing started meanwhile, so nothing uploaded before the answer.
		#expect(await b.sync.engine(.organization)?.isRunning != true)
		#expect(await b.sync.engine(.preferences)?.isRunning != true)
		#expect(try OrganizationRows(b.organization).profiles.map(\.id) == [bProfile])

		await b.sync.confirmMerge(keepingSeparate: [])
		#expect(await b.sync.status.mergePreview == nil)
		try await converge(a, b)
		#expect(try OrganizationRows(a.organization) == OrganizationRows(b.organization))
		#expect(try Set(OrganizationRows(b.organization).spaces.map(\.name)) == ["Home", "Jobs", "Work", "Side"])
	}

	@Test
	internal func aJoinMergeThatFailsStartsNothing() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		let b: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		defer {
			a.remove()
			b.remove()
		}
		try seedA(a)
		try seedB(b)
		await a.sync.setEnabled(true)
		try await a.send()
		await b.sync.setEnabled(true)
		#expect(await b.sync.status.mergePreview != nil)

		// iCloud can't be read when the answer comes.
		cloud.isOffline.setValue(true)
		await b.sync.confirmMerge(keepingSeparate: [])
		#expect(await b.sync.engine(.organization)?.isRunning != true)
		#expect(await b.sync.engine(.preferences)?.isRunning != true)
		#expect(try OrganizationRows(b.organization).profiles.map(\.id) == [bProfile])

		// Online again, the retry merges what the person approved, then starts the rest: the device
		// directory last.
		cloud.isOffline.setValue(false)
		var isDone: Bool = false
		for _ in 0 ..< 300 where !isDone {
			try await Task.sleep(for: .milliseconds(10))
			let preferences: Bool = await b.sync.engine(.preferences)?.isRunning == true
			let directory: Bool = await b.sync.directoryEngineForDiagnostics()?.isRunning == true
			isDone = preferences && directory
		}
		#expect(isDone)
		#expect(await b.sync.engine(.organization)?.isRunning == true)
		try await converge(a, b)
		#expect(try OrganizationRows(b.organization).profiles.map(\.id) == [aProfile])
		#expect(try OrganizationRows(a.organization) == OrganizationRows(b.organization))
	}

	/// DEV-1215's onboarding keeps the first launch's Default "this Mac only" while it joins: the
	/// merge leaves it out, so nothing needs review and nothing of it uploads.
	@Test
	internal func aThisMacOnlyDefaultStaysOutOfTheJoin() async throws {
		let cloud: TestCloud = .init()
		let a: TestMac = try .init(cloud: cloud, mergesWhenJoining: true)
		defer { a.remove() }
		try seedA(a)
		await a.sync.setEnabled(true)
		try await a.send()

		let directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("JoinMergeTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		let provisional: Profile.ID = .init(rawValue: UUID(201))
		try store.save(
			BrowserOrganization(
				profiles: [.init(id: provisional, name: "Default", syncsWithICloud: false)],
				legacyProfileID: provisional,
				spaces: [.init(id: .init(rawValue: UUID(202)), profileID: provisional, name: "Home")],
				tabs: []
			),
			preferences: .init()
		)
		let sync: WorkspaceSync = try .init(
			organization: store.database,
			preferences: try #require(store.preferencesDatabase),
			settings: SyncSettingsStore(directory: directory),
			cloud: CloudAccess(
				account: { .available("account-a") },
				deleteZone: { _ in },
				placements: { records in try cloud.placements(records) },
				recordValues: { zoneName, recordNames in try cloud.recordValues(zoneName, recordNames) },
				zoneRecords: { zoneName, fields in try cloud.zoneRecords(zoneName, fields) }
			),
			makeEngine: cloud.makeEngine(),
			deviceName: { "New Mac" },
			accountRetryDelay: .milliseconds(20),
			mergesWhenJoining: true
		)

		await sync.setEnabled(true)
		#expect(await sync.status.mergePreview == nil)
		#expect(await sync.engine(.organization)?.isRunning == true)
		try await sync.engine(.organization)?.sendChanges()
		try await sync.engine(.organization)?.fetchChanges()
		try await sync.repair(.organization)

		#expect(inCloud(cloud, [UUID(201), UUID(202)]).isEmpty)
		let organization: BrowserOrganization? = try store.load()?.organization
		#expect(Set(organization?.profiles.map(\.id.rawValue) ?? []) == [aProfile, UUID(201)])
		#expect(organization?.profiles.first { $0.id == provisional }?.syncsWithICloud == false)
	}

	/// The app saved, the merge replaced its profile and space, then a save it made from the
	/// workspace it read before (a renamed space) reaches the store before it reads again.
	@Test
	internal func aSaveFromBeforeTheMergeLandsOnTheKeptItems() async throws {
		let directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("JoinMergeTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		let profile: Profile.ID = .init(rawValue: UUID(201))
		let work: Space.ID = .init(rawValue: UUID(202))
		let pin: BrowserCore.Tab.ID = .init(rawValue: UUID(203))
		let open: BrowserCore.Tab.ID = .init(rawValue: UUID(204))
		func organization(workName: String, openTitle: String? = nil, unpinned: Bool = false) -> BrowserOrganization {
			.init(
				profiles: [.init(id: profile, name: "Default")],
				legacyProfileID: profile,
				spaces: [
					.init(
						id: work,
						profileID: profile,
						name: workName,
						savedItems: unpinned ? [] : [.tab(pin)],
						unpinnedTabs: unpinned ? [pin, open] : [open],
						selectedTabID: open
					)
				],
				tabs: [
					.init(
						id: pin,
						profileID: profile,
						savedDestination: unpinned ? nil : .init(title: "Tracker", url: URL(string: "https://tracker.example")!),
						restoration: .init(title: "Tracker", url: URL(string: "https://tracker.example")!)
					),
					.init(id: open, profileID: profile, restoration: .init(title: "Open", url: URL(string: "https://open.example")!), customTitle: openTitle),
				]
			)
		}
		try store.save(organization(workName: "Work"), preferences: .init())

		// iCloud's Default has a Work with the same pin, and its own icon.
		let cloud: WorkspaceMerge.Snapshot = .init(
			profiles: [ProfileRecord(id: aProfile, name: "Default", position: "V")],
			spaces: [SpaceRecord(id: aWork, profileID: aProfile, name: "Work", icon: #""briefcase""#, position: "V")],
			pinnedTabs: [PinnedTabRecord(id: UUID(21), spaceID: aWork, title: "Tracker", url: "https://tracker.example", position: "V")]
		)
		try await store.database.writeAllowingSyncedDeletions { db in
			let matching: WorkspaceMerge.Matching = WorkspaceMerge.match(local: try .init(db), cloud: cloud, macName: "Mac")
			#expect(matching.spaces == [UUID(202): aWork])
			try WorkspaceMerge.applyJoining(matching, cloud: cloud, db)
		}

		// The save from before: the space renamed, the open tab retitled.
		try store.save(organization(workName: "Jobs", openTitle: "Mine"), preferences: .init())

		try await store.database.read { (db: Database) throws in
			#expect(try ProfileRecord.all.fetchAll(db).map(\.id) == [aProfile])
			let space: SpaceRecord? = try SpaceRecord.find(aWork).fetchOne(db)
			#expect(space?.name == "Jobs")
			// Only what the person changed: iCloud's icon stays.
			#expect(space?.icon == #""briefcase""#)
			#expect(try SpaceRecord.find(UUID(202)).fetchOne(db) == nil)
			#expect(try RegularTabRecord.find(UUID(204)).fetchOne(db)?.spaceID == aWork)
			#expect(try RegularTabRecord.find(UUID(204)).fetchOne(db)?.customTitle == "Mine")
		}

		// Reading again takes the kept items, and a save from there lands as it is.
		let loaded: BrowserOrganization? = try store.load()?.organization
		#expect(loaded?.profiles.map(\.id.rawValue) == [aProfile])
		#expect(loaded?.spaces.map(\.name) == ["Jobs"])
		var renamed: BrowserOrganization = try #require(loaded)
		renamed.spaces[0].name = "Projects"
		try store.save(renamed, preferences: .init())
		try await store.database.read { (db: Database) throws in
			#expect(try SpaceRecord.find(aWork).fetchOne(db)?.name == "Projects")
			// Kept until sync's next launch: another store may still save from before the merge.
			#expect(try MergeRemapRecord.all.fetchCount(db) > 0)
		}
		try await store.database.write { db in try MergeRemapRecord.forget(db) }
		#expect(try await store.database.read { db in try MergeRemapRecord.all.fetchCount(db) } == 0)
	}

	/// A save from before the merge that unpins the tab the merge replaced with iCloud's pin.
	@Test
	internal func aSaveFromBeforeTheMergeUnpinningTheMergedTabStillLoads() async throws {
		let directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("JoinMergeTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { TestFolders.removeAtExit(directory) }
		let store: WorkspaceDatabase = try .init(directory: directory, separatePreferencesConnection: true)
		let profile: Profile.ID = .init(rawValue: UUID(201))
		let work: Space.ID = .init(rawValue: UUID(202))
		let pin: BrowserCore.Tab.ID = .init(rawValue: UUID(203))
		let url: URL = URL(string: "https://tracker.example")!
		func organization(pinned: Bool) -> BrowserOrganization {
			.init(
				profiles: [.init(id: profile, name: "Default")],
				legacyProfileID: profile,
				spaces: [
					.init(id: work, profileID: profile, name: "Work", savedItems: pinned ? [.tab(pin)] : [], unpinnedTabs: pinned ? [] : [pin])
				],
				tabs: [
					.init(
						id: pin,
						profileID: profile,
						savedDestination: pinned ? .init(title: "Tracker", url: url) : nil,
						restoration: .init(title: "Tracker", url: url)
					)
				]
			)
		}
		try store.save(organization(pinned: true), preferences: .init())
		let cloud: WorkspaceMerge.Snapshot = .init(
			profiles: [ProfileRecord(id: aProfile, name: "Default", position: "V")],
			spaces: [SpaceRecord(id: aWork, profileID: aProfile, name: "Work", position: "V")],
			pinnedTabs: [PinnedTabRecord(id: UUID(21), spaceID: aWork, title: "Tracker", url: "https://tracker.example", position: "V")]
		)
		try await store.database.writeAllowingSyncedDeletions { db in
			try WorkspaceMerge.applyJoining(WorkspaceMerge.match(local: try .init(db), cloud: cloud, macName: "Mac"), cloud: cloud, db)
		}

		try store.save(organization(pinned: false), preferences: .init())

		try await store.database.read { (db: Database) throws in
			#expect(try RegularTabRecord.find(UUID(21)).fetchOne(db)?.spaceID == aWork)
			#expect(try RegularTabRecord.find(UUID(203)).fetchOne(db) == nil)
		}
		let loaded: BrowserOrganization? = try store.load()?.organization
		#expect(loaded?.spaces.first?.unpinnedTabs.map(\.rawValue) == [UUID(21)])
	}
}
