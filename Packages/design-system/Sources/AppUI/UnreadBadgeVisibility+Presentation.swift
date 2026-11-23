import BrowserCore
import SwiftUI

extension UnreadBadgeVisibility {
	/// Show or Hide, as the levels' pickers list it (DEV-1258).
	public var title: String {
		switch self {
		case .show: String.localized(.appUI.unreadBadges.show)
		case .hide: String.localized(.appUI.unreadBadges.hide)
		}
	}

	/// The inherit choice, naming what it inherits: "Default (Show)".
	public static func inheritTitle(_ inherited: Self) -> String {
		String.localized(.appUI.siteMenu.defaultSetting(inherited.title))
	}
}

/// A level's unread badges choice (DEV-1258): inherit what the level above gives, show or hide.
/// The profile's settings, the site menu and the tab's menu pick it the same way.
public struct UnreadBadgeVisibilityPicker: View {
	private let title: String
	private let selection: Binding<UnreadBadgeVisibility?>
	private let inherited: UnreadBadgeVisibility

	public init(
		_ title: String,
		selection: Binding<UnreadBadgeVisibility?>,
		inherited: UnreadBadgeVisibility
	) {
		self.title = title
		self.selection = selection
		self.inherited = inherited
	}

	public var body: some View {
		Picker(title, selection: selection) {
			Text(UnreadBadgeVisibility.inheritTitle(inherited)).tag(UnreadBadgeVisibility?.none)
			ForEach(UnreadBadgeVisibility.allCases, id: \.self) { visibility in
				Text(visibility.title).tag(Optional(visibility))
			}
		}
	}
}
