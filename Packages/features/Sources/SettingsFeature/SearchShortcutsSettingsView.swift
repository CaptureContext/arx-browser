import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Search Shortcuts as a list, as Air Traffic Control lists its routes: each shortcut with its
/// switch, Edit and Remove. Add Shortcut and Edit open the shortcut's form in a sheet (DEV-1001).
/// Helium's
/// bundled bangs follow, read-only. The sheet's bar searches them (DEV-782): while it holds a
/// query, only the matching bangs show.
internal struct SearchShortcutsSettingsView: View {
	internal let store: StoreOf<SettingsFeature>

	internal init(store: StoreOf<SettingsFeature>) {
		self.store = store
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			if !isSearchingBangs {
				Text(localized: .appUI.search.instructions)
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				shortcuts
			}
			BundledBangsSection(store: store)
		}
	}

	// MARK: - Shortcuts

	private var shortcuts: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(localized: .appUI.search.list)
					.font(.system(size: 13, weight: .semibold))
					.accessibilityAddTraits(.isHeader)
				Spacer()
				Button(String.localized(.appUI.search.addShortcut), systemImage: "plus") {
					store.send(.ui(.addShortcut))
				}
				.disabled(isAddingShortcut)
			}
			.padding(.horizontal, 14)

			// Arx starts with none: the bundled bangs below work without any (DEV-1321).
			SettingsSection {
				if store.searchShortcuts.isEmpty, !isAddingShortcut {
					Text(localized: .appUI.search.empty)
						.foregroundStyle(.secondary)
						.settingsRow()
				}
				ForEach(store.searchShortcuts) { shortcut in
					SearchShortcutRow(
						shortcut: shortcut,
						onToggle: { store.send(.ui(.toggleShortcut(shortcut.id))) },
						onEdit: { store.send(.ui(.editShortcut(shortcut.id))) },
						onRemove: { store.send(.ui(.deleteShortcut(shortcut.id))) }
					)
				}
			}
		}
		.sheet(
			isPresented: Binding(
				get: { store.isEditingShortcut },
				set: { if !$0 { store.send(.ui(.cancelShortcutEdit)) } }
			)
		) {
			SearchShortcutEditor(store: store, isNew: isAddingShortcut)
		}
	}

	private var isSearchingBangs: Bool {
		!store.bangQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	private var isAddingShortcut: Bool {
		store.isEditingShortcut && store.editingKeyword == nil
	}
}

/// One shortcut: its name and `!keyword`, the search URL under them, then its switch, Edit and
/// Remove. The context menu offers Edit and Remove too.
private struct SearchShortcutRow: View {
	internal let shortcut: SearchShortcut
	internal let onToggle: () -> Void
	internal let onEdit: () -> Void
	internal let onRemove: () -> Void

	internal var body: some View {
		HStack(spacing: 10) {
			Image(systemName: "magnifyingglass")
				.foregroundStyle(.secondary)
				.frame(width: 18)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(shortcut.name)
					Text("!" + shortcut.keyword)
						.foregroundStyle(.secondary)
				}
				Text(shortcut.template)
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			.accessibilityElement(children: .combine)
			Spacer(minLength: 12)
			Toggle(shortcut.name, isOn: Binding(get: { shortcut.isEnabled }, set: { _ in onToggle() }))
				.toggleStyle(.switch)
				.controlSize(.mini)
				.labelsHidden()
			Button(String.localized(.appUI.search.edit), action: onEdit)
				.controlSize(.small)
			Button(action: onRemove) {
				Image(systemName: "minus.circle.fill")
					.foregroundStyle(.secondary)
			}
			.buttonStyle(.arx(.plain, size: .small))
			.help(String.localized(.appUI.search.remove))
			.accessibilityLabel(Text(localized: .appUI.search.remove))
		}
		.opacity(shortcut.isEnabled ? 1 : 0.55)
		.padding(.vertical, 10)
		.contentShape(.rect)
		.contextMenu {
			Button(String.localized(.appUI.search.edit), action: onEdit)
			Button(String.localized(.appUI.search.remove), role: .destructive, action: onRemove)
		}
	}
}

