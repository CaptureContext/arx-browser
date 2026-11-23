import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Every command, with its conflict resolution, its alias, which finds it in the command bar, and
/// its hotkey, in two sections (DEV-1332): Customized Shortcuts, the commands the person changed,
/// shown only while there are any, then Default Shortcuts, the rest. A row moves between them when
/// its edit ends, never while its shortcut is being recorded.
internal struct SettingsShortcutsView: View {
	internal let store: StoreOf<SettingsFeature>
	internal let shortcuts: [SettingsShortcut]

	/// Where each row was when its recording started, so it stays there until the recording ends.
	@SwiftUI.State
	private var heldSections: [BrowserCommand: Bool] = [:]

	internal init(
		store: StoreOf<SettingsFeature>,
		shortcuts: [SettingsShortcut]
	) {
		self.store = store
		self.shortcuts = shortcuts
	}

	private var matches: [SettingsShortcut] {
		shortcuts.filter { shortcut in
			if shortcut.matches(store.shortcutQuery) { return true }
			guard
				let command = BrowserCommand(rawValue: shortcut.id),
				let alias = store.commandAliases.alias(for: command),
				let query = CommandAlias.normalized(store.shortcutQuery)
			else { return false }

			return alias.hasPrefix(query)
		}
	}

	internal static var searchIndex: [SettingsSearchEntry] {
		[
			.init(
				String.localized(.appUI.settingsSearch.commands),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.commands)),
				in: .shortcuts,
				destination: .row(.shortcuts, .commands)
			),
		]
	}

	/// Whether the row goes in Customized Shortcuts: where it was while it records, else whether the
	/// person changed anything of it.
	private func isCustomized(_ command: BrowserCommand) -> Bool {
		heldSections[command] ?? store.state.isCustomized(command)
	}

	/// Whether any command at all is customized, searched for or not.
	private var hasCustomizations: Bool {
		BrowserCommand.allCases.contains(where: isCustomized)
	}

	internal var body: some View {
		let matches = matches
		let customized = matches.filter { BrowserCommand(rawValue: $0.id).map(isCustomized) ?? false }
		let others = matches.filter { !(BrowserCommand(rawValue: $0.id).map(isCustomized) ?? false) }

		// The search is pinned in the pane's navigation bar.
		VStack(alignment: .leading, spacing: 12) {
			VStack(alignment: .leading, spacing: 20) {
				if hasCustomizations {
					SettingsSection(
						String.localized(.appUI.settings.shortcutsCustomized),
						caption: String.localized(.appUI.settings.shortcutsDescription)
					) {
						if customized.isEmpty {
							Text(localized: .appUI.settings.shortcutEmpty)
								.foregroundStyle(.secondary)
								.settingsRow()
						}
						rows(customized)
					}
				}
				SettingsSection(
					String.localized(.appUI.settings.shortcutsDefault),
					caption: hasCustomizations ? nil : String.localized(.appUI.settings.shortcutsDescription),
					content: {
						if others.isEmpty {
							Text(localized: .appUI.settings.shortcutEmpty)
								.foregroundStyle(.secondary)
								.settingsRow()
						}
						rows(others)
					},
					footer: {
						VStack(alignment: .leading, spacing: 6) {
							Text("\(Text(localized: .appUI.settings.aliasHelp)) \(Text(localized: .appUI.settings.shortcutLocal))")

							// Conflict resolution, the pickers' column (DEV-1332).
							Text(localized: .appUI.settings.conflictResolution)
								.bold()
								.padding(.top, 4)
							Text(localized: .appUI.settings.conflictResolutionHelp)
						}
					}
				)
			}
			.settingsAnchor(.commands)
			Button(String.localized(.appUI.settings.shortcutResetAll)) {
				store.send(.ui(.resetKeyboardShortcuts))
			}
			.padding(.horizontal, 14)
		}
		.onChange(of: store.recordingCommand, initial: true) { _, command in holdSections(recording: command) }
		.onChange(of: store.shortcutConflict?.command) { _, _ in holdSections(recording: store.recordingCommand) }
		.onDisappear { store.send(.ui(.recordKeyboardShortcut(nil))) }
	}

	@ViewBuilder
	private func rows(_ shortcuts: [SettingsShortcut]) -> some View {
		ForEach(shortcuts) { shortcut in
			if let command = BrowserCommand(rawValue: shortcut.id) {
				SettingsShortcutRow(store: store, command: command, keys: shortcut.keys)
			}
		}
	}

	/// Keeps a row whose shortcut is being recorded, or waits on a conflict, where it is.
	private func holdSections(recording command: BrowserCommand?) {
		let editing = Set([command, store.shortcutConflict?.command].compactMap(\.self))
		heldSections = heldSections.filter { editing.contains($0.key) }
		for command in editing where heldSections[command] == nil {
			heldSections[command] = store.state.isCustomized(command)
		}
	}
}

