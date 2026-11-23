import BrowserCore
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// A starter profile of this Mac's that turning on iCloud Sync found a copy of (DEV-989): Settings
/// opens on removing it, and its data is erased only once the person confirms.
@Suite(.dependencies)
@MainActor
internal struct DuplicateStarterProfilesTests {
	private let duplicate: Profile.ID = .init(rawValue: UUID(9))

	private func store(
		duplicateHasSpace: Bool = false,
		retirementAvailable: Bool = true,
		forgotten: LockIsolated<[UUID]>
	) -> TestStoreOf<AppFeature> {
		var organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		organization.profiles.append(.init(id: duplicate, name: "Starter"))
		if duplicateHasSpace {
			organization.spaces.append(.init(id: .init(rawValue: UUID(10)), profileID: duplicate, name: "Kept"))
		}
		var state: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.retirementAvailable = retirementAvailable
		let duplicate: Profile.ID = duplicate
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceSync.isAvailable = { true }
			$0.workspaceSync.duplicateStarterProfiles = { [duplicate.rawValue] }
			$0.workspaceSync.forgetDuplicateStarterProfile = { id in forgotten.withValue { $0.append(id) } }
			$0.browserEngine.retirementIsAvailable = { false }
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off
		return store
	}

	@Test
	internal func settingsOpensOnRemovingItWithErasingOn() async {
		let forgotten: LockIsolated<[UUID]> = .init([])
		let store: TestStoreOf<AppFeature> = store(forgotten: forgotten)

		await store.send(.event(.workspaceSyncApplied))
		await store.receive(\.event.duplicateStarterProfilesFound)
		await store.skipReceivedActions(strict: false)

		#expect(store.state.settingsIsOpen)
		#expect(store.state.settings.organizationEditorIsPresented)
		#expect(store.state.settings.organizationEditor.kind == .removeProfile(duplicate))
		#expect(store.state.settings.organizationEditor.eraseWebsiteData)
		#expect(store.state.settings.organizationEditor.note != nil)
		// Offered once.
		#expect(forgotten.value == [duplicate.rawValue])
	}

	@Test
	internal func itsDataIsErasedOnlyOnceThePersonConfirms() async {
		let forgotten: LockIsolated<[UUID]> = .init([])
		let store: TestStoreOf<AppFeature> = store(forgotten: forgotten)
		await store.send(.event(.workspaceSyncApplied))
		await store.skipReceivedActions(strict: false)

		// Without its name typed, nothing starts.
		await store.send(.settings(.ui(.submitOrganizationEditor)))
		#expect(!store.state.settings.isManagingOrganization)
		#expect(store.state.settings.organizationEditorIsPresented)

		var editor: OrganizationEditor = store.state.settings.organizationEditor
		editor.eraseConfirmation = editor.name
		await store.send(.settings(.ui(.organizationEditorChanged(editor))))
		await store.send(.settings(.ui(.submitOrganizationEditor)))
		await store.receive(\.settings.delegate.retireProfile)
		await store.skipReceivedActions(strict: false)
	}

	@Test
	internal func oneWithASpaceIsntOfferedYet() async {
		let forgotten: LockIsolated<[UUID]> = .init([])
		let store: TestStoreOf<AppFeature> = store(duplicateHasSpace: true, forgotten: forgotten)

		await store.send(.event(.workspaceSyncApplied))
		await store.receive(\.event.duplicateStarterProfilesFound)
		await store.skipReceivedActions(strict: false)

		// Its spaces may not be reloaded here yet: it stays listed for later.
		#expect(!store.state.settings.organizationEditorIsPresented)
		#expect(forgotten.value.isEmpty)
	}

	@Test
	internal func theOfferWaitsUntilErasingIsAvailable() async {
		let forgotten: LockIsolated<[UUID]> = .init([])
		let store: TestStoreOf<AppFeature> = store(retirementAvailable: false, forgotten: forgotten)

		await store.send(.event(.workspaceSyncApplied))
		await store.receive(\.event.duplicateStarterProfilesFound)
		await store.skipReceivedActions(strict: false)

		#expect(!store.state.settings.organizationEditorIsPresented)
		#expect(forgotten.value.isEmpty)
	}
}
