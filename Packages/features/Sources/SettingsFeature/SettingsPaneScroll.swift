import BrowserCore
import Foundation
import SwiftUI

/// Back from a page returns its pane to where it was scrolled (Max, 18 Nov): Advanced scrolled
/// down, Feature Flags, then Back shows the same rows, as do Back's tile, ⌘[ and ←. Choosing
/// another pane in the sidebar forgets it, so a pane chosen there starts at its top, as macOS
/// Settings does. On by default, as every flag is for the beta; `ARX_SETTINGS_SCROLL_RESTORE`
/// set to `0`, `false`, `no` or `off` opens every pane at its top again.
public enum SettingsScrollRestore {
	public static let featureFlag: String = FeatureFlag.settingsScrollRestore.name

	/// Whether Back restores the pane's scroll. Read once, at launch.
	public static let isEnabled: Bool = FeatureFlag.settingsScrollRestore.isOn()
}

/// Where Settings is: the pane, and the page open over it, if any.
internal struct SettingsLocation: Equatable {
	internal var category: SettingsCategory
	internal var page: SettingsPage?

	internal init(
		category: SettingsCategory,
		page: SettingsPage?
	) {
		self.category = category
		self.page = page
	}
}

/// How far a pane was scrolled from its top the last time it moved.
internal struct SettingsPaneOffset: Equatable {
	internal var category: SettingsCategory
	internal var offset: CGFloat

	internal init(
		category: SettingsCategory,
		offset: CGFloat
	) {
		self.category = category
		self.offset = offset
	}
}

/// The pane's scroll position, kept while a page covers the pane, so the pane comes back at it.
///
/// It's one position, for the pane in front: opening a page from the pane saves how far it was
/// scrolled, and the pane, made again on Back, starts there. Another pane, and one reached
/// together with a page from the sidebar's search, starts at its top.
internal struct SettingsPaneScroll {
	/// The pane the position belongs to.
	internal private(set) var category: SettingsCategory?

	/// Where that pane is, or starts when it's made again.
	internal private(set) var position: ScrollPosition

	internal init() {
		self.category = nil
		self.position = .init(edge: .top)
	}

	/// A pane's position: the saved one for the pane in front, else its top.
	internal subscript(position category: SettingsCategory) -> ScrollPosition {
		get {
			guard self.category == category else { return .init(edge: .top) }
			return position
		}
		set {
			self.category = category
			position = newValue
		}
	}

	/// Follows Settings from one place to another, given how far the pane was last scrolled.
	internal mutating func navigated(
		from old: SettingsLocation,
		to new: SettingsLocation,
		lastOffset: SettingsPaneOffset?
	) {
		guard new.category == old.category else {
			category = new.category
			position = .init(edge: .top)
			return
		}
		guard old.page == nil, new.page != nil else { return }

		// A page opened over the pane: the pane comes back where it was.
		category = new.category
		if let lastOffset, lastOffset.category == new.category {
			position = .init(y: lastOffset.offset)
		} else {
			position = .init(edge: .top)
		}
	}
}

/// How far the pane in front was scrolled, updated as it scrolls. A reference, so a scroll
/// doesn't redraw Settings.
@MainActor
internal final class SettingsPaneOffsetReading {
	internal var value: SettingsPaneOffset?

	internal init() {
		self.value = nil
	}
}

extension View {
	/// Keeps the pane's scroll in `scroll`, and reports how far it's scrolled to `reading`, while
	/// `SettingsScrollRestore` is on.
	internal func settingsPaneScroll(
		_ scroll: Binding<SettingsPaneScroll>,
		category: SettingsCategory,
		reading: SettingsPaneOffsetReading,
		isEnabled: Bool = SettingsScrollRestore.isEnabled
	) -> some View {
		modifier(SettingsPaneScrollModifier(
			scroll: scroll,
			category: category,
			reading: reading,
			isEnabled: isEnabled
		))
	}
}

private struct SettingsPaneScrollModifier: ViewModifier {
	@Binding
	fileprivate var scroll: SettingsPaneScroll

	fileprivate let category: SettingsCategory
	fileprivate let reading: SettingsPaneOffsetReading
	fileprivate let isEnabled: Bool

	@ViewBuilder
	fileprivate func body(content: Content) -> some View {
		if isEnabled {
			content
				.scrollPosition($scroll[position: category])
				.onScrollGeometryChange(for: CGFloat.self, of: Self.offset) { _, offset in
					reading.value = .init(category: category, offset: offset)
				}
		} else {
			content
		}
	}

	/// How far the content has moved up from its top, under the pane's bar.
	private static func offset(_ geometry: ScrollGeometry) -> CGFloat {
		max(0, geometry.contentOffset.y + geometry.contentInsets.top)
	}
}