extension SettingsFeature.State {
	/// Whether the person changed anything of the command (DEV-1332): its shortcuts (recorded or
	/// removed), its alias, or its conflict resolution.
	internal func isCustomized(_ command: BrowserCommand) -> Bool {
		keyboardShortcuts.contains { $0.command == command }
		|| commandAliases.alias(for: command) != nil
		|| shortcutConflictChoices.contains { $0.command == command }
	}
}

/// A command's icon and name, its alias field and its hotkey, which records in a popover.
private struct SettingsShortcutRow: View {
	internal let store: StoreOf<SettingsFeature>
	internal let command: BrowserCommand
	internal let keys: String

	@SwiftUI.State
	private var aliasDraft: String

	@FocusState
	private var isAliasFocused: Bool

	internal init(
		store: StoreOf<SettingsFeature>,
		command: BrowserCommand,
		keys: String
	) {
		self.store = store
		self.command = command
		self.keys = keys
		self._aliasDraft = .init(initialValue: store.commandAliases.alias(for: command) ?? "")
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 10) {
				Image(systemName: command.symbol)
					.font(.system(size: 13))
					.foregroundStyle(.secondary)
					.frame(width: 20)
					.accessibilityHidden(true)
				Text(command.title)
					.lineLimit(1)
				Spacer(minLength: 12)
				conflictPicker
				aliasField
				hotkeyButton
			}
			if let error = store.aliasError, error.command == command {
				Text(error.message)
					.font(SettingsTypography.caption)
					.foregroundStyle(.red)
					.padding(.leading, 30)
			}
		}
		.padding(.vertical, 6)
		.frame(minHeight: 40)
		.onChange(of: store.commandAliases.alias(for: command)) { _, alias in
			if !isAliasFocused { aliasDraft = alias ?? "" }
		}
	}

	/// Conflict resolution (DEV-1332): Arx, Site, Both or Delayed, left of the alias. Shown disabled
	/// at Arx for the commands that always keep their keys, and while the command has no ⌘ shortcut,
	/// which a page can't be asked about first. Hovering it shows what the chosen mode does, as a
	/// tooltip: a line that came and went under the row would move every row below it.
	@ViewBuilder
	private var conflictPicker: some View {
		// No shortcut, nothing to resolve: no picker, its room kept so the columns line up.
		if store.keyboardShortcuts.shortcuts(for: command).isEmpty {
			Color.clear
				.frame(width: Self.pickerWidth, height: 1)
				.accessibilityHidden(true)
		} else {
			conflictDropdown
		}
	}

	private static let pickerWidth: CGFloat = 100

	private var conflictDropdown: some View {
		let offers = command.offersConflictResolution(
			shortcuts: store.keyboardShortcuts.shortcuts(for: command),
			followsAllKeys: store.followsAllShortcutKeys
		)
		let resolution = offers ? store.shortcutConflictChoices.resolution(for: command) : .arx
		return ArxDropdown(
			String.localized(.appUI.settings.conflictResolution),
			selection: Binding(
				get: { resolution },
				set: { store.send(.ui(.shortcutConflictResolutionChanged(command, $0))) }
			),
			options: ShortcutConflictResolution.allCases.map { .init(id: $0, title: $0.title) },
			size: .small
		)
		.frame(width: Self.pickerWidth)
		.disabled(!offers)
		.help(conflictHint(resolution, offers: offers))
	}

	private func conflictHint(
		_ resolution: ShortcutConflictResolution,
		offers: Bool
	) -> String {
		if BrowserCommand.keepsItsKeys.contains(command) {
			return String.localized(.appUI.settings.conflictKept)
		}
		guard offers else { return String.localized(.appUI.settings.conflictNeedsCommand) }

		return resolution.hint
	}

	/// Saved on Return or when the field loses focus.
	private var aliasField: some View {
		TextField(
			String.localized(.appUI.settings.alias),
			text: $aliasDraft,
			prompt: Text(localized: .appUI.settings.alias)
		)
		.textFieldStyle(.arx(size: .small))
		.multilineTextAlignment(.center)
		.focused($isAliasFocused)
		.frame(width: 96)
		.onSubmit(commitAlias)
		.onChange(of: isAliasFocused) { _, focused in
			if !focused { commitAlias() }
		}
		.accessibilityLabel(Text(localized: .appUI.settings.alias))
	}

	private func commitAlias() {
		guard aliasDraft != (store.commandAliases.alias(for: command) ?? "") else { return }
		store.send(.ui(.commandAliasChanged(command, aliasDraft)))
	}

	private var isRecording: Bool { store.recordingCommand == command }

	/// Recording, or showing why the shortcut just pressed wasn't saved.
	private var showsRecorder: Bool {
		isRecording
			|| store.shortcutConflict?.command == command
			|| (store.selectedCommand == command && store.shortcutError != nil)
	}

	private var hasShortcut: Bool { store.keyboardShortcuts.shortcut(for: command) != nil }

	private var hotkeyButton: some View {
		Button {
			store.send(.ui(.recordKeyboardShortcut(command)))
		} label: {
			Text(hasShortcut ? keys : String.localized(.appUI.settings.shortcutRecord))

				// Dimmed while there's no shortcut, so a recorded one stands out.
				.opacity(hasShortcut || isRecording ? 1 : 0.6)
				.frame(minWidth: 92)
		}

		// Recording reads as pressed, until a shortcut is pressed or the popover closes.
		.buttonStyle(.arx(isRecording ? .primary : .secondary, size: .small))
		.accessibilityLabel(Text(command.title))
		.accessibilityValue(Text(hasShortcut ? keys : String.localized(.appUI.settings.shortcutNone)))
		.popover(
			isPresented: Binding(
				get: { showsRecorder },
				set: { if !$0, showsRecorder { store.send(.ui(.recordKeyboardShortcut(nil))) } }
			),
			arrowEdge: .bottom
		) {
			SettingsShortcutRecording(store: store, command: command)
		}
		.contextMenu {
			Button(String.localized(.appUI.settings.shortcutAdd)) {
				store.send(.ui(.addKeyboardShortcut(command)))
			}
			Button(String.localized(.appUI.settings.shortcutRemove)) {
				store.send(.ui(.assignKeyboardShortcut(command, nil)))
			}
			Button(String.localized(.appUI.settings.shortcutReset)) {
				store.send(.ui(.resetKeyboardShortcut(command)))
			}
		}
	}
}

