import AppKit
import AppUI
import BrowserCore
import MigrationAssistant
import SwiftUI
import UniformTypeIdentifiers
import _ComposableArchitecture

/// Passwords and sign-ins on Customize's review (DEV-842): how they'll move, and in CSV mode
/// a file per source profile. Nothing is read until the import runs.
internal struct CredentialConfiguration: View {
	internal let store: StoreOf<CredentialMigrationFeature>

	internal var body: some View {
		switch store.mode {
		case nil:
			MigrationProgressRow(title: String.localized(.appUI.migration.credentials.kind))

		case .direct:
			SettingsSection(
				String.localized(.appUI.migration.credentials.kind),
				footer: promptFooter
			) {
				SettingsRow(String.localized(.appUI.migration.credentials.directSummary(store.sourceName))) {
					EmptyView()
				}
				SettingsRow("") {
					Button(String.localized(.appUI.migration.credentials.useFilesInstead)) {
						store.send(.ui(.useCSV))
					}
					.buttonStyle(.link)
				}
			}

		case let .csv(reason):
			CredentialFiles(store: store, reason: reason, profiles: store.sourceProfiles.map { ($0.id, $0.name, true) })
			if reason == .chosen, store.source != nil, store.canWrite {
				Button(String.localized(.appUI.migration.credentials.useDirectInstead(store.sourceName))) {
					store.send(.ui(.useDirect))
				}
				.buttonStyle(.link)
			}
		}
	}

	private var promptFooter: String {
		store.source.map(\.accessExplanation) ?? ""
	}
}

/// A CSV export per source profile, with why Arx is on this path.
private struct CredentialFiles: View {
	internal let store: StoreOf<CredentialMigrationFeature>
	internal let reason: CredentialMigrationFeature.CSVReason

	/// The source profile's ID and name, and whether a file can go anywhere.
	internal let profiles: [(id: String, name: String, canAttach: Bool)]

	internal var body: some View {
		SettingsSection(
			String.localized(.appUI.migration.credentials.kind),
			footer: reason == .passwordsApp
			? String.localized(.appUI.migration.credentials.csvPasswordsAppSteps)
			: String.localized(.appUI.migration.credentials.csvSteps(store.sourceName))
		) {
			SettingsRow(reason.message(sourceName: store.sourceName)) {
				EmptyView()
			}
			ForEach(profiles, id: \.id) { profile in
				let file = store.csvFiles[profile.id]
				SettingsRow(profile.name, detail: detail(for: profile.id, file: file, canAttach: profile.canAttach)) {
					if store.state.hasImportedCSV(profile.id) {
						Image(systemName: "checkmark.circle.fill")
							.foregroundStyle(.green)
					} else if file != nil {
						Button(String.localized(.appUI.migration.credentials.removeFile)) {
							store.send(.ui(.removeCSV(profile.id)))
						}
					} else {
						Button(String.localized(.appUI.migration.credentials.chooseFile)) {
							chooseCSV(for: profile.id)
						}
						.disabled(!profile.canAttach)
					}
				}
			}
		}
	}

	/// The file, or after an import what happened to it: a failed file stays for another try.
	private func detail(
		for id: String,
		file: URL?,
		canAttach: Bool
	) -> String {
		guard canAttach else { return String.localized(.appUI.migration.credentials.noArxProfile) }

		switch store.csvResults[id: id]?.result {
		case let .success(value):
			return String.localized(.appUI.migration.credentials.csvImportedCount(value.imported))
		case let .failure(failure):
			return [file?.lastPathComponent, failure.message].compactMap { $0 }.joined(separator: " – ")
		case nil:
			return file?.lastPathComponent ?? String.localized(.appUI.migration.credentials.noFile)
		}
	}

	private func chooseCSV(for id: String) {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.allowedContentTypes = [.commaSeparatedText]
		if panel.runModal() == .OK, let url = panel.url {
			store.send(.ui(.csvChosen(id, url)))
		}
	}
}

/// The step's cards once it has taken over the modal after the import. `MigrationAssistantView`
/// shows `content` in its body and `actions` in its footer.
internal struct CredentialMigrationContent: View {
	internal let store: StoreOf<CredentialMigrationFeature>

