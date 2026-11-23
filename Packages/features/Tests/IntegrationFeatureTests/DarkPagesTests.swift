import BrowserCore
import BrowserWorkspaceClient
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature
@testable import MainFeature

/// DEV-1020: Settings' dark pages mode, and the Dark Page command and site menu switch.
@Suite(.dependencies)
@MainActor
internal struct DarkPagesTests {
	@Test
	internal func theModeSavesOnlyWhileDarkPagesAreAvailable() async {
		let (unavailable, document) = Self.state(available: false)
		let store = TestStore(initialState: unavailable) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.darkPages(.always))))
		#expect(store.state.settings.general.darkPages == .off)
		#expect(!store.state.main.darkPagesOffered)

		let (available, availableDocument) = Self.state(available: true)
		let offered = TestStore(initialState: available) { AppFeature() } withDependencies: {
			$0.workspaceDocument = availableDocument
		}
		offered.exhaustivity = .off(showSkippedAssertions: false)

		await offered.send(.settings(.ui(.darkPages(.withTheme))))
		#expect(availableDocument.preferences.darkPages == .withTheme)
		#expect(offered.state.main.darkPagesOffered)
		#expect(offered.state.main.commandCandidates.contains { $0.intent == .command(.darkPage) })

		await offered.send(.settings(.ui(.darkPages(.off))))
		#expect(!offered.state.main.darkPagesOffered)
		#expect(!offered.state.main.commandCandidates.contains { $0.intent == .command(.darkPage) })
	}

	@Test
	internal func theCommandTurnsThePagesSiteOffAndBackOnInItsProfile() async throws {
		let (state, document) = Self.state(available: true, mode: .always)
		let profileID = try #require(state.workspace.profiles.first?.id)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.command(.darkPage, .window(state.main.id))))
		await store.receive(\.delegate.save)
		#expect(store.state.workspace.profiles[id: profileID]?.darkPagesOffSites == ["capturecontext.dev"])
		#expect(store.state.main.siteMenuContext?.darkPage == false)

		await store.send(.ui(.command(.darkPage, .window(state.main.id))))
		await store.receive(\.delegate.save)
		#expect(store.state.workspace.profiles[id: profileID]?.darkPagesOffSites == nil)
		#expect(store.state.main.siteMenuContext?.darkPage == true)
	}

	@Test
	internal func whileOffTheCommandAndTheSwitchAreAbsent() async throws {
		let (state, document) = Self.state(available: true, mode: .off)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.command(.darkPage, .window(state.main.id))))
		#expect(store.state.workspace.profiles.allSatisfy { $0.darkPagesOffSites == nil })
		#expect(store.state.main.siteMenuContext?.darkPage == nil)
	}

	@Test
	internal func theSwitchFollowsTheCommandWhileTheMenuStaysOpen() async throws {
		var (state, document) = Self.state(available: true, mode: .always)
		let profileID = try #require(state.workspace.profiles.first?.id)

		// The site menu is open over the page.
		state.main.siteMenu.context = state.main.siteMenuContext
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.command(.darkPage, .window(state.main.id))))
		await store.receive(\.delegate.save)
		#expect(store.state.workspace.profiles[id: profileID]?.darkPagesOffSites == ["capturecontext.dev"])

		// The menu's switch shows off now; turning it back on reaches the profile.
		await store.send(.main(.ui(.siteMenu(.setDarkPage(true)))))
		await store.receive(\.delegate.save)
		#expect(store.state.workspace.profiles[id: profileID]?.darkPagesOffSites == nil)
	}

	@Test
	internal func theSwitchDoesNothingOnceTheMenusPageIsAnotherProfiles() async throws {
		var (state, document) = Self.state(available: true, mode: .always)

		// The menu opened over the same address in another profile's tab.
		state.main.siteMenu.context = state.main.siteMenuContext
		state.main.siteMenu.context?.profileID = .init(rawValue: UUID())
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.ui(.siteMenu(.setDarkPage(false)))))
		#expect(store.state.workspace.profiles.allSatisfy { $0.darkPagesOffSites == nil })
	}

	@Test
	internal func aWebKitPageHasNoSwitchOrCommand() async throws {
		var (state, document) = Self.state(available: true, mode: .always)
		let tab = try #require(state.main.viewer.item.tab)
		state.main.viewer.item.navigation = .init(url: tab.restoration.url, engine: .webKit)
		#expect(!state.main.commandContext.darkPagesOffered)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		#expect(store.state.main.siteMenuContext?.darkPage == nil)
		await store.send(.ui(.command(.darkPage, .window(state.main.id))))
		#expect(store.state.workspace.profiles.allSatisfy { $0.darkPagesOffSites == nil })
	}

	private static func state(
		available: Bool,
		mode: DarkPagesMode = .off
	) -> (AppFeature.State, WorkspaceDocument) {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved()
		document.updatePreferences(requestsSave: false) { $0.darkPages = mode }
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}

		// The window shows its selected tab's page.
		if let tab = state.main.sidebar.selectedTab {
			state.main.viewer.item.tab = tab
			state.main.viewer.item.navigation = .init(url: tab.restoration.url)
		}
		state.settings.darkPagesAvailable = available
		state.reconcileDarkPages()
		return (state, document)
	}
}
