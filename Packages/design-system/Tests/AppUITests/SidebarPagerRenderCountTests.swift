#if DEBUG
// Bodies are counted only in Debug builds.
import AppKit
@testable import AppUI
import Foundation
import Observation
import SwiftUI
import Testing

/// DEV-937: the active tab's navigation re-renders neither the pager nor any space, a change in
/// one space's tabs re-renders only that space, and only the spaces on screen and next to it are
/// mounted at all, so the sidebar's work doesn't grow with the tabs in other spaces.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views")
)
internal struct SidebarPagerRenderCountTests {
	@Test
	internal func aNavigationEventRendersNeitherThePagerNorAnySpace() {
		let pager = HostedPager(spaceCount: 3, selected: 1)
		defer { pager.close() }

		let loading = pager.recording { $0.navigation = .init(canGoBack: true, isLoading: true, isAvailable: true) }
		#expect(loading.isEmpty, "\(loading)")

		let loaded = pager.recording { $0.navigation = .init(canGoBack: true, isLoading: false, isAvailable: true) }
		#expect(loaded.isEmpty, "\(loaded)")
	}

	@Test
	internal func aTabChangeInOneSpaceRendersOnlyThatSpace() {
		let pager = HostedPager(spaceCount: 3, selected: 1)
		defer { pager.close() }

		let renamed = pager.recording { $0.rename(tab: 4, inSpace: 0) }
		#expect(renamed[.sidebar(HostedPager.name(0))] != nil, "\(renamed)")
		#expect(renamed[.sidebar(HostedPager.name(1))] == nil, "\(renamed)")
		#expect(renamed[.sidebar(HostedPager.name(2))] == nil, "\(renamed)")

		let opened = pager.recording { $0.open(inSpace: 1) }
		#expect(opened[.sidebar(HostedPager.name(1))] != nil, "\(opened)")
		#expect(opened[.sidebar(HostedPager.name(0))] == nil, "\(opened)")
		#expect(opened[.sidebar(HostedPager.name(2))] == nil, "\(opened)")
	}

	/// DEV-1235, DEV-1310: the three spaces on either side of the selected one are built once
	/// the sidebar rests on it, the nearest first, and stay mounted while they're that near, so
	/// neither a swipe to a neighbour, a second one straight after it nor going back builds a page.
	@Test
	internal func theSpacesNearestTheSelectedOneAreMounted() async {
		let pager = HostedPager(spaceCount: 10, selected: 0)
		defer { pager.close() }

		// At first only the selected space and its neighbour, so opening a window builds no more.
		let first = pager.mountedSpaces()
		#expect(first == [0, 1])

		await pager.rest()
		let rested = pager.mountedSpaces()
		#expect(rested == [0, 1, 2, 3])

		await pager.select(5)
		let second = pager.mountedSpaces()
		#expect(second == [2, 3, 4, 5, 6, 7, 8])

		// Past seven, the spaces wanted longest ago go.
		await pager.select(8)
		let third = pager.mountedSpaces()
		#expect(third == [3, 4, 5, 6, 7, 8, 9])
	}

	/// DEV-1310: a second jump made before the sidebar had rested on the first built the space
	/// it went to as it came into view, under the fingers. Rested once, the sidebar has the
	/// next spaces built, so neither jump builds a row.
	@Test
	internal func jumpingTwiceWithoutRestingBuildsNoRows() async {
		let pager = HostedPager(spaceCount: 6, selected: 0)
		defer { pager.close() }
		await pager.rest()

		SidebarRenderTrace.startRecording()
		pager.update { $0.selectedSpaceID = HostedPager.spaceID(1) }
		pager.update { $0.selectedSpaceID = HostedPager.spaceID(2) }
		pager.update { $0.selectedSpaceID = HostedPager.spaceID(3) }
		let rows = SidebarRenderTrace.counts ?? [:]
		SidebarRenderTrace.stopRecording()
		#expect(rows.isEmpty, "built: \(rows.count) rows")
	}

	/// DEV-1235: selecting a space used to build its far neighbour and tear down the space left
	/// behind in the frame the swipe there lands on. With its neighbours built ahead, selecting
	/// one builds no row.
	@Test
	internal func selectingTheNextSpaceBuildsNoRows() async {
		let pager = HostedPager(spaceCount: 6, selected: 1)
		defer { pager.close() }
		await pager.rest()

		SidebarRenderTrace.startRecording()
		pager.update(settling: true) { $0.selectedSpaceID = HostedPager.spaceID(2) }
		let rows = SidebarRenderTrace.counts ?? [:]
		let views = SidebarRenderTrace.views ?? [:]
		SidebarRenderTrace.stopRecording()
		#expect(rows.isEmpty, "built: \(rows.count) rows")
		// Neither space's sidebar runs its body either: what changed for them is who is selected.
		#expect(views[.sidebar(HostedPager.name(1))] == nil, "\(views)")
		#expect(views[.sidebar(HostedPager.name(2))] == nil, "\(views)")
	}

