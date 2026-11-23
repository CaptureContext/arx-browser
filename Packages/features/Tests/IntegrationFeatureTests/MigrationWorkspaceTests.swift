import BrowserCore
import BrowserEngineClient
import BrowserHistoryClient
import BrowserSiteIconClient
import CustomDump
import Foundation
import MainFeature
import MigrationAssistant
import Testing
import _ComposableArchitecture
import _TestSupport
@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct MigrationWorkspaceTests {
	private static let profile = MigrationSourceProfile(id: "Default", name: "Personal")
	private static let space = MigrationSourceSpace(id: "Default/s1", name: "Home", profile: profile)

	private func batch(_ destination: MigrationDestination) -> MigrationBatch {
		.init(
			planID: .init(rawValue: UUID(900)),
			destination: destination,
			sourceName: "Arc",
			category: .bookmarks,
			items: [
				.init(
					key: .init(sourceID: .init(rawValue: "arc"), category: .bookmarks, sourceItemID: "a"),
					title: "Swift",
					url: URL(string: "https://swift.org")!,
					space: Self.space,
					profile: Self.profile
				),
			]
		)
	}

	private func fixture(
		prepared: LockIsolated<[Profile.ID]> = .init([]),
		preparationFails: Bool = false
	) -> (StoreOf<AppFeature>, MigrationDestination) {
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.uuid = .init { UUID() }
			$0.browserEngine.prepareProfile = { id in
				if preparationFails { throw CancellationError() }
				prepared.withValue { $0.append(id) }
			}
		}
		let destination = MigrationDestination(
			profileID: organization.spaces[0].profileID,
			spaceID: organization.spaces[0].id,
			defaultRoute: .newProfile
		)
		return (store, destination)
	}

	@Test
	internal func aCommitPreparesTheNewProfileThenPublishesAndSavesItWithTheLedger() async {
		let prepared = LockIsolated<[Profile.ID]>([])
		let (store, destination) = fixture(prepared: prepared)

		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(destination))))).finish()

		let created = store.workspace.profiles.last
		expectNoDifference(created?.name, "Personal")
		expectNoDifference(prepared.value, [created!.id])
		expectNoDifference(store.main.sidebar.organization.profiles.last?.name, "Personal")
		expectNoDifference(store.migrationLedger.createdProfiles["Default"], created?.id)
		expectNoDifference(store.migrationCommit, UUID(901))

		await store.send(.event(.saveSucceeded(store.workspace, store.persistedPreferences))).finish()
		expectNoDifference(store.migrationCommit, nil)
	}

	@Test
	internal func importedTabsBringTheirIconsAndSpacesTheirColors() async throws {
		let seeded = LockIsolated<[BrowserSiteIconKey: Data]>([:])
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.uuid = .init { UUID() }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserSiteIcons.seed = { icons in seeded.withValue { $0.merge(icons) { $1 } } }
		}
		let destination = MigrationDestination(
			profileID: organization.spaces[0].profileID,
			spaceID: organization.spaces[0].id,
			defaultRoute: .newProfile
		)
		let appearance = AppearanceOverride(tintHue: 20, tintIntensity: 0.8)
		var space = Self.space
		space.appearance = appearance
		var batch = batch(destination)
		batch.items[0].space = space
		batch.items[0].icon = Data([0x89, 0x50])

		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch)))).finish()

		// DEV-897: the new space takes the source's colors, and its tab the source's icon.
		let created = try #require(store.workspace.spaces.first { $0.name == "Home" })
		expectNoDifference(created.appearance, appearance)
		expectNoDifference(
			seeded.value,
			[.init(profileID: created.profileID, pageURL: URL(string: "https://swift.org")!): Data([0x89, 0x50])]
		)
	}

	@Test
	internal func iconsStayWithTheProfileTheirTabLandedIn() async throws {
		let seeded = LockIsolated<[BrowserSiteIconKey: Data]>([:])
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.uuid = .init { UUID() }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserSiteIcons.seed = { icons in seeded.withValue { $0.merge(icons) { $1 } } }
		}
		let destination = MigrationDestination(
			profileID: organization.spaces[0].profileID,
			spaceID: organization.spaces[0].id,
			defaultRoute: .newProfile
		)
		let work = MigrationSourceProfile(id: "Profile 1", name: "Work")
		let workSpace = MigrationSourceSpace(id: "Profile 1/s2", name: "Job", profile: work)
		let url = URL(string: "https://mail.example.org")!
		let batch = MigrationBatch(
			planID: .init(rawValue: UUID(900)),
			destination: destination,
			sourceName: "Arc",
			category: .bookmarks,
			items: [
				.init(
					key: .init(sourceID: .init(rawValue: "arc"), category: .bookmarks, sourceItemID: "a"),
					title: "Mail", url: url, space: Self.space, profile: Self.profile, icon: Data([1])
				),
				.init(
					key: .init(sourceID: .init(rawValue: "arc"), category: .bookmarks, sourceItemID: "b"),
					title: "Mail", url: url, space: workSpace, profile: work, icon: Data([2])
				),
			]
		)

		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch)))).finish()

		let personal = try #require(store.workspace.profiles.first { $0.name == "Personal" })
		let job = try #require(store.workspace.profiles.first { $0.name == "Work" })
		expectNoDifference(seeded.value, [
			.init(profileID: personal.id, pageURL: url): Data([1]),
			.init(profileID: job.id, pageURL: url): Data([2]),
		])
	}

	/// A saved tab shows the page it's on and, once closed, its saved page (DEV-1294). Each page
	/// keeps its own imported icon; a page with none borrows the other's only on the same site.
	@Test
	internal func aSavedTabsPagesEachKeepTheirOwnImportedIcon() async throws {
		let seeded = LockIsolated<[BrowserSiteIconKey: Data]>([:])
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.uuid = .init { UUID() }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserSiteIcons.seed = { icons in seeded.withValue { $0.merge(icons) { $1 } } }
		}
		let destination = MigrationDestination(
			profileID: organization.spaces[0].profileID,
			spaceID: organization.spaces[0].id,
			defaultRoute: .newProfile
		)
		let mail = URL(string: "https://mail.example.org")!
		let inbox = URL(string: "https://mail.example.org/inbox")!
		let news = URL(string: "https://news.example.org")!
		let article = URL(string: "https://elsewhere.example.net/article")!
		let lists = URL(string: "https://lists.example.org")!
		let thread = URL(string: "https://lists.example.org/thread")!
		func item(
			_ id: String,
			_ url: URL,
			current: URL?,
			icon: UInt8
		) -> MigrationItem {
			var item = MigrationItem(
				key: .init(sourceID: .init(rawValue: "arc"), category: .bookmarks, sourceItemID: id),
				title: id, url: url, space: Self.space, profile: Self.profile, icon: Data([icon])
			)
			item.currentURL = current
			return item
		}
		let batch = MigrationBatch(
			planID: .init(rawValue: UUID(900)),
			destination: destination,
			sourceName: "Arc",
			category: .bookmarks,
			items: [
				// Its current page, on the same site, has no icon of its own: it borrows the saved one.
				item("mail", mail, current: inbox, icon: 1),
				// Its current page is another site's: that page gets nothing from this one.
				item("news", news, current: article, icon: 2),
				// Both pages have icons: each keeps its own.
				item("lists", lists, current: thread, icon: 3),
				item("thread", thread, current: nil, icon: 4),
			]
		)

		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch)))).finish()

		let created = try #require(store.workspace.spaces.first { $0.name == "Home" })
		func key(_ url: URL) -> BrowserSiteIconKey { .init(profileID: created.profileID, pageURL: url) }
		expectNoDifference(seeded.value, [
			key(mail): Data([1]),
			key(inbox): Data([1]),
			key(news): Data([2]),
			key(lists): Data([3]),
			key(thread): Data([4]),
		])
	}

	@Test
	internal func anUnrelatedSaveDoesNotAnswerACommit() async {
		let (store, destination) = fixture()
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(destination))))).finish()

		await store.send(.event(.saveSucceeded(IntegrationFeatureTests().fixture(), .init()))).finish()

		expectNoDifference(store.migrationCommit, UUID(901))
	}

	@Test
	internal func aFailedProfilePreparationChangesNothing() async {
		let (store, destination) = fixture(preparationFails: true)
		let before = store.workspace

		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch(destination))))).finish()

		expectNoDifference(store.workspace, before)
		expectNoDifference(store.migrationLedger, .init())
		expectNoDifference(store.migrationCommit, nil)
	}

	@Test
	internal func aWorkspaceThatChangedDuringPreparationRefusesTheCommit() async throws {
		let (store, destination) = fixture()
		let previous = store.workspace
		var ledger = MigrationLedger()
		var nextID = 950
		let updated = try previous.applyingMigration(batch(destination), ledger: &ledger) {
			nextID += 1
			return UUID(nextID)
		}
		let createProfile = OrganizationChange.createProfile(.init(rawValue: UUID(960)), name: "Other")
		await store.send(.settings(.delegate(.changeOrganization(createProfile)))).finish()
		#expect(store.workspace != previous)

		await store.send(.migrationWorkspace(.approved(UUID(901), previous, updated, ledger, nil))).finish()

		#expect(store.workspace != updated)
		expectNoDifference(store.migrationCommit, nil)
	}

	@Test
	internal func aHistoryCommitWritesTheHistoryStoreBeforePublishingItsLedger() async throws {
		let merged = LockIsolated<[Profile.ID: [URL]]>([:])
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.uuid = .init { UUID() }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserHistory = .init(merge: { profile, entries in
				merged.withValue { $0[profile, default: []] += entries.map(\.url) }
				return .init(snapshot: .init(profileID: profile))
			})
		}
		let destination = MigrationDestination(
			profileID: organization.spaces[0].profileID,
			spaceID: organization.spaces[0].id,
			defaultRoute: .newProfile
		)
		let batch = MigrationBatch(
			planID: .init(rawValue: UUID(900)),
			destination: destination,
			sourceName: "Archive",
			category: .history,
			items: [
				.init(
					key: .init(sourceID: .init(rawValue: "arx-archive"), category: .history, sourceItemID: "h1"),
					title: "Visited",
					url: URL(string: "https://visited.example.org")!,
					profile: Self.profile,
					lastVisited: Date(timeIntervalSince1970: 10)
				),
			]
		)

		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch)))).finish()

		let created = try #require(store.workspace.profiles.last)
		expectNoDifference(created.name, "Personal")
		expectNoDifference(merged.value, [created.id: [URL(string: "https://visited.example.org")!]])
		#expect(store.migrationLedger.importedItems[created.id.rawValue.uuidString]?.isEmpty == false)
		expectNoDifference(store.migrationCommit, UUID(901))
	}

	@Test
	internal func aFailedHistoryWriteChangesNothing() async {
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.uuid = .init { UUID() }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserHistory = .init(merge: { _, _ in throw BrowserHistoryClient.Failure.writeFailed })
		}
		let destination = MigrationDestination(
			profileID: organization.spaces[0].profileID,
			spaceID: organization.spaces[0].id
		)
		let batch = MigrationBatch(
			planID: .init(rawValue: UUID(900)),
			destination: destination,
			sourceName: "Archive",
			category: .history,
			items: [
				.init(
					key: .init(sourceID: .init(rawValue: "arx-archive"), category: .history, sourceItemID: "h1"),
					title: "Visited",
					url: URL(string: "https://visited.example.org")!,
					lastVisited: Date(timeIntervalSince1970: 10)
				),
			]
		)
		let before = store.workspace

		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch)))).finish()

		expectNoDifference(store.workspace, before)
		expectNoDifference(store.migrationLedger, .init())
		expectNoDifference(store.migrationCommit, nil)
	}

	@Test
	internal func aPreferencesCommitReachesTheWindowsAndSaves() async {
		let (store, destination) = fixture()
		var exported = BrowserPreferences()
		exported.grainIntensity = 0.5
		exported.searchShortcuts.append(
			.init(name: "Other", keyword: "other", template: "https://other.example/?q={query}")
		)
		let key = MigrationItemKey(sourceID: .init(rawValue: "arx-archive"), category: .preferences, sourceItemID: "digest")

		let batch = MigrationBatch(
			planID: .init(rawValue: UUID(900)),
			destination: destination,
			sourceName: "Archive",
			category: .preferences,
			items: [],
			preferences: .init(exported),
			preferencesKey: key
		)
		await store.send(.migrationWorkspace(.request(.commit(UUID(901), batch)))).finish()

		expectNoDifference(store.settings.chromeAppearance.grain.intensity, 0.5)
		#expect(store.main.commandBar.shortcuts.contains { $0.keyword == "other" })
		#expect(!store.migrationLedger.importedItems.isEmpty)
		expectNoDifference(store.migrationCommit, UUID(901))
	}

	@Test
	internal func theWriterReadsAndCommitsThroughTheBridgeEndToEnd() async throws {
		let bridge = MigrationWorkspaceBridge()
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.uuid = .init { UUID() }
			$0.browserEngine.prepareProfile = { _ in }
			$0.migrationWorkspace = bridge
		}
		let destination = MigrationDestination(
			profileID: organization.spaces[0].profileID,
			spaceID: organization.spaces[0].id,
			defaultRoute: .newProfile
		)
		let writer = bridge.writer
		let batch = batch(destination)
		let work = Task {
			let before = try await writer.state()
			try await writer.commit(batch)
			return before
		}

		var served = 0
		for await request in bridge.requests {
			await store.send(.migrationWorkspace(.request(request))).finish()
			served += 1
			if case .commit = request {
				await store.send(.event(.saveSucceeded(store.workspace, store.persistedPreferences))).finish()
				break
			}
		}

		let before = try await work.value
		expectNoDifference(served, 2)
		expectNoDifference(before.organization, organization)
		expectNoDifference(store.workspace.profiles.last?.name, "Personal")
	}
}