	internal var body: some View {
		VStack(alignment: .leading, spacing: 20) {
			if let problem = store.problem {
				Label(problem.message, systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)
					.fixedSize(horizontal: false, vertical: true)
			}

			phase
		}
	}

	@ViewBuilder
	private var phase: some View {
		switch store.phase {
		case .loading, .configuring, .resolving:
			MigrationProgressRow(title: nil)

		case .intro:
			intro

		case .reading:
			MigrationProgressRow(title: String.localized(.appUI.migration.credentials.reading))

		case .choosing:
			ForEach(store.inventories) { profile in
				ProfileChoices(store: store, profile: profile, title: title(for: profile.id))
			}

		case .importing, .importingCSV:
			MigrationProgressRow(title: String.localized(.appUI.migration.credentials.importing))

		case .finished:
			ForEach(store.reports) { profile in
				if let report = profile.report {
					CredentialReportView(report: report, title: title(for: profile.id))
				} else {
					SettingsSection(title(for: profile.id)) {
						SettingsRow(String.localized(.appUI.migration.credentials.profileFailed)) {
							Image(systemName: "exclamationmark.triangle.fill")
								.foregroundStyle(.orange)
						}
					}
				}
			}

		case .undoing:
			MigrationProgressRow(title: String.localized(.appUI.migration.credentials.undoing))

		case .undone:
			Text(localized: .appUI.migration.credentials.undone)
				.fixedSize(horizontal: false, vertical: true)

		case let .csv(reason):
			CredentialFiles(
				store: store,
				reason: reason,
				profiles: store.targets.map { ($0.id, title(for: $0.id), $0.profileID != nil) }
			)

		case .csvFinished:
			ForEach(store.csvResults) { profile in
				CSVResultView(result: profile.result, title: title(for: profile.id))
			}
		}
	}

	/// Where each source profile's passwords go, then macOS's prompt explained.
	@ViewBuilder
	private var intro: some View {
		Text(localized: .appUI.migration.credentials.intro(store.sourceName))
			.fixedSize(horizontal: false, vertical: true)

		SettingsSection(
			String.localized(.appUI.migration.mapping.title),
			footer: store.source.map(\.accessExplanation) ?? ""
		) {
			ForEach(store.targets) { target in
				SettingsRow(target.sourceName) {
					Text(
						target.profileID == nil
						? String.localized(.appUI.migration.credentials.noArxProfile)
						: target.profileTitle
					)
					.foregroundStyle(.secondary)
				}
			}
		}
	}

	/// "Work → Work" when there are several profiles; the Arx profile alone otherwise.
	private func title(for id: String) -> String {
		guard let target = store.targets[id: id] else { return "" }
		guard store.targets.count > 1 || target.id != CredentialMigrationFeature.State.wholeSource else {
			return target.profileTitle
		}

		return String.localized(.appUI.migration.credentials.profileArrow(target.sourceName, target.profileTitle))
	}
}

/// One source profile's passwords and sign-ins, each selectable.
private struct ProfileChoices: View {
	internal let store: StoreOf<CredentialMigrationFeature>
	internal let profile: CredentialMigrationFeature.ProfileInventory
	internal let title: String

	internal var body: some View {
		let inventory = profile.inventory
		SettingsSection(title) {
			SettingsToggle(
				String.localized(.appUI.migration.credentials.passwords),
				detail: String.localized(.appUI.migration.credentials.passwordCount(inventory.passwordCount)),
				isOn: Binding(
					get: { profile.selection.passwords },
					set: { _ in store.send(.ui(.togglePasswords(profile.id))) }
				)
			)
			.disabled(inventory.passwordCount == 0)
		} footer: {
			if inventory.unreadablePasswordCount > 0 {
				Text(localized: .appUI.migration.credentials.unreadablePasswords(inventory.unreadablePasswordCount))
			}

			// Said before anything is chosen too, so a profile with only these still explains
			// where its passwords went (DEV-896).
			if inventory.httpAuthPasswordCount > 0 {
				Text(localized: .appUI.migration.credentials.httpAuthNotImported(inventory.httpAuthPasswordCount))
			}
		}

		SettingsSection(
			String.localized(.appUI.migration.credentials.signIns),
			footer: String.localized(.appUI.migration.credentials.signInsFooter)
		) {
			if inventory.signInSites.isEmpty {
				SettingsRow(String.localized(.appUI.migration.credentials.noSignIns)) {
					EmptyView()
				}
			} else {
				SettingsRow("") {
					HStack {
						Button(String.localized(.appUI.migration.credentials.selectAll)) {
							store.send(.ui(.setAllSites(profile.id, true)))
						}
						Button(String.localized(.appUI.migration.credentials.selectNone)) {
							store.send(.ui(.setAllSites(profile.id, false)))
						}
					}
					.buttonStyle(.link)
				}
				ForEach(inventory.signInSites) { site in
					SettingsToggle(
						site.host,
						detail: site.note,
						isOn: Binding(
							get: { profile.selection.signInHosts.contains(site.host) },
							set: { _ in store.send(.ui(.toggleSite(profile.id, host: site.host))) }
						)
					)
					.disabled(site.cookieCount == 0)
				}
			}
		}
	}
}

