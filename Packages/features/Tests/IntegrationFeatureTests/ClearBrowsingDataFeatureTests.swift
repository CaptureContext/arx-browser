import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import BrowserHistoryClient
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

@MainActor
@Suite(.dependencies, .serialized)
internal struct ClearBrowsingDataFeatureTests {
	private static let profileID = Profile.ID(rawValue: UUID(0))
	private static let now = Date(timeIntervalSince1970: 1_800_000_000)

	@Test
	internal func onlyListedProfilesOpenTheSheet() async throws {
		let profile = Profile(id: .init(rawValue: UUID()), name: "Work")
		var state = SettingsFeature.State()
		state.extensionProfiles = [profile]
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.showClearBrowsingData(.init(rawValue: UUID()))))
		#expect(store.state.clearBrowsingData == nil)

		await store.send(.ui(.showClearBrowsingData(profile.id)))
		#expect(store.state.clearBrowsingData == .init(profileID: profile.id, profileName: "Work"))

		await store.send(.ui(.clearBrowsingDataPresented(false)))
		#expect(store.state.clearBrowsingData == nil)

		await store.send(.ui(.showClearBrowsingData(profile.id)))
		await store.send(.configureExtensions([]))
		#expect(store.state.clearBrowsingData == nil)
	}

	@Test
	internal func countsComeFromTheAppAndTheEngineForTheRange() async throws {
		let engine = ProfileDataEngineDouble()
		let store = makeStore(engine)

		await store.send(.ui(.appeared)) {
			$0.isCounting = true
		}
		await store.receive(\.event.counted) {
			$0.counts.history = 1
			$0.counts.downloads = 1
		}
		await store.receive(\.event.engineCounted) {
			$0.isCounting = false
			$0.counts.cookieSites = 3
			$0.counts.cacheBytes = 4_096
		}
		expectNoDifference(engine.counted.map(\.kinds), [[.cookies, .cache, .autofill, .siteSettings]])
		expectNoDifference(engine.counted.map(\.since), [Self.now.addingTimeInterval(-3_600)])

		await store.send(.ui(.rangeChanged(.allTime))) {
			$0.range = .allTime
			$0.isCounting = true
			$0.counts = .init()
		}
		await store.receive(\.event.counted) {
			$0.counts.history = 2
			$0.counts.downloads = 2
		}
		await store.receive(\.event.engineCounted) {
			$0.isCounting = false
			$0.counts.cookieSites = 3
			$0.counts.cacheBytes = 4_096
		}
		#expect(engine.counted.last?.since == nil)
	}

	/// Back-to-back range changes race to register their counts off the main actor. The newest
	/// range is always counted, whichever count registers first (DEV-606).
	@Test
	internal func backToBackRangeChangesAlwaysCountTheNewestRange() async throws {
		var stranded = 0

		// About one back-to-back pair in a hundred registers out of order.
		for _ in 0..<1_000 {
			let engine = ProfileDataEngineDouble()
			let store = Store(
				initialState: ClearBrowsingDataFeature.State(profileID: Self.profileID, profileName: "Work")
			) {
				ClearBrowsingDataFeature()
			} withDependencies: {
				$0.browserEngine = engine.client
				$0.date.now = Self.now
				$0.browserHistory = .init(load: { .init(snapshot: .init(profileID: $0)) })
				$0.browserDownloads = .init(snapshot: { .init() })
			}
			let older = store.send(.ui(.rangeChanged(.lastDay)))
			let newer = store.send(.ui(.rangeChanged(.allTime)))
			await older.finish()
			await newer.finish()

			if store.isCounting || store.counts.cookieSites != 3 { stranded += 1 }
		}

		#expect(stranded == 0)
	}

	@Test
	internal func clearingRemovesEveryChosenKindThenCloses() async throws {
		let engine = ProfileDataEngineDouble()
		let removed = LockIsolated<[Set<BrowserDownload.ID>]>([])
		let store = makeStore(engine, loaded: true, removedDownloads: removed)

		await store.send(.ui(.kindToggled(.downloads, true))) {
			$0.kinds.insert(.downloads)
		}
		await store.send(.ui(.kindToggled(.cache, false))) {
			$0.kinds.remove(.cache)
		}
		await store.send(.ui(.clear)) {
			$0.isClearing = true
		}
		let since = Self.now.addingTimeInterval(-3_600)
		await store.receive(\.delegate.clearHistory)

		// Cookies went, so hover cards' site details fetched with them go too (DEV-1142).
		await store.receive(\.delegate.clearedSiteData, Self.profileID)
		await store.receive(\.event.cleared) {
			$0.isClearing = false
		}
		await store.receive(\.delegate.dismiss)
		expectNoDifference(engine.cleared.map(\.kinds), [[.history, .cookies, .downloads]])
		expectNoDifference(engine.cleared.map(\.since), [since])

		// Only the finished download in the range, picked before the engine cleared.
		expectNoDifference(removed.value, [[.init(profileID: Self.profileID, guid: "new")]])
	}

	@Test
	internal func engineFailureKeepsTheSheetAndTheAppsLists() async throws {
		let engine = ProfileDataEngineDouble()
		engine.failure = .unavailable
		let removed = LockIsolated<[Set<BrowserDownload.ID>]>([])
		let store = makeStore(engine, loaded: true, removedDownloads: removed)
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.clear))
		await store.receive(\.event.cleared) {
			$0.notice = .failed(.unavailable)
		}

		// Cookies were asked for too, so the app's own lists wait for the engine.
		#expect(removed.value.isEmpty)
	}

	@Test
	internal func historyAndDownloadsAloneClearWithoutTheEngine() async throws {
		let engine = ProfileDataEngineDouble()
		engine.isAvailable = false
		let removed = LockIsolated<[Set<BrowserDownload.ID>]>([])
		let store = makeStore(engine, loaded: true, kinds: [.history, .downloads], removedDownloads: removed)

		await store.send(.ui(.clear)) {
			$0.isClearing = true
		}
		await store.receive(\.delegate.clearHistory)
		await store.receive(\.event.cleared) {
			$0.isClearing = false
		}
		await store.receive(\.delegate.dismiss)
		#expect(engine.cleared.isEmpty)
		#expect(removed.value.count == 1)
	}

	@Test
	internal func aPolicyKeepingHistoryKeepsTheAppsListsToo() async throws {
		let engine = ProfileDataEngineDouble()
		engine.failure = .managed
		let removed = LockIsolated<[Set<BrowserDownload.ID>]>([])
		let store = makeStore(engine, loaded: true, kinds: [.history, .downloads], removedDownloads: removed)
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.clear))
		await store.receive(\.event.cleared) {
			$0.notice = .failed(.managed)
		}
		#expect(removed.value.isEmpty)
	}

	@Test
	internal func partialFailuresAreNamed() async throws {
		let engine = ProfileDataEngineDouble()
		engine.failed = [.cache]
		let store = makeStore(engine, loaded: true)
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.clear))
		await store.receive(\.event.cleared) {
			$0.notice = .partial([.cache])
		}
	}

	@Test
	internal func rangedHistoryClearsReachTheParentWithTheirStart() async throws {
		let profile = Profile(id: Self.profileID, name: "Work")
		var state = SettingsFeature.State()
		state.extensionProfiles = [profile]
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.showClearBrowsingData(profile.id)))

		let since = Self.now
		await store.send(.clearBrowsingData(.delegate(.clearHistory(profile.id, since: since))))
		await store.receive(\.delegate.clearHistorySince)
		await store.send(.clearBrowsingData(.delegate(.clearHistory(profile.id, since: nil))))
		await store.receive(\.delegate.clearHistory)
	}

	@Test
	internal func downloadFolderChangesGoThroughTheEngine() async throws {
		let engine = ProfileDataEngineDouble()
		let profile = Profile(id: Self.profileID, name: "Work")
		var state = SettingsFeature.State()
		state.extensionProfiles = [profile]
		let store = TestStore(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.browserEngine = engine.client
		}

		await store.send(.ui(.loadDownloadSettings(profile.id)))
		await store.receive(\.event.downloadSettingsLoaded) {
			$0.downloadSettings[profile.id] = ProfileDataEngineDouble.downloads
		}

		let folder = URL(filePath: "/Volumes/Data/Inbox", directoryHint: .isDirectory)
		await store.send(.ui(.chooseDownloadFolder(profile.id, folder))) {
			$0.downloadSettingsChanging = [profile.id]
		}
		await store.receive(\.event.downloadSettingsLoaded) {
			$0.downloadSettings[profile.id]?.directory = folder
		}
		await store.receive(\.event.downloadSettingsChangeFinished) {
			$0.downloadSettingsChanging = []
		}
		await store.send(.ui(.asksWhereToSave(profile.id, true))) {
			$0.downloadSettingsChanging = [profile.id]
		}
		await store.receive(\.event.downloadSettingsLoaded) {
			$0.downloadSettings[profile.id]?.asksWhereToSave = true
		}
		await store.receive(\.event.downloadSettingsChangeFinished) {
			$0.downloadSettingsChanging = []
		}
		await store.send(.ui(.resetDownloadFolder(profile.id))) {
			$0.downloadSettingsChanging = [profile.id]
		}
		await store.receive(\.event.downloadSettingsLoaded) {
			$0.downloadSettings[profile.id]?.directory = ProfileDataEngineDouble.downloads.defaultDirectory
		}
		await store.receive(\.event.downloadSettingsChangeFinished) {
			$0.downloadSettingsChanging = []
		}
		expectNoDifference(engine.changes.map(\.folder), [folder, nil, ProfileDataEngineDouble.downloads.defaultDirectory])
		expectNoDifference(engine.changes.map(\.asks), [false, true, true])

		// A refused folder shows what Chromium has, then why.
		engine.failure = .invalid
		await store.send(.ui(.chooseDownloadFolder(profile.id, folder))) {
			$0.downloadSettingsChanging = [profile.id]
		}
		await store.receive(\.event.downloadSettingsLoaded)
		await store.receive(\.event.downloadSettingsLoaded) {
			$0.downloadSettingsNotice[profile.id] = .invalid
		}
		await store.receive(\.event.downloadSettingsChangeFinished) {
			$0.downloadSettingsChanging = []
		}
	}

	@Test
	internal func managedFoldersAreReadOnly() async throws {
		let engine = ProfileDataEngineDouble()
		let profile = Profile(id: Self.profileID, name: "Work")
		var state = SettingsFeature.State()
		state.extensionProfiles = [profile]
		var managed = ProfileDataEngineDouble.downloads
		managed.isManaged = true
		state.downloadSettings[profile.id] = managed
		let store = TestStore(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.browserEngine = engine.client
		}

		await store.send(.ui(.asksWhereToSave(profile.id, true)))
		#expect(engine.changes.isEmpty)
	}

	@Test
	internal func aSecondFolderChangeWaitsForTheFirst() async throws {
		let engine = ProfileDataEngineDouble()
		let profile = Profile(id: Self.profileID, name: "Work")
		var state = SettingsFeature.State()
		state.extensionProfiles = [profile]
		state.downloadSettings[profile.id] = ProfileDataEngineDouble.downloads
		state.downloadSettingsChanging = [profile.id]
		let store = TestStore(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.browserEngine = engine.client
		}

		await store.send(.ui(.asksWhereToSave(profile.id, true)))
		await store.send(.ui(.resetDownloadFolder(profile.id)))
		#expect(engine.changes.isEmpty)
	}

	/// DEV-1142: clearing cookies or the cache reaches the parent, which forgets site details.
	@Test
	internal func clearedSiteDataReachesTheParent() async throws {
		let profile = Profile(id: Self.profileID, name: "Work")
		var state = SettingsFeature.State()
		state.extensionProfiles = [profile]
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.showClearBrowsingData(profile.id)))

		await store.send(.clearBrowsingData(.delegate(.clearedSiteData(profile.id))))
		await store.receive(\.delegate.clearedSiteData, profile.id)
	}

	private func makeStore(
		_ engine: ProfileDataEngineDouble,
		loaded: Bool = false,
		kinds: Set<BrowsingDataKind> = BrowsingDataKind.defaults,
		removedDownloads: LockIsolated<[Set<BrowserDownload.ID>]> = .init([])
	) -> TestStoreOf<ClearBrowsingDataFeature> {
		var state = ClearBrowsingDataFeature.State(profileID: Self.profileID, profileName: "Work", kinds: kinds)
		if loaded { state.counts = .init(history: 1) }
		let queue = DownloadQueue(downloads: [
			.init(id: .init(profileID: Self.profileID, guid: "new"), profileName: "Work", filename: "a", status: .complete, startedAt: Self.now.addingTimeInterval(-60)),
			.init(id: .init(profileID: Self.profileID, guid: "old"), profileName: "Work", filename: "b", status: .complete, startedAt: Self.now.addingTimeInterval(-7_200)),
		])
		let history = BrowsingHistorySnapshot(profileID: Self.profileID, entries: [
			.init(id: UUID(1), url: URL(string: "https://new.example")!, title: "", lastVisited: Self.now.addingTimeInterval(-60)),
			.init(id: UUID(2), url: URL(string: "https://old.example")!, title: "", lastVisited: Self.now.addingTimeInterval(-7_200)),
		])
		return TestStore(initialState: state) {
			ClearBrowsingDataFeature()
		} withDependencies: {
			$0.browserEngine = engine.client
			$0.date.now = Self.now
			$0.browserHistory = .init(load: { .init(snapshot: history.profileID == $0 ? history : .init(profileID: $0)) })
			$0.browserDownloads = .init(
				snapshot: { queue },
				removeHistory: { ids in
					removedDownloads.withValue { $0.append(ids) }
					return ids.count
				}
			)
		}
	}
}

