import AppKit
import AppUI
import BrowserCore
import ExtensionsFeature
import MigrationAssistant
import SwiftUI
import _ComposableArchitecture

/// Customize: the Migration Assistant in full, drawn as an Arx modal (DEV-791). A glassy
/// header bar with Close, the source's name and Choose a File…, settings-list sections for the
/// source and the kinds of data, then a review with the profile mapping (DEV-842), and the
/// actions pinned in a footer as modal buttons. Passwords and sign-ins are one of the kinds;
/// after the import their step takes over the modal.
public struct MigrationAssistantView: View {
	public let store: StoreOf<MigrationAssistantFeature>
	private let barTopInset: CGFloat

	/// - Parameters:
	///   - barTopInset: keeps the header bar clear of traffic lights over the view, while its
	///     soft edge still runs to the top (onboarding's window).
	public init(
		store: StoreOf<MigrationAssistantFeature>,
		barTopInset: CGFloat = 0
	) {
		self.store = store
		self.barTopInset = barTopInset
	}

	public var body: some View {
		ArxModalScaffold(barTopInset: barTopInset) {
			ArxHeaderBar(
				.close { store.send(.ui(.dismiss)) },
				title: store.showsCredentials
				? String.localized(.appUI.migration.credentials.title)
				: String.localized(.appUI.migration.title),
				subtitle: store.selectedSource?.name
			) {
				if store.phase == .selecting {
					Button(String.localized(.appUI.migration.chooseFile), action: chooseFile)
						.buttonStyle(.arxRaised(.capsule))
				}
			}
			.disabled(!store.canDismiss)
		} content: {
			if store.showsCredentials, let credentials = store.scope(state: \.credentials, action: \.credentials) {
				CredentialMigrationContent(store: credentials)
			} else {
				VStack(alignment: .leading, spacing: 20) {
					if let problem = store.problem {
						Label(problem.message, systemImage: "exclamationmark.triangle.fill")
							.foregroundStyle(.orange)
							.fixedSize(horizontal: false, vertical: true)
					}

					content
				}
			}
		} footer: {
			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				Spacer(minLength: 0)
				if store.showsCredentials, let credentials = store.scope(state: \.credentials, action: \.credentials) {
					CredentialMigrationActions(store: credentials)
				} else {
					actions
				}
			}
		}
		.task { store.send(.ui(.task)) }
		.extensionImportReview(store.scope(state: \.extensionImport, action: \.extensionImport))
	}

	@ViewBuilder
	private var content: some View {
		switch store.phase {
		case .idle, .discovering:
			MigrationProgressRow(title: nil)

		case .selecting:
			selection

		case .confirmingClear:
			if let existing = store.existingData {
				ClearConfirmation(existing: existing)
			}

		case .clearing:
			MigrationProgressRow(title: String.localized(.appUI.migration.clearing))

		case .inspecting:
			MigrationProgressRow(title: String.localized(.appUI.migration.reading))

		case .previewing:
			if let preview = store.preview {
				if store.offersMapping, !store.mappings.isEmpty {
					mappings
				}

				// Passwords follow the mapping, so they're set up right under it.
				if let credentials = store.scope(state: \.credentials, action: \.credentials) {
					CredentialConfiguration(store: credentials)
				}
				ForEach(preview.categories, id: \.category) { category in
					PreviewRow(category: category)
				}

				// Spaces that bring their colors show them (DEV-897).
				if preview.spaces.contains(where: { $0.appearance != nil }) {
					SpaceColors(spaces: preview.spaces, sourceName: store.selectedSource?.name ?? "")
				}
			}

		case .importing, .cancelling:
			SettingsSection {
				ProgressView(value: store.progress?.fractionCompleted ?? 0) {
					Text(
						localized: store.phase == .cancelling
						? .appUI.migration.cancelling
						: .appUI.migration.importing
					)
				}
				.settingsGroupRow()
			}

		case .finished:
			if let report = store.report {
				ResultView(report: report)
			}
			if let extensions = store.extensionImport {
				ExtensionImportSection(state: extensions) {
					store.send(.extensionImport(.ui(.skipAll)))
				}
			}
		}
	}

	@ViewBuilder
	private var selection: some View {
		if store.sources.isEmpty {
			SettingsSection(footer: String.localized(.appUI.migration.sourceUnchanged)) {
				SettingsRow(String.localized(.appUI.migration.noSources)) {
					EmptyView()
				}
			}

		} else {
			SettingsSection(footer: String.localized(.appUI.migration.sourceUnchanged)) {
				SettingsRow(String.localized(.appUI.migration.source)) {
					ArxDropdown(
						String.localized(.appUI.migration.source),
						selection: Binding(
							get: { store.selectedSourceID ?? store.sources[0].id },
							set: { store.send(.ui(.selectSource($0))) }
						),
						options: store.sources.map { source in
							ArxSuggestion(
								id: source.id,
								title: [source.name, source.version].compactMap { $0 }.joined(separator: " ")
							)
						}
					)
				}
			}

			if store.needsFullDiskAccess, let source = store.selectedSource {
				FullDiskAccessPrompt(sourceName: source.name, status: store.fullDiskAccess) {
					store.send(.ui(.allowFullDiskAccess))
				}
			} else {
				SettingsSection(String.localized(.appUI.migration.categories)) {
					ForEach(store.offeredCategories, id: \.self) { category in
						SettingsToggle(
							category.title,
							isOn: Binding(
								get: { store.selectedCategories.contains(category) },
								set: { _ in store.send(.ui(.toggleCategory(category))) }
							)
						)
					}

					if store.offersCredentials {
						SettingsToggle(
							String.localized(.appUI.migration.credentials.kind),
							detail: String.localized(.appUI.migration.credentials.kindDetail),
							isOn: Binding(
								get: { store.includesCredentials },
								set: { _ in store.send(.ui(.toggleCredentials)) }
							)
						)
					}
				}
			}

			if store.existingData != nil {
				SettingsSection(footer: String.localized(.appUI.migration.clearFooter)) {
					SettingsToggle(
						String.localized(.appUI.migration.clearFirst),
						isOn: Binding(
							get: { store.clearsExistingData },
							set: { store.send(.ui(.setClearsExistingData($0))) }
						)
					)
				}
			}
		}
	}

	private func chooseFile() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.allowedContentTypes = [.json, .html]
		if panel.runModal() == .OK, let url = panel.url {
			store.send(.ui(.fileChosen(url)))
		}
	}

	/// Each source profile into a new Arx profile, named here, or one that exists (DEV-842).
	private var mappings: some View {
		SettingsSection(
			String.localized(.appUI.migration.mapping.title),
			footer: String.localized(.appUI.migration.mapping.footer(store.selectedSource?.name ?? ""))
		) {
			ForEach(store.mappings) { mapping in
				ProfileMappingRow(
					mapping: mapping,
					options: store.profileOptions,
					allowsNewProfile: store.allowsNewProfiles,
					map:{ store.send(.ui(.mapProfile(mapping.id, $0))) },
					rename: { store.send(.ui(.renameProfile(mapping.id, $0))) }
				)
			}
		}
	}

	@ViewBuilder
	private var actions: some View {
		switch store.phase {
		case .selecting:
			ArxModalButton(String.localized(.appUI.migration.continue)) { store.send(.ui(.inspect)) }
				.disabled(!store.canInspect)

		case .confirmingClear:
			ArxModalButton(String.localized(.appUI.migration.back), prominence: .secondary, key: nil) {
				store.send(.ui(.back))
			}

			// No Return shortcut: removing Arx's data takes a deliberate click.
			ArxModalButton(
				String.localized(.appUI.migration.clearAndContinue),
				prominence: .destructive,
				key: nil
			) {
				store.send(.ui(.confirmClear))
			}

		case .inspecting, .importing:
			ArxModalButton(String.localized(.appUI.migration.cancel), prominence: .secondary, key: nil) {
				store.send(.ui(.cancel))
			}

		case .previewing:
			ArxModalButton(String.localized(.appUI.migration.back), prominence: .secondary, key: nil) {
				store.send(.ui(.back))
			}
			ArxModalButton(String.localized(.appUI.migration.import)) { store.send(.ui(.startImport)) }
				.disabled(!store.canImport)

		case .finished:
			if store.canRetry {
				ArxModalButton(String.localized(.appUI.migration.retry), prominence: .secondary, key: nil) {
					store.send(.ui(.retry))
				}
			}
			ArxModalButton(String.localized(.appUI.migration.done)) { store.send(.ui(.done)) }

		case .idle, .discovering, .cancelling, .clearing:
			EmptyView()
		}
	}
}

