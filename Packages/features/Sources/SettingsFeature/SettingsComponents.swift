import AppKit
import AppUI
import SwiftUI

/// A card of rows that lays out its own dividers, in the grouped style every section uses.
internal struct SettingsCard<Content: View>: View {
	private let content: Content

	internal init(@ViewBuilder content: () -> Content) {
		self.content = content()
	}

	internal var body: some View {
		SettingsGroupCard { content }
	}
}

#if DEBUG
/// Options that don't work yet. Debug only: release builds hide them.
internal struct SettingsPendingRow: View {
	private let title: String
	private let symbol: String?

	internal init(
		_ title: String,
		symbol: String? = nil
	) {
		self.title = title
		self.symbol = symbol
	}

	internal var body: some View {
		HStack(spacing: 12) {
			if let symbol {
				Image(systemName: symbol)
					.foregroundStyle(.tint)
					.frame(width: 24)
			}
			Text(title)
			Spacer(minLength: 16)
			Text(localized: .appUI.settings.pending)
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
		}
		.settingsRow()
		.accessibilityElement(children: .combine)
	}
}

internal struct SettingsPendingGroup: View {
	private let titles: [String]

	internal init(_ titles: [String]) {
		self.titles = titles
	}

	internal var body: some View {
		SettingsSection {
			ForEach(titles, id: \.self) { title in
				SettingsPendingRow(title)
			}
		}
	}
}
#endif

internal enum SettingsMetrics {
	/// A pane's navigation bar, measured from the window's top edge: as tall as a unified
	/// toolbar, so the title-bar area and the bar are one.
	internal static let navigationBarHeight: CGFloat = 52

	/// Room above a pane's or page's navigation bar, so it clears the window's top edge (DEV-806):
	/// its controls start where the sidebar's search does, just below the window controls.
	internal static let navigationBarTopInset: CGFloat = sidebarSearchTop
		- (navigationBarHeight - ArxHeaderBarMetrics.controlHeight) / 2

	/// Where the sidebar's search starts, just below the window controls.
	internal static let sidebarSearchTop: CGFloat = 40

	/// Between one section and the next one's header.
	internal static let cardSpacing: CGFloat = 22

	/// Between a pane's or page's bar and its first section, so a first header or card never
	/// sits on the bar (DEV-1241).
	internal static let contentTopInset: CGFloat = 16
}

extension View {
	/// Settings draws Arx's own buttons: a button without a style of its own is an Arx button.
	/// Each sheet applies it again, so its window matches. Inline fields opt in with
	/// `.textFieldStyle(.arx)`; fields that take a whole row stay `SettingsTextField`.
	internal func settingsControls() -> some View {
		buttonStyle(.arx)
	}

	internal func settingsRow() -> some View {
		settingsGroupRow()
	}
}

/// Shared metrics keep pane text separate from native toolbar typography.
internal enum SettingsTypography {
	internal static let body: Font = .system(size: 13, weight: .regular)
	internal static let heading: Font = .system(size: 11, weight: .semibold)
	internal static let caption: Font = .system(size: 11, weight: .regular)
}

/// The surfaces behind Settings' bars, which content scrolls under with a soft edge
/// (DEV-790, DEV-806).
internal enum SettingsBarStyle {
	internal static let background: Color = ArxModalMetrics.background

	/// The sidebar's surface: the window's background with a faint tint of the text color, as
	/// one opaque color.
	internal static let sidebarBackground: Color = .init(nsColor: NSColor(name: nil) { appearance in
		var color: NSColor = .windowBackgroundColor
		appearance.performAsCurrentDrawingAppearance {
			let base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor
			let tint = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
			color = base.blended(withFraction: 0.03, of: tint.withAlphaComponent(1)) ?? base
		}
		return color
	})
}

