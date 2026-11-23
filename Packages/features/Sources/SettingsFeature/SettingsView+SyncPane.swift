import AppUI
import SwiftUI

extension SettingsView {
	/// Settings › Sync (DEV-1336): iCloud Sync, which was a section of the Arx pane, with its rows as
	/// they were.
	internal static var syncSearchIndex: [SettingsSearchEntry] {
		[
			.init(
				String.localized(.appUI.settings.iCloudSync.title),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.iCloudSync)),
				in: .sync,
				destination: .row(.sync, .iCloudSync)
			),
		]
	}

	internal var syncPane: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			ICloudSyncSettingsSection(store: store.scope(state: \.iCloudSync, action: \.iCloudSync))
		}
		.settingsAnchor(.iCloudSync)
	}
}
