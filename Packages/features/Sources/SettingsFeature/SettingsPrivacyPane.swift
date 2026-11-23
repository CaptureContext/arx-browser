import AppUI
import DiagnosticsClient
import SwiftUI

// MARK: - Privacy

extension SettingsView {
	internal static var privacySearchIndex: [SettingsSearchEntry] {
		[
			.init(
				String.localized(.appUI.settings.crashReportsKept),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.crashReports)),
				in: .privacy,
				destination: .row(.privacy, .crashReports)
			),
			.init(
				String.localized(.appUI.settings.reportProblem),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.reportProblem)),
				in: .privacy,
				destination: .row(.privacy, .reportProblem)
			),
		]
	}

	/// The crash reports kept on this Mac, and Report a Problem….
	internal var privacyPane: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			SettingsSection(
				String.localized(.appUI.settings.section.crashReports),
				footer: String.localized(.appUI.settings.crashReportsFooter)
			) {
				SettingsRow(
					String.localized(.appUI.settings.crashReportsKept),
					detail: keptCrashReportsText
				) {
					Button(String.localized(.appUI.settings.removeCrashReports)) {
						store.send(.ui(.removeCrashReports))
					}
					.disabled(store.diagnostics?.hasReports != true)
				}
				.settingsAnchor(.crashReports)
			}

			// The row and its button name it, so the section has no title (DEV-1241).
			SettingsSection(footer: String.localized(.appUI.settings.reportProblemDetail)) {
				SettingsRow(String.localized(.appUI.settings.reportProblem)) {
					Button(String.localized(.appUI.settings.reportProblemButton)) {
						store.send(.ui(.reportProblem))
					}
				}
				.settingsAnchor(.reportProblem)
			}
		}
		.task { store.send(.ui(.loadDiagnostics)) }
	}

	private var keptCrashReportsText: String {
		let count: Int = store.diagnostics?.crashReports ?? 0
		guard count > 0
		else { return String.localized(.appUI.settings.crashReportsNone) }

		return String.localized(.appUI.settings.crashReportsCount(count.formatted()))
	}
}
