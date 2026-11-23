import BrowserCore
import CommandBarFeature
import Foundation
import Testing
import _ComposableArchitecture

@testable import AppFeature
@testable import LittleArxFeature

/// Little Arx's launcher profile picker (DEV-1331): which launchers offer it, and that choosing a
/// profile lists that profile's pages only.
@MainActor
@Suite(.dependencies)
internal struct LittleArxProfilePickerTests {
	private let work = Profile.ID(rawValue: UUID(0))
	private let home = Profile.ID(rawValue: UUID(100))
	private let homeSpace = Space.ID(rawValue: UUID(101))
	private let workPage = URL(string: "https://work.example/secret-plan")!
	private let homePage = URL(string: "https://home.example/recipes")!

	@Test
	internal func aSingleProfileHasNoPicker() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = launcherStore(AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		)))
		let id = try await openLauncher(store)

		let launcher = try #require(store.state.littleWindows[id: id])
		#expect(launcher.commandBar.isPresented)
		expectNoDifference(launcher.launcherProfileIDs, [work])
		#expect(!launcher.offersProfilePicker)

		await store.send(.littleWindows(.element(id: id, action: .ui(.profilePickerToggled))))
		#expect(store.state.littleWindows[id: id]?.profilePicker == nil)
	}

	@Test
	internal func thePickerPreselectsTheFrontWindowsProfileAndListsEveryProfileWithASpace() async throws {
		let store = launcherStore(twoProfiles(showing: homeSpace))
		let id = try await openLauncher(store)

		let launcher = try #require(store.state.littleWindows[id: id])
		expectNoDifference(launcher.tab.profileID, home)
		expectNoDifference(launcher.launcherProfileIDs, [work, home])
		#expect(launcher.offersProfilePicker)

		await store.send(.littleWindows(.element(id: id, action: .ui(.profilePickerToggled))))
		expectNoDifference(store.state.littleWindows[id: id]?.profilePicker, .init(selectedID: home))

		// ⌘I again closes it.
		await store.send(.littleWindows(.element(id: id, action: .ui(.profilePickerToggled))))
		#expect(store.state.littleWindows[id: id]?.profilePicker == nil)
	}

	@Test
	internal func choosingAProfileListsOnlyThatProfilesPages() async throws {
		var state = twoProfiles(showing: IntegrationFeatureTests().fixture().spaces[0].id)
		state.main.browsingHistory[work] = .init(profileID: work, entries: [entry(1, workPage)])
		state.main.browsingHistory[home] = .init(profileID: home, entries: [entry(2, homePage)])
		let store = launcherStore(state)
		let id = try await openLauncher(store)

		// Work's page is listed, and typed text stays as the profile changes.
		var launcher = try #require(store.state.littleWindows[id: id])
		#expect(launcher.commandBar.candidates.contains { $0.intent == .open(workPage) })
		await store.send(.littleWindows(.element(id: id, action: .commandBar(.ui(.queryChanged("re"))))))

		await store.send(.littleWindows(.element(id: id, action: .ui(.profilePickerToggled))))
		await store.send(.littleWindows(.element(id: id, action: .ui(.launcherProfileSelected(home)))))
		await store.receive(\.littleWindows)
		await store.receive(\.littleWindows)
		await store.skipReceivedActions(strict: false)

		launcher = try #require(store.state.littleWindows[id: id])
		expectNoDifference(launcher.tab.profileID, home)
		expectNoDifference(launcher.spaceID, homeSpace)
		#expect(launcher.profilePicker == nil)
		#expect(launcher.commandBar.isPresented)
		expectNoDifference(launcher.commandBar.query, "re")
		expectNoDifference(launcher.commandBar.bangIconProfileID, home)
		expectNoDifference(launcher.commandBar.searchEngine, .duckDuckGo)

		// Nothing of Work's: its page, its tabs, its site icons.
		#expect(launcher.commandBar.candidates.contains { $0.intent == .open(homePage) })
		#expect(!launcher.commandBar.candidates.contains { $0.intent == .open(workPage) })
		#expect(!launcher.launcherSuggestions.contains { $0.intent == .open(workPage) })
		let icons = launcher.commandBar.candidates.compactMap(\.presentation.siteIcon?.profileID)
		#expect(!icons.isEmpty)
		#expect(icons.allSatisfy { $0 == home.rawValue })
		#expect(!launcher.commandBar.entries.contains { $0.presentation.subtitle.contains("work.example") })
	}

	@Test
	internal func choosingTheSameProfileOnlyClosesTheList() async throws {
		let store = launcherStore(twoProfiles(showing: homeSpace))
		let id = try await openLauncher(store)

		await store.send(.littleWindows(.element(id: id, action: .ui(.profilePickerToggled))))
		await store.send(.littleWindows(.element(id: id, action: .ui(.launcherProfileSelected(home)))))
		await store.finish()

		#expect(store.state.littleWindows[id: id]?.profilePicker == nil)
		expectNoDifference(store.state.littleWindows[id: id]?.tab.profileID, home)
	}

	@Test
	internal func aPrivateLauncherHasNoPicker() async throws {
		var state = LittleArxFeature.State(
			id: UUID(20),
			spaceID: homeSpace,
			tab: .init(id: .init(rawValue: UUID(21)), profileID: home, restoration: .init(title: "", url: URL(string: "about:blank")!)),
			isCommandOnly: true,
			launcherProfileIDs: [work, home]
		)
		state.isPrivate = true
		state.commandBar.isPresented = true
		#expect(!state.offersProfilePicker)

		let store = TestStore(initialState: state) { LittleArxFeature() }
		await store.send(.ui(.profilePickerToggled))
		await store.send(.ui(.launcherProfileSelected(work)))
		await store.send(.useLauncherProfile(.init(profileID: work, spaceID: UUID(1).spaceID, searchEngine: .google, suggestions: [])))
	}

	@Test
	internal func openingActionsClosesTheProfileListAndTheListClosesActions() async {
		var state = LittleArxFeature.State(
			id: UUID(20),
			spaceID: homeSpace,
			tab: .init(id: .init(rawValue: UUID(21)), profileID: home, restoration: .init(title: "", url: URL(string: "about:blank")!)),
			isCommandOnly: true,
			launcherProfileIDs: [work, home]
		)
		state.commandBar.isPresented = true
		state.profilePicker = .init(selectedID: home)
		let store = TestStore(initialState: state) { LittleArxFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.commandBar(.ui(.actionsToggled)))
		#expect(store.state.profilePicker == nil)
	}

	// MARK: - Fixtures

	private func twoProfiles(showing spaceID: Space.ID) -> AppFeature.State {
		var organization = IntegrationFeatureTests().fixture()
		organization.profiles.append(.init(id: home, name: "Home", searchEngine: .duckDuckGo))
		let homeTab = BrowserCore.Tab(
			id: .init(rawValue: UUID(102)),
			profileID: home,
			restoration: .init(title: "Recipes", url: homePage)
		)
		organization.tabs.append(homeTab)
		organization.spaces.append(.init(id: homeSpace, profileID: home, name: "Home", unpinnedTabs: [homeTab.id]))

		// Work's open tabs lead to its own page.
		for index in organization.tabs.indices where organization.tabs[index].profileID == work {
			organization.tabs[index].restoration.url = workPage
		}
		return AppFeature.State(main: .init(organization: organization, spaceID: spaceID))
	}

	private func entry(_ id: Int, _ url: URL) -> BrowsingHistoryEntry {
		.init(id: UUID(id), url: url, title: "Page \(id)", lastVisited: Date(timeIntervalSince1970: Double(id)))
	}

	private func launcherStore(_ state: AppFeature.State) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 500)
			$0.continuousClock = ImmediateClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	/// Opens a launcher with ⌥⌘A's action and presents its bar, as its window does when it appears.
	private func openLauncher(_ store: TestStoreOf<AppFeature>) async throws -> UUID {
		await store.send(.ui(.openLittleArx()))
		let id = try #require(store.state.littleWindows.last?.id)
		await store.send(.littleWindows(.element(id: id, action: .ui(.task))))
		await store.skipReceivedActions(strict: false)
		return id
	}
}

extension UUID {
	fileprivate var spaceID: Space.ID { .init(rawValue: self) }
}
