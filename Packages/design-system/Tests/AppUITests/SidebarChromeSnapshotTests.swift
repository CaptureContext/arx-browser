import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// Writes offscreen PNGs of the sidebar's chrome, light and dark, for visual review,
/// when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct SidebarChromeSnapshotTests {
	/// A quarter of the way into opening the side menu: the spaces are half faded and slightly smaller.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func sideMenuOpening(_ appearance: NSAppearance.Name) throws {
		for progress: CGFloat in [0, 0.25] {
			try SidebarChromeSnapshot.write(
				SidebarChromeFixture.sidebar(libraryProgress: progress),
				size: .init(width: 416, height: 480),
				appearance: appearance,
				name: "side-menu-opening-\(Int(progress * 100))"
			)
		}
	}

	/// DEV-752: the header at the narrow widths, with a short and a long profile name.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func profileBadge(_ appearance: NSAppearance.Name) throws {
		for width: CGFloat in [216, 260, 286] {
			for (label, name) in [("short", "Arx"), ("long", "Personal Projects and Research")] {
				try SidebarChromeSnapshot.write(
					SidebarChromeFixture.sidebar(profileName: name, width: width),
					size: .init(width: width, height: 140),
					appearance: appearance,
					name: "profile-badge-\(Int(width))-\(label)"
				)
			}
		}
	}

	/// DEV-753: the footer with the Library button's hint showing, as after a long hover.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func libraryHint(_ appearance: NSAppearance.Name) async throws {
		let timer = SidebarSpaceHintTimer()
		let view = VStack {
			Spacer()
			HStack(spacing: BrowserMetrics.SpaceSwitcher.spacing) {
				SidebarLibraryButton(isOpen: false, title: "Library", shortcut: ["⇧", "⌘", "L"]) {}
				Spacer()
			}
			.font(.system(size: BrowserMetrics.SpaceSwitcher.symbolSize - 2, weight: .medium))
			.padding(.horizontal, 14)
			.frame(height: BrowserMetrics.SpaceSwitcher.height)
			.sidebarFooterHintRow()
		}
		.environment(\.sidebarFooterHintTimer, timer)
		.sidebarSpaceHintHost()
		timer.pointerMoved(over: SidebarSpaceHintTimer.libraryHintID)
		try await Task.sleep(for: SidebarSpaceHintTimer.delay + .milliseconds(200))
		#expect(timer.hinted == SidebarSpaceHintTimer.libraryHintID)
		try SidebarChromeSnapshot.write(
			view,
			size: .init(width: 286, height: 140),
			appearance: appearance,
			name: "library-hint"
		)
	}

	/// DEV-758: recent downloads fanned out above the footer, as while the Library button is hovered:
	/// a picture's thumbnail, file icons, names and ages, newest nearest the button.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func libraryRecentDownloads(_ appearance: NSAppearance.Name) async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "dev-758-downloads-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }

		let now = Date(timeIntervalSince1970: 1_800_000_000)
		let profile = Profile.ID(rawValue: UUID())
		let files: [(name: String, minutesAgo: Double)] = [
			("Sunset over the bay.png", 2),
			("Arx-0.9-universal.dmg", 14),
			("Quarterly planning notes and action items for the design review.txt", 95),
			("invoice-2026-11.pdf", 60 * 26),
		]
		let downloads = try files.map { file in
			let url = folder.appending(path: file.name)
			try SidebarChromeFixture.fileData(named: file.name).write(to: url)
			return BrowserDownload(
				id: .init(profileID: profile, guid: file.name),
				profileName: "Work",
				target: url,
				filename: file.name,
				status: .complete,
				startedAt: now.addingTimeInterval(-file.minutesAgo * 60)
			)
		}
		let view = VStack(alignment: .leading, spacing: 0) {
			Spacer()
			SidebarRecentDownloadsList(downloads: downloads, now: now, isFanned: true, open: { _ in })
				.padding(.leading, 6)
			HStack(spacing: BrowserMetrics.SpaceSwitcher.spacing) {
				SidebarLibraryButton(isOpen: false, title: "Library", shortcut: ["⇧", "⌘", "L"]) {}
				Spacer()
			}
			.font(.system(size: BrowserMetrics.SpaceSwitcher.symbolSize - 2, weight: .medium))
			.padding(.horizontal, 14)
			.frame(height: BrowserMetrics.SpaceSwitcher.height)
		}

		// Quick Look draws the picture's thumbnail off the main thread.
		_ = try SidebarChromeSnapshot.render(view, size: .init(width: 286, height: 340), appearance: appearance)
		try await Task.sleep(for: .seconds(1))
		try SidebarChromeSnapshot.write(
			view,
			size: .init(width: 286, height: 340),
			appearance: appearance,
			name: "library-recent-downloads"
		)
	}

	/// DEV-758 review: a panorama's and a portrait's thumbnails stay inside their square, clear of the
	/// name and of the rows around them.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func libraryRecentDownloadThumbnails(_ appearance: NSAppearance.Name) throws {
		let now = Date(timeIntervalSince1970: 1_800_000_000)
		let profile = Profile.ID(rawValue: UUID())
		let pictures: [(name: String, size: CGSize)] = [
			("Panorama of the harbour at dusk.jpg", .init(width: 600, height: 80)),
			("Portrait.heic", .init(width: 60, height: 400)),
			("Square.png", .init(width: 200, height: 200)),
		]
		let view = VStack(alignment: .leading, spacing: 6) {
			ForEach(Array(pictures.enumerated()), id: \.offset) { index, picture in
				SidebarRecentDownloadRow(
					download: .init(
						id: .init(profileID: profile, guid: picture.name),
						profileName: "Work",
						filename: picture.name,
						status: .complete,
						startedAt: now.addingTimeInterval(-Double(index + 1) * 300)
					),
					now: now,
					thumbnail: SidebarChromeFixture.picture(size: picture.size),
					open: {}
				)
			}
		}
		.padding(8)
		try SidebarChromeSnapshot.write(
			view,
			size: .init(width: 286, height: 190),
			appearance: appearance,
			name: "library-recent-download-thumbnails"
		)
	}
}

