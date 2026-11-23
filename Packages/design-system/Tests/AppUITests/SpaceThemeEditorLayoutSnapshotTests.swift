import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// Writes offscreen PNGs of the theme panel (DEV-1299) where it's shown, light and dark, when
/// `ARX_DESIGN_SNAPSHOTS` names a directory: the space's pop-over, and Settings' Window background
/// card at its narrowest and widest content widths.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct SpaceThemeEditorLayoutSnapshotTests {
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func thePopover(_ appearance: NSAppearance.Name) throws {
		try SidebarChromeSnapshot.write(
			popover,
			size: .init(width: 1_040, height: 720),
			appearance: appearance,
			name: "theme-panel-popover"
		)
	}

	/// Settings' window has one size (900 × 680) and caps a page at 620 points, so the card's
	/// content runs from the page's narrowest (a profile page, 572) to its widest (620).
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func settings(_ appearance: NSAppearance.Name) throws {
		try SidebarChromeSnapshot.write(
			settings,
			size: .init(width: 1_340, height: 720),
			appearance: appearance,
			name: "theme-panel-settings"
		)
	}

	private static let threeColors: AppearanceOverride = AppearanceOverride(grainIntensity: 0.4)
		.settingThemeDots(.init(angle: 200, distance: 0.55, arrangement: .splitComplementary), over: .default)

	private static let gradient: AppearanceOverride = AppearanceOverride(theme: .dark)
		.settingThemeDots(.init(angle: 20, distance: 0.4, arrangement: .analogous), over: .default)

	private var popover: some View {
		HStack(alignment: .top, spacing: 16) {
			ForEach([AppearanceOverride(), Self.threeColors, Self.gradient], id: \.self) { choices in
				SpaceThemeEditor(
					choices: choices,
					inherited: .default,
					offersMatchSite: true,
					offersAccent: true,
					onCommit: { _ in },
					onClear: {}
				)
				.frame(width: SpaceThemeEditor.width)
				.padding(14)
				.background(.regularMaterial, in: .rect(cornerRadius: 16))
			}
		}
		.padding(16)
		.frame(maxHeight: .infinity, alignment: .top)
	}

	private var settings: some View {
		HStack(alignment: .top, spacing: 24) {
			ForEach([572, 620] as [CGFloat], id: \.self) { width in
				SettingsSection("Window background", caption: "Colors the sidebar and window frame.") {
					Self.settingsPanel()
				}
				.frame(width: width)
			}
		}
		.padding(24)
		.frame(maxHeight: .infinity, alignment: .top)
		.background(Color(nsColor: .windowBackgroundColor))
	}

	/// As `SettingsEditors.swift` shows the browser default's panel.
	private static func settingsPanel() -> some View {
		SpaceThemeEditor(
			level: .global,
			layout: .settings,
			choices: .init(ChromeAppearance(tint: .init(hue: 240, intensity: 0.2))),
			inherited: .default,
			offersMatchSite: true,
			offersAccent: true,
			onCommit: { _ in },
			onClear: {}
		)
	}
}
