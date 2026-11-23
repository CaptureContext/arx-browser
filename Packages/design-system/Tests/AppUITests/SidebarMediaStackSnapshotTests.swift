import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs of the sidebar's media stack (DEV-1245) with one, two and four items,
/// at rest and hovered, light and dark, and frames of a row's hover transition (DEV-1244), when
/// `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct SidebarMediaStackSnapshotTests {
	private static let profileID: UUID = .init(uuidString: "00000000-0000-0000-0000-000000000001")!

	private static let items: [SidebarMediaItem] = [
		.init(
			id: id(1),
			title: "Lo-fi beats to build a browser to",
			subtitle: "youtube.com",
			artist: "Lofi Girl",
			playback: .playing,
			canPause: true,
			canNextTrack: true
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
			title: "Swift Over Coffee",
			subtitle: "podcasts.apple.com",
			artist: "Paul Hudson",
			playback: .paused,
			canPlay: true,
			canPreviousTrack: true,
			canNextTrack: true
		),
		.init(
			id: id(4),
			title: "WWDC Keynote",
			subtitle: "developer.apple.com",
			playback: .playing,
			canPause: true
		),
	]

	@Test(arguments: [1, 2, 4], [false, true])
	internal func stack(
		count: Int,
		dark: Bool
	) throws {
		let items = Array(Self.items.prefix(count))
		for expanded in [false, true] {
			let view = SidebarMediaStack(ids: items.map(\.id), restingID: items[items.count - 1].id) { id in
				if let item = items.first(where: { $0.id == id }) {
					Self.player(item)
				}
			}
			.environment(\.sidebarMediaStackHover, expanded)
			.environment(\.sidebarMediaHover, false)
			try Self.write(
				view,
				dark: dark,
				name: "sidebar-media-\(count)-\(expanded ? "hovered" : "rest")-\(dark ? "dark" : "light").png"
			)
		}
	}

	/// A row's hover in and out, frame by frame: nothing may show outside its background.
	@Test(arguments: [true, false])
	internal func hoverFrames(entering: Bool) throws {
		let directory = try Self.directory()
		let hover = HoverModel(isHovered: !entering)
		let view = HoverDriver(model: hover) { Self.player(Self.items[2]) }
		let (window, host) = Self.host(view, dark: false, size: .init(width: 260, height: 90))
		defer { window.close() }

		withAnimation(.snappy(duration: 0.2)) { hover.isHovered = entering }
		let start = Date.now
		for frame in 0..<8 {
			RunLoop.main.run(until: start.addingTimeInterval(Double(frame) * 0.03))
			host.layoutSubtreeIfNeeded()
			let name = "sidebar-media-hover-\(entering ? "in" : "out")-\(frame).png"
			try Self.png(host).write(to: directory.appending(path: name))
		}
	}

	private static func player(_ item: SidebarMediaItem) -> some View {
		SidebarMediaPlayer(
			item: item,
			canSeek: true,
			progress: { .init(position: 75, duration: 214) },
			onPlayPause: {},
			onSeek: { _ in },
			onOpen: {},
			onCast: {}
		)
	}

	private static func write(
		_ view: some View,
		dark: Bool,
		name: String
	) throws {
		let directory = try directory()
		let (window, host) = host(view, dark: dark, size: nil)
		defer { window.close() }
		try png(host).write(to: directory.appending(path: name))
	}

	private static func host(
		_ view: some View,
		dark: Bool,
		size: CGSize?
	) -> (NSWindow, NSView) {
		let root = view
			.padding(BrowserMetrics.Sidebar.horizontalPadding)
			.frame(width: 260, height: size?.height, alignment: .bottom)
			.background { BrowserChromeBackground(textured: true) }
		let host = NSHostingView(rootView: root)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: size ?? host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host

		// The stack measures its rows, then takes their height.
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		if size == nil {
			host.frame.size = host.fittingSize
			window.setContentSize(host.frame.size)
			for _ in 0..<4 {
				host.layoutSubtreeIfNeeded()
				RunLoop.main.run(until: .now.addingTimeInterval(0.05))
			}
		}
		return (window, host)
	}

	private static func png(_ host: NSView) throws -> Data {
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		return try #require(representation.representation(using: .png, properties: [:]))
	}

	private static func directory() throws -> URL {
		URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
	}

	private static func id(_ number: Int) -> BrowserMediaSource.ID {
		.init(
			tabID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(number)")!),
			profileID: .init(rawValue: profileID),
			generation: 1
		)
	}
}

@MainActor
@Observable
private final class HoverModel {
	var isHovered: Bool

	init(isHovered: Bool) {
		self.isHovered = isHovered
	}
}

private struct HoverDriver<Content: View>: View {
	let model: HoverModel

	@ViewBuilder
	let content: () -> Content

	var body: some View {
		content().environment(\.sidebarMediaHover, model.isHovered)
	}
}
