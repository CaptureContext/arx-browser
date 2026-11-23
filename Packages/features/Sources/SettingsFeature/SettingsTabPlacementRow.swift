import AppUI
import BrowserCore
import SwiftUI

/// Where new tabs of one kind open among a space's open tabs (DEV-913, DEV-1174): at the bottom,
/// at the top or below the current tab.
internal struct SettingsTabPlacementRow: View {
	private let title: String

	@Binding
	private var selection: NewTabPlacement

	internal init(
		_ title: String,
		selection: Binding<NewTabPlacement>
	) {
		self.title = title
		self._selection = selection
	}

	internal var body: some View {
		SettingsRow(title) {
			Picker(title, selection: $selection) {
				Text(localized: .appUI.settings.newTabsAtBottom).tag(NewTabPlacement.bottom)
				Text(localized: .appUI.settings.newTabsAtTop).tag(NewTabPlacement.top)
				Text(localized: .appUI.settings.newTabsBelowCurrent).tag(NewTabPlacement.belowCurrent)
			}
			.labelsHidden()
			.fixedSize()
		}
	}
}