	/// DEV-1235: a selection made elsewhere, as by a footer button, slides past any number of
	/// spaces. Only the one it lands on is built for it.
	@Test
	internal func slidingPastSpacesBuildsOnlyTheOneItLandsOn() {
		let pager = HostedPager(spaceCount: 8, selected: 0)
		defer { pager.close() }

		// No rest in between: only what the slide itself builds.
		pager.update(settling: true) { $0.selectedSpaceID = HostedPager.spaceID(6) }
		let mounted = pager.mountedSpaces()
		#expect(mounted == [0, 1, 6])
	}

	@Test
	internal func aSpaceMountedAgainOpensWhereItWasScrolled() async throws {
		let pager = HostedPager(spaceCount: 8, selected: 0)
		defer { pager.close() }

		let scrolled: CGFloat = 400
		let list = try #require(pager.visibleList())
		let resting = list.contentView.bounds.origin.y
		list.contentView.scroll(to: .init(x: 0, y: resting + scrolled))
		list.reflectScrolledClipView(list.contentView)
		pager.update { _ in }

		// Far enough, for long enough, that the first space is let go.
		await pager.select(4)
		await pager.select(7)
		#expect(!pager.mountedSpaces().contains(0))
		await pager.select(0)

		let restored = try #require(pager.visibleList())
		#expect(restored !== list)
		#expect(abs(restored.contentView.bounds.origin.y - (resting + scrolled)) < 1)
	}

	/// DEV-1235: the edges under the header and over the footer strengthen over the first and
	/// last 24 points of a scroll. Their progress was view state of the sidebar and the pager, so
	/// every frame of a scroll there ran both bodies again.
	@Test
	internal func scrollingNearEitherEndRendersNeitherThePagerNorTheSidebar() throws {
		let pager = HostedPager(spaceCount: 2, selected: 0)
		defer { pager.close() }

		let list = try #require(pager.visibleList())
		let clip = list.contentView
		let document = try #require(list.documentView)
		let top: CGFloat = clip.bounds.origin.y
		let bottom: CGFloat = document.frame.height + clip.contentInsets.bottom - clip.bounds.height
		let nearTop: [CGFloat] = stride(from: 4, through: 28, by: 4).map { top + $0 }
		let nearBottom: [CGFloat] = stride(from: 28, through: 0, by: -4).map { bottom - $0 }

		SidebarRenderTrace.startRecording()
		defer { SidebarRenderTrace.stopRecording() }
		for y in nearTop + nearBottom {
			clip.scroll(to: .init(x: 0, y: y))
			list.reflectScrolledClipView(clip)
			pager.update { _ in }
		}
		let views = SidebarRenderTrace.views ?? [:]
		#expect(views[.pager] == nil, "\(views)")
		#expect(views[.sidebar(HostedPager.name(0))] == nil, "\(views)")
	}
}

private let tabsPerSpace: Int = 40

private func uuid(
	_ space: Int,
	_ index: Int
) -> UUID {
	UUID(uuidString: String(format: "00000000-0000-0000-%04x-%012x", space, index))!
}

/// The window's state the pager reads: each space's tabs, the selection and the active tab's navigation.
@MainActor
@Observable
private final class PagerInputs {
	internal var spaces: [SidebarSpace]
	internal var selectedSpaceID: UUID
	internal var navigation: SidebarNavigation

	internal init(
		spaceCount: Int,
		selected: Int
	) {
		self.spaces = (0..<spaceCount).map { space in
			SidebarSpace(
				id: HostedPager.spaceID(space),
				name: HostedPager.name(space),
				favorites: [],
				savedItems: [],
				unpinnedTabs: (0..<tabsPerSpace).map { index in
					SidebarItem(id: .tab(uuid(space, index)), title: "Tab \(index)", isPinned: false)
				},
				selectedID: .tab(uuid(space, 0)),
				url: nil
			)
		}
		self.selectedSpaceID = HostedPager.spaceID(selected)
		self.navigation = .init()
	}

	internal func rename(
		tab index: Int,
		inSpace space: Int
	) {
		spaces[space].unpinnedTabs[index].title = "Renamed"
	}

	internal func open(inSpace space: Int) {
		let index = spaces[space].unpinnedTabs.count
		spaces[space].unpinnedTabs.append(.init(id: .tab(uuid(space, index)), title: "New", isPinned: false))
		spaces[space].selectedID = .tab(uuid(space, index))
	}
}