@MainActor
internal enum SidebarChromeSnapshot {
	internal nonisolated static var directory: URL? {
		ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
	}

	internal static func write(
		_ view: some View,
		size: CGSize,
		appearance: NSAppearance.Name,
		name: String
	) throws {
		let directory = try #require(directory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let representation = try render(view, size: size, appearance: appearance)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(appearance == .darkAqua ? "dark" : "light").png"))
	}

	internal static func render(
		_ view: some View,
		size: CGSize,
		appearance: NSAppearance.Name
	) throws -> NSBitmapImageRep {
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: appearance)

		let host = NSHostingView(rootView: ZStack {
			BrowserChromeBackground(textured: true)
			view
		}
		.frame(width: size.width, height: size.height))
		host.safeAreaRegions = []
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		window.close()
		return representation
	}
}

@MainActor
internal enum SidebarChromeFixture {
	/// A gradient picture of `size`, with a white frame so any overflow past its square shows.
	internal static func picture(size: CGSize) -> NSImage {
		NSImage(size: size, flipped: false) { rect in
			NSGradient(colors: [.systemTeal, .systemBlue, .systemPurple])?.draw(in: rect, angle: 0)
			NSColor.white.setStroke()
			NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2)).stroke()
			return true
		}
	}

	/// A small gradient picture for a `.png`, so Quick Look has a thumbnail to draw; empty data otherwise.
	internal static func fileData(named name: String) throws -> Data {
		guard name.hasSuffix(".png") else { return Data() }
		let image = NSImage(size: .init(width: 120, height: 80), flipped: false) { rect in
			NSGradient(colors: [.systemOrange, .systemPink, .systemIndigo])?.draw(in: rect, angle: 70)
			return true
		}
		let tiff = try #require(image.tiffRepresentation)
		return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
	}

	private static func id(_ value: UInt8) -> UUID {
		UUID(uuid: (value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
	}

	internal static func space(profileName: String? = nil) -> SidebarSpace {
		.init(
			id: id(1),
			name: "Work",
			profileID: profileName.map { _ in id(2) },
			profileName: profileName,
			favorites: [
				.init(id: .tab(id(10)), title: "Mail", symbol: "envelope.fill", tint: .blue),
				.init(id: .tab(id(11)), title: "Calendar", symbol: "calendar", tint: .orange),
			],
			savedItems: [
				.init(id: .tab(id(20)), title: "Pull requests", symbol: "arrow.triangle.pull", tint: .lavender),
				.init(id: .tab(id(21)), title: "Documentation", symbol: "book.closed", tint: .blue),
			],
			unpinnedTabs: [
				.init(id: .tab(id(40)), title: "Release notes", symbol: "doc.text", tint: .green),
			],
			selectedID: .tab(id(20)),
			url: URL(string: "https://github.com/capturecontext/arx/pulls")
		)
	}

	internal static func sidebar<Footer: View>(
		libraryProgress: CGFloat = 0,
		profileName: String? = nil,
		width: CGFloat = 286,
		@ViewBuilder footer: () -> Footer
	) -> some View {
		SidebarPager(
			spaces: [space(profileName: profileName)],
			selectedSpaceID: id(1),
			navigation: .init(canGoBack: true, isAvailable: true),
			library: .init(
				isOpen: libraryProgress == 1,
				progress: .constant(libraryProgress),
				sections: [.media, .downloads, .spaces, .archive],
				selection: .downloads,
				setOpen: { _ in },
				select: { _ in }
			),
			profileMenu: profileName.map { _ in { _ in AnyView(EmptyView()) } },
			onSelectSpace: { _ in },
			onAction: { _, _ in },
			onCopyURL: {},
			footer: footer,
			libraryPanel: { Color.clear }
		)
		.environment(\.sidebarWidths, .init(base: width, expanded: max(width, BrowserMetrics.Library.minimumWidth)))
	}
}

extension SidebarChromeFixture {
	internal static func sidebar(
		libraryProgress: CGFloat = 0,
		profileName: String? = nil,
		width: CGFloat = 286
	) -> some View {
		sidebar(libraryProgress: libraryProgress, profileName: profileName, width: width) { Color.clear.frame(height: 40) }
	}
}
