import BrowserCore
import CustomDump
import Foundation
import MainFeature
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct KeyboardCommandTests {
	@Test
	internal func conflictingAssignmentRequiresExplicitReplacementAndCanBeCanceled() async throws {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		let binding = ShortcutBinding(command: .reload, shortcut: .init(key: "t"))
		await store.send(.ui(.assignKeyboardShortcut(.reload, binding.shortcut))) {
			$0.shortcutConflict = binding
		}
		expectNoDifference(store.state.keyboardShortcuts, [])
		await store.send(.ui(.cancelKeyboardConflict)) { $0.shortcutConflict = nil }
		await store.send(.ui(.assignKeyboardShortcut(.reload, binding.shortcut))) { $0.shortcutConflict = binding }

		// Keyboard shortcuts are a shared key; AppFeature saves the edit.
		await store.send(.ui(.replaceKeyboardShortcut)) {
			$0.$keyboardShortcuts.withLock {
				$0.setShortcut(nil, for: .newTab)
				$0.setShortcut(binding.shortcut, for: .reload)
			}
			$0.shortcutConflict = nil
		}
		#expect(store.state.keyboardShortcuts.shortcut(for: .newTab) == nil)
		try BrowserPreferences(keyboardShortcuts: store.state.keyboardShortcuts).validate()
		await store.send(.ui(.resetKeyboardShortcuts)) { $0.$keyboardShortcuts.withLock { $0 = [] } }
		expectNoDifference(store.state.keyboardShortcuts.shortcut(for: .newTab), .init(key: "t"))
	}

	@Test
	internal func individualResetChecksDefaultCollisionInsteadOfOverwriting() async throws {
		let initial = SettingsFeature.State()
		initial.$keyboardShortcuts.withLock {
			$0.setShortcut(nil, for: .newTab)
			$0.setShortcut(.init(key: "t"), for: .reload)
		}
		let bindings = initial.keyboardShortcuts
		let store = TestStore(initialState: initial) { SettingsFeature() }
		await store.send(.ui(.resetKeyboardShortcut(.newTab))) {
			$0.shortcutConflict = .init(command: .newTab, shortcut: .init(key: "t"))
			$0.shortcutConflictResets = true
		}
		expectNoDifference(store.state.keyboardShortcuts, bindings)
		await store.send(.ui(.recordKeyboardShortcut(.newTab))) {
			$0.recordingCommand = .newTab
			$0.shortcutConflict = nil
		}
		await store.send(.ui(.categorySelected(.profiles))) {
			$0.category = .profiles
			$0.recordingCommand = nil
		}
	}

	@Test
	internal func commandBarKeepsOriginWindowAndRechecksAvailability() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.main.viewer.item.tab = organization.tabs[0]
		let otherID = UUID(20)
		initial.windows.append(.init(organization: organization, spaceID: organization.spaces[1].id, id: otherID))
		initial.focusedWindowID = otherID
		let store = TestStore(initialState: initial) { AppFeature() }
		await store.send(.main(.delegate(.command(.toggleSidebar))))
		await store.receive(\.ui.command)
		await store.receive(\.main.sidebar.ui.sidebar) { $0.main.sidebar.sidebarIsVisible = false }
		await store.receive(\.main.synchronize)

		// Sidebar synchronization delegates persistence even for a visibility change.
		await store.receive(\.main.delegate.organizationChanged) { $0.unsavedOrganization = organization }
		expectNoDifference(store.state.windows[id: otherID]?.sidebar.sidebarIsVisible, true)
		await store.receive(\.delegate.save)

		// No tab exists in the second space, so an old result cannot invoke reload there.
		await store.send(.ui(.command(.reload, .window(otherID))))
		await store.send(.ui(.command(.toggleSidebar, .window(UUID(99)))))
		await store.finish()
	}

	@Test
	internal func presentedCommandsUseTheSameAvailabilityAsNativeDispatch() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let state = MainFeature.State(organization: organization, spaceID: organization.spaces[1].id)
		let offered = state.commandCandidates.compactMap { entry -> BrowserCommand? in
			guard case let .command(command) = entry.intent else { return nil }
			return command
		}
		expectNoDifference(offered, BrowserCommand.allCases.filter { $0.isEnabled(in: state.commandContext) })
		#expect(!offered.contains(.reload))
		#expect(offered.contains(.newFolder))
	}

	@Test
	internal func archiveCommandOpensOriginatingProfileAndRejectsPrivateHosts() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var initial = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let otherID = UUID(20)
		initial.windows.append(.init(organization: organization, spaceID: organization.spaces[1].id, isPrivate: true, id: otherID))
		initial.focusedWindowID = otherID
		let store = TestStore(initialState: initial) { AppFeature() }
		await store.send(.ui(.command(.openArchive, .window(otherID))))
		await store.send(.ui(.command(.openArchive, .window(initial.main.id))))
		await store.receive(\.main.ui.openArchive) {
			$0.main.archive.profileID = organization.spaces[0].profileID
			$0.main.archive.profileName = organization.profiles[0].name
			$0.main.archive.spaces = organization.spaces
			$0.main.archive.profiles = organization.profiles
			$0.main.archive.isPresented = true
		}
		expectNoDifference(store.state.windows[id: otherID]?.archive.isPresented, false)
		await store.finish()
	}
}
