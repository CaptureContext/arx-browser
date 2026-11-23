import AppUI
import BrowserCore
import _ComposableArchitecture

@Reducer
internal struct KeyboardShortcutSettings {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.selectKeyboardCommand) { state, command in
			state.selectedCommand = command
			state.recordingCommand = nil
			state.shortcutConflict = nil
			state.shortcutError = nil
			return .none
		}

		Pullback(\.ui.recordKeyboardShortcut) { state, command in
			if let command { state.selectedCommand = command }
			state.recordingCommand = command
			state.recordingAddsShortcut = false
			state.shortcutConflict = nil
			state.shortcutError = nil
			return .none
		}

		Pullback(\.ui.addKeyboardShortcut) { state, command in
			state.selectedCommand = command
			state.recordingCommand = command
			state.recordingAddsShortcut = true
			state.shortcutConflict = nil
			state.shortcutError = nil
			return .none
		}

		Pullback(\.ui.assignKeyboardShortcut) { state, value in
			let (command, shortcut) = value
			state.shortcutConflict = nil
			state.shortcutConflictResets = false

			// A refused shortcut keeps recording, so trying again records instead of running a command.
			if let shortcut {
				guard shortcut.isValid, !shortcut.isReserved else {
					state.shortcutError = String.localized(
						shortcut.isReserved
						? .appUI.settings.shortcutReserved
						: .appUI.settings.shortcutInvalid
					)
					return .none
				}
				if !state.keyboardShortcuts.conflicts(for: shortcut, excluding: command).isEmpty {
					state.shortcutConflict = .init(command: command, shortcut: shortcut)
					return .none
				}
			}

			// Keyboard shortcuts are a shared key: AppFeature saves their edits.
			let adds = state.recordingAddsShortcut && state.recordingCommand == command
			state.$keyboardShortcuts.withLock { bindings in
				if adds, let shortcut {
					bindings.addShortcut(shortcut, for: command)
				} else {
					bindings.setShortcut(shortcut, for: command)
				}
			}
			state.recordingCommand = nil
			state.recordingAddsShortcut = false
			state.shortcutError = nil
			return .none
		}

		Pullback(\.ui.replaceKeyboardShortcut) { state in
			guard let pending = state.shortcutConflict, let shortcut = pending.shortcut
			else { return .none }

			let adds = state.recordingAddsShortcut && state.recordingCommand == pending.command
			let resets = state.shortcutConflictResets
			state.shortcutConflictResets = false

			state.$keyboardShortcuts.withLock { bindings in
				let restored = resets ? pending.command.defaultShortcuts : [shortcut]
				for key in restored {
					for conflict in bindings.conflicts(for: key, excluding: pending.command) {
						bindings.removeShortcut(key, for: conflict)
					}
				}
				if resets {
					bindings.removeAll { $0.command == pending.command }
				} else if adds {
					bindings.addShortcut(shortcut, for: pending.command)
				} else {
					bindings.setShortcut(shortcut, for: pending.command)
				}
			}
			state.recordingCommand = nil
			state.recordingAddsShortcut = false
			state.shortcutConflict = nil
			state.shortcutError = nil
			return .none
		}

		Pullback(\.ui.cancelKeyboardConflict) { state in
			state.shortcutConflict = nil
			state.shortcutConflictResets = false
			return .none
		}

		Pullback(\.ui.resetKeyboardShortcut) { state, command in
			state.recordingCommand = nil
			state.shortcutError = nil
			let conflictingShortcut = command.defaultShortcuts.first { shortcut in
				!state.keyboardShortcuts.conflicts(for: shortcut, excluding: command).isEmpty
			}

			if let conflictingShortcut {
				state.shortcutConflict = .init(command: command, shortcut: conflictingShortcut)
				state.shortcutConflictResets = true
				return .none
			}
			state.$keyboardShortcuts.withLock { $0.removeAll { $0.command == command } }
			return .none
		}

		Pullback(\.ui.resetKeyboardShortcuts) { state in
			state.$keyboardShortcuts.withLock { $0 = [] }

			// The page's reset starts over: every command's Conflict resolution too (DEV-1332).
			state.$shortcutConflictChoices.withLock { $0 = [] }
			state.recordingCommand = nil
			state.shortcutConflict = nil
			state.shortcutError = nil
			return .none
		}

		Pullback(\.ui.commandAliasChanged) { state, value in
			let (command, text) = value
			state.aliasError = nil
			guard let alias = CommandAlias.normalized(text) else {
				state.$commandAliases.withLock { $0.setAlias(nil, for: command) }
				return .none
			}
			guard CommandAlias(command: command, alias: alias).isValid else {
				state.aliasError = .init(command: command, message: String.localized(.appUI.settings.aliasInvalid))
				return .none
			}
			if let owner = state.commandAliases.command(forAlias: alias), owner != command {
				state.aliasError = .init(command: command, message: String.localized(.appUI.settings.aliasTaken(owner.title)))
				return .none
			}

			// A shared key: AppFeature saves the edit.
			state.$commandAliases.withLock { $0.setAlias(alias, for: command) }
			return .none
		}

		Pullback(\.ui.shortcutConflictResolutionChanged) { state, value in
			let (command, resolution) = value
			guard command.offersConflictResolution(
				shortcuts: state.keyboardShortcuts.shortcuts(for: command),
				followsAllKeys: state.followsAllShortcutKeys
			)
			else { return .none }

			// A shared key kept on this Mac; only a choice other than the default is stored.
			state.$shortcutConflictChoices.withLock { $0.setResolution(resolution, for: command) }
			return .none
		}

		Pullback(\.event.followsAllShortcutKeys) { state, follows in
			state.followsAllShortcutKeys = follows
			return .none
		}

		Pullback(\.ui.categorySelected) { state, _ in
			state.recordingCommand = nil
			return .none
		}
	}
}