/// What a CSV import brought into one profile.
private struct CSVResultView: View {
	internal let result: Result<CredentialMigrationFeature.CSVResult, CredentialMigrationFeature.CSVFailure>
	internal let title: String

	internal var body: some View {
		SettingsSection(title) {
			switch result {
			case let .success(value):
				CountRow(label: .appUI.migration.credentials.imported, count: value.imported)
				CountRow(label: .appUI.migration.credentials.conflicts, count: value.conflicts)
				CountRow(label: .appUI.migration.credentials.skipped, count: value.skipped)

			case let .failure(failure):
				SettingsRow(failure.message) {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange)
				}
			}
		}
	}
}

/// The step's footer buttons.
internal struct CredentialMigrationActions: View {
	internal let store: StoreOf<CredentialMigrationFeature>

	internal var body: some View {
		switch store.phase {
		case .intro:
			skip
			ArxModalButton(
				String.localized(.appUI.migration.credentials.useFileInstead),
				prominence: .secondary,
				key: nil
			) {
				store.send(.ui(.useCSV))
			}
			ArxModalButton(String.localized(.appUI.migration.credentials.continue)) {
				store.send(.ui(.continue))
			}
			.disabled(!store.canContinue)

		case .choosing:
			skip
			ArxModalButton(String.localized(.appUI.migration.credentials.import)) {
				store.send(.ui(.startImport))
			}
			.disabled(!store.canImport)

		case .finished:
			ArxModalButton(String.localized(.appUI.migration.credentials.undo), prominence: .secondary, key: nil) {
				store.send(.ui(.undo))
			}
			ArxModalButton(String.localized(.appUI.migration.done)) { store.send(.ui(.close)) }

		case .csv:
			skip
			ArxModalButton(String.localized(.appUI.migration.credentials.import)) {
				store.send(.ui(.importCSV))
			}
			.disabled(!store.canImportCSV)

		case .csvFinished, .undone:
			ArxModalButton(String.localized(.appUI.migration.done)) { store.send(.ui(.close)) }

		case .loading, .configuring, .resolving, .reading, .importing, .undoing, .importingCSV:
			EmptyView()
		}
	}

	private var skip: some View {
		ArxModalButton(String.localized(.appUI.migration.credentials.skip), prominence: .secondary, key: nil) {
			store.send(.ui(.close))
		}
	}
}

/// Per site, what happened in one profile, after Arx checked.
private struct CredentialReportView: View {
	internal let report: CredentialReport
	internal let title: String

	internal var body: some View {
		if let passwords = report.passwords {
			SettingsSection(title) {
				CountRow(label: .appUI.migration.credentials.imported, count: passwords.imported)
				CountRow(label: .appUI.migration.credentials.conflicts, count: passwords.conflicts)
				CountRow(label: .appUI.migration.credentials.skipped, count: passwords.skipped)
			} footer: {
				if passwords.httpAuthNotImported > 0 {
					Text(localized: .appUI.migration.credentials.httpAuthNotImported(passwords.httpAuthNotImported))
				}
			}
		}
		if !report.sites.isEmpty {
			SettingsSection(
				report.passwords == nil
				? title
				: String.localized(.appUI.migration.credentials.signIns)
			) {
				ForEach(report.sites) { site in
					SettingsRow(site.host, detail: site.result.reason) {
						Text(site.result.title)
							.foregroundStyle(site.result.isProblem ? Color.orange : Color.secondary)
					}
				}
			}
		}
	}
}

