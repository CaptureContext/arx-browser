@testable import AppFeature
@testable import AppUI
import BrowserCore
import BrowserSiteIconClient
import CustomDump
import Darwin
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct FavoriteSiteIconTests {
	internal enum SavedKind: CaseIterable, Sendable {
		case favorite
		case pinned
	}

	/// A saved tab with no icon of its own shows the icon of the page it loaded, as any tab does,
	/// not the one its saved address had when it was saved (DEV-1294).
	@Test(arguments: SavedKind.allCases)
	internal func aSavedTabsIconFollowsThePageItLoads(_ kind: SavedKind) async throws {
		let (store, id) = savedTabStore(kind)
		#expect(store.state.sidebar.tabItem(id)?.siteIcon?.pageURL == Self.saved)

		let loaded = URL(string: "https://fixture.invalid/saved/inbox")!
		await load(loaded, in: id, store)

		#expect(store.state.sidebar.tabItem(id)?.siteIcon?.pageURL == loaded)
		#expect(store.state.sidebar.tabItem(id)?.customIcon == nil)
	}

	/// A custom icon (DEV-1251) stays put while the page underneath loads.
	@Test(arguments: SavedKind.allCases)
	internal func aSavedTabsCustomIconStaysWhenItsPageLoads(_ kind: SavedKind) async throws {
		let (store, id) = savedTabStore(kind, icon: .star)

		let loaded = URL(string: "https://fixture.invalid/saved/inbox")!
		await load(loaded, in: id, store)

		let item = try #require(store.state.sidebar.tabItem(id))
		#expect(item.customIcon == .star)
		#expect(item.siteIcon?.pageURL == loaded)
	}

	/// Browsing away from the saved page shows where the tab is; closing it back to its saved page
	/// shows the saved page's icon again, which the detour never wrote over.
	@Test(arguments: SavedKind.allCases)
	internal func aDetourShowsItsOwnIconAndClosingReturnsTheSavedOne(_ kind: SavedKind) async throws {
		let (store, id) = savedTabStore(kind)

		let detour = URL(string: "https://elsewhere.invalid/article")!
		await load(detour, in: id, store)
		#expect(store.state.sidebar.tabItem(id)?.siteIcon?.pageURL == detour)

		await store.send(.sidebar(.event(.closeApproved(id, reset: true, expectedLocation: nil))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.organization.tabs[id: id]?.restoration.url == Self.saved)
		#expect(store.state.sidebar.tabItem(id)?.siteIcon?.pageURL == Self.saved)
	}

	@Test
	internal func updatingTheSavedURLAndUndoingItKeepTheLoadedPagesIcon() async throws {
		var organization = IntegrationFeatureTests().fixture()
		let id = organization.tabs[0].id
		let current = URL(string: "https://fixture.invalid/current")!
		organization.tabs[0].savedDestination = .init(title: "Saved", url: Self.saved)
		organization.tabs[0].restoration.url = current
		organization.spaces[0].unpinnedTabs.removeAll { $0 == id }
		organization.profiles[0].favorites.append(id)
		let store = Store(initialState: SidebarFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { SidebarFeature() }
		let expected = SidebarItem.SiteIcon(profileID: organization.profiles[0].id.rawValue, pageURL: current)
		expectNoDifference(store.favorites.first?.siteIcon, expected)

		await store.send(.ui(.sidebar(.updateSavedURL(.tab(id.rawValue))))).finish()
		expectNoDifference(store.favorites.first?.siteIcon, expected)
		await store.send(.ui(.undo)).finish()
		expectNoDifference(store.favorites.first?.siteIcon, expected)
		expectNoDifference(store.organization.tabs[0].savedDestination?.url, Self.saved)
	}

	private static let saved = URL(string: "https://fixture.invalid/saved")!

	private func savedTabStore(
		_ kind: SavedKind,
		icon: SpaceIcon? = nil
	) -> (TestStoreOf<MainFeature>, BrowserCore.Tab.ID) {
		var organization = IntegrationFeatureTests().fixture()
		let id = organization.tabs[0].id
		organization.tabs[0].savedDestination = .init(title: "Saved", url: Self.saved)
		organization.tabs[0].restoration = .init(title: "Saved", url: Self.saved)
		organization.tabs[0].icon = icon
		organization.spaces[0].unpinnedTabs.removeAll { $0 == id }
		switch kind {
		case .favorite:
			organization.profiles[0].favorites.append(id)

		case .pinned:
			organization.spaces[0].savedItems.append(.tab(id))
		}
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.sidebar.select(id)
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return (store, id)
	}

	private func load(
		_ url: URL,
		in id: BrowserCore.Tab.ID,
		_ store: TestStoreOf<MainFeature>
	) async {
		await store.send(.takePageNavigation(id, BrowserNavigation(url: url, title: "Loaded")))
		await store.finish()
		await store.skipReceivedActions(strict: false)
	}

	@Test
	internal func identicalDestinationInAnotherProfileHasDistinctPresentationKey() async throws {
		var organization = IntegrationFeatureTests().fixture()
		let saved = URL(string: "https://fixture.invalid/saved")!
		organization.tabs[0].savedDestination = .init(title: "Saved", url: saved)
		let first = SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let original = try #require(first.tabItem(organization.tabs[0].id)?.siteIcon)
		let tab = organization.tabs[0]
		organization.tabs[0] = .init(
			id: .init(rawValue: UUID(98)),
			profileID: .init(rawValue: UUID(99)),
			savedDestination: tab.savedDestination,
			restoration: tab.restoration
		)
		let second = SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let moved = try #require(second.tabItem(organization.tabs[0].id)?.siteIcon)
		#expect(original != moved)
		expectNoDifference(original.pageURL, moved.pageURL)
	}

	@Test
	internal func profilePublicationRevokesIconsBeforeClosingEffectsRun() async throws {
		var organization = IntegrationFeatureTests().fixture()
		let removedProfile = Profile.ID(rawValue: UUID(90))
		let removedTab = BrowserCore.Tab(
			id: .init(rawValue: UUID(91)),
			profileID: removedProfile,
			savedDestination: .init(title: "Other", url: URL(string: "https://fixture.invalid/other")!),
			restoration: .init(title: "Other", url: URL(string: "https://fixture.invalid/other")!)
		)
		organization.profiles.append(.init(id: removedProfile, name: "Other", favorites: [removedTab.id]))
		organization.tabs.append(removedTab)
		let updated = try organization.applying(.removeProfile(removedProfile), uuid: UUID.init)
		var configured: [Set<Profile.ID>] = []
		var closed: [BrowserCore.Tab.ID] = []
		let expected = Set(updated.profiles.map(\.id))
		let store = Store(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() } withDependencies: {
			$0.browserSiteIcons.configureProfiles = { configured.append($0) }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { id in
				expectNoDifference(configured.last, expected)
				closed.append(id)
			}
		}
		await store.send(.event(.organizationChangeApproved(organization, updated, [removedTab.id]))).finish()
		expectNoDifference(configured, [expected])
		expectNoDifference(closed, [removedTab.id])
	}

	@Test
	internal func imagePresentationRejectsMalformedOrOversizedData() async throws {
		let png = Data(
			base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
		)!
		#expect(FavoriteSiteIcon.image(png) != nil)
		#expect(FavoriteSiteIcon.image(Data([1, 2, 3])) == nil)
		#expect(FavoriteSiteIcon.image(Data(repeating: 0, count: 65_537)) == nil)
	}

	@Test
	internal func nativeFixtureRequiresOwnedProfileMarkerAndLoopback() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-smoke-icons-" + UUID().uuidString)
		let profile = root.appendingPathComponent("profile")
		try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		chmod(root.path, 0o700)
		chmod(profile.path, 0o700)
		let marker = root.appendingPathComponent(".arx-site-icons-smoke")
		try Data(SiteIconSmokeFixture.sentinel.utf8).write(to: marker)
		chmod(marker.path, 0o600)
		let url = URL(string: "http://127.0.0.1:12345/index.html")!
		try SiteIconSmokeFixture.validate(root: root, profile: profile, baseURL: url)
		#expect(throws: SiteIconSmoke.Failure.self) {
			try SiteIconSmokeFixture.validate(
				root: root,
				profile: profile,
				baseURL: URL(string: "https://fixture.invalid/index.html")!
			)
		}
		chmod(marker.path, 0o644)
		#expect(throws: SiteIconSmoke.Failure.self) {
			try SiteIconSmokeFixture.validate(root: root, profile: profile, baseURL: url)
		}
	}

	@Test
	internal func restartManifestRequiresExactOrdinaryProfilesSavedURLAndSingleWrite() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let primary = organization.profiles[0].id.rawValue
		let legacy = (organization.legacyProfileID ?? organization.profiles[0].id).rawValue
		let secondary = UUID(99)
		let baseURL = URL(string: "http://127.0.0.1:12345/index.html")!
		let savedURL = URL(string: "http://127.0.0.1:12345/site-icons/page.html")!
		let manifest = SiteIconRestartManifest(
			primaryProfile: primary,
			secondaryProfile: secondary,
			legacyProfile: legacy,
			savedURL: savedURL
		)
		try manifest.validate(organization: organization, baseURL: baseURL)

		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer { try? FileManager.default.removeItem(at: root) }
		let path = root.appendingPathComponent(SiteIconRestartManifest.filename)
		#expect(FileManager.default.createFile(
			atPath: path.path,
			contents: nil,
			attributes: [.posixPermissions: 0o600]
		))
		try manifest.write(to: root)
		expectNoDifference(try SiteIconRestartManifest.read(from: root), manifest)
		#expect(throws: SiteIconSmoke.Failure.self) { try manifest.write(to: root) }
		chmod(path.path, 0o644)
		#expect(throws: SiteIconSmoke.Failure.self) { try SiteIconRestartManifest.read(from: root) }

		let invalid: [SiteIconRestartManifest] = [
			.init(
				version: 2,
				primaryProfile: primary,
				secondaryProfile: secondary,
				legacyProfile: legacy,
				savedURL: savedURL
			),
			.init(
				primaryProfile: primary,
				secondaryProfile: primary,
				legacyProfile: legacy,
				savedURL: savedURL
			),
			.init(
				primaryProfile: secondary,
				secondaryProfile: primary,
				legacyProfile: legacy,
				savedURL: savedURL
			),
			.init(
				primaryProfile: primary,
				secondaryProfile: secondary,
				legacyProfile: secondary,
				savedURL: savedURL
			),
			.init(
				primaryProfile: primary,
				secondaryProfile: secondary,
				legacyProfile: legacy,
				savedURL: baseURL
			),
		]
		for value in invalid {
			#expect(throws: SiteIconSmoke.Failure.self) {
				try value.validate(organization: organization, baseURL: baseURL)
			}
		}
	}

	@Test
	internal func restartReadHasBoundedTimeoutAndHonorsPreCancellation() async throws {
		let (stream, continuation) = AsyncStream<Data?>.makeStream()
		defer { continuation.finish() }
		do {
			try await SiteIconRestartSmoke.verify(stream, color: [0, 0, 255], timeout: .milliseconds(1))
			Issue.record("A silent image stream escaped the deadline")
		} catch let SiteIconSmoke.Failure.timedOut(phase) {
			expectNoDifference(phase, "restart database read")
		}

		let (canceledStream, canceledContinuation) = AsyncStream<Data?>.makeStream()
		defer { canceledContinuation.finish() }
		let task = Task { try await SiteIconRestartSmoke.verify(canceledStream, color: [0, 0, 255]) }
		task.cancel()
		await #expect(throws: CancellationError.self) { try await task.value }
	}

}
