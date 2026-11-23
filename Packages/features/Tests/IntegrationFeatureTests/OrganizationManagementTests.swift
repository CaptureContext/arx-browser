import AppFeature
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func settingsChangesReachAllNormalWindowsAndTheSaveDelegate() async throws {
		let organization = fixture()
		let space = organization.spaces[0]
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		initial.windows.append(
			.init(
				organization: organization,
				spaceID: organization.spaces[1].id,
				id: UUID(50)
			)
		)
		initial.windows.append(
			.init(
				organization: organization,
				spaceID: space.id,
				isPrivate: true,
				id: UUID(51)
			)
		)
		let store = TestStore(initialState: initial) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		let change = OrganizationChange.updateSpace(
			space.id,
			profileID: space.profileID,
			name: "Renamed",
			icon: .briefcase
		)
		await store.send(.settings(.ui(.changeOrganization(change))))
		await store.receive(\.delegate.save)
		await store.finish()
		expectNoDifference(store.state.workspace.spaces[0].name, "Renamed")
		expectNoDifference(store.state.main.sidebar.space.icon, .briefcase)
		expectNoDifference(store.state.windows[0].sidebar.organization.spaces[0].name, "Renamed")
		expectNoDifference(store.state.windows[0].sidebar.spaceID, organization.spaces[1].id)
		expectNoDifference(store.state.windows[1].sidebar.organization, organization)
		expectNoDifference(store.state.unsavedOrganization, store.state.workspace)
		expectNoDifference(store.state.settings.isManagingOrganization, false)
	}

	@Test
	internal func cancellingSpaceDeletionPreservesEveryTabAndLeavesEditorOpen() async {
		let organization = fixture()
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.settings.organizationEditorIsPresented = true
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in false }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.changeOrganization(.removeSpace(organization.spaces[0].id)))))
		await store.receive(\.settings.event.organizationChangeFailed)
		await store.finish()
		expectNoDifference(store.state.workspace, organization)
		expectNoDifference(store.state.unsavedOrganization, nil)
		expectNoDifference(store.state.settings.organizationEditorIsPresented, true)
		expectNoDifference(closed, [])
	}

	@Test
	internal func approvedDeletionClosesRemovedPagesAndSelectsASurvivingSpace() async {
		let organization = fixture()
		var closed: [BrowserCore.Tab.ID] = []
		let initial = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.close = { closed.append($0) }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.changeOrganization(.removeSpace(organization.spaces[0].id)))))
		await store.receive(\.delegate.save)
		await store.finish()
		expectNoDifference(closed, organization.tabs.map(\.id))
		expectNoDifference(store.state.workspace.tabs, [])
		expectNoDifference(store.state.main.sidebar.spaceID, organization.spaces[1].id)
	}

	@Test
	internal func staleCloseApprovalCannotOverwriteAConcurrentEdit() async throws {
		let previous = fixture()
		let updated = try previous.applying(.removeSpace(previous.spaces[0].id), uuid: UUID.init)
		var initial = AppFeature.State(main: .init(organization: previous, spaceID: previous.spaces[0].id))
		initial.workspace.spaces[1].name = "Concurrent rename"
		let store = TestStore(initialState: initial) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.organizationChangeApproved(previous, updated, previous.tabs.map(\.id))))
		await store.receive(\.settings.event.organizationChangeFailed)
		await store.finish()
		expectNoDifference(store.state.workspace, initial.workspace)
	}

	@Test
	internal func changingSpaceProfileLoadsFreshIdentityAndRetainsWindowSelection() async throws {
		var organization = fixture()
		let profile = Profile.ID(rawValue: UUID(20))
		organization.profiles.append(.init(id: profile, name: "Other"))
		var opened: [BrowserCore.Tab] = []
		var closed: [BrowserCore.Tab.ID] = []
		let ids = LockIsolated([UUID(30), UUID(31)])
		let initial = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .init { ids.withValue { $0.removeFirst() } }
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let change = OrganizationChange.updateSpace(
			organization.spaces[0].id,
			profileID: profile,
			name: "Changed",
			icon: .house
		)
		await store.send(.settings(.ui(.changeOrganization(change))))
		await store.receive(\.delegate.save)
		await store.finish()
		try store.state.workspace.validate()
		expectNoDifference(opened.map(\.profileID), [profile])
		expectNoDifference(opened.first?.id, store.state.main.sidebar.selectedTab?.id)
		expectNoDifference(closed, organization.tabs.map(\.id))
		#expect(!organization.tabs.map(\.id).contains(store.state.main.sidebar.selectedTab!.id))
	}
}

