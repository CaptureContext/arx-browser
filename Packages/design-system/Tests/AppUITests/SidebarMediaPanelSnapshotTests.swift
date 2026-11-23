import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs of the Library's Media page (DEV-783): with media playing, paused, muted
/// and in ArxPiP, and with nothing playing, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct SidebarMediaPanelSnapshotTests {
	private static let profileID: UUID = .init(uuidString: "00000000-0000-0000-0000-000000000001")!

	private static let items: [SidebarMediaItem] = [
		.init(
			id: id(1),
			title: "Lo-fi beats to build a browser to",
			subtitle: "youtube.com",
			playback: .playing,
			canPause: true
		),
		.init(
			id: id(2),
			title: "Point-Free Episode #300",
			subtitle: "pointfree.co",
			playback: .paused,
			canPlay: true,
			isMuted: true
		),
		.init(
			id: id(3),
			title: "WWDC Keynote",
			subtitle: "developer.apple.com",
			playback: .pictureInPicture,
			canPause: true
		),
	]

	@Test(arguments: [false, true], [false, true])
	internal func panel(
		hasMedia: Bool,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = SidebarMediaPanel(
			items: hasMedia ? Self.items : [],
			notice: nil,
			onPlayPause: { _ in },
			onMute: { _ in },
			onReturn: { _ in }
		)
		.padding(.top, BrowserMetrics.Library.headerInset)
		.frame(width: 300, height: 320, alignment: .top)
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
		let name = "library-media-\(hasMedia ? "playing" : "empty")-\(dark ? "dark" : "light").png"
		try data.write(to: directory.appending(path: name))
		window.close()
	}

	private static func id(_ value: UInt8) -> BrowserMediaSource.ID {
		.init(
			tabID: .init(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))),
			profileID: .init(rawValue: profileID),
			generation: 1
		)
	}
}
