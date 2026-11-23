import AppKit
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

extension IntegrationFeatureTests {
	@Test
	internal func newTabAddressAndCommandsKeepTheirDistinctEntryModes() async throws {
		let organization = fixture()
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.main.viewer.item = .init(tab: organization.tabs[0], navigation: .init(url: organization.tabs[0].restoration.url))
		let store = Store(initialState: initial) { AppFeature() }
		let commands = BrowserCommands(store: store)

		commands.perform(.newTab)
		expectNoDifference(store.main.commandBar.mode, .newTab)
		expectNoDifference(store.main.commandBar.query, "")
		expectNoDifference(store.main.commandBar.entries.first?.intent, .selectTab(organization.tabs[0].id))

		commands.perform(.address)
		expectNoDifference(store.main.commandBar.mode, .currentTab)
		expectNoDifference(store.main.commandBar.query, organization.tabs[0].restoration.url.absoluteString)
		expectNoDifference(store.main.commandBar.entries.first?.intent, .selectTab(organization.tabs[0].id))

		// Over the open bar, ⌘K shows the highlighted result's actions (DEV-810); Esc closes them,
		// then the bar.
		commands.perform(.commandBar)
		expectNoDifference(store.main.commandBar.mode, .currentTab)
		#expect(store.main.commandBar.actionPanel != nil)
		store.send(.main(.commandBar(.ui(.dismissed))))
		#expect(store.main.commandBar.actionPanel == nil)
		#expect(store.main.commandBar.isPresented)
		store.send(.main(.commandBar(.ui(.dismissed))))
		#expect(!store.main.commandBar.isPresented)

		commands.perform(.commandBar)
		expectNoDifference(store.main.commandBar.mode, .commands)
		expectNoDifference(store.main.commandBar.query, "")
		expectNoDifference(store.main.commandBar.entries.first?.intent, .command(.newFolder))
	}