/// One source profile and where it goes: a new profile with an editable name, or an
/// existing one.
private struct ProfileMappingRow: View {
	internal let mapping: MigrationAssistantFeature.ProfileMapping
	internal let options: [MigrationAssistantFeature.ProfileOption]

	/// Onboarding after iCloud offers existing profiles only (DEV-1220).
	internal let allowsNewProfile: Bool
	internal let map: (Profile.ID?) -> Void
	internal let rename: (String) -> Void

	internal var body: some View {
		SettingsRow(mapping.sourceName) {
			ArxDropdown(
				mapping.sourceName,
				selection: Binding<Profile.ID?>(
					get: { mapping.profileID },
					set: { map($0) }
				),
				options: newProfileOptions + options.map { option in
					ArxSuggestion(id: Optional(option.id), title: option.title)
				}
			)
		}

		if mapping.profileID == nil {
			// Arx's labelled field (DEV-847). An empty name shows the source's as its prompt,
			// and the import names the new profile after the source then.
			SettingsTextField(
				String.localized(.appUI.migration.mapping.name),
				text: Binding(
					get: { mapping.newName },
					set: { rename($0) }
				),
				prompt: mapping.sourceName
			)
			.settingsGroupRow()
		}
	}

	private var newProfileOptions: [ArxSuggestion<Profile.ID?>] {
		guard allowsNewProfile else { return [] }

		return [ArxSuggestion(id: nil, title: String.localized(.appUI.migration.mapping.newProfile))]
	}
}

