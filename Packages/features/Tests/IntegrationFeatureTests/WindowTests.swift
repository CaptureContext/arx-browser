import AppFeature
import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func additionalWindowDoesNotClaimAnAlreadyPresentedPage() async throws {
		let organization = fixture()
		let id = UUID(90)
		let initial = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .constant(id)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.newWindow))
		expectNoDifference(store.state.windows.count, 1)
		expectNoDifference(store.state.focusedWindowID, id)
		#expect(store.state.windows[id: id]?.sidebar.selectedTab == nil)
		expectNoDifference(store.state.main.sidebar.organization, organization)
		await store.send(.ui(.closeAdditionalWindow(id)))
		#expect(store.state.windows.isEmpty)
		#expect(!store.state.shouldQuit)
	}

	@Test
	internal func sharedOrganizationRetainsEachWindowsSelection() async throws {
		let organization = fixture()
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)

		initial.viewer.item.tab = organization.tabs[0]
		let store = TestStore(initialState: initial) { MainFeature() }
		var changed = organization
		changed.spaces[0].name = "Renamed elsewhere"
		changed.spaces[0].selectedTabID = organization.tabs[1].id
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.reconcile(changed))
		expectNoDifference(store.state.sidebar.space.selectedTabID, organization.tabs[0].id)
		expectNoDifference(store.state.sidebar.space.name, "Renamed elsewhere")
	}

	@Test
	internal func cancelingQuitKeepsAllWindowsAndOrganization() async throws {
		let organization = fixture()
		let initial = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in false }
		}
		await store.send(.ui(.quit)) { $0.checkingQuit = true }
		await store.receive(\.event.quitDecision) { $0.checkingQuit = false }
		expectNoDifference(store.state.workspace, organization)
		#expect(!store.state.shouldQuit)
	}

	@Test(arguments: [QuitConfirmation.Answer.cancel, .quit, .quitAndStopAsking])
	internal func quitCommandAsksFirst(answer: QuitConfirmation.Answer) async throws {
		let organization = fixture()
		let asked = LockIsolated(0)

		// The cases run in parallel; one of them turns the question off, so each has its own document.
		let document = WorkspaceDocument.unsaved()
		let initial = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.browserEngine.permitsClosing = { _ in false }
			$0.quitConfirmation.confirm = { _ in
				asked.withValue { $0 += 1 }
				return answer
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.confirmQuit))
		if answer != .cancel {
			await store.receive(\.event.quitConfirmed)
			await store.receive(\.ui.quit)
			await store.skipReceivedActions()
		}
		await store.finish()
		#expect(asked.value == 1)
		#expect(store.state.settings.general.warnsBeforeQuitting == (answer != .quitAndStopAsking))
	}

	@Test
	internal func quitCommandSkipsTheQuestionWhenTurnedOff() async throws {
		let organization = fixture()
		let initial = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.settings.$general.withLock { $0.warnsBeforeQuitting = false }
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in false }
			$0.quitConfirmation.confirm = { _ in
				Issue.record("Asked to confirm")
				return .cancel
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.confirmQuit))
		await store.receive(\.ui.quit)
	}
}

extension IntegrationFeatureTests {
	@Test
	internal func selectingAPageOwnedByAnotherWindowFocusesItsExistingHost() async throws {
		let organization = fixture()
		var primary = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		primary.viewer.item.tab = organization.tabs[0]
		var secondary = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			id: UUID(90)
		)
		secondary.viewer.item.tab = organization.tabs[1]
		secondary.sidebar.select(organization.tabs[1].id)
		var initial = AppFeature.State(main: primary)

		initial.windows.append(secondary)

		initial.focusedWindowID = secondary.id
		let store = TestStore(initialState: initial) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.windows(.element(
			id: secondary.id,
			action: .sidebar(.ui(.sidebar(.select(.tab(organization.tabs[0].id.rawValue)))))
		)))
		expectNoDifference(store.state.focusedWindowID, primary.id)
		expectNoDifference(
			store.state.windows[id: secondary.id]?.sidebar.selectedTab?.id,
			organization.tabs[1].id
		)
		await store.finish()
	}
}
