import AppFeature
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func sharingKeepsTheInvokingWindowAndItsURLWhenFocusChanges() async throws {
		let organization = fixture()
		var source = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, id: UUID(900))
		source.sidebar.organization.spaces[0].selectedTabID = organization.tabs[1].id
		source.viewer.item.tab = organization.tabs[1]
		source.viewer.item.navigation.url = URL(string: "https://source.example/current")!
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.windows.append(source)
		let (started, didStart) = AsyncStream<Void>.makeStream()
		let (completion, complete) = AsyncStream<Void>.makeStream()
		var shared: [URL] = []
		var sourceID: UUID?
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.share = { urls, windowID in
				shared = urls
				sourceID = windowID
				didStart.yield(())
				didStart.finish()
				for await _ in completion { break }
				return .cancelled
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// Explicit originating window differs from the currently focused window.
		await store.send(.ui(.shareProxyLinks(sourceWindowID: source.id)))
		for await _ in started { break }
		await store.send(.ui(.focusWindow(source.id)))
		await store.send(.ui(.focusWindow(state.main.id)))
		complete.yield(())
		complete.finish()
		await store.receive(\.event.linkActionFinished)
		await store.finish()
		expectNoDifference(shared, [URL(string: "https://source.example/current")!])
		expectNoDifference(sourceID, source.id)
		expectNoDifference(store.state.linkActionFeedback?.windowID, source.id)
		expectNoDifference(store.state.linkActionFeedback?.status, .share(.cancelled))
		expectNoDifference(store.state.workspace, organization)
	}

	@Test
	internal func explicitMissingShareHostCannotFallBackToTheFocusedPagesURL() async throws {
		let organization = fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() }
		await store.send(.ui(.shareProxyLinks(sourceWindowID: UUID(901))))
		await store.finish()
	}

	@Test
	internal func copyUsesTheExplicitSourceInsteadOfTheFocusedWindow() async throws {
		let organization = fixture()
		var source = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, id: UUID(902))
		source.sidebar.organization.spaces[0].selectedTabID = organization.tabs[1].id
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.windows.append(source)
		var copied: String?
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.copy = {
				copied = $0
				return true
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.copyLinks(.original, sourceWindowID: source.id)))
		await store.receive(\.event.linkActionFinished)
		await store.finish()
		expectNoDifference(copied, organization.tabs[1].restoration.url.absoluteString)
		expectNoDifference(store.state.linkActionFeedback?.windowID, source.id)
	}
}