/// What "Clear Arx data first" removes, named before anything happens.
private struct ClearConfirmation: View {
	internal let existing: MigrationAssistantFeature.ExistingData

	internal var body: some View {
		SettingsSection(
			String.localized(.appUI.migration.clearTitle),
			footer: String.localized(.appUI.migration.clearConfirmationFooter)
		) {
			SettingsRow(
				String.localized(.appUI.migration.clearProfiles),
				detail: existing.profileNames.formatted(.list(type: .and))
			) {
				Text(existing.profileNames.count, format: .number)
					.monospacedDigit()
					.foregroundStyle(.secondary)
			}
			CountRow(label: .appUI.migration.clearSpaces, count: existing.spaceCount)
			CountRow(label: .appUI.migration.clearTabs, count: existing.tabCount)
			SettingsRow(String.localized(.appUI.migration.clearProfileData)) {
				EmptyView()
			}
		}
	}
}

/// A spinner on a card while the assistant looks for browsers or reads one.
internal struct MigrationProgressRow: View {
	internal let title: String?

	internal var body: some View {
		SettingsSection {
			HStack(spacing: 10) {
				ProgressView()
					.controlSize(.small)
				if let title {
					Text(title)
						.foregroundStyle(.secondary)
				}
				Spacer(minLength: 0)
			}
			.settingsGroupRow()
		}
	}
}

/// A category the import would bring: its counts on a card, with notes under it.
/// The source's spaces with the colors they bring (DEV-897).
private struct SpaceColors: View {
	internal let spaces: [MigrationSourceSpace]
	internal let sourceName: String

	internal var body: some View {
		SettingsSection(
			String.localized(.appUI.migration.spaces.title),
			footer: String.localized(.appUI.migration.spaces.footer(sourceName))
		) {
			ForEach(spaces) { space in
				SettingsRow([emoji(space.icon), space.name].compactMap { $0 }.joined(separator: " ")) {
					if let appearance = space.appearance {
						AppearanceSwatch(appearance)
					}
				}
			}
		}
	}

	/// A symbol name isn't text, so only an emoji icon shows before the name.
	private func emoji(_ icon: String?) -> String? {
		icon.flatMap(SpaceIcon.init(rawValue:)).flatMap { $0.isEmoji ? $0.rawValue : nil }
	}
}

private struct PreviewRow: View {
	private let category: MigrationPreview.Category

	internal init(category: MigrationPreview.Category) {
		self.category = category
	}

	internal var body: some View {
		SettingsSection(category.category.title) {
			if category.category == .preferences {
				if category.preferences != nil {
					SettingsRow(String.localized(.appUI.migration.preferencesNote)) {
						EmptyView()
					}
				}

			} else if category.category == .extensions {
				// DEV-845: store extensions install after the import; the rest are listed.
				CountRow(
					label: .appUI.migration.extensionsFromStore,
					count: category.reinstalls.count(where: \.installsFromStore)
				)
				CountRow(
					label: .appUI.migration.extensionsManual,
					count: category.reinstalls.count { !$0.installsFromStore }
				)

			} else {
				CountRow(label: .appUI.migration.new, count: category.tabCount)
			}
			if category.category != .extensions {
				CountRow(label: .appUI.migration.alreadyImported, count: category.alreadyImported.count)
				CountRow(label: .appUI.migration.invalid, count: category.issues.count(where: \.isInvalid))
			}
		} footer: {
			VStack(alignment: .leading, spacing: 4) {
				if category.reinstalls.contains(where: \.installsFromStore) {
					Text(localized: .appUI.migration.extensionsReview)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				IssueNotes(issues: category.issues)
			}
		}
	}
}

/// What a run brought, per category.
private struct ResultView: View {
	private let report: MigrationReport

