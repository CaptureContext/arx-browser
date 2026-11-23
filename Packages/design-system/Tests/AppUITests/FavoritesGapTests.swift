import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import Observation
import SwiftUI
import Testing

/// DEV-999: a favorite dragged out of the grid, whose move lands before its drag ends, used to
/// leave its held cell open: an empty cell after the favorites, a row's gap above the space's name.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views")
)
internal struct FavoritesGapTests {
	/// The pinned header is the URL bar and Favorites, and the space's name sits right under it, so
	/// its height is where the name goes.
	@Test
	internal func aFavoriteMovedOutMidDragLeavesNoGap() async throws {
		let favorites = GapFixture.favorites(9)
		let header = HostedHeader(favorites: favorites)
		defer { header.close() }
		await header.settle()
		let atRest = HostedHeader(favorites: Array(favorites.prefix(8)))
		defer { atRest.close() }
		await atRest.settle()

		// The last favorite is picked up, so its cell is held.
		header.preview.begin(.init(item: favorites[8], fromFavorites: true))
		await header.settle()

		// It lands among the tabs while its source still reports the drag.
		header.inputs.favorites.removeLast()
		await header.settle()

		#expect(header.height == atRest.height)

		// Nor when the drag then ends.
		header.preview.end(favorites[8].id)
		await header.settle()
		#expect(header.height == atRest.height)
	}

	/// A held cell stays while its favorite is still carried: the grid keeps its height.
	@Test
	internal func aPickedUpFavoriteKeepsItsCell() async throws {
		let favorites = GapFixture.favorites(9)
		let header = HostedHeader(favorites: favorites)
		defer { header.close() }
		await header.settle()
		let before = header.height

		header.preview.begin(.init(item: favorites[8], fromFavorites: true))
		await header.settle()
		#expect(header.height == before)
	}

	/// A drag the source reports again in the same update as its reset keeps its item's id, so
	/// following the item's id left it untracked: nothing ended it, and its favorite's cell stayed held.
	@Test
	internal func aDragBegunAgainAfterItsResetIsTrackedAgain() {
		let model = SidebarDragPreviewModel()
		let favorite = GapFixture.favorites(1)[0]
		model.begin(.init(item: favorite, fromFavorites: true))
		let first = model.trackedDrag
		model.end(favorite.id)
		model.begin(.init(item: favorite, fromFavorites: true), isNew: false)

		#expect(first != nil)
		#expect(model.trackedDrag != nil)
		#expect(model.trackedDrag != first)
	}

	/// DEV-1230: with no favorites, the card that a drag shows is there before the drag too, so
	/// starting and ending a drag doesn't move the rows under it.
	@Test
	internal func theEmptyCardStaysThroughADrag() async throws {
		let header = HostedHeader(favorites: [])
		defer { header.close() }
		await header.settle()
		let idle = header.height
		let tab = GapFixture.tabs(1)[0]

		header.preview.begin(.init(item: tab, fromFavorites: false))
		await header.settle()
		#expect(header.height == idle)

		header.preview.end(tab.id)
		await header.settle()
		#expect(header.height == idle)
	}

	/// The card is the same height idle as during a drag, and taller than the header without it.
	@Test
	internal func theEmptyCardShowsWithNothingDragged() async throws {
		let header = HostedHeader(favorites: [])
		defer { header.close() }
		await header.settle()
		let idle = header.height
		let tab = GapFixture.tabs(1)[0]
		header.preview.begin(.init(item: tab, fromFavorites: false))
		await header.settle()

		#expect(idle == header.height)
		#expect(idle > HostedHeader.urlBarOnlyHeight)
	}

	/// Folders can't be favorites: dragging one leaves the card where it is.
	@Test
	internal func aFolderDragKeepsTheEmptyCard() async throws {
		let header = HostedHeader(favorites: [])
		defer { header.close() }
		await header.settle()
		let idle = header.height
		let folder = SidebarItem(id: .folder(GapFixture.uuid(0xF0, 0)), title: "Folder")

		header.preview.begin(.init(item: folder, fromFavorites: false))
		await header.settle()
		#expect(header.height == idle)
	}

