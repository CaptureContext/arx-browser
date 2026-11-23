import AppUI
import BrowserCore
import CustomDump
import SettingsFeature
import Testing
import _ComposableArchitecture

/// Settings › Shortcuts saves one alias per command, never shared, and explains what it refuses.
@Suite(.dependencies)
@MainActor
internal struct CommandAliasSettingsTests {
	@Test
	internal func anAliasIsSavedLowercasedAndRemovedWhenCleared() async throws {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		await store.send(.ui(.commandAliasChanged(.pinTab, "  Pin "))) {
			$0.$commandAliases.withLock { $0 = [.init(command: .pinTab, alias: "pin")] }
		}
		try BrowserPreferences(commandAliases: store.state.commandAliases).validate()
		await store.send(.ui(.commandAliasChanged(.pinTab, ""))) {
			$0.$commandAliases.withLock { $0 = [] }
		}
	}

	@Test
	internal func anAliasAnotherCommandHasIsRefused() async {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		await store.send(.ui(.commandAliasChanged(.pinTab, "p"))) {
			$0.$commandAliases.withLock { $0 = [.init(command: .pinTab, alias: "p")] }
		}
		await store.send(.ui(.commandAliasChanged(.reload, "P"))) {
			$0.aliasError = .init(command: .reload, message: String.localized(.appUI.settings.aliasTaken(BrowserCommand.pinTab.title)))
		}
		await store.send(.ui(.commandAliasChanged(.reload, "two words"))) {
			$0.aliasError = .init(command: .reload, message: String.localized(.appUI.settings.aliasInvalid))
		}
		await store.send(.ui(.commandAliasChanged(.reload, "r"))) {
			$0.aliasError = nil
			$0.$commandAliases.withLock { $0.append(.init(command: .reload, alias: "r")) }
		}
	}

	/// A refused shortcut keeps recording, so the next keys are recorded rather than run.
	@Test
	internal func recordingContinuesAfterARefusedShortcut() async {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		store.exhaustivity = .off
		await store.send(.ui(.recordKeyboardShortcut(.reload)))
		await store.send(.ui(.assignKeyboardShortcut(.reload, .init(key: "t"))))
		#expect(store.state.recordingCommand == .reload)
		#expect(store.state.shortcutConflict != nil)
		await store.send(.ui(.cancelKeyboardConflict))
		#expect(store.state.recordingCommand == .reload)
		await store.send(.ui(.assignKeyboardShortcut(.reload, .init(key: "y", modifiers: [.command, .shift]))))
		#expect(store.state.recordingCommand == nil)
	}
}
