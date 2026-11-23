import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of onboarding's five tour pages when `ARX_DESIGN_SNAPSHOTS` names a
/// directory: each page held at its demo's key frame, in light and dark, at the onboarding
/// window's size.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct OnboardingTourSnapshotTests {
	@Test(arguments: [false, true])
	internal func peek(dark: Bool) throws {
		try write(.peek, dark: dark)
	}

	@Test(arguments: [false, true])
	internal func splitView(dark: Bool) throws {
		try write(.splitView, dark: dark)
	}

	@Test(arguments: [false, true])
	internal func commandBar(dark: Bool) throws {
		try write(.commandBar, dark: dark)
	}

	@Test(arguments: [false, true])
	internal func chats(dark: Bool) throws {
		try write(.chats, dark: dark)
	}

	@Test(arguments: [false, true])
	internal func littleArx(dark: Bool) throws {
		try write(.littleArx, dark: dark)
	}

	private func write(
		_ demo: TourDemo,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = OnboardingTourPage(demo: demo, frozenTime: demo.keyFrame)
			.frame(width: 760, height: 540)
			.background(Color(nsColor: .windowBackgroundColor))
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: .init(width: 760, height: 540))
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
		try data.write(to: directory.appending(path: "tour-\(demo.fileName)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