	/// The empty Favorites card idle and during a tab drag, on a textured theme, light and dark
	/// (DEV-1230). Written on `main` too, where the idle state has no card, for the before image.
	@Test(
		.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil),
		arguments: [NSAppearance.Name.aqua, .darkAqua]
	)
	internal func emptyCardSnapshot(_ appearance: NSAppearance.Name) async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let tints: [(name: String, tint: ChromeTint)] = [
			("default", .default),
			("violet", .init(hue: 265, intensity: 1)),
		]
		let mode = appearance == .darkAqua ? "dark" : "light"
		for (name, tint) in tints {
			let pager = HostedPager(favorites: [], tint: tint, appearance: appearance)
			defer { pager.close() }
			await pager.settle()
			try pager.write(to: directory.appending(path: "favorites-empty-idle-\(name)-\(mode).png"))
			let tab = pager.inputs.space.unpinnedTabs[0]
			pager.preview.begin(.init(item: tab, fromFavorites: false))
			await pager.settle()
			try pager.write(to: directory.appending(path: "favorites-empty-drag-\(name)-\(mode).png"))
			pager.preview.end(tab.id)
			await pager.settle()
		}
	}

	/// The pager with the favorite moved out mid-drag, as Max's sidebar showed it.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
	internal func snapshot() async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let favorites = GapFixture.favorites(9)
		let pager = HostedPager(favorites: favorites)
		defer { pager.close() }
		await pager.settle()
		pager.preview.begin(.init(item: favorites[8], fromFavorites: true))
		await pager.settle()
		pager.inputs.moveLastFavoriteToTabs()
		await pager.settle()
		try pager.write(to: directory.appending(path: "favorites-moved-out-mid-drag.png"))
	}
}

private enum GapFixture {
	internal static let spaceID: UUID = UUID(uuidString: "00000000-0000-0000-0000-00000000FFFF")!

	internal static func favorites(_ count: Int) -> [SidebarItem] {
		(0..<count).map { index in
			SidebarItem(id: .tab(uuid(0xF00, index)), title: "Favorite \(index)", isPinned: true)
		}
	}

	internal static func tabs(_ count: Int) -> [SidebarItem] {
		(0..<count).map { index in
			SidebarItem(id: .tab(uuid(0, index)), title: "Tab \(index)", isPinned: false)
		}
	}

	internal static func uuid(
		_ group: Int,
		_ index: Int
	) -> UUID {
		UUID(uuidString: String(format: "00000000-0000-0000-%04x-%012x", group, index))!
	}
}

@MainActor
@Observable
private final class HeaderInputs {
	internal var favorites: [SidebarItem]

	internal init(favorites: [SidebarItem]) {
		self.favorites = favorites
	}
}

private struct HeaderRoot: View {
	internal let inputs: HeaderInputs
	internal let preview: SidebarDragPreviewModel

	internal var body: some View {
		SidebarPinnedHeader(
			url: URL(string: "https://example.com"),
			favorites: inputs.favorites,
			selectedID: nil,
			splitIDs: [],
			availableHeight: 1_000,
			onAction: { _ in },
			onCopyURL: {}
		)
		.frame(width: 260)
		.environment(\.sidebarDragPreview, preview)
	}
}

/// The pinned header in a window of its own, so its tasks and geometry run as in the app.
@MainActor
private final class HostedHeader {
	internal let inputs: HeaderInputs
	internal let preview: SidebarDragPreviewModel
	private let window: NSWindow
	private let host: NSHostingView<HeaderRoot>

	internal init(favorites: [SidebarItem]) {
		self.inputs = .init(favorites: favorites)
		self.preview = .init()
		self.host = NSHostingView(rootView: HeaderRoot(inputs: inputs, preview: preview))
		self.window = HostWindow.make(content: host, size: .init(width: 260, height: 400))
	}