	@Test
	internal func menuCommandsFollowFocusedWindowAndDisableUnavailableTabActions() {
		let organization = fixture()
		var initial = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))
		initial.windows.append(.init(
			organization: organization,
			spaceID: organization.spaces[1].id,
			id: UUID(20)
		))
		initial.focusedWindowID = UUID(20)
		let store = Store(initialState: initial) { AppFeature() }
		let commands = BrowserCommands(store: store)
		#expect(!commands.isEnabled(.reload))
		#expect(!commands.isEnabled(.duplicateTab))
		#expect(commands.isEnabled(.toggleSidebar))
		commands.perform(.toggleSidebar)
		#expect(store.windows[id: UUID(20)]?.sidebar.sidebarIsVisible == false)
		#expect(store.main.sidebar.sidebarIsVisible)
	}

	@Test
	internal func shortcutDefaultsAreDistinctAndIncludeRequestedModifiers() {
		let shortcuts = BrowserCommand.allCases.compactMap(\.shortcut)
		for index in shortcuts.indices {
			#expect(!shortcuts.dropFirst(index + 1).contains(shortcuts[index]))
		}
		expectNoDifference(BrowserCommand.newPrivateWindow.shortcut, .init(key: "n", modifiers: [.command, .shift]))
		expectNoDifference(BrowserCommand.littleArx.shortcut, .init(key: "a", modifiers: [.command, .option]))
		expectNoDifference(BrowserCommand.copyURL.shortcut, .init(key: "c", modifiers: [.command, .shift]))
		expectNoDifference(BrowserCommand.clearCacheAndReload.shortcut, .init(key: "r", modifiers: [.command, .shift]))
	}

	@Test
	internal func duplicateUsesCurrentURLAndBookmarkMovesTheCopyIntoPins() async throws {
		let organization = fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let url = URL(string: "https://capturecontext.dev/current")!
		state.viewer.item.tab = organization.tabs[0]
		state.viewer.item.navigation = .init(url: url, title: "Current page")
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .constant(UUID(20))
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.duplicateTab))
		await store.receive(\.synchronize)
		await store.finish()
		let copy = try #require(store.state.sidebar.selectedTab)
		#expect(copy.id != organization.tabs[0].id)
		expectNoDifference(copy.restoration.url, url)
		expectNoDifference(copy.profileID, organization.profiles[0].id)
		#expect(copy.savedDestination == nil)

		await store.send(.ui(.pinTab))
		await store.receive(\.sidebar.ui.sidebar.move)
		await store.receive(\.synchronize)
		await store.finish()
		#expect(store.state.sidebar.space.savedItems.contains(.tab(copy.id)))
		#expect(!store.state.sidebar.space.unpinnedTabs.contains(copy.id))
		expectNoDifference(store.state.sidebar.selectedTab?.savedDestination?.url, url)
		expectNoDifference(store.state.sidebar.organization.tabs.count, 3)
	}

	@Test
	internal func privateWindowChangesNeverReachPersistentWorkspace() async throws {
		let organization = fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() } withDependencies: {
			$0.browserEngine.preparePrivateProfile = { _, _ in }
			$0.browserEngine.open = { _ in }
			$0.uuid = .constant(UUID(20))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.newPrivateWindow))
		await store.receive(\.event.privateWindowReady)
		await store.receive(\.windows)
		await store.receive(\.windows)
		await store.finish()
		let id = try #require(store.state.windows.first?.id)
		#expect(store.state.windows[id: id]?.isPrivate == true)
		#expect(store.state.windows[id: id]?.commandBar.isPresented == true)

		await store.send(.windows(.element(id: id, action: .commandBar(.ui(.queryChanged("https://private.example"))))))
		await store.send(.windows(.element(id: id, action: .commandBar(.ui(.selected("destination"))))))
		await store.receive(\.windows)
		await store.finish()
		#expect(store.state.windows[id: id]?.sidebar.organization.tabs.count == 1)
		expectNoDifference(store.state.workspace, organization)
		#expect(store.state.unsavedOrganization == nil)

		await store.send(.main(.delegate(.organizationChanged(organization))))
		await store.finish()
		#expect(store.state.windows[id: id]?.sidebar.organization.tabs.count == 1)
		#expect(store.state.windows[id: id]?.sidebar.organization.profiles[0].id != organization.profiles[0].id)
	}

	@Test
	internal func privateCloseCancellationRetainsWindowAndApprovalDisposesContext() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.windows.append(.init(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true,
			id: UUID(20)
		))
		var closed: [BrowserCore.Tab.ID] = []
		var released: [Profile.ID] = []
		var permitsClose = false
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.permitsClosing = { _ in permitsClose }
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.releasePrivateProfile = { released.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.requestClosePrivateWindow(UUID(20))))
		await store.receive(\.event.privateWindowCloseDecision)
		#expect(store.state.windows.count == 1)
		#expect(closed.isEmpty && released.isEmpty)

		permitsClose = true
		await store.send(.ui(.requestClosePrivateWindow(UUID(20))))
		await store.receive(\.event.privateWindowCloseDecision)
		await store.finish()
		#expect(store.state.windows.isEmpty)
		expectNoDifference(closed, organization.tabs.map(\.id))
		expectNoDifference(released, organization.profiles.map(\.id))
	}

	@Test
	internal func littleArxDoesNotCreatePageUntilCommandIsSubmitted() async throws {
		let organization = fixture()
		let tab = organization.tabs[0]
		var opened: [BrowserCore.Tab] = []
		let store = TestStore(initialState: LittleArxFeature.State(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: tab,
			isCommandOnly: true
		)) { LittleArxFeature() } withDependencies: {
			$0.browserEngine.open = { opened.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.task))
		await store.receive(\.commandBar.present)
		await store.finish()
		#expect(opened.isEmpty)
		#expect(store.state.commandBar.isPresented)
		#expect(store.state.viewer.tab == nil)

		await store.send(.commandBar(.ui(.queryChanged("capturecontext.dev"))))
		await store.send(.commandBar(.ui(.selected("destination"))))
		await store.receive(\.commandBar.delegate.execute)
		await store.receive(\.navigateFromCommandBar)
		await store.finish()
		#expect(!store.state.isCommandOnly)
		#expect(opened.count == 1)
		expectNoDifference(opened.first?.restoration.url, URL(string: "https://capturecontext.dev"))
	}

	@Test
	internal func dismissingInitialLittleCommandClosesWithoutOpeningPage() async {
		let organization = fixture()
		let store = TestStore(initialState: LittleArxFeature.State(
			id: UUID(20),
			spaceID: organization.spaces[0].id,
			tab: organization.tabs[0],
			isCommandOnly: true
		)) { LittleArxFeature() }
		await store.send(.commandBar(.delegate(.dismissed)))
		await store.receive(\.delegate.close)
	}
}
