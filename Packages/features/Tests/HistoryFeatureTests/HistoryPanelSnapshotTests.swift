import AppKit
import AppUI
import BrowserCore
import Foundation
import HistoryFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// Writes offscreen PNGs of the Library's History page (DEV-817): with history, searching, empty
/// and with no matches, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(.dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct HistoryPanelSnapshotTests {
	internal enum Content: String, CaseIterable, Sendable {
		case history
		case searching
		case empty
		case noMatches = "no-matches"
	}

	@Test(arguments: Content.allCases, [false, true])
	internal func panel(
		content: Content,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let state: HistoryFeature.State = switch content {
		case .history: Fixture.state()
		case .searching: Fixture.state(query: "point")
		case .empty: .init(profileID: Fixture.profileID)
		case .noMatches: Fixture.state(query: "nothing like this")
		}
		let store = Store(initialState: state) { HistoryFeature() }
		let view = HistoryPanelView(store: store, now: Fixture.date(day: 0, hour: 20))
			.environment(\.calendar, Fixture.calendar)
			.environment(\.timeZone, Fixture.calendar.timeZone)
			.environment(\.locale, Locale(identifier: "en_US"))
			.padding(.top, BrowserMetrics.Library.headerInset)
			.frame(width: 300, height: 420, alignment: .top)
			.background { BrowserChromeBackground(textured: true) }

		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "library-history-\(content.rawValue)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
