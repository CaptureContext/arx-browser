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
	@Test
	internal func spaceMovesToProfileWithItsTabsAndFolders() async throws {
		let organization = try spaceMoveFixture()
		let source = organization.spaces[0]
		let profile = organization.profiles[1]
		let folder = organization.folders.first { $0.spaceID == source.id }!
		var opened: [BrowserCore.Tab] = []
		var closed: [BrowserCore.Tab.ID] = []
		var prepared: [Profile.ID] = []
		let ids = LockIsolated([UUID(100), UUID(101), UUID(102)])
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: source.id)) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .init { ids.withValue { $0.removeFirst() } }
			$0.browserEngine.snapshot = { id in
				organization.tabs[id: id].map { .init(navigation: .init(url: $0.restoration.url), revision: 1) }
			}
			$0.browserEngine.prepareProfile = { prepared.append($0) }
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		expectNoDifference(store.state.sidebar.sidebarSpaces.first { $0.id == source.id.rawValue }?.profileName, "Default")

		await store.send(.ui(.moveSpaceToProfile(source.id, profile.id)))
		expectNoDifference(store.state.pendingProfileMove, source.id)
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.movedAcrossProfiles)
		await store.finish()

		let result = store.state.sidebar.organization
		try result.validate()
		let space = try #require(result.spaces[id: source.id])
		let pinned = BrowserCore.Tab.ID(rawValue: UUID(100))
		let open = BrowserCore.Tab.ID(rawValue: UUID(101))
		expectNoDifference(space.profileID, profile.id)
		expectNoDifference(space.name, source.name)
		expectNoDifference(space.savedItems, [.folder(folder.id)])
		expectNoDifference(result.folders[id: folder.id]?.children, [.tab(pinned)])
		expectNoDifference(result.folders[id: folder.id]?.spaceID, source.id)
		expectNoDifference(space.unpinnedTabs, [open])
		expectNoDifference(space.selectedTabID, open)
		expectNoDifference(
			result.tabs.filter { [pinned, open].contains($0.id) }.map(\.profileID),
			[profile.id, profile.id]
		)
		expectNoDifference(result.tabs[id: open]?.restoration, organization.tabs[1].restoration)
		expectNoDifference(
			result.tabs.contains { $0.profileID == organization.profiles[0].id && $0.id != organization.tabs[2].id },
			false
		)

		// Favorites belong to the profile and stay behind.
		expectNoDifference(result.profiles[0].favorites, organization.profiles[0].favorites)
		expectNoDifference(prepared, [profile.id])
		expectNoDifference(Set(opened.map(\.id)), [pinned, open])
		expectNoDifference(Set(closed), [organization.tabs[0].id, organization.tabs[1].id])
		expectNoDifference(store.state.sidebar.spaceID, source.id)
		expectNoDifference(store.state.sidebar.undo.map(\.before), [organization])
		expectNoDifference(store.state.sidebar.sidebarSpaces.first { $0.id == source.id.rawValue }?.profileName, "Other")
	}

	@Test(arguments: ["prepare", "cancel", "open"])
	internal func failedSpaceProfileMovePreservesSource(_ failure: String) async throws {
		let organization = try spaceMoveFixture()
		var closed: [BrowserCore.Tab.ID] = []
		var opened: [BrowserCore.Tab.ID] = []
		let ids = LockIsolated([UUID(100), UUID(101), UUID(102)])
		let store = TestStore(initialState: MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .init { ids.withValue { $0.removeFirst() } }
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

		await store.send(.ui(.moveSpaceToProfile(organization.spaces[0].id, organization.profiles[1].id)))
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.moveFailed)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, organization)
		expectNoDifference(store.state.transferInProgress, false)
		expectNoDifference(closed.contains(organization.tabs[0].id), false)
		expectNoDifference(closed.contains(organization.tabs[1].id), false)
		expectNoDifference(Set(closed), Set(opened))
	}

	@Test
	internal func emptySpaceMovesToProfileWithoutConfirmation() async throws {
		let organization = try spaceMoveFixture()
		let empty = organization.spaces[1]
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: empty.id)) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .constant(UUID(100))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.moveSpaceToProfile(empty.id, organization.profiles[1].id)))
		await store.receive(\.performTabMove)
		await store.finish()
		let result = store.state.sidebar.organization
		try result.validate()
		expectNoDifference(store.state.pendingTabMove, nil)
		expectNoDifference(result.spaces[id: empty.id]?.profileID, organization.profiles[1].id)
		expectNoDifference(result.tabs, organization.tabs)
	}

	@Test
	internal func privateWindowCannotMoveSpaceToProfile() async throws {
		let organization = try spaceMoveFixture()
		let store = TestStore(initialState: MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true
		)) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.moveSpaceToProfile(organization.spaces[0].id, organization.profiles[1].id)))
		await store.finish()
		expectNoDifference(store.state.pendingTabMove, nil)
		expectNoDifference(store.state.sidebar.organization, organization)
	}

	@Test
	internal func movingSpaceToItsOwnProfileIsRejected() throws {
		let organization = try spaceMoveFixture()
		#expect(throws: OrganizationMoveError.invalidDestination) {
			try organization.movingSpace(
				organization.spaces[0].id,
				toProfile: organization.profiles[0].id,
				newTabID: { .init(rawValue: UUID(100)) }
			)
		}
	}

	/// "Work" (Default profile) holds a folder with a pinned tab, an open selected tab, and a favorite that stays behind.
	private func spaceMoveFixture() throws -> BrowserOrganization {
		var organization = fixture()
		let work = organization.spaces[0].id
		let folder = Folder.ID(rawValue: UUID(30))
		organization.folders.append(.init(id: folder, spaceID: work, name: "Reading"))
		organization.spaces[0].savedItems = [.folder(folder)]
		try organization.move(.tab(organization.tabs[0].id.rawValue), to: .inside(.folder(folder.rawValue)), in: work)
		organization.spaces[0].selectedTabID = organization.tabs[1].id
		let favorite = BrowserCore.Tab(
			id: .init(rawValue: UUID(31)),
			profileID: organization.profiles[0].id,
			savedDestination: .init(title: "Favorite", url: URL(string: "https://favorite.example")!),
			restoration: .init(title: "Favorite", url: URL(string: "https://favorite.example")!)
		)
		organization.tabs.append(favorite)
		organization.profiles[0].favorites = [favorite.id]
		organization.profiles.append(.init(id: .init(rawValue: UUID(20)), name: "Other"))
		try organization.validate()
		return organization
	}
}
