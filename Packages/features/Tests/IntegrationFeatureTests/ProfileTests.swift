import AppFeature
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
	internal func beforeUnloadCancellationPreservesTabAndSelection() async throws {
		let organization = fixture()
		let store = TestStore(initialState: MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { MainFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in false }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.closeTab))
		await store.receive(\.sidebar.delegate.requestClose)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, organization)
	}

	@Test
	internal func failedCrossProfileCreationPreservesSource() async throws {
		var organization = fixture()
		let profile = Profile.ID(rawValue: UUID(10))
		let destination = Space.ID(rawValue: UUID(11))
		organization.profiles.append(.init(
			id: profile,
			name: "Isolated"
		))
		organization.spaces.append(.init(
			id: destination,
			profileID: profile,
			name: "Isolated"
		))
		let store = TestStore(initialState: MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { MainFeature() } withDependencies: {
			$0.browserEngine.open = { _ in throw BrowserEngineClient.Failure.unavailable }
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1) }
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.moveSelectedTab(destination)))
		await store.receive(\.transferTabs)
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.moveFailed)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, organization)
	}

	@Test
	internal func newProfileOwnsItsSpaceWithoutRebindingExistingSpaces() async throws {
		let organization = fixture()
		let ids = LockIsolated([UUID(10), UUID(11)])
		let store = TestStore(initialState: SidebarFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { SidebarFeature() } withDependencies: {
			$0.uuid = .init { ids.withValue { $0.removeFirst() } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.createProfile("Personal")))
		let result = store.state.organization
		try result.validate()
		expectNoDifference(Array(result.spaces.prefix(2)), Array(organization.spaces))
		expectNoDifference(result.profiles.count, 2)
		expectNoDifference(result.spaces.last?.profileID, result.profiles.last?.id)
	}
}
