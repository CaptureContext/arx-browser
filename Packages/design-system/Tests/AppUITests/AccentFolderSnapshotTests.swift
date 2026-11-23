import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// Writes offscreen PNGs of sidebar folders in a few accents (DEV-1117), light and dark, for visual
/// review, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct AccentFolderSnapshotTests {
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func foldersInAccents(_ appearance: NSAppearance.Name) throws {
		try SidebarChromeSnapshot.write(
			Self.folders,
			size: .init(width: 620, height: 300),
			appearance: appearance,
			name: "accent-folders"
		)
	}

	private struct Sample {
		internal let name: String
		internal let tint: ChromeTint
		internal let accent: ChromeAccent?
		internal let siteColor: ChromePalette.RGB?
	}

	private static let samples: [Sample] = [
		.init(name: "Automatic", tint: .default, accent: nil, siteColor: nil),
		.init(name: "Automatic, orange tint", tint: .init(hue: 30, intensity: 0.5), accent: nil, siteColor: nil),
		.init(name: "Red", tint: .default, accent: ChromeAccent.Preset.red.accent, siteColor: nil),
		.init(name: "Yellow", tint: .default, accent: ChromeAccent.Preset.yellow.accent, siteColor: nil),
		.init(name: "Graphite", tint: .default, accent: ChromeAccent.Preset.graphite.accent, siteColor: nil),
		.init(name: "Custom, deep navy", tint: .default, accent: .init(red: 0.1, green: 0.12, blue: 0.35), siteColor: nil),
		.init(name: "Teal on a site", tint: .default, accent: ChromeAccent.Preset.teal.accent, siteColor: .init(argb: 0xFF11_1827)),
	]

	private static var folders: some View {
		VStack(alignment: .leading, spacing: 0) {
			ForEach(samples, id: \.name) { sample in
				HStack(spacing: 10) {
					SidebarFolderIcon(isExpanded: false)
					SidebarFolderIcon(isExpanded: true)
					Text(verbatim: sample.name)
						.font(.system(size: 13))
						.foregroundStyle(BrowserTheme.text)
					Spacer()
					Capsule()
						.strokeBorder(BrowserTheme.accent, lineWidth: 2)
						.frame(width: 60, height: 22)
				}
				.padding(.horizontal, 16)
				.frame(height: 40)
				.background { BrowserChromeBackground(textured: true) }
				.environment(\.browserChromeTint, sample.tint)
				.environment(\.browserChromeAccent, sample.accent)
				.environment(\.browserChromeSiteColor, sample.siteColor)
			}
		}
		.environment(\.browserAccentIsEnabled, true)
	}
}
