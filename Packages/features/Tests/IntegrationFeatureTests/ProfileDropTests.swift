import AppUI
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test(arguments: ["space", "spacePinned", "folder", "between", "blank", "favorite"])
	internal func crossProfileDropUsesDraggedTabAndExactPlacement(_ placement: String) async throws {
		var organization = profileDropFixture()
		organization.tabs[0].customTitle = "My reference"
		organization.tabs[0].automationClientID = UUID(80)
		if placement == "spacePinned" {
			try organization.move(
				.tab(organization.tabs[0].id.rawValue),
				to: .savedRoot,
				in: organization.spaces[0].id
			)
		}
		let source = organization.tabs[0]
		let destination = organization.spaces[2]
		let folder = organization.folders[0]
		let existing = organization.tabs[2]
		var opened: [BrowserCore.Tab] = []
		var closed: [BrowserCore.Tab.ID] = []
		var prepared: [Profile.ID] = []
		var initial = MainFeature.State(organization: organization, spaceID: destination.id)
		initial.viewer.item.tab = existing
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserEngine.snapshot = { id in
				organization.tabs[id: id].map { .init(navigation: .init(url: $0.restoration.url), revision: 1) }
			}
			$0.browserEngine.prepareProfile = { prepared.append($0) }
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let id = SidebarItem.ID.tab(source.id.rawValue)
		switch placement {
		case "space", "spacePinned":
			await store.send(.sidebar(.ui(.tabsDroppedOnSpace([id], destination.id))))
		case "folder":
			await store.send(.sidebar(.ui(.move(id, .inside(.folder(folder.id.rawValue)), destination.id))))
		case "between":
			await store.send(.sidebar(.ui(.move(id, .before(.tab(existing.id.rawValue)), destination.id))))
		case "favorite":
			await store.send(.sidebar(.ui(.sidebar(.move(id, .favoritesRoot)))))
		default:
			await store.send(.sidebar(.ui(.sidebar(.move(id, .unpinnedRoot)))))
		}
		await store.receive(\.transferTabs)
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.movedAcrossProfiles)
		await store.finish()

		let result = store.state.sidebar.organization
		try result.validate()
		let moved = try #require(result.tabs.first { $0.id.rawValue == UUID(100) })
		expectNoDifference(moved.profileID, destination.profileID)
		expectNoDifference(moved.restoration, source.restoration)
		expectNoDifference(moved.customTitle, "My reference")
		expectNoDifference(moved.automationClientID, source.automationClientID)
		expectNoDifference(opened.first?.automationClientID, source.automationClientID)
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.tab(source.id, profileID: source.profileID, location: .space(organization.spaces[0].id))],
			allowsRead: true,
			grantRevision: UUID(81)
		)
		#expect(!AutomationAccess.permitsTab(moved.id, client: client, organization: result))
		expectNoDifference(result.tabs.ids.contains(source.id), false)
		expectNoDifference(result.tabs[id: existing.id], existing)
		expectNoDifference(prepared, [destination.profileID])
		expectNoDifference(Set(closed), [source.id])
		expectNoDifference(Set(opened.map(\.id)), [moved.id])
		expectNoDifference(store.state.sidebar.message, nil)
		expectNoDifference(store.state.sidebar.undo.map(\.before), [organization])
		expectNoDifference(store.state.sidebar.selectedTab?.id, existing.id)

		switch placement {
		case "spacePinned":
			expectNoDifference(result.spaces[2].savedItems, [.folder(folder.id), .tab(moved.id)])
		case "folder":
			expectNoDifference(result.folders[0].children, [.tab(moved.id)])
		case "between":
			expectNoDifference(result.spaces[2].unpinnedTabs, [moved.id, existing.id])
		case "favorite":
			expectNoDifference(result.profiles[1].favorites, [moved.id])
		default:
			expectNoDifference(result.spaces[2].unpinnedTabs, [existing.id, moved.id])
		}
	}

	@Test
	internal func transferringNavigatedPinResumesCurrentPageWithoutChangingSavedURL() async throws {
		var organization = profileDropFixture()
		let sourceID = organization.tabs[0].id
		try organization.move(.tab(sourceID.rawValue), to: .savedRoot, in: organization.spaces[0].id)
		let savedDestination = organization.tabs[0].savedDestination
		let currentURL = URL(string: "https://capturecontext.dev/current-page")!
		organization.tabs[0].restoration.url = currentURL
		var opened: [BrowserCore.Tab] = []
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[2].id)
		initial.viewer.item.tab = organization.tabs[2]
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserEngine.snapshot = { id in
				organization.tabs[id: id].map { .init(navigation: .init(url: $0.restoration.url), revision: 1) }
			}
			$0.browserEngine.open = { opened.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.sidebar(.ui(.tabsDroppedOnSpace([.tab(sourceID.rawValue)], organization.spaces[2].id))))
		await store.receive(\.transferTabs)
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.movedAcrossProfiles)
		await store.finish()
		let staged = try #require(opened.first)
		let persisted = try #require(store.state.sidebar.organization.tabs[id: staged.id])
		expectNoDifference(staged.reopeningURL, currentURL)
		expectNoDifference(persisted.savedDestination, savedDestination)
		expectNoDifference(persisted.restoration.url, currentURL)
	}

	@Test(arguments: ["prepare", "cancel", "open"])
	internal func failedProfileDropPreservesSource(_ failure: String) async throws {
		let organization = profileDropFixture()
		var closed: [BrowserCore.Tab.ID] = []
		var opened: [BrowserCore.Tab.ID] = []
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[2].id)
		initial.viewer.item.tab = organization.tabs[2]
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserEngine.snapshot = { id in
				organization.tabs[id: id].map { .init(navigation: .init(url: $0.restoration.url), revision: 1) }
			}
			$0.browserEngine.prepareProfile = { _ in
				if failure == "prepare" { throw BrowserEngineClient.Failure.unavailable }
			}
			$0.browserEngine.permitsClosing = { _ in failure != "cancel" }
			$0.browserEngine.open = { tab in
				opened.append(tab.id)
				if failure == "open" { throw BrowserEngineClient.Failure.unavailable }
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.tabsDroppedOnSpace(
			[.tab(organization.tabs[0].id.rawValue)],
			organization.spaces[2].id
		))))
		await store.receive(\.transferTabs)
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.moveFailed)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, organization)
		expectNoDifference(store.state.transferInProgress, false)
		expectNoDifference(closed.contains(organization.tabs[0].id), false)
		if failure == "cancel" {
			expectNoDifference(closed, opened)
			expectNoDifference(store.state.sidebar.message, nil)
		}
	}

	@Test
	internal func staleProfileDropClosesOnlyThePreparedCopy() async throws {
		let original = profileDropFixture()
		var current = original
		current.spaces[0].name = "Concurrent edit"
		let copy = BrowserCore.Tab(
			id: .init(rawValue: UUID(100)),
			profileID: original.profiles[1].id,
			restoration: original.tabs[0].restoration
		)
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: MainFeature.State(
			organization: current,
			spaceID: current.spaces[0].id
		)) { MainFeature() } withDependencies: {
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let plan = OrganizationMove(
			previous: original,
			updated: original,
			roots: [],
			destination: original.spaces[2].id,
			replacements: [.init(source: original.tabs[0], destination: copy)],
			movedTabIDs: [copy.id]
		)
		let request = TabMoveRequest(
			id: UUID(90),
			plan: plan,
			selection: [],
			sourceSpace: original.spaces[0].id,
			selectedTab: original.tabs[0].id
		)
		await store.send(.event(.movedAcrossProfiles(request)))
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, current)
		expectNoDifference(closed, [copy.id])
	}

	@Test
	internal func partialBatchOpenFailureDisposesCopiesWithoutRemovingSources() async throws {
		let organization = profileDropFixture()
		var opened: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let identities = LockIsolated([UUID(100), UUID(101), UUID(102)])
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[2].id)
		initial.viewer.item.tab = organization.tabs[2]
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.uuid = .init { identities.withValue { $0.removeFirst() } }
			$0.browserEngine.snapshot = { id in
				organization.tabs[id: id].map { .init(navigation: .init(url: $0.restoration.url), revision: 1) }
			}
			$0.browserEngine.open = { tab in
				opened.append(tab.id)
				if opened.count == 2 { throw BrowserEngineClient.Failure.unavailable }
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.tabsDroppedOnSpace(
			organization.tabs.prefix(2).map { .tab($0.id.rawValue) },
			organization.spaces[2].id
		))))
		await store.receive(\.transferTabs)
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.moveFailed)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, organization)
		expectNoDifference(closed, opened)
		expectNoDifference(opened.count, 2)
	}

	private func profileDropFixture() -> BrowserOrganization {
		var organization = fixture()
		let profile = Profile.ID(rawValue: UUID(20))
		let space = Space.ID(rawValue: UUID(21))
		let folder = Folder.ID(rawValue: UUID(22))
		let existing = BrowserCore.Tab(
			id: .init(rawValue: UUID(23)),
			profileID: profile,
			restoration: .init(title: "Destination", url: URL(string: "https://destination.example")!)
		)
		organization.profiles.append(.init(id: profile, name: "Other"))
		organization.spaces.append(.init(
			id: space,
			profileID: profile,
			name: "Other",
			savedItems: [.folder(folder)],
			unpinnedTabs: [existing.id],
			selectedTabID: existing.id
		))
		organization.folders.append(.init(id: folder, spaceID: space, name: "Destination folder"))
		organization.tabs.append(existing)
		return organization
	}
}
