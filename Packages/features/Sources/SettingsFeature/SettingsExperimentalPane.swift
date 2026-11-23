import AppUI
import SwiftUI

extension SettingsView {
	/// Opt-in experiments. It has none now, so ``SettingsCategory/available`` leaves it out;
	/// an experiment's controls go between the description and the footnote.
	internal var experimentalPane: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			Text(localized: .appUI.settings.experimentalDescription)
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
				.padding(.horizontal, 14)
			Text(localized: .appUI.settings.experimentalFootnote)
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
				.padding(.horizontal, 14)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}