/// Records what Settings asks the engine for profile data.
@MainActor
private final class ProfileDataEngineDouble {
	static let downloads = DownloadSettings(
		directory: URL(filePath: "/Users/a/Downloads", directoryHint: .isDirectory),
		defaultDirectory: URL(filePath: "/Users/a/Downloads", directoryHint: .isDirectory)
	)

	var isAvailable: Bool = true

	/// Every clear and change fails with this.
	var failure: ProfileDataFailure?

	/// Kinds a clear reports as not fully cleared.
	var failed: Set<BrowsingDataKind> = []
	var counted: [(kinds: Set<BrowsingDataKind>, since: Date?)] = []
	var cleared: [(kinds: Set<BrowsingDataKind>, since: Date?)] = []
	var changes: [(folder: URL?, asks: Bool)] = []
	var stored: DownloadSettings = downloads

	var client: BrowserEngineClient {
		var client = BrowserEngineClient(status: { .ready })
		client.profileDataIsAvailable = { [self] in isAvailable }
		client.countBrowsingData = { [self] _, kinds, since throws(ProfileDataFailure) in
			counted.append((kinds, since))
			return .init(cookieSites: 3, cacheBytes: 4_096)
		}
		client.clearBrowsingData = { [self] _, kinds, since throws(ProfileDataFailure) in
			cleared.append((kinds, since))
			if let failure { throw failure }
			return failed
		}
		client.downloadSettings = { [self] _ throws(ProfileDataFailure) in stored }
		client.changeDownloadSettings = { [self] _, folder, asks throws(ProfileDataFailure) in
			if let failure { throw failure }
			changes.append((folder, asks))
			if let folder { stored.directory = folder }
			stored.asksWhereToSave = asks
			return stored
		}
		return client
	}
}