	internal var height: CGFloat { host.fittingSize.height }

	/// The header's height with a URL bar and nothing under it but the Favorites' bottom padding.
	internal static var urlBarOnlyHeight: CGFloat {
		BrowserMetrics.URLBar.height + BrowserMetrics.Sidebar.sectionSpacing + BrowserMetrics.Section.dividerSpacing
	}

	/// Waits without holding the main actor, so the grid's own tasks run.
	internal func settle() async {
		await HostWindow.settle(host)
	}

	internal func close() {
		window.close()
	}
}

@MainActor
@Observable
private final class PagerInputs {
	internal var space: SidebarSpace

	internal init(favorites: [SidebarItem]) {
		self.space = SidebarSpace(
			id: GapFixture.spaceID,
			name: "Relax",
			favorites: favorites,
			savedItems: [],
			unpinnedTabs: GapFixture.tabs(4),
			selectedID: GapFixture.tabs(1)[0].id,
			url: URL(string: "https://example.com")
		)
	}

	internal func moveLastFavoriteToTabs() {
		let moved = space.favorites.removeLast()
		space.unpinnedTabs.insert(.init(id: moved.id, title: moved.title, isPinned: false), at: 0)
	}
}

private struct PagerRoot: View {
	internal let inputs: PagerInputs
	internal let preview: SidebarDragPreviewModel

	/// The theme behind the sidebar, textured as the window draws it; plain without one.
	internal var tint: ChromeTint? = nil

	internal var body: some View {
		SidebarPager(
			spaces: [inputs.space.summary],
			selectedSpaceID: GapFixture.spaceID,
			space: { [inputs] _ in inputs.space },
			onSelectSpace: { _ in },
			onAction: { _, _ in },
			onCopyURL: {}
		) {
			Color.clear.frame(height: 40)
		} libraryPanel: {
			EmptyView()
		}
		.environment(\.sidebarWidths, .init(base: 260, expanded: 260))
		.environment(\.sidebarDragPreview, preview)
		.environment(\.browserChromeTint, tint ?? .default)
		.background {
			if let tint {
				BrowserChromeBackground(textured: true).environment(\.browserChromeTint, tint)
			} else {
				Color(nsColor: .windowBackgroundColor)
			}
		}
	}
}

@MainActor
private final class HostedPager {
	internal let inputs: PagerInputs
	internal let preview: SidebarDragPreviewModel
	private let window: NSWindow
	private let host: NSHostingView<PagerRoot>

	internal init(
		favorites: [SidebarItem],
		tint: ChromeTint? = nil,
		appearance: NSAppearance.Name = .darkAqua
	) {
		self.inputs = .init(favorites: favorites)
		self.preview = .init()
		self.host = NSHostingView(rootView: PagerRoot(inputs: inputs, preview: preview, tint: tint))
		self.window = HostWindow.make(content: host, size: .init(width: 260, height: 600))
		window.appearance = NSAppearance(named: appearance)
	}

	internal func settle() async {
		await HostWindow.settle(host)
	}

	internal func write(to url: URL) throws {
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: url)
	}

	internal func close() {
		window.close()
	}
}

@MainActor
private enum HostWindow {
	/// A transparent window on a screen, passing every click through: the pager's track runs on the
	/// screen's display link.
	internal static func make(
		content: NSView,
		size: CGSize
	) -> NSWindow {
		content.frame = CGRect(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .zero, size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = content
		window.appearance = NSAppearance(named: .darkAqua)
		if let screen = NSScreen.main {
			window.alphaValue = 0
			window.ignoresMouseEvents = true
			window.setFrameOrigin(screen.visibleFrame.origin)
			window.orderFrontRegardless()
		}
		return window
	}

	/// Longer than the grid's 600 ms wait for a move to land, in short sleeps that leave the main
	/// actor free.
	internal static func settle(_ view: NSView) async {
		for _ in 0..<40 {
			view.layoutSubtreeIfNeeded()
			try? await Task.sleep(for: .milliseconds(20))
		}
	}
}