	internal init(report: MigrationReport) {
		self.report = report
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 20) {
			Label {
				Text(report.outcome.message)
					.fixedSize(horizontal: false, vertical: true)
			} icon: {
				Image(systemName: report.outcome == .completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
					.foregroundStyle(report.outcome == .completed ? Color.green : Color.orange)
			}

			ForEach(report.categories, id: \.category) { category in
				SettingsSection(category.category.title) {
					CountRow(
						label: .appUI.migration.imported,
						count: importedItemCount(category)
					)
					CountRow(label: .appUI.migration.alreadyImported, count: category.alreadyImported.count)
					CountRow(label: .appUI.migration.invalid, count: category.issues.count(where: \.isInvalid))
				} footer: {
					IssueNotes(issues: category.issues)
				}
			}
		}
	}

	/// Spaces, folders and profiles are organization, not imported items.
	private func importedItemCount(_ category: MigrationReport.Category) -> Int {
		category.imported
			.filter { item in
				let id = item.sourceItemID
				return !id.hasPrefix("space:")
				&& !id.hasPrefix("folder:")
				&& !id.hasPrefix("profile:")
			}
			.count
	}
}

/// What isn't imported and what to reinstall, under a category's card.
private struct IssueNotes: View {
	internal let issues: [MigrationIssue]

	internal var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			UnsupportedNote(issues: issues)
			ReinstallNote(issues: issues)
		}
	}
}

/// Names what Arx has no equivalent for, so nothing goes missing silently.
private struct UnsupportedNote: View {
	private let issues: [MigrationIssue]

	internal init(issues: [MigrationIssue]) {
		self.issues = issues
	}

	private var kinds: [String] {
		var seen: Set<MigrationIssue.UnsupportedKind> = []
		return issues.compactMap { issue in
			guard
				case let .unsupported(kind) = issue.reason,
				seen.insert(kind).inserted
			else { return nil }

			return kind.title
		}
	}

