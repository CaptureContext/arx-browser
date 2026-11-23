import BrowserCore
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

/// DEV-920: several shortcuts for one command in Settings › Shortcuts.
@Suite(.dependencies)
@MainActor
internal struct ShortcutBindingsTests {
	@Test
	internal func addShortcutKeepsTheCommandsOthers() async throws {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		store.state.$keyboardShortcuts.withLock { $0 = [] }
		let extra = KeyboardShortcut(key: "down", modifiers: [.command, .option])

		await store.send(.ui(.addKeyboardShortcut(.nextTab)))
		#expect(store.state.recordingAddsShortcut)
		await store.send(.ui(.assignKeyboardShortcut(.nextTab, extra)))
		expectNoDifference(
			store.state.keyboardShortcuts.shortcuts(for: .nextTab),
			[BrowserCommand.nextTab.shortcut!, extra]
		)
		#expect(!store.state.recordingAddsShortcut)

		// Recording without Add replaces them all.
		await store.send(.ui(.recordKeyboardShortcut(.nextTab)))
		await store.send(.ui(.assignKeyboardShortcut(.nextTab, .init(key: "f6", modifiers: []))))
		expectNoDifference(store.state.keyboardShortcuts.shortcuts(for: .nextTab), [.init(key: "f6", modifiers: [])])
	}

	@Test
	internal func resetAfterAConflictRestoresEveryDefault() async throws {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		let secondary = KeyboardShortcut(key: "[", modifiers: [.control, .shift])
		store.state.$keyboardShortcuts.withLock {
			$0 = [
				.init(command: .focusOtherPane, shortcut: nil),
				.init(command: .reload, shortcut: secondary),
			]
		}

		await store.send(.ui(.resetKeyboardShortcut(.focusOtherPane)))
		#expect(store.state.shortcutConflict?.shortcut == secondary)
		await store.send(.ui(.replaceKeyboardShortcut))

		expectNoDifference(
			store.state.keyboardShortcuts.shortcuts(for: .focusOtherPane),
			BrowserCommand.focusOtherPane.defaultShortcuts
		)
		#expect(store.state.keyboardShortcuts.shortcuts(for: .reload).isEmpty)
	}
}
