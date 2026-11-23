import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// Writes offscreen PNGs of the Match site control at its three levels (DEV-1170), light and dark,
/// for visual review, when `ARX_DESIGN_SNAPSHOTS` names a directory: Settings' browser default,
/// a profile inheriting it and one turning it off, and a space turning it back on.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct MatchSiteLevelsSnapshotTests {
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func matchSiteAtEveryLevel(_ appearance: NSAppearance.Name) throws {
		try SidebarChromeSnapshot.write(
			Self.levels,
			size: .init(width: 1_280, height: 560),
			appearance: appearance,
			name: "match-site-levels"
		)
	}

	private struct Sample {
		internal let title: String
		internal let level: ChromeAppearanceEditor.Level
		internal let choices: AppearanceOverride
		internal let inherited: ChromeAppearance
	}

	/// Film grain off, so each editor stays short.
	private static let browserDefault: ChromeAppearance = .init(grain: .init(isEnabled: false), matchesSite: true)

	private static let samples: [Sample] = [
		.init(
			title: "Settings › Appearance: on",
			level: .global,
			choices: .init(browserDefault),
			inherited: .default
		),
		.init(
			title: "Profile: inherits on",
			level: .profile,
			choices: .init(),
			inherited: browserDefault
		),
		.init(
			title: "Profile: off",
			level: .profile,
			choices: .init(matchesSite: false),
			inherited: browserDefault
		),
		.init(
			title: "Space: on, over a profile's off",
			level: .space,
			choices: .init(matchesSite: true),
			inherited: AppearanceOverride(matchesSite: false).applied(to: browserDefault)
		),
	]

	private static var levels: some View {
		HStack(alignment: .top, spacing: 16) {
			ForEach(samples, id: \.title) { sample in
				VStack(alignment: .leading, spacing: 0) {
					Text(verbatim: sample.title)
						.font(.headline)
						.padding(.bottom, 4)
					ChromeAppearanceEditor(
						level: sample.level,
						offersMatchSite: true,
						offersAccent: true,
						choices: sample.choices,
						inherited: sample.inherited,
						onCommit: { _ in }
					)
				}
				.padding(14)
				.frame(width: 296, alignment: .top)
				.background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 12))
			}
		}
		.padding(16)
		.frame(maxHeight: .infinity, alignment: .top)
	}
}
