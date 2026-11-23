@testable import AppFeature
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import SettingsFeature
import Testing
import _ComposableArchitecture

/// DEV-725: ⌃1 to ⌃9 switch to the space in that place of the switcher and the Library.
@Suite(.dependencies)
@MainActor
internal struct SpaceShortcutTests {
	@Test
	internal func eachSpaceCommandDefaultsToControlAndItsNumber() {
		expectNoDifference(BrowserCommand.switchToSpace.count, 9)
		for (index, command) in BrowserCommand.switchToSpace.enumerated() {
			expectNoDifference(command.spaceNumber, index + 1)
			expectNoDifference(command.shortcut, .init(key: "\(index + 1)", modifiers: .control))
			expectNoDifference(BrowserCommand.switchToSpace(index + 1), command)
		}
		expectNoDifference(BrowserCommand.switchToSpace(0), nil)
		expectNoDifference(BrowserCommand.switchToSpace(10), nil)
		expectNoDifference(BrowserCommand.nextSpace.spaceNumber, nil)
		expectNoDifference(KeyboardShortcut(key: "4", modifiers: .control).keyCaps, ["⌃", "4"])
		expectNoDifference(KeyboardShortcut(key: "k", modifiers: [.command, .shift]).keyCaps, ["⇧", "⌘", "K"])
	}

	/// DEV-1310: keys for the space beside the one shown, which give way to a binding
	/// someone already made with them.
	@Test
	internal func nextAndPreviousSpaceDefaultToOptionCommandArrows() {
		expectNoDifference(BrowserCommand.nextSpace.shortcut, .init(key: "right", modifiers: [.command, .option]))
		expectNoDifference(BrowserCommand.previousSpace.shortcut, .init(key: "left", modifiers: [.command, .option]))
		expectNoDifference(BrowserCommand.nextSpace.shortcut?.keyCaps, ["⌥", "⌘", "→"])
		expectNoDifference(BrowserCommand.previousSpace.shortcut?.keyCaps, ["⌥", "⌘", "←"])
		#expect(BrowserCommand.nextSpace.defaultShortcutYieldsToUserBindings)
		#expect(BrowserCommand.previousSpace.defaultShortcutYieldsToUserBindings)
	}

	@Test
	internal func aSpaceCommandIsAvailableOnlyWhenThatSpaceExists() {
		let context = BrowserCommandContext(host: .main, spaceCount: 3)

		#expect(BrowserCommand.space1.isEnabled(in: context))
		#expect(BrowserCommand.space3.isEnabled(in: context))
		#expect(!BrowserCommand.space4.isEnabled(in: context))
		#expect(!BrowserCommand.space1.isEnabled(in: .init(host: .little, spaceCount: 3)))
		#expect(!BrowserCommand.space1.isEnabled(in: .init(host: .main, isBusy: true, spaceCount: 3)))
	}

	@Test
	internal func aUserBindingOnTheSameKeysWinsOverTheDefault() {
		let bindings: [ShortcutBinding] = [.init(command: .newFolder, shortcut: .init(key: "2", modifiers: .control))]

		expectNoDifference(bindings.shortcut(for: .space2), nil)
		expectNoDifference(bindings.shortcut(for: .space1), .init(key: "1", modifiers: .control))
		expectNoDifference(bindings.shortcut(for: .newFolder), .init(key: "2", modifiers: .control))
	}

	@Test
	internal func theShortcutSwitchesToTheSpaceInThatPlace() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.command(.space2, .window(store.state.main.id))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.main.sidebar.spaceID, organization.spaces[1].id)

		await store.send(.ui(.command(.space1, .window(store.state.main.id))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.main.sidebar.spaceID, organization.spaces[0].id)
		await store.finish()
	}

	@Test
	internal func aShortcutForASpaceThatDoesNotExistDoesNothing() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() }

		#expect(organization.spaces.count < 9)
		await store.send(.ui(.command(.space9, .window(store.state.main.id))))
		await store.finish()
		expectNoDifference(store.state.main.sidebar.spaceID, organization.spaces[0].id)
	}

	@Test
	internal func theShortcutFollowsAReorder() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		// Move the first space to the end: ⌃1 now names the space that was second.
		await store.send(.main(.ui(.changeOrganization(.moveSpace(organization.spaces[0].id, before: nil)))))
		await store.skipReceivedActions()
		await store.send(.ui(.command(.space1, .window(store.state.main.id))))
		await store.skipReceivedActions()
		expectNoDifference(store.state.main.sidebar.spaceID, organization.spaces[1].id)
		await store.finish()
	}

	@Test
	internal func settingsListsEverySpaceCommandToRebind() async throws {
		let shortcuts = BrowserCommand.switchToSpace.map { $0.settingsShortcut(bindings: []) }

		expectNoDifference(shortcuts.map(\.keys), (1...9).map { "⌃\($0)" })
		let state = SettingsFeature.State()
		let store = TestStore(initialState: state) { SettingsFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.assignKeyboardShortcut(.space3, .init(key: "3", modifiers: [.control, .option]))))
		expectNoDifference(store.state.keyboardShortcuts.shortcut(for: .space3), .init(key: "3", modifiers: [.control, .option]))
	}
}
