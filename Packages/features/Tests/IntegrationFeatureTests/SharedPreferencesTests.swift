import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import LittleArxFeature
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct SharedPreferencesTests {
	@Test
	internal func sharedKeyEditsAskAppFeatureToSave() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument(
			client: .init(file: URL(filePath: "/dev/null/arx-unset-workspace.json")),
			organization: organization,
			preferences: .init()
		)
		let store = TestStore(
			initialState: AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		) {
			SharedPreferences()
		} withDependencies: {
			$0.workspaceDocument = document
		}

		let observation = await store.send(.observeWorkspaceDocument)
		withDependencies {
			$0.workspaceDocument = document
		} operation: {
			@Shared(.workspacePreference(\.chromeAppearance))
			var appearance

			$appearance.withLock { $0.tint.hue = 42 }
		}
		await store.receive(\.event.workspaceDocumentChanged) {
			$0.unsavedOrganization = $0.workspace
		}
		await store.receive(\.delegate.save)
		await observation.cancel()
	}

	@Test
	internal func theOrganizationIsMirroredAndAutomationWaitsForTheFlush() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument(
			client: .init(file: URL(filePath: "/dev/null/arx-unset-workspace.json")),
			organization: organization,
			preferences: .init()
		)
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let store = TestStore(initialState: state) {
			Reduce<AppFeature.State, AppFeature.Action> { state, action in
				guard case .settings(.ui(.warnsBeforeQuitting(false))) = action else { return .none }

				state.automationPreferences.isEnabled = true
				state.workspace.spaces[0].name = "Renamed"
				return .none
			}
			.mirroringIntoWorkspaceDocument()
		} withDependencies: {
			$0.workspaceDocument = document
		}
		let changes = document.changes()

		await store.send(.settings(.ui(.warnsBeforeQuitting(false)))) {
			$0.automationPreferences.isEnabled = true
			$0.workspace.spaces[0].name = "Renamed"
		}

		expectNoDifference(document.organization, store.state.workspace)

		// Automation is reducer-owned: it reaches the document only when WorkspacePersistence flushes.
		#expect(document.preferences.automation.isEnabled == false)
		expectNoDifference(store.state.persistedPreferences.automation, store.state.automationPreferences)

		// The reducer that changed the organization saves it itself.
		#expect(await changes.yields(within: .milliseconds(50)) == false)
	}

	@Test
	internal func anAppearanceEditInSettingsReachesTheWorkspaceFile() async throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("workspace.json")
		let organization = IntegrationFeatureTests().fixture()
		let client = BrowserWorkspaceClient(file: file)
		try client.save(organization)
		let document = WorkspaceDocument(client: client, organization: organization, preferences: .init())
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let store = Store(initialState: state) {
			AppFeature()
			WorkspacePersistence(workspace: client)
		} withDependencies: {
			$0.workspaceDocument = document
			$0.continuousClock = ImmediateClock()
		}

		// The save request itself is covered above; flushing directly keeps this test independent of the
		// coalescing delay, whose cancellation ID other stores in this process share.
		await store.send(.settings(.ui(.grainEnabled(false)))).finish()
		store.send(.event(.workspaceDocumentChanged))
		await store.send(.flushWorkspaceSave).finish()

		let saved = try BrowserWorkspaceClient(file: file).loadWithRecovery()
		#expect(saved.preferences.grainEnabled == false)
		#expect(store.unsavedOrganization == nil)
	}

	@Test
	internal func littleArxFollowsItsSpacesAppearance() async throws {
		var organization = IntegrationFeatureTests().fixture()
		let home = organization.spaces[0].id
		let other = organization.spaces[1].id
		organization.spaces[1].appearance = .init(tintHue: 250)
		let document = WorkspaceDocument(
			client: .init(file: URL(filePath: "/dev/null/arx-unset-workspace.json")),
			organization: organization,
			preferences: .init()
		)
		let tab = try #require(organization.tabs.first)
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			LittleArxFeature.State(id: UUID(), spaceID: home, tab: tab)
		}
		let store = TestStore(initialState: state) {
			LittleArxFeature()
		} withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		#expect(store.state.chromeAppearance == BrowserPreferences().chromeAppearance)

		await store.send(.event(.profileChanged(tab, other)))
		#expect(store.state.chromeAppearance.tint.hue == 250)

		// An override edit reaches the open window without an action.
		organization.spaces[1].appearance = .init(tintHue: 20)
		document.update(organization: organization)
		#expect(store.state.chromeAppearance.tint.hue == 20)
	}

	@Test
	internal func aSearchShortcutEditReachesEveryCommandBar() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved(BrowserPreferences(searchShortcuts: SearchShortcut.fixtures))
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
			state.windows.append(.init(organization: organization, spaceID: organization.spaces[1].id, id: UUID()))
			state.littleWindows.append(.init(id: UUID(), spaceID: organization.spaces[0].id, tab: organization.tabs[0]))
			return state
		}
		let store = TestStore(initialState: state) {
			Scope<AppFeature.State, AppFeature.Action, SettingsFeature>(state: \.settings, action: \.settings) {
				SettingsFeature()
			}
		} withDependencies: {
			$0.workspaceDocument = document
		}
		let keyword = try #require(SearchShortcut.fixtures.first?.id)

		await store.send(.settings(.ui(.toggleShortcut(keyword)))) {
			$0.settings.$searchShortcuts.withLock { $0[0].isEnabled.toggle() }
		}

		let shortcuts = store.state.settings.searchShortcuts
		#expect(shortcuts[0].isEnabled == false)
		expectNoDifference(store.state.main.commandBar.shortcuts, shortcuts)
		expectNoDifference(try #require(store.state.windows.first).commandBar.shortcuts, shortcuts)
		expectNoDifference(try #require(store.state.littleWindows.first).commandBar.shortcuts, shortcuts)
		expectNoDifference(document.preferences.searchShortcuts, shortcuts)
	}

	@Test
	internal func aKeyboardShortcutEditReachesWindowsAndRegistersTheGlobalShortcutAgain() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
			state.settings.$linkClicks.withLock { $0.globalLittleArxEnabled = true }
			state.littleWindows.append(.init(id: UUID(), spaceID: organization.spaces[0].id, tab: organization.tabs[0]))
			return state
		}
		let store = TestStore(initialState: state) {
			Scope<AppFeature.State, AppFeature.Action, SettingsFeature>(state: \.settings, action: \.settings) {
				SettingsFeature()
			}
			.reconfiguringGlobalShortcut()
		} withDependencies: {
			$0.workspaceDocument = document
		}
		let shortcut = BrowserCore.KeyboardShortcut(key: "l", modifiers: [.command, .option, .control])

		await store.send(.settings(.ui(.assignKeyboardShortcut(.littleArx, shortcut)))) {
			$0.settings.$keyboardShortcuts.withLock { $0.setShortcut(shortcut, for: .littleArx) }
		}
		await store.receive(\.configureGlobalShortcut)

		expectNoDifference(store.state.main.keyboardShortcuts.shortcut(for: .littleArx), shortcut)
		expectNoDifference(try #require(store.state.littleWindows.first).keyboardShortcuts.shortcut(for: .littleArx), shortcut)
		expectNoDifference(document.preferences.keyboardShortcuts, store.state.settings.keyboardShortcuts)
	}

	@Test
	internal func anInvalidRoutingEditNeverReachesTheSharedKey() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			SettingsFeature.State()
		}
		let store = TestStore(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// A destination in a space that doesn't exist can't be resolved.
		await store.send(.ui(.routing(.changed(.init(
			name: "Nowhere",
			host: "capturecontext.dev",
			destination: .init(scope: .space(.init(rawValue: UUID())), mode: .mainBrowser)
		)))))
		await store.send(.ui(.routing(.save(organization))))

		#expect(store.state.routing.error != nil)
		expectNoDifference(store.state.routingPreferences, RoutingPreferences())
		expectNoDifference(document.preferences.routing, RoutingPreferences())
	}

	@Test
	internal func automaticPictureInPictureSettingsReachMedia() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let store = TestStore(initialState: state) {
			Scope<AppFeature.State, AppFeature.Action, SettingsFeature>(state: \.settings, action: \.settings) {
				SettingsFeature()
			}
			.followingAutomaticPictureInPicture()
		} withDependencies: {
			$0.workspaceDocument = document
		}
		let enabled = !state.settings.automaticPictureInPicture.isEnabled

		await store.send(.settings(.ui(.automaticPictureInPicture(enabled)))) {
			$0.settings.$automaticPictureInPicture.withLock { $0.isEnabled = enabled }
			$0.media.automatic.isEnabled = enabled
		}
		#expect(document.preferences.automaticPictureInPicture.isEnabled == enabled)
	}
}

extension AsyncStream where Element == Void {
	/// Whether an element arrives within `duration`. Consumes the stream.
	fileprivate func yields(within duration: Duration) async -> Bool {
		await withTaskGroup(of: Bool.self) { group in
			group.addTask {
				for await _ in self { return true }
				return false
			}
			group.addTask {
				try? await Task.sleep(for: duration)
				return false
			}
			let first = await group.next() ?? false
			group.cancelAll()
			return first
		}
	}
}
