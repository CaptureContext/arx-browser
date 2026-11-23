import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// The Picture in Picture items of a tab's menu and a media cell's menu (DEV-1106), drawn as a
/// menu lists them, in light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory: a playing
/// tab, a tab whose site keeps its video out of Picture in Picture, a silent tab, and the media
/// cell's menu. A context menu can't be drawn offscreen, so each item is a row with its title,
/// dimmed when disabled, and its help below.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct PictureInPictureMenuSnapshotTests {
	@Test(arguments: [false, true])
	internal func menus(dark: Bool) async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let reason = String.localized(.appUI.media.pictureUnavailableSite)
		let menus = HStack(alignment: .top, spacing: 16) {
			Self.menu("Playing tab", Self.rows(BrowserPictureInPictureMenu.items(media: .available, canPresentTab: true)))
			Self.menu(
				"Protected video",
				Self.rows(BrowserPictureInPictureMenu.items(media: .unavailable(reason: reason), canPresentTab: true))
			)
			Self.menu("Silent tab", Self.rows(BrowserPictureInPictureMenu.items(media: nil, canPresentTab: true)))
			Self.menu("Media cell", AnyView(Self.mediaCell))
		}
		.padding(16)
		.background(Color.gray.opacity(0.3))
		try write(menus, dark: dark, to: directory.appending(path: "pip-menus-\(dark ? "dark" : "light").png"))
	}

	private static func rows(_ items: [BrowserPictureInPictureMenu.Item]) -> AnyView {
		AnyView(VStack(alignment: .leading, spacing: 6) {
			ForEach(items, id: \.kind) { item in
				VStack(alignment: .leading, spacing: 2) {
					Text(verbatim: item.title)
						.foregroundStyle(item.isEnabled ? .primary : .tertiary)
					if let help = item.help {
						Text(verbatim: help)
							.font(.caption)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
			}
		})
	}

	/// The media cell's menu as `SidebarMediaMenu` builds it, its buttons drawn as menu rows.
	private static var mediaCell: some View {
		VStack(alignment: .leading, spacing: 6) {
			SidebarMediaMenu(
				item: .init(
					id: .init(tabID: .init(rawValue: UUID()), profileID: .init(rawValue: UUID()), generation: 1),
					title: "Live",
					subtitle: "example.com",
					playback: .playing,
					canPlay: true,
					canPause: true,
					isMuted: false,
					volume: nil,
					canReturn: true
				),
				pictureInPicture: .available,
				onPresent: {},
				onPlayPause: { _ in },
				onMute: {},
				onReturn: {}
			)
		}
		.buttonStyle(.plain)
	}

	private static func menu(
		_ title: String,
		_ content: AnyView
	) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
			content
				.font(.system(size: 13))
				.padding(10)
				.frame(width: 260, alignment: .leading)
				.background(.regularMaterial, in: .rect(cornerRadius: 8))
		}
	}

	private func write(
		_ view: some View,
		dark: Bool,
		to file: URL
	) throws {
		let host = NSHostingView(rootView: view.fixedSize())
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
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: file)
		window.close()
	}
}
