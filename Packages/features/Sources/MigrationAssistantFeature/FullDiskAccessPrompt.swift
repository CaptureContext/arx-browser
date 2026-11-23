import AppUI
import MigrationAssistant
import SwiftUI

/// Shown in place of the categories while a source needs Full Disk Access (Safari, DEV-840):
/// why Arx needs it, and a button to its pane in System Settings. The host checks again when
/// Arx becomes active and swaps this for the categories once access is granted.
public struct FullDiskAccessPrompt: View {
	private let sourceName: String
	private let status: FullDiskAccessStatus
	private let openSettings: () -> Void

	public init(
		sourceName: String,
		status: FullDiskAccessStatus,
		openSettings: @escaping () -> Void
	) {
		self.sourceName = sourceName
		self.status = status
		self.openSettings = openSettings
	}

	public var body: some View {
		SettingsSection(
			String.localized(.appUI.migration.fullDiskAccess.title),
			caption: String.localized(.appUI.migration.fullDiskAccess.message(sourceName)),
			footer: String.localized(.appUI.migration.fullDiskAccess.steps)
		) {
			SettingsRow(
				status == .denied
				? String.localized(.appUI.migration.fullDiskAccess.denied)
				: String.localized(.appUI.migration.fullDiskAccess.title)
			) {
				Button(String.localized(.appUI.migration.fullDiskAccess.openSettings), action: openSettings)
					.buttonStyle(.arxRaised(.capsule))
			}
		}
	}
}