extension CredentialMigrationFeature.Target {
	fileprivate var profileTitle: String {
		profileName.isEmpty ? String.localized(.appUI.migration.mapping.currentProfile) : profileName
	}
}

extension CredentialSite {
	fileprivate var note: String? {
		if cookieCount > 0 { return nil }
		if unreadableCookieCount > 0 { return String.localized(.appUI.migration.credentials.unreadableSite) }
		return String.localized(.appUI.migration.credentials.sessionOnly)
	}
}

extension CredentialSiteOutcome.Result {
	fileprivate var title: String {
		switch self {
		case .kept: String.localized(.appUI.migration.credentials.kept)
		case .signInAgain: String.localized(.appUI.migration.credentials.signInAgain)
		case .notChecked: String.localized(.appUI.migration.credentials.notChecked)
		case .skipped: String.localized(.appUI.migration.credentials.notImported)
		}
	}

	fileprivate var reason: String? {
		guard case let .signInAgain(reason) = self else { return nil }

		switch reason {
		case .sessionOnly: return String.localized(.appUI.migration.credentials.reasonSessionOnly)
		case .unreadable: return String.localized(.appUI.migration.credentials.reasonUnreadable)
		case .rejected: return String.localized(.appUI.migration.credentials.reasonRejected)
		case .partlyRejected: return String.localized(.appUI.migration.credentials.reasonPartlyRejected)
		case .notKept: return String.localized(.appUI.migration.credentials.reasonNotKept)
		}
	}

	fileprivate var isProblem: Bool {
		if case .signInAgain = self { return true }
		return false
	}
}

extension CredentialMigrationFeature.CSVReason {
	fileprivate func message(sourceName: String) -> String {
		switch self {
		case .chosen: String.localized(.appUI.migration.credentials.csvChosen)
		case .denied: String.localized(.appUI.migration.credentials.csvDenied)
		case .missing: String.localized(.appUI.migration.credentials.csvMissing(sourceName))
		case .engineNotReady: String.localized(.appUI.migration.credentials.csvEngineNotReady)
		case .unsupported: String.localized(.appUI.migration.credentials.csvUnsupported(sourceName))
		case .passwordsApp: String.localized(.appUI.migration.credentials.csvPasswordsApp)
		case .primaryPassword: String.localized(.appUI.migration.credentials.csvPrimaryPassword(sourceName, sourceName))
		}
	}
}

extension CredentialSource {
	/// What reading the source asks of the user: macOS's Keychain prompt, nothing, or the
	/// Full Disk Access Safari's import already has (DEV-896).
	fileprivate var accessExplanation: String {
		switch access {
		case let .keychain(service, isVerified):
			String.localized(.appUI.migration.credentials.promptExplanation(service))
			+ (isVerified ? "" : "\n" + String.localized(.appUI.migration.credentials.unverifiedItem))

		case .profileFiles:
			String.localized(.appUI.migration.credentials.profileFilesExplanation(browserName, browserName))

		case .fullDiskAccess:
			String.localized(.appUI.migration.credentials.safariExplanation)
		}
	}
}

extension CredentialMigrationFeature.Problem {
	fileprivate var message: String {
		switch self {
		case .notForeground: String.localized(.appUI.migration.credentials.notForeground)
		case .presenceDenied: String.localized(.appUI.migration.credentials.presenceDenied)
		case .unreadable: String.localized(.appUI.migration.credentials.unreadable)
		case .writeFailed: String.localized(.appUI.migration.credentials.writeFailed)
		case .undoFailed: String.localized(.appUI.migration.credentials.undoFailed)
		}
	}
}

extension CredentialMigrationFeature.CSVFailure {
	fileprivate var message: String {
		switch self {
		case .unreadableFile: String.localized(.appUI.migration.credentials.csvUnreadableFile)
		case .badFormat: String.localized(.appUI.migration.credentials.csvBadFormat)
		case .tooLarge: String.localized(.appUI.migration.credentials.csvTooLarge)
		case .unavailable: String.localized(.appUI.migration.credentials.csvUnavailable)
		case .failed: String.localized(.appUI.migration.credentials.csvFailed)
		}
	}
}
