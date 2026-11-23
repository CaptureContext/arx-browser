import AppKit
@testable import AppUI
import Foundation
import SwiftUI
import Testing

/// Writes offscreen PNGs of each hover preview card (DEV-802): a folder's list (and its search with
/// no results and with a selection, DEV-836), a Gmail favorite
/// with unread mail and while it's closed, and a Linear favorite's recent pages, and a page that
/// isn't loaded with and without the site's preview image (DEV-1142), light and dark, when
/// `ARX_DESIGN_SNAPSHOTS` names a directory. Offscreen renders show the material's fallback.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct SidebarHoverPreviewSnapshotTests {
	private static let now: Date = .now

	@Test(arguments: [false, true])
	internal func folderList(dark: Bool) throws {
		try render(
			SidebarFolderPreviewList(folder: Self.folder, previews: Self.folderPreviews, search: .init(), send: { _ in }),
			name: "hover-folder",
			dark: dark
		)
	}

	/// DEV-1286: over a window with a strong Jeans texture, the preview keeps plain glass; the
	/// texture stays on the window background around it.
	@Test(arguments: [false, true])
	internal func folderOverATexturedWindow(dark: Bool) throws {
		try render(
			SidebarFolderPreviewList(folder: Self.folder, previews: Self.folderPreviews, search: .init(), send: { _ in })
				.environment(\.browserFilmGrain, .init(intensity: 1, texture: .jeans)),
			name: "hover-folder-over-texture",
			dark: dark,
			backdrop: AnyView(
				BrowserChromeBackground(textured: true)
					.environment(\.browserFilmGrain, .init(intensity: 1, texture: .jeans))
			)
		)
	}

	/// DEV-836: a query that matches nothing keeps the list open with its message.
	@Test(arguments: [false, true])
	internal func folderSearchWithNoResults(dark: Bool) throws {
		try render(
			SidebarFolderPreviewList(
				folder: Self.folder,
				previews: Self.folderPreviews,
				search: .init(query: "zzz", isEngaged: true),
				send: { _ in }
			),
			name: "hover-folder-no-results",
			dark: dark
		)
	}

	/// DEV-836: a query selects its first result; the arrows moved it to the second.
	@Test(arguments: [false, true])
	internal func folderSearchSelection(dark: Bool) throws {
		try render(
			SidebarFolderPreviewList(
				folder: Self.folder,
				previews: Self.folderPreviews,
				search: .init(query: "a", selection: UUID(3), isEngaged: true),
				send: { _ in }
			),
			name: "hover-folder-selected",
			dark: dark
		)
	}

	/// DEV-1275: an empty folder keeps its search and Close over its message.
	@Test(arguments: [false, true])
	internal func emptyFolder(dark: Bool) throws {
		try render(
			SidebarFolderPreviewList(
				folder: SidebarItem(id: .folder(UUID(12)), title: "Later"),
				previews: Self.folderPreviews,
				search: .init(),
				send: { _ in }
			),
			name: "hover-folder-empty",
			dark: dark
		)
	}

	/// DEV-1275: a Split View in a folder is one row naming both panes.
	@Test(arguments: [false, true])
	internal func folderWithSplitView(dark: Bool) throws {
		let split = SidebarItem.Split(
			id: UUID(20),
			members: [
				.init(id: .tab(UUID(1)), title: "Arx MVP – Linear", symbol: "list.bullet"),
				.init(id: .tab(UUID(2)), title: "Design review notes", symbol: "doc.text"),
			]
		)
		let folder = SidebarItem(
			id: .folder(UUID(10)),
			title: "Research",
			children: [
				.init(id: .tab(UUID(1)), title: "Arx MVP – Linear", symbol: "list.bullet", split: split),
				.init(id: .tab(UUID(3)), title: "Attention Is All You Need", symbol: "book"),
			]
		)
		try render(
			SidebarFolderPreviewList(folder: folder, previews: Self.folderPreviews, search: .init(), send: { _ in }),
			name: "hover-folder-split",
			dark: dark
		)
	}

	private static var folder: SidebarItem {
		SidebarItem(
			id: .folder(UUID(10)),
			title: "Research",
			children: [
				.init(id: .tab(UUID(1)), title: "Arx MVP – Linear", symbol: "list.bullet"),
				.init(id: .tab(UUID(2)), title: "Design review notes", symbol: "doc.text"),
				.init(id: .folder(UUID(11)), title: "Papers", children: [
					.init(id: .tab(UUID(3)), title: "Attention Is All You Need", symbol: "book"),
				]),
			]
		)
	}

	private static var folderPreviews: SidebarHoverPreviews {
		SidebarHoverPreviews(tabs: { _ in
			[
				UUID(1): .init(title: "Arx MVP", url: URL(string: "https://linear.app/capturecontext")!, lastUsed: Self.now.addingTimeInterval(-600)),
				UUID(2): .init(title: "Design review notes", url: URL(string: "https://notion.so/notes")!, lastUsed: Self.now.addingTimeInterval(-86_400)),
				UUID(3): .init(title: "Attention Is All You Need", url: URL(string: "https://arxiv.org/abs/1706.03762")!),
			]
		})
	}

	@Test(arguments: [false, true])
	internal func gmailUnread(dark: Bool) throws {
		let site = SidebarSitePreview(
			kind: .mail,
			items: [
				.init(id: "1", title: "Design review moved to Thursday", detail: "Ada Lovelace", date: Self.now.addingTimeInterval(-300)),
				.init(id: "2", title: "Your invoice for November", detail: "Railway", date: Self.now.addingTimeInterval(-7_200)),
				.init(id: "3", title: "Re: Hover previews", detail: "Grace Hopper", date: Self.now.addingTimeInterval(-90_000)),
			],
			total: 12
		)
		try render(
			card(
				title: "Inbox (12) - maxim@example.com - Gmail",
				url: "https://mail.google.com/mail/u/0/#inbox",
				site: site
			),
			name: "hover-gmail",
			dark: dark
		)
	}

	@Test(arguments: [false, true])
	internal func gmailClosed(dark: Bool) throws {
		let site = SidebarSitePreview(kind: .mail, needsOpenPage: true)
		try render(
			card(title: "Gmail", url: "https://mail.google.com/mail/u/0/", site: site),
			name: "hover-gmail-closed",
			dark: dark
		)
	}

	@Test(arguments: [false, true])
	internal func recentPages(dark: Bool) throws {
		let site = SidebarSitePreview(
			kind: .recentPages,
			items: [
				.init(id: "a", title: "DEV-802 Implement the hover preview settings", date: Self.now.addingTimeInterval(-120)),
				.init(id: "b", title: "Arx MVP", date: Self.now.addingTimeInterval(-3_600)),
				.init(id: "c", title: "My issues", date: Self.now.addingTimeInterval(-172_800)),
			]
		)
		try render(
			card(title: "Linear", url: "https://linear.app/capturecontext", site: site),
			name: "hover-recent",
			dark: dark
		)
	}

	/// DEV-1142: an unloaded page's card with the picture its site publishes, its title and
	/// description.
	@Test(arguments: [false, true])
	internal func unloadedPageWithSitePicture(dark: Bool) throws {
		let picture = try Self.sitePicture()
		try render(
			unloadedCard(
				title: "Arx: a calmer browser for the Mac",
				url: "https://arx.example/blog/calmer-browser",
				summary: "How Arx keeps hundreds of tabs light: pictures instead of pages, and pages only when you look.",
				picture: picture
			),
			name: "hover-unloaded-site-picture",
			dark: dark
		)
	}

	/// DEV-1142: a site that publishes no picture: title, description and site icon only.
	@Test(arguments: [false, true])
	internal func unloadedPageWithoutPicture(dark: Bool) throws {
		try render(
			unloadedCard(
				title: "Release notes – Arx",
				url: "https://arx.example/releases",
				summary: "Every change in each Arx release, newest first.",
				picture: nil
			),
			name: "hover-unloaded-no-picture",
			dark: dark
		)
	}

	/// DEV-1275: with Shift + hover loads the page on, an unloaded page's card says ⇧ loads it.
	@Test(arguments: [false, true])
	internal func unloadedPageWithLoadHint(dark: Bool) throws {
		let picture = try Self.sitePicture()
		try render(
			unloadedCard(
				title: "Arx: a calmer browser for the Mac",
				url: "https://arx.example/blog/calmer-browser",
				summary: "How Arx keeps hundreds of tabs light: pictures instead of pages, and pages only when you look.",
				picture: picture,
				loadsPages: true
			),
			name: "hover-unloaded-load-hint",
			dark: dark
		)
	}

	private func unloadedCard(
		title: String,
		url: String,
		summary: String,
		picture: CGImage?,
		loadsPages: Bool = false
	) -> some View {
		let id = UUID(1)
		let previews = SidebarHoverPreviews(
			tabs: { _ in [id: .init(title: title, url: URL(string: url)!, lastUsed: Self.now.addingTimeInterval(-7_200))] },
			thumbnail: { _ in picture },
			livePage: loadsPages ? { @MainActor @Sendable _ in nil } : nil,
			summary: { _ in summary }
		)
		return SidebarTabPreviewCard(
			id: id,
			fallbackTitle: title,
			siteIcon: nil,
			symbol: "globe",
			tint: .white,
			previews: previews
		)
	}

	/// A stand-in for a site's 1200×630 Open Graph picture, at card size.
	private static func sitePicture() throws -> CGImage {
		let width = 528
		let height = 277
		let context = try #require(CGContext(
			data: nil,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		))
		let colors = [
			CGColor(red: 0.16, green: 0.33, blue: 0.75, alpha: 1),
			CGColor(red: 0.55, green: 0.32, blue: 0.82, alpha: 1),
		] as CFArray
		let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]))
		context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
		context.fill(CGRect(x: 40, y: 150, width: 300, height: 28))
		context.fill(CGRect(x: 40, y: 110, width: 200, height: 18))
		return try #require(context.makeImage())
	}

	private func card(
		title: String,
		url: String,
		site: SidebarSitePreview
	) -> some View {
		let id = UUID(1)
		let previews = SidebarHoverPreviews(
			tabs: { _ in [id: .init(title: title, url: URL(string: url)!, lastUsed: Self.now.addingTimeInterval(-60))] },
			site: { _ in site }
		)
		return SidebarTabPreviewCard(
			id: id,
			fallbackTitle: title,
			siteIcon: nil,
			symbol: "globe",
			tint: .white,
			previews: previews
		)
	}

	/// The preview's raised glass over a page beside the sidebar, as the sidebar presents it
	/// (DEV-1275).
	private func render(
		_ content: some View,
		name: String,
		dark: Bool,
		backdrop: AnyView = AnyView(Rectangle().fill(BrowserTheme.page))
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = content
			.padding(SidebarPreviewGlassMetrics.shadowMargin + 10)
			.background(backdrop)
			.fixedSize()

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

		// The site's rows arrive from a task; let it finish and the card grow.
		for _ in 0..<8 {
			host.layoutSubtreeIfNeeded()
			host.frame.size = host.fittingSize
			window.setContentSize(host.frame.size)
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}

extension UUID {
	fileprivate init(_ value: Int) {
		self.init(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
	}
}

/// DEV-802: folders open their list only while folder previews are on.
internal struct SidebarHoverPreviewSourcesTests {
	@Test
	internal func foldersFollowTheirOptionAndTabsAlwaysPreview() {
		let folder = SidebarItem(id: .folder(UUID(1)), title: "Folder")
		let tab = SidebarItem(id: .tab(UUID(2)), title: "Tab")
		let on = SidebarHoverPreviews(tabs: { _ in [:] })
		let off = SidebarHoverPreviews(tabs: { _ in [:] }, showsFolders: false)
		#expect(on.covers(folder))
		#expect(on.covers(tab))
		#expect(!off.covers(folder))
		#expect(off.covers(tab))
	}
}
