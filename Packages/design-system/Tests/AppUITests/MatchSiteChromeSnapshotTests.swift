import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// Writes offscreen PNGs of the chrome matching a light, a dark and a saturated site (DEV-1101),
/// light and dark, for visual review, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct MatchSiteChromeSnapshotTests {
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func chromeAroundSites(_ appearance: NSAppearance.Name) throws {
		let sites: [(name: String, argb: UInt32)] = [
			("light", 0xFFFF_FFFF),
			("dark", 0xFF11_1827),
			("saturated", 0xFFE5_0914),
		]
		for site in sites {
			try SidebarChromeSnapshot.write(
				Self.window(site: .init(argb: site.argb)),
				size: .init(width: 620, height: 360),
				appearance: appearance,
				name: "match-site-\(site.name)"
			)
		}
	}

	/// The sidebar and the page card in the site's chrome, with the site itself in the card.
	private static func window(site: ChromePalette.RGB) -> some View {
		ZStack {
			BrowserChromeBackground(textured: true)
			HStack(spacing: 0) {
				SidebarChromeFixture.sidebar()
					.frame(width: 286)
				RoundedRectangle(cornerRadius: BrowserMetrics.PageCard.cornerRadius, style: .continuous)
					.fill(Color(site))
					.overlay {
						RoundedRectangle(cornerRadius: BrowserMetrics.PageCard.cornerRadius, style: .continuous)
							.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth)
					}
					.padding(8)
			}
		}
		.environment(\.browserChromeSiteColor, site)
	}
}