/// Records a new hotkey: press it, or Escape to cancel. Conflicts and errors show here too.
private struct SettingsShortcutRecording: View {
	internal let store: StoreOf<SettingsFeature>
	internal let command: BrowserCommand

	internal var body: some View {
		VStack(spacing: 12) {
			Text(localized: .appUI.settings.shortcutRecording)
				.font(.callout)
				.foregroundStyle(.secondary)
			Text(recordedKeys)
				.font(.title2.monospaced())
				.foregroundStyle(.secondary)
				.padding(.horizontal, 16)
				.padding(.vertical, 10)
				.frame(minWidth: 160)
				.background(.quaternary.opacity(0.5), in: ArxControlShape())
				.overlay {
					// Only while recording: the browser's own shortcuts are held back just then.
					if store.recordingCommand == command {
						ShortcutRecorder { shortcut in
							if let shortcut {
								store.send(.ui(.assignKeyboardShortcut(command, shortcut)))
							} else {
								store.send(.ui(.recordKeyboardShortcut(nil)))
							}
						}
					}
				}
			if let error = store.shortcutError {
				Text(error)
					.font(.caption)
					.foregroundStyle(.red)
					.multilineTextAlignment(.center)
			}
			if let pending = store.shortcutConflict, pending.command == command, let shortcut = pending.shortcut {
				Text(conflictMessage(for: shortcut))
					.font(.caption)
					.multilineTextAlignment(.center)
				HStack {
					Button(String.localized(.appUI.common.cancel)) {
						store.send(.ui(.cancelKeyboardConflict))
					}
					Button(String.localized(.appUI.settings.shortcutReplace)) {
						store.send(.ui(.replaceKeyboardShortcut))
					}
					.buttonStyle(.arx(.primary))
				}
			}
			Divider()
			HStack {
				Button(String.localized(.appUI.settings.shortcutRemove)) {
					store.send(.ui(.assignKeyboardShortcut(command, nil)))
				}
				Spacer()

				// Another shortcut beside these, as Next Tab ⌘⇧] and ⌃Tab (DEV-920).
				if !store.recordingAddsShortcut, store.keyboardShortcuts.shortcut(for: command) != nil {
					Button(String.localized(.appUI.settings.shortcutAdd)) {
						store.send(.ui(.addKeyboardShortcut(command)))
					}
					Spacer()
				}
				Button(String.localized(.appUI.settings.shortcutReset)) {
					store.send(.ui(.resetKeyboardShortcut(command)))
				}
			}
			.buttonStyle(.link)
			.font(.caption)
		}
		.padding(16)
		.frame(width: 280)
	}

