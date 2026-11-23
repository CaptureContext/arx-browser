import AppKit
import BrowserCore
import Foundation
import SwiftUI
import TabArchiveFeature
import Testing
import _ComposableArchitecture

/// Writes offscreen PNGs of the Library's empty Tab Archive for a profile that never chose an
/// interval (the six-hour default), one that chose a week and one that chose Never (DEV-1326),
/// light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(.renderTurn, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct TabArchiveSnapshotTests {
	@Test(arguments: [nil, TabArchiveInterval.week, .never], [false, true])
	internal func emptyArchive(_ interval: TabArchiveInterval?, dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let profile = Profile(id: .init(rawValue: UUID()), name: "Work", tabArchiveInterval: interval)
		let store = Store(initialState: TabArchiveFeature.State(profiles: [profile], profileID: profile.id)) {
			TabArchiveFeature()
		}

		// The Library's panel beside the rail.
		let size = CGSize(width: 300, height: 360)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		let host = NSHostingView(
			rootView: TabArchivePanelView(store: store).background(Color(nsColor: .windowBackgroundColor))
		)
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		let name = interval?.rawValue ?? "default"
		try data.write(to: directory.appending(path: "tab-archive-empty-\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