/// A shortcut being added or edited, in its own sheet (DEV-1001): its fields, then Cancel (Esc)
/// and Add or Save (↩), and Delete for a saved one.
internal struct SearchShortcutEditor: View {
	internal let store: StoreOf<SettingsFeature>
	internal let isNew: Bool

	internal var body: some View {
		SettingsListForm(
			title: isNew ? String.localized(.appUI.search.newShortcut) : store.draft.name,
			primaryTitle: String.localized(isNew ? .appUI.settings.siteForm.add : .appUI.common.save),
			isValid: (try? store.draft.validate()) != nil,
			message: store.error,
			deleteTitle: String.localized(.appUI.search.remove),
			onCancel: { store.send(.ui(.cancelShortcutEdit)) },
			onSubmit: { store.send(.ui(.saveShortcut)) },
			onDelete: store.editingKeyword.map { keyword in
				{ store.send(.ui(.deleteShortcut(keyword))) }
			}
		) {
			HStack(spacing: 10) {
				SettingsTextField(
					String.localized(.appUI.common.name),
					text: draft(\.name),
					prompt: String.localized(.appUI.settings.example.searchName)
				)
				SettingsTextField(
					String.localized(.appUI.search.keyword),
					text: draft(\.keyword),
					prompt: String.localized(.appUI.settings.example.keyword)
				)
				.frame(width: 160)
			}
			SettingsFieldFrame(String.localized(.appUI.search.template)) {
				TemplateField(
					String.localized(.appUI.settings.example.searchTemplate),
					text: draft(\.template),
					placeholders: [.query],
					isBordered: false,
					label: String.localized(.appUI.search.template)
				)
			}
			SettingsTextField(
				String.localized(.appUI.search.homepage),
				text: Binding(
					get: { store.draft.homepage?.absoluteString ?? "" },
					set: { value in
						var draft = store.draft
						draft.homepage = value.isEmpty ? nil : URL(string: value)
						store.send(.ui(.draftChanged(draft)))
					}
				),
				prompt: String.localized(.appUI.settings.example.homepage)
			)
		}
	}

	private func draft(_ keyPath: WritableKeyPath<SearchShortcut, String>) -> Binding<String> {
		Binding(
			get: { store.draft[keyPath: keyPath] },
			set: { value in
				var draft = store.draft
				draft[keyPath: keyPath] = value
				store.send(.ui(.draftChanged(draft)))
			}
		)
	}
}

/// Helium's bundled bangs: read-only, filtered by the sheet bar's search. The user's own
/// shortcuts stay above.
private struct BundledBangsSection: View {
	internal let store: StoreOf<SettingsFeature>

	internal var body: some View {
		SettingsSection(
			String.localized(.appUI.search.bundled),
			content: {
				if store.bangs.bangs.isEmpty {
					Text(localized: .appUI.search.bundledLoading)
						.foregroundStyle(.secondary)
						.settingsRow()
				} else {
					let results = store.bundledBangResults
					if results.isEmpty {
						Text(localized: .appUI.search.bundledNoMatches)
							.foregroundStyle(.secondary)
							.settingsRow()
					}
					ForEach(results, id: \.keywords) { bang in
						BundledBangRow(
							bang: bang,
							overridden: bang.keywords.filter { keyword in
								store.searchShortcuts.contains { $0.id == keyword }
							}
						)
					}
				}
			},
			footer: { Text(localized: .appUI.search.bundledFooter(store.bangs.keywordCount)) }
		)
	}
}

private struct BundledBangRow: View {
	internal let bang: BangCatalog.Bang

	/// Keywords the user's own shortcuts answer instead.
	internal let overridden: [String]

	internal var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(bang.name)
			Text(bang.keywords.map { "!" + $0 }.joined(separator: " "))
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
				.lineLimit(2)
			if !overridden.isEmpty {
				Text(localized: .appUI.search.bundledOverridden(
					overridden.map { "!" + $0 }.joined(separator: ", ")
				))
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
			}
		}
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, alignment: .leading)
		.accessibilityElement(children: .combine)
	}
}
