import AppUI
import BrowserCore
import CommandBarFeature
import Foundation
import SettingsFeature

extension CommandBarSettingsRows {
	/// Settings' search index as command bar rows (DEV-1015): each row's title, where it lives,
	/// its keywords and, for a switch, whether it's on now. Return opens Settings at the row.
	/// Only the rows Settings shows with these feature flags.
	internal static func settingsIndex(_ flags: SettingsFeatureFlags) -> Self {
		.init {
			SettingsCategory.searchIndex
				.filter { $0.isAvailable(flags) }
				.map(CommandBarFeature.Entry.init(setting:))
		}
	}
}

extension CommandBarFeature.Entry {
	/// A command bar row for a Settings search entry, with its switch's state read now.
	internal init(setting entry: SettingsSearchEntry) {
		let place = ([entry.category.title] + entry.trail).joined(separator: " › ")
		let state = entry.toggle.map { toggle in
			toggle.isOn
			? String.localized(.appUI.command.settingOn)
			: String.localized(.appUI.command.settingOff)
		}
		self.init(
			presentation: .init(
				id: "setting-" + entry.destination.id,
				title: entry.title,
				subtitle: String.localized(.appUI.command.settingsPath(place)),
				actionTitle: String.localized(.appUI.command.showSetting),
				symbol: "gearshape",
				state: state
			),
			intent: .openSettings(entry.destination.id),
			keywords: entry.keywords
		)
	}
}
