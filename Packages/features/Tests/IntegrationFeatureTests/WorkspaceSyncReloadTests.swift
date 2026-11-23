import BrowserCore
import BrowserWorkspaceClient
import Foundation
import Testing
import ViewerItemFeature
import WorkspaceDatabase
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// iCloud sync's changes reach AppFeature (DEV-977): the workspace is read from the SQLite store again
/// and published, but never while an edit here waits to be saved.
@Suite(.dependencies)
@MainActor
internal struct WorkspaceSyncReloadTests {
	private struct Fixture {
		let directory: URL
		let client: BrowserWorkspaceClient
		let document: WorkspaceDocument
		let organization: BrowserOrganization

		/// Another Mac renamed the first space, as a sync engine writes it.
		func renameFirstSpace() throws {
			let store: WorkspaceDatabase = try #require(client.workspaceDatabase)
			let spaceID: UUID = organization.spaces[0].id.rawValue
			try store.database.write { db in
				try SpaceRecord.find(spaceID).update { $0.name = "From another Mac" }.execute(db)
			}
		}

		/// Another Mac moved a space to another profile.
		func moveSpace(_ id: Space.ID, to profileID: Profile.ID) throws {
			let store: WorkspaceDatabase = try #require(client.workspaceDatabase)
			try store.database.write { db in
				try SpaceRecord.find(id.rawValue).update { $0.profileID = profileID.rawValue }.execute(db)
			}
		}

		/// Another Mac removed a space.
		func removeSpace(_ id: Space.ID) throws {
			let store: WorkspaceDatabase = try #require(client.workspaceDatabase)
			try store.database.write { db in
				try SpaceRecord.find(id.rawValue).delete().execute(db)
			}
		}
	}

	private func fixture(
		_ organization: BrowserOrganization = IntegrationFeatureTests().fixture()
	) throws -> Fixture {
		let directory: URL = .temporaryDirectory.appendingPathComponent("WorkspaceSyncReloadTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let client: BrowserWorkspaceClient = .init(
			file: directory.appendingPathComponent("arx-workspace.json"),
			storage: .sqlite,
			separatePreferencesConnection: true
		)
		_ = try client.loadWithRecovery()
		try client.save(organization)
		let document: WorkspaceDocument = .init(client: client, organization: organization, preferences: .init())
		return .init(directory: directory, client: client, document: document, organization: organization)
	}