	/// While adding, an empty field; otherwise the command's shortcuts, or the modifiers.
	private var recordedKeys: String {
		let shortcuts = store.keyboardShortcuts.shortcuts(for: command)
		guard !store.recordingAddsShortcut, !shortcuts.isEmpty else { return "⌘ ⌥ ⇧ ⌃" }
		return shortcuts.map(\.display).joined(separator: ", ")
	}

	private func conflictMessage(for shortcut: BrowserCore.KeyboardShortcut) -> String {
		let conflicts = store.keyboardShortcuts
			.conflicts(for: shortcut, excluding: command)
			.map(\.title)
			.joined(separator: ", ")
		return String.localized(.appUI.settings.shortcutConflict) + " " + conflicts
	}
}

extension ShortcutConflictResolution {
	/// The picker's name for it (DEV-1332).
	internal var title: String {
		switch self {
		case .arx: String.localized(.appUI.settings.conflictArx)
		case .site: String.localized(.appUI.settings.conflictSite)
		case .both: String.localized(.appUI.settings.conflictBoth)
		case .delayed: String.localized(.appUI.settings.conflictDelayed)
		}
	}

	/// What it does, for the picker's tooltip (DEV-1332).
	internal var hint: String {
		switch self {
		case .arx: String.localized(.appUI.settings.conflictHintArx)
		case .site: String.localized(.appUI.settings.conflictHintSite)
		case .both: String.localized(.appUI.settings.conflictHintBoth)
		case .delayed: String.localized(.appUI.settings.conflictHintDelayed)
		}
	}
}