extension IntegrationFeatureTests {
	@Test
	internal func profilePreparationFailurePreservesSourcePages() async {
		var organization = fixture()
		let profile = Profile.ID(rawValue: UUID(20))
		organization.profiles.append(.init(id: profile, name: "Other"))
		var closed: [BrowserCore.Tab.ID] = []
		let ids = LockIsolated([UUID(30), UUID(31)])
		let initial = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .init { ids.withValue { $0.removeFirst() } }
			$0.browserEngine.prepareProfile = { _ in throw BrowserEngineClient.Failure.unavailable }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let change = OrganizationChange.updateSpace(
			organization.spaces[0].id,
			profileID: profile,
			name: "Changed",
			icon: .house
		)
		await store.send(.settings(.ui(.changeOrganization(change))))
		await store.receive(\.settings.event.organizationChangeFailed)
		await store.finish()
		expectNoDifference(store.state.workspace, organization)
		expectNoDifference(closed, [])
	}
}

extension IntegrationFeatureTests {
	@Test
	internal func creatingAProfileDoesNotSwitchTheWindowsBrowsingContext() async {
		let organization = fixture()
		let profileID = Profile.ID(rawValue: UUID(70))
		let initial = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .constant(profileID.rawValue)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.editOrganization(.init(name: "Personal")))))
		expectNoDifference(store.state.workspace, organization)
		await store.send(.settings(.ui(.submitOrganizationEditor)))
		await store.receive(\.delegate.save)
		await store.finish()
		expectNoDifference(store.state.workspace.profiles.last?.id, profileID)
		expectNoDifference(store.state.workspace.spaces, organization.spaces)
		expectNoDifference(store.state.main.sidebar.spaceID, organization.spaces[0].id)
		expectNoDifference(store.state.settings.selectedProfileID, profileID)
		expectNoDifference(store.state.settings.organizationEditorIsPresented, false)
	}
}

extension IntegrationFeatureTests {
	/// Return in New Profile's name field may submit twice (DEV-774). The app commits a change
	/// at once and closes the editor, which keeps its name, so the second submit finds the sheet
	/// closed and sends nothing.
	@Test
	internal func aRepeatedSubmitCreatesOneProfile() async {
		let profileID = Profile.ID(rawValue: UUID(70))
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
			$0.uuid = .constant(profileID.rawValue)
			$0.defaultBrowser = .unavailable
		}
		store.exhaustivity = .on

		await store.send(.ui(.editOrganization(.init(name: "Personal")))) {
			$0.organizationEditor = .init(name: "Personal")
			$0.organizationEditorIsPresented = true
		}
		await store.send(.ui(.submitOrganizationEditor))
		await store.receive(\.ui.changeOrganization, .createProfile(profileID, name: "Personal")) {
			$0.isManagingOrganization = true
		}
		await store.receive(\.delegate.changeOrganization, .createProfile(profileID, name: "Personal"))
		await store.send(.event(.organizationChanged)) {
			$0.isManagingOrganization = false
			$0.organizationEditorIsPresented = false
		}
		await store.send(.ui(.submitOrganizationEditor))
	}
}

extension IntegrationFeatureTests {
	@Test
	internal func settingsCannotRemoveASpaceDuringAnInFlightTabTransfer() async {
		let organization = fixture()
		var initial = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		initial.main.transferInProgress = true
		let store = TestStore(initialState: initial) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.changeOrganization(.removeSpace(organization.spaces[1].id)))))
		await store.receive(\.settings.event.organizationChangeFailed)
		await store.finish()
		expectNoDifference(store.state.workspace, organization)
		expectNoDifference(store.state.unsavedOrganization, nil)
	}
}