	internal var body: some View {
		if !kinds.isEmpty {
			Text(localized: .appUI.migration.notImported(kinds.formatted(.list(type: .and))))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

/// Extensions Arx can't install for the user: not from the Chrome Web Store, or with no
/// source profile (an Arx archive's). Store extensions link to their page.
private struct ReinstallNote: View {
	private let issues: [MigrationIssue]

	internal init(issues: [MigrationIssue]) {
		self.issues = issues
	}

	private var extensions: [MigrationIssue.Extension] {
		issues.compactMap { issue in
			guard
				case let .reinstallManually(value) = issue.reason,
				!value.installsFromStore
			else { return nil }
			return value
		}
	}

	internal var body: some View {
		if !extensions.isEmpty {
			VStack(alignment: .leading, spacing: 4) {
				Text(localized: .appUI.migration.reinstallExtensions(
					extensions.map(\.name).formatted(.list(type: .and))
				))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

				ForEach(extensions, id: \.id) { value in
					if value.fromWebStore, let url = value.storeURL {
						Link(value.name, destination: url)
					}
				}
			}
		}
	}
}

/// Store extensions installed after the import (DEV-845): progress, then each one's outcome.
private struct ExtensionImportSection: View {
	private let state: ExtensionImportFeature.State

	/// Leaves out the rest, also while a package is still downloading.
	private let skipAll: () -> Void

	internal init(
		state: ExtensionImportFeature.State,
		skipAll: @escaping () -> Void
	) {
		self.state = state
		self.skipAll = skipAll
	}

	private var items: [ExtensionImportFeature.Item] {
		state.items.filter(\.extension.installsFromStore)
	}

	internal var body: some View {
		SettingsSection(String.localized(.appUI.migration.extensions)) {
			if state.isRunning, let position = state.position {
				SettingsRow(String.localized(.appUI.migration.extensionsInstalling(position.index, position.count))) {
					HStack(spacing: 8) {
						ProgressView()
							.controlSize(.small)
						Button(String.localized(.appUI.extensions.skipAll), action: skipAll)
							.disabled(state.isResolving)
					}
				}
			}
			ForEach(items) { item in
				SettingsRow(item.extension.name, detail: item.profileName) {
					Text(item.outcome.title)
						.foregroundStyle(.secondary)
				}
			}
		}
	}
}

internal struct CountRow: View {
	private let label: _XCStringResource
	private let count: Int

	internal init(
		label: _XCStringResource,
		count: Int
	) {
		self.label = label
		self.count = count
	}

	internal var body: some View {
		SettingsRow(String.localized(label)) {
			Text(count, format: .number)
				.monospacedDigit()
				.foregroundStyle(.secondary)
		}
		.accessibilityElement(children: .combine)
	}
}

extension MigrationCategory {
	fileprivate var title: String {
		switch self {
		case .favorites: String.localized(.appUI.migration.favorites)
		case .bookmarks: String.localized(.appUI.migration.bookmarks)
		case .openTabs: String.localized(.appUI.migration.openTabs)
		case .archivedTabs: String.localized(.appUI.migration.archivedTabs)
		case .history: String.localized(.appUI.migration.history)
		case .extensions: String.localized(.appUI.migration.extensions)
		case .preferences: String.localized(.appUI.migration.preferences)
		}
	}
}

extension MigrationIssue.UnsupportedKind {
	fileprivate var title: String {
		switch self {
		case .easel: String.localized(.appUI.migration.unsupportedEasels)
		case .note: String.localized(.appUI.migration.unsupportedNotes)
		case .onboardingItem: String.localized(.appUI.migration.unsupportedOnboarding)
		}
	}
}

extension MigrationAssistantFeature.ProfileOption {
	fileprivate var title: String {
		name.isEmpty ? String.localized(.appUI.migration.mapping.currentProfile) : name
	}
}

extension MigrationReport.Outcome {
	fileprivate var message: String {
		switch self {
		case .completed: String.localized(.appUI.migration.completed)
		case .partiallyCompleted: String.localized(.appUI.migration.partiallyCompleted)
		case .failed: String.localized(.appUI.migration.failed)
		case .cancelled: String.localized(.appUI.migration.cancelled)
		}
	}
}

extension MigrationAssistantFeature.Problem {
	fileprivate var message: String {
		switch self {
		case .discoveryFailed: String.localized(.appUI.migration.discoveryFailed)
		case .missingDestination: String.localized(.appUI.migration.missingDestination)
		case .inspectionFailed: String.localized(.appUI.migration.inspectionFailed)
		case .sourceChanged: String.localized(.appUI.migration.sourceChanged)
		case .importFailed: String.localized(.appUI.migration.importFailed)
		case .unreadableFile: String.localized(.appUI.migration.unreadableFile)
		case .newerFile: String.localized(.appUI.migration.newerFile)
		case .fileTooLarge: String.localized(.appUI.migration.fileTooLarge)
		case .clearFailed: String.localized(.appUI.migration.clearFailed)
		}
	}
}

extension MigrationIssue {
	/// Extensions to reinstall aren't failures: they're reported apart.
	fileprivate var isInvalid: Bool {
		if case .reinstallManually = reason { return false }
		return true
	}
}

extension Optional where Wrapped == ExtensionImportFeature.Outcome {
	fileprivate var title: String {
		switch self {
		case nil: String.localized(.appUI.migration.extensionOutcome.waiting)
		case .installed: String.localized(.appUI.migration.extensionOutcome.installed)
		case .alreadyInstalled: String.localized(.appUI.migration.extensionOutcome.alreadyInstalled)
		case .declined: String.localized(.appUI.migration.extensionOutcome.declined)
		case .skipped: String.localized(.appUI.migration.extensionOutcome.skipped)
		case .reinstallManually: String.localized(.appUI.migration.extensionOutcome.reinstallManually)
		case .failed(.missingProfile): String.localized(.appUI.migration.extensionOutcome.missingProfile)
		case .failed(.unavailable): String.localized(.appUI.migration.extensionOutcome.unavailable)
		case .failed(.blockedByPolicy): String.localized(.appUI.migration.extensionOutcome.blockedByPolicy)
		case .failed(.failed): String.localized(.appUI.migration.extensionOutcome.failed)
		}
	}
}

extension MigrationIssue.Extension {
	/// Chromium IDs are 32 letters from a to p; anything else gets no link.
	fileprivate var storeURL: URL? {
		guard id.count == 32, id.allSatisfy({ ("a"..."p").contains($0) })
		else { return nil }

		return URL(string: "https://chromewebstore.google.com/detail/" + id)
	}
}