/// Builds the pager as the window does: the space summaries are read above it, each space's tabs
/// by its page and the navigation by the toolbar, with new closures on every pass.
private struct PagerRoot: View {
	internal let inputs: PagerInputs

	internal var body: some View {
		SidebarPager(
			spaces: inputs.spaces.map(\.summary),
			selectedSpaceID: inputs.selectedSpaceID,
			space: { [inputs] id in inputs.spaces.first { $0.id == id } },
			navigation: { [inputs] in inputs.navigation },
			spaceMenu: { _ in AnyView(EmptyView()) },
			onSelectSpace: { [inputs] in inputs.selectedSpaceID = $0 },
			onAction: { _, _ in },
			onCopyURL: {}
		) {
			Color.clear.frame(height: 40)
		} libraryPanel: {
			EmptyView()
		}
		.environment(\.sidebarWidths, .init(base: HostedPager.size.width, expanded: HostedPager.size.width))
	}
}

@MainActor
private final class HostedPager {
	internal static let size: CGSize = .init(width: 260, height: 700)

	private let inputs: PagerInputs
	private let window: NSWindow
	private let host: NSHostingView<PagerRoot>

	internal init(
		spaceCount: Int,
		selected: Int
	) {
		self.inputs = .init(spaceCount: spaceCount, selected: selected)
		self.host = NSHostingView(rootView: PagerRoot(inputs: inputs))
		host.frame = CGRect(origin: .zero, size: Self.size)

		// Never shown: the window only gives the hosting view somewhere to lay out.
		self.window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: Self.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host

		// The track's spring runs on the screen's display link, so the window sits on a screen,
		// transparent and passing every click through.
		if let screen = NSScreen.main {
			window.alphaValue = 0
			window.ignoresMouseEvents = true
			window.setFrameOrigin(screen.visibleFrame.origin)
			window.orderFrontRegardless()
		}
		settle()
	}

	internal static func spaceID(_ index: Int) -> UUID { uuid(index, 0xFFFF) }

	internal static func name(_ index: Int) -> String { "Space \(index)" }

	/// Changes the inputs and lets the window catch up, and when `settling`, lets the track's
	/// spring come to rest.
	internal func update(
		settling: Bool = false,
		_ change: (PagerInputs) -> Void
	) {
		change(inputs)
		settle()
		guard settling else { return }
		for _ in 0..<60 {
			RunLoop.main.run(until: .now.addingTimeInterval(0.03))
			host.layoutSubtreeIfNeeded()
		}
		settle()
	}

	/// Selects a space, lets the track's spring land and then lets the pager rest on it.
	internal func select(_ index: Int) async {
		update(settling: true) { $0.selectedSpaceID = Self.spaceID(index) }
		await rest()
	}

	/// Waits as long as the pager takes, once at rest, to build the spaces around the selected
	/// one and let go of spaces visited long ago. Its task waits its turn on the main actor, which a
	/// test only gives up while it's suspended.
	internal func rest() async {
		for _ in 0..<200 {
			try? await Task.sleep(for: .milliseconds(10))
			host.layoutSubtreeIfNeeded()
		}
		settle()
	}

	internal func recording(_ change: (PagerInputs) -> Void) -> [SidebarRenderTrace.Subject: Int] {
		SidebarRenderTrace.startRecording()
		defer { SidebarRenderTrace.stopRecording() }
		update(change)
		return SidebarRenderTrace.views ?? [:]
	}

	/// The spaces whose sidebars are mounted, found by renaming a tab in every space and seeing
	/// which sidebars render.
	internal func mountedSpaces() -> [Int] {
		let rendered = recording { inputs in
			for space in inputs.spaces.indices { inputs.rename(tab: 1, inSpace: space) }
		}
		inputs.spaces.indices.forEach { space in
			inputs.spaces[space].unpinnedTabs[1].title = "Tab 1"
		}
		settle()
		return inputs.spaces.indices.filter { rendered[.sidebar(Self.name($0))] != nil }
	}

	/// The list of the space on screen.
	internal func visibleList() -> NSScrollView? {
		func lists(in view: NSView) -> [NSScrollView] {
			let own: [NSScrollView] = (view as? NSScrollView).map { [$0] } ?? []
			return own + view.subviews.flatMap(lists)
		}
		return lists(in: host).first { list in
			let frame = list.convert(list.bounds, to: nil)
			return abs(frame.minX) < 1
			&& frame.width > 100
			&& list.documentView.map { $0.frame.height > Self.size.height } == true
		}
	}

	internal func close() {
		window.close()
	}

	/// The pages are in a hosting view of their own (`SidebarPagesLayer`), which takes what the
	/// pager hands it a turn of the run loop after the pager's own update, so the window is
	/// given a few more turns than one hosting view needed.
	private func settle() {
		for _ in 0..<8 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.02))
		}
	}
}
#endif
