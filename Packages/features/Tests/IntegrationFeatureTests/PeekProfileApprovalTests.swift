import AppFeature
import BrowserCore
import CustomDump
import Foundation
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func profileDeletionApprovalRechecksPreviewCreatedDuringBeforeUnload() async throws {
		var previous = fixture()
		let other = Profile.ID(rawValue: UUID(90))
		previous.profiles.append(.init(id: other, name: "Other"))
		previous.spaces.append(.init(id: .init(rawValue: UUID(91)), profileID: other, name: "Other"))
		let profileID = previous.profiles[0].id
		var updated = previous
		updated.profiles.removeAll { $0.id == profileID }
		updated.spaces.removeAll { $0.profileID == profileID }
		updated.tabs.removeAll { $0.profileID == profileID }
		try updated.validate()
		var initial = AppFeature.State(main: .init(organization: previous, spaceID: previous.spaces[0].id))
		let preview = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: profileID,
			restoration: .init(title: "Preview", url: URL(string: "https://preview.example")!)
		)
		initial.peeks.append(
			.init(
				id: UUID(81),
				source: .init(
					windowID: initial.main.id,
					paneID: initial.main.viewer.activePaneID,
					tabID: nil,
					spaceID: previous.spaces[0].id,
					profileID: profileID,
					identity: "Default · Work"
				),
				tab: preview,
				isTemporary: true
			)
		)
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.close = { _ in Issue.record("Approved deletion closed a profile with a new Peek") }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.organizationChangeApproved(previous, updated, previous.tabs.map(\.id))))
		await store.receive(\.settings.event.organizationChangeFailed)
		await store.finish()
		expectNoDifference(store.state.workspace, previous)
		expectNoDifference(store.state.peeks, initial.peeks)
		expectNoDifference(store.state.unsavedOrganization, nil)
	}
}
