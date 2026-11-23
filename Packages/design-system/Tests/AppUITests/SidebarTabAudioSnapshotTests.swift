import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs of a tab's sound (DEV-800): rows with their speaker (playing, muted,
/// turned down), the speaker's volume popover, and Media rows with their sliders, light and dark,
/// when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct SidebarTabAudioSnapshotTests {
	private static let profileID: UUID = .init(uuidString: "00000000-0000-0000-0000-000000000001")!

	@Test(arguments: [false, true])
	internal func rows(dark: Bool) throws {
		let rows: [(String, SidebarItem.Audio?)] = [
			("Google Meet", .init(isPlaying: true, volume: 1)),
			("Lo-fi beats to build a browser to", .init(isPlaying: true, isMuted: true, volume: 1)),
			("Weekly sync", .init(isPlaying: true, volume: 0.4)),
			("Point-Free", .init(volume: 1)),
		]
		let view = VStack(spacing: BrowserMetrics.Row.spacing) {
			ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
				SidebarRow(
					item: .init(
						id: .tab(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index + 1)))),
						title: row.0,
						isPinned: false,
						audio: row.1
					),
					selected: index == 0,
					onAction: { _ in }
				)
			}
		}
		.padding(BrowserMetrics.Sidebar.horizontalPadding)
		.frame(width: 260)
		.background { BrowserChromeBackground(textured: true) }
		try write(view, dark: dark, name: "tab-audio-rows")
	}

	@Test(arguments: [false, true], [false, true])
	internal func popover(
		muted: Bool,
		dark: Bool
	) throws {
		let view = SidebarTabVolumePopover(
			title: "Google Meet – Weekly sync",
			audio: .init(isPlaying: true, isMuted: muted, volume: 0.4),
			onMute: {},
			onVolume: { _ in }
		)
		.background(Color(nsColor: .windowBackgroundColor))
		try write(view, dark: dark, name: "tab-volume-popover\(muted ? "-muted" : "")")
	}

	@Test(arguments: [false, true])
	internal func mediaRows(dark: Bool) throws {
		let view = SidebarMediaPanel(
			items: [
				.init(
					id: Self.id(1),
					title: "Weekly sync",
					subtitle: "meet.google.com",
					playback: .playing,
					canPause: true,
					volume: 0.4
				),
				.init(
					id: Self.id(2),
					title: "Lo-fi beats to build a browser to",
					subtitle: "youtube.com",
					playback: .paused,
					canPlay: true,
					isMuted: true,
					volume: 1
				),
			],
			onPlayPause: { _ in },
			onMute: { _ in },
			onVolume: { _, _ in },
			onReturn: { _ in }
		)
		.padding(.top, BrowserMetrics.Library.headerInset)
		.frame(width: 300, height: 260, alignment: .top)
		.background { BrowserChromeBackground(textured: true) }
		try write(view, dark: dark, name: "library-media-volume")
	}

	private func write(
		_ view: some View,
		dark: Bool,
		name: String
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
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
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
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

/// What a tab row's speaker shows (DEV-800).
internal struct SidebarTabAudioTests {
	@Test
	internal func theSpeakerShowsWhilePlayingMutedOrTurnedDown() {
		#expect(!SidebarItem.Audio().showsIndicator)
		#expect(!SidebarItem.Audio(volume: 1).showsIndicator)
		#expect(SidebarItem.Audio(isPlaying: true).showsIndicator)
		#expect(SidebarItem.Audio(isMuted: true).showsIndicator)
		#expect(SidebarItem.Audio(volume: 0.5).showsIndicator)
	}

	@Test
	internal func itsWavesFollowTheVolume() {
		#expect(SidebarItem.Audio(isMuted: true, volume: 0.8).symbol == "speaker.slash.fill")
		#expect(SidebarItem.Audio(volume: 0).symbol == "speaker.fill")
		#expect(SidebarItem.Audio(volume: 0.2).symbol == "speaker.wave.1.fill")
		#expect(SidebarItem.Audio(volume: 0.5).symbol == "speaker.wave.2.fill")
		#expect(SidebarItem.Audio(volume: 1).symbol == "speaker.wave.3.fill")
		// An engine without volume plays at full volume.
		#expect(SidebarItem.Audio(isPlaying: true).symbol == "speaker.wave.3.fill")
	}
}