	private func store(
		_ fixture: Fixture,
		spaceID: Space.ID? = nil,
		editWaitsToBeSaved: Bool = false
	) -> TestStoreOf<AppFeature> {
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(
				organization: fixture.organization,
				spaceID: spaceID ?? fixture.organization.spaces[0].id
			))
		}
		if editWaitsToBeSaved {
			state.unsavedOrganization = state.workspace
		}
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
		}
		store.exhaustivity = Exhaustivity.off
		return store
	}

	@Test
	internal func aRemoteChangeIsPublishedWhenNothingWaitsToBeSaved() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture)

		try fixture.renameFirstSpace()
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.spaces[0].name == "From another Mac")
		#expect(store.state.main.sidebar.organization.spaces[0].name == "From another Mac")
		#expect(fixture.document.organization?.spaces[0].name == "From another Mac")
		#expect(store.state.unsavedOrganization == nil)
		#expect(store.state.syncReloadPending == false)
	}

	@Test
	internal func downloadsFollowARemoteChange() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: fixture.organization, spaceID: fixture.organization.spaces[0].id))
		}
		state.downloadsReady = true
		let configured: LockIsolated<[BrowserOrganization]> = .init([])
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
			$0.browserDownloads.configure = { organization in configured.withValue { $0.append(organization) } }
		}
		store.exhaustivity = Exhaustivity.off

		try fixture.renameFirstSpace()
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()

		#expect(configured.value.last?.spaces[0].name == "From another Mac")
	}

	@Test
	internal func aRemoteChangeWaitsForAPreferenceGroupChange() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: fixture.organization, spaceID: fixture.organization.spaces[0].id))
		}
		state.isChangingPreferenceGroup = true
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
		}
		store.exhaustivity = Exhaustivity.off

		// Settings' group toggles wait for it too.
		#expect(store.state.settings.iCloudSync.isChangingPreferenceGroup)

		try fixture.renameFirstSpace()
		await store.send(.event(.workspaceSyncChanged))
		#expect(store.state.syncReloadPending)
		#expect(store.state.workspace.spaces[0].name == fixture.organization.spaces[0].name)

		// The change lands with what's shown, then the remote change is read.
		var saved: BrowserPreferences = fixture.document.preferences
		saved.automation = store.state.automationPreferences
		await store.send(.event(.preferenceGroupSaved(.routing, tookSyncedValues: false, store.state.workspace, saved)))
		await store.skipReceivedActions(strict: false)
		#expect(!store.state.isChangingPreferenceGroup)
		#expect(!store.state.settings.iCloudSync.isChangingPreferenceGroup)
		#expect(store.state.syncReloadPending == false)
		#expect(store.state.workspace.spaces[0].name == "From another Mac")
	}

	@Test
	internal func keepingThisMacsValuesKeepsAnEditToTheGroupMadeMeanwhile() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: fixture.organization, spaceID: fixture.organization.spaces[0].id))
		}
		state.isChangingPreferenceGroup = true
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
		}
		store.exhaustivity = Exhaustivity.off

		var saved: BrowserPreferences = fixture.document.preferences
		saved.automation = store.state.automationPreferences

		// The group's own edit, made while its change was being written.
		fixture.document.updatePreferences(requestsSave: false) {
			$0.searchShortcuts = [.init(name: "Newer", keyword: "newer", template: "https://newer.example/?q={query}")]
		}

		await store.send(.event(.preferenceGroupSaved(.searchEngines, tookSyncedValues: false, store.state.workspace, saved)))
		await store.skipReceivedActions(strict: false)

		#expect(fixture.document.preferences.searchShortcuts.map(\.keyword) == ["newer"])
		#expect(store.state.unsavedOrganization != nil)
	}

	@Test
	internal func aPreferenceGroupChangeLandsAsTheSaveAFlowWaitsFor() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: fixture.organization, spaceID: fixture.organization.spaces[0].id))
		}
		state.isChangingPreferenceGroup = true
		state.unsavedOrganization = state.workspace
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
		}
		store.exhaustivity = Exhaustivity.off

		var saved: BrowserPreferences = fixture.document.preferences
		saved.automation = store.state.automationPreferences
		await store.send(.event(.preferenceGroupSaved(.routing, tookSyncedValues: false, store.state.workspace, saved)))
		await store.receive(\.event.saveSucceeded)

		#expect(store.state.unsavedOrganization == nil)
	}

	@Test
	internal func anEarlierSaveLandingDuringAGroupChangeLeavesItUnsaved() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: fixture.organization, spaceID: fixture.organization.spaces[0].id))
		}
		state.isChangingPreferenceGroup = true
		state.unsavedOrganization = state.workspace
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
		}
		store.exhaustivity = Exhaustivity.off

		var saved: BrowserPreferences = fixture.document.preferences
		saved.automation = store.state.automationPreferences
		await store.send(.event(.saveSucceeded(store.state.workspace, saved)))
		#expect(store.state.unsavedOrganization != nil)

		await store.send(.event(.preferenceGroupSaved(.routing, tookSyncedValues: false, store.state.workspace, saved)))
		await store.receive(\.event.saveSucceeded)
		#expect(store.state.unsavedOrganization == nil)
	}

	@Test
	internal func aFailedGroupChangeShowsItsErrorWithTheToggles() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: fixture.organization, spaceID: fixture.organization.spaces[0].id))
		}
		state.isChangingPreferenceGroup = true
		state.unsavedOrganization = state.workspace
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
		}
		store.exhaustivity = Exhaustivity.off

		await store.send(.event(.preferenceGroupFailed("Invalid")))
		#expect(!store.state.isChangingPreferenceGroup)
		#expect(store.state.settings.iCloudSync.preferenceGroupError == "Invalid")

		// The workspace's own save landing doesn't clear it.
		var saved: BrowserPreferences = fixture.document.preferences
		saved.automation = store.state.automationPreferences
		await store.send(.event(.saveSucceeded(store.state.workspace, saved)))
		#expect(store.state.settings.iCloudSync.preferenceGroupError == "Invalid")
		#expect(store.state.persistenceError == nil)
	}

	@Test
	internal func iCloudsValuesForAPreferenceGroupKeepOtherEdits() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: fixture.organization, spaceID: fixture.organization.spaces[0].id))
		}
		state.isChangingPreferenceGroup = true
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
		}
		store.exhaustivity = Exhaustivity.off

		// The store saved iCloud's search shortcuts; an edit to another part came meanwhile.
		var saved: BrowserPreferences = fixture.document.preferences
		saved.automation = store.state.automationPreferences
		saved.searchShortcuts = [.init(name: "Remote", keyword: "remote", template: "https://remote.example/?q={query}")]
		fixture.document.updatePreferences(requestsSave: false) { $0.warnsBeforeQuitting.toggle() }
		let edited: Bool = fixture.document.preferences.warnsBeforeQuitting

		await store.send(.event(.preferenceGroupSaved(.searchEngines, tookSyncedValues: true, store.state.workspace, saved)))
		await store.skipReceivedActions(strict: false)

		#expect(fixture.document.preferences.searchShortcuts.map(\.keyword) == ["remote"])
		#expect(fixture.document.preferences.warnsBeforeQuitting == edited)
		// The edit made meanwhile is saved now.
		#expect(store.state.unsavedOrganization != nil)
	}

	@Test
	internal func aRemoteChangeWaitsForAnUnsavedEditToBeSaved() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture, editWaitsToBeSaved: true)

		try fixture.renameFirstSpace()
		await store.send(.event(.workspaceSyncChanged))
		#expect(store.state.syncReloadPending)
		#expect(store.state.workspace.spaces[0].name == fixture.organization.spaces[0].name)

		// Its save lands, then the change is read.
		var saved: BrowserPreferences = fixture.document.preferences
		saved.automation = store.state.automationPreferences
		await store.send(.event(.saveSucceeded(store.state.workspace, saved)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.syncReloadPending == false)
		#expect(store.state.workspace.spaces[0].name == "From another Mac")
	}

	@Test
	internal func aSharedPreferenceEditIsSavedBeforeARemoteChangeIsRead() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store: TestStoreOf<AppFeature> = store(fixture)

		// A shared key's edit is in the document, and AppFeature hasn't heard of it yet.
		fixture.document.updatePreferences { $0.warnsBeforeQuitting.toggle() }
		let edited: BrowserPreferences = fixture.document.preferences
		try fixture.renameFirstSpace()
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.syncReloadPending)
		#expect(fixture.document.preferences == edited)
		#expect(store.state.workspace.spaces[0].name == fixture.organization.spaces[0].name)

		// The save it asked for lands, then the change is read with the edit kept.
		var saved: BrowserPreferences = fixture.document.preferences
		saved.automation = store.state.automationPreferences
		try fixture.client.save(store.state.workspace, preferences: saved)
		await store.send(.event(.saveSucceeded(store.state.workspace, saved)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.syncReloadPending == false)
		#expect(store.state.workspace.spaces[0].name == "From another Mac")
		#expect(fixture.document.preferences.warnsBeforeQuitting == edited.warnsBeforeQuitting)
	}

	@Test
	internal func aRemoteChangeWaitsForAProfileTransferEvenOneThatsCancelled() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let moveID: UUID = .init()
		let spaceID: Space.ID = fixture.organization.spaces[0].id
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: fixture.organization, spaceID: spaceID))
		}
		state.main.activeTabMove = .init(
			id: moveID,
			plan: .init(
				previous: fixture.organization,
				updated: fixture.organization,
				roots: [],
				destination: spaceID,
				replacements: [],
				movedTabIDs: []
			),
			selection: [],
			sourceSpace: spaceID,
			selectedTab: nil
		)
		state.main.transferInProgress = true
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
		}
		store.exhaustivity = Exhaustivity.off

		try fixture.renameFirstSpace()
		await store.send(.event(.workspaceSyncChanged))
		#expect(store.state.syncReloadPending)

		// Cancelling the move saves nothing, and the change is read then.
		await store.send(.main(.event(.moveFailed(moveID, ""))))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.syncReloadPending == false)
		#expect(store.state.workspace.spaces[0].name == "From another Mac")
	}

	@Test
	internal func aWindowOnASpaceRemovedOnAnotherMacMovesToOneThatsLeft() async throws {
		let fixture: Fixture = try fixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let removed: Space.ID = fixture.organization.spaces[1].id
		let store: TestStoreOf<AppFeature> = store(fixture, spaceID: removed)

		try fixture.removeSpace(removed)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.spaces[id: removed] == nil)
		#expect(store.state.main.sidebar.spaceID == fixture.organization.spaces[0].id)
	}

	@Test
	internal func openTabsInASpaceMovedToAnotherProfileGetNewPages() async throws {
		var organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let work: Profile.ID = .init(rawValue: UUID(9))
		organization.profiles.append(.init(id: work, name: "Work"))
		let fixture: Fixture = try fixture(organization)
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let space: Space = organization.spaces[0]
		let closed: LockIsolated<Set<BrowserCore.Tab.ID>> = .init([])
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		}
		state.main.viewer.item.tab = organization.tabs[0]
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
			$0.browserEngine.close = { id in closed.withValue { _ = $0.insert(id) } }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.uuid = .init { UUID() }
		}
		store.exhaustivity = Exhaustivity.off

		try fixture.moveSpace(space.id, to: work)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()

		// Same places, new tabs in the new profile; the old profile's pages close.
		let moved: Space = try #require(store.state.workspace.spaces[id: space.id])
		#expect(moved.profileID == work)
		#expect(moved.unpinnedTabs.count == space.unpinnedTabs.count)
		#expect(Set(moved.unpinnedTabs).isDisjoint(with: space.unpinnedTabs))
		for id in moved.unpinnedTabs {
			#expect(store.state.workspace.tabs[id: id]?.profileID == work)
		}
		#expect(store.state.workspace.tabs[id: moved.unpinnedTabs[0]]?.reopeningURL == organization.tabs[0].reopeningURL)
		#expect(closed.value == Set(space.unpinnedTabs))
		#expect(store.state.main.sidebar.selectedTab?.id == moved.unpinnedTabs[0])

		// The new identities exist only here until saved, so a save is asked for.
		#expect(store.state.unsavedOrganization == store.state.workspace)
	}

	@Test
	internal func aPageThatWontCloseKeepsItsSpacesMoveUnread() async throws {
		var organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let work: Profile.ID = .init(rawValue: UUID(9))
		organization.profiles.append(.init(id: work, name: "Work"))
		let fixture: Fixture = try fixture(organization)
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let space: Space = organization.spaces[0]
		let permits: LockIsolated<Bool> = .init(false)
		let closed: LockIsolated<Set<BrowserCore.Tab.ID>> = .init([])

		// The window shows the other space and keeps a layout for the one that moves.
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[1].id))
		}
		state.main.viewer.presentations = [
			.init(id: space.id, panes: [.init(id: UUID(70), tabID: organization.tabs[0].id)], activePaneID: UUID(70)),
		]
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
			$0.browserEngine.close = { id in closed.withValue { _ = $0.insert(id) } }
			$0.browserEngine.permitsClosing = { _ in permits.value }
			$0.uuid = .init { UUID() }
		}
		store.exhaustivity = Exhaustivity.off

		try fixture.moveSpace(space.id, to: work)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()

		// A page with unsaved changes stays: nothing moves or closes.
		#expect(store.state.workspace.spaces[id: space.id]?.profileID == space.profileID)
		#expect(store.state.workspace.spaces[id: space.id]?.unpinnedTabs == space.unpinnedTabs)
		#expect(closed.value.isEmpty)
		#expect(!store.state.syncReloadAwaitingApproval)
		#expect(!store.state.syncReloadPending)
		// And a save of what's shown doesn't undo the move on the other Mac.
		try fixture.client.save(store.state.workspace)
		let saved: BrowserOrganization? = try WorkspaceDatabase(directory: fixture.directory).load()?.organization
		#expect(saved?.spaces[id: space.id]?.profileID == work)

		// The next change asks again; once the pages agree, the tabs move.
		permits.setValue(true)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()

		let moved: Space = try #require(store.state.workspace.spaces[id: space.id])
		#expect(moved.profileID == work)
		#expect(closed.value == Set(space.unpinnedTabs))
		// The layout the window keeps for the moved space points at the new tab.
		let kept: BrowserSpacePresentation? = store.state.main.viewer.presentations.first { $0.id == space.id }
		#expect(kept?.panes.first?.tabID == moved.unpinnedTabs[0])
	}

	@Test
	internal func aTabAnotherMacRemovedClosesOnlyOnceItsPageAgrees() async throws {
		let organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let fixture: Fixture = try fixture(organization)
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let removedSpace: Space = organization.spaces[0]
		let permits: LockIsolated<Bool> = .init(false)
		let closed: LockIsolated<Set<BrowserCore.Tab.ID>> = .init([])
		let state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[1].id))
		}
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
			$0.browserEngine.close = { id in closed.withValue { _ = $0.insert(id) } }
			$0.browserEngine.permitsClosing = { _ in permits.value }
		}
		store.exhaustivity = Exhaustivity.off

		// Another Mac deletes the space with this Mac's open tabs in it.
		try fixture.removeSpace(removedSpace.id)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(store.state.workspace.spaces[id: removedSpace.id] != nil)
		#expect(closed.value.isEmpty)

		permits.setValue(true)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(store.state.workspace.spaces[id: removedSpace.id] == nil)
		#expect(closed.value == Set(removedSpace.unpinnedTabs))
	}

	@Test
	internal func aPinnedTabThatChangesProfileReopensInTheNewOne() async throws {
		var organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let work: Profile.ID = .init(rawValue: UUID(9))
		organization.profiles.append(.init(id: work, name: "Work"))
		let pinID: BrowserCore.Tab.ID = .init(rawValue: UUID(20))
		let url: URL = URL(string: "https://pinned.example")!
		organization.tabs.append(.init(
			id: pinID,
			profileID: organization.profiles[0].id,
			savedDestination: .init(title: "Pinned", url: url),
			restoration: .init(title: "Pinned", url: url)
		))
		organization.spaces[0].savedItems = [.tab(pinID)]
		let fixture: Fixture = try fixture(organization)
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let space: Space = organization.spaces[0]
		let closed: LockIsolated<Set<BrowserCore.Tab.ID>> = .init([])
		let state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		}
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
			$0.browserEngine.close = { id in closed.withValue { _ = $0.insert(id) } }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.uuid = .init { UUID() }
		}
		store.exhaustivity = Exhaustivity.off

		// The space's new profile arrives before the pin's replacement does.
		try fixture.moveSpace(space.id, to: work)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()

		// It keeps its ID until then, and its old profile's page closes.
		#expect(store.state.workspace.tabs[id: pinID]?.profileID == work)
		#expect(closed.value.contains(pinID))
	}

	@Test
	internal func aPinOnScreenThatChangesProfileOpensAgainInPlace() async throws {
		var organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let work: Profile.ID = .init(rawValue: UUID(9))
		organization.profiles.append(.init(id: work, name: "Work"))
		let pinID: BrowserCore.Tab.ID = .init(rawValue: UUID(20))
		let url: URL = URL(string: "https://pinned.example")!
		let pin: BrowserCore.Tab = .init(
			id: pinID,
			profileID: organization.profiles[0].id,
			savedDestination: .init(title: "Pinned", url: url),
			restoration: .init(title: "Pinned", url: url)
		)
		organization.tabs.append(pin)
		organization.spaces[0].savedItems = [.tab(pinID)]
		organization.spaces[0].selectedTabID = pinID
		let fixture: Fixture = try fixture(organization)
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let space: Space = organization.spaces[0]
		let closed: LockIsolated<[BrowserCore.Tab.ID]> = .init([])
		let opened: LockIsolated<[BrowserCore.Tab]> = .init([])

		// Each tab's live page, by the profile it's in.
		let personal: Profile.ID = organization.profiles[0].id
		let live: LockIsolated<[BrowserCore.Tab.ID: Profile.ID]> = .init([pinID: personal])
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		}

		// On screen: its pane observes its page.
		state.main.viewer.item = .init(tab: pin)
		state.main.viewer.item.isObserving = true
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
			$0.browserEngine.close = { id in
				closed.withValue { $0.append(id) }
				live.withValue { $0[id] = nil }
			}
			$0.browserEngine.open = { tab in

				// The old profile's page is gone by the time the pane opens the tab again.
				#expect(closed.value.contains(tab.id))
				opened.withValue { $0.append(tab) }
				live.withValue { $0[tab.id] = tab.profileID }
			}
			$0.browserEngine.snapshot = { id in
				live.value[id].map { .init(navigation: .init(), revision: 1, nativeProfileID: $0) }
			}
			$0.browserEngine.permitsClosing = { _ in true }
			$0.uuid = .init { UUID() }
		}
		store.exhaustivity = Exhaustivity.off

		try fixture.moveSpace(space.id, to: work)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()

		// The pane still shows the pin, now in its new profile, with its page open there.
		#expect(store.state.main.viewer.item.tab?.id == pinID)
		#expect(store.state.main.viewer.item.tab?.profileID == work)
		#expect(opened.value.contains { $0.id == pinID && $0.profileID == work })
		#expect(store.state.main.sidebar.selectedTab?.id == pinID)

		// An earlier reload's notice arriving late opens nothing: the pane shows the current profile.
		let opens: Int = opened.value.count
		await store.send(.event(.workspaceSyncPagesClosed([pinID])))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(opened.value.count == opens)

		// Moved there and back before the notices came: the pane's profile is current, but its page
		// is gone, so it opens again.
		live.withValue { $0[pinID] = nil }
		await store.send(.event(.workspaceSyncPagesClosed([pinID])))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(opened.value.count == opens + 1)
	}

	@Test
	internal func aClosedWindowDoesntOpenAPinThatChangesProfile() async throws {
		var organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let work: Profile.ID = .init(rawValue: UUID(9))
		organization.profiles.append(.init(id: work, name: "Work"))
		let pinID: BrowserCore.Tab.ID = .init(rawValue: UUID(20))
		let url: URL = URL(string: "https://pinned.example")!
		let pin: BrowserCore.Tab = .init(
			id: pinID,
			profileID: organization.profiles[0].id,
			savedDestination: .init(title: "Pinned", url: url),
			restoration: .init(title: "Pinned", url: url)
		)
		organization.tabs.append(pin)
		organization.spaces[0].savedItems = [.tab(pinID)]
		organization.spaces[0].selectedTabID = pinID
		let fixture: Fixture = try fixture(organization)
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let opened: LockIsolated<[BrowserCore.Tab]> = .init([])
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}

		// The main window was closed: its pane keeps the pin, suspended.
		state.main.viewer.item = .init(tab: pin)
		state.main.viewer.item.isObserving = false
		state.windowIsOpen = false
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
			$0.browserEngine.close = { _ in }
			$0.browserEngine.open = { tab in opened.withValue { $0.append(tab) } }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.uuid = .init { UUID() }
		}
		store.exhaustivity = Exhaustivity.off

		try fixture.moveSpace(organization.spaces[0].id, to: work)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()

		#expect(store.state.workspace.tabs[id: pinID]?.profileID == work)
		#expect(opened.value.isEmpty)
		#expect(!store.state.main.viewer.item.isObserving)
	}

	@Test
	internal func aSplitShowingAMovedSpaceKeepsItsPanes() async throws {
		var organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let work: Profile.ID = .init(rawValue: UUID(9))
		organization.profiles.append(.init(id: work, name: "Work"))
		let fixture: Fixture = try fixture(organization)
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let space: Space = organization.spaces[0]
		let first: BrowserCore.Tab = try #require(organization.tabs[id: space.unpinnedTabs[0]])
		let second: BrowserCore.Tab = try #require(organization.tabs[id: space.unpinnedTabs[1]])
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		}

		// Two open tabs side by side, not a tab group.
		state.main.viewer.item = .init(tab: first)
		state.main.viewer.item.isObserving = true
		var secondItem: ViewerItemFeature.State = .init(tab: second)
		secondItem.isObserving = true
		state.main.viewer.panes.append(.init(id: UUID(71), item: secondItem))
		state.main.viewer.fractions = [0.5, 0.5]
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
			$0.browserEngine.close = { _ in }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.uuid = .init { UUID() }
		}
		store.exhaustivity = Exhaustivity.off

		try fixture.moveSpace(space.id, to: work)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()

		// Both panes stay, showing the tabs' new identities in the new profile.
		let moved: Space = try #require(store.state.workspace.spaces[id: space.id])
		#expect(Set(moved.unpinnedTabs).isDisjoint(with: space.unpinnedTabs))
		#expect(store.state.main.viewer.panes.map(\.item.tab?.id) == moved.unpinnedTabs.map(Optional.some))
		#expect(store.state.main.viewer.panes.allSatisfy { $0.item.tab?.profileID == work })
	}

	@Test
	internal func anApprovalHoldsOnlyForThePageThatGaveIt() async throws {
		let organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let fixture: Fixture = try fixture(organization)
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let removedSpace: Space = organization.spaces[0]
		let document: LockIsolated<UInt64> = .init(1)
		let asked: LockIsolated<Int> = .init(0)
		let permits: LockIsolated<Bool> = .init(false)
		let closed: LockIsolated<Set<BrowserCore.Tab.ID>> = .init([])
		func page(_ revision: UInt64) -> BrowserSessionSnapshot {
			.init(navigation: .init(), revision: 1, documentRevision: revision, nativePageID: 7)
		}
		var state = withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[1].id))
		}

		// The pages agreed for a read that didn't happen, then went to other documents.
		state.syncApprovedTabCloses = Dictionary(
			uniqueKeysWithValues: removedSpace.unpinnedTabs.map { ($0, SyncClosingPage(page(1))) }
		)
		document.setValue(2)
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = fixture.document
			$0.browserEngine.snapshot = { _ in page(document.value) }
			$0.browserEngine.close = { id in closed.withValue { _ = $0.insert(id) } }
			$0.browserEngine.permitsClosing = { _ in
				asked.withValue { $0 += 1 }
				return permits.value
			}
		}
		store.exhaustivity = Exhaustivity.off

		// Another Mac deletes the space with this Mac's open tabs in it: the pages are asked again.
		try fixture.removeSpace(removedSpace.id)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(asked.value > 0)
		#expect(store.state.workspace.spaces[id: removedSpace.id] != nil)
		#expect(closed.value.isEmpty)
		#expect(store.state.syncApprovedTabCloses.isEmpty)

		// Once they agree as they are, the tabs close.
		permits.setValue(true)
		await store.send(.event(.workspaceSyncChanged))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(store.state.workspace.spaces[id: removedSpace.id] == nil)
		#expect(closed.value == Set(removedSpace.unpinnedTabs))
	}
}
