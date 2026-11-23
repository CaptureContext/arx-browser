import AppKit
import SwiftUI

/// One space's place in the pager: its page while fingers have the track show it, the pager
/// keeps it mounted or a drag started in it, and an empty page otherwise. So the sidebar's work doesn't grow with
/// the tabs of spaces nobody can see.
internal struct SidebarPagerSlot<Content: View>: View {
	private let driver: SidebarTrackDriver
	private let drags: SidebarPagerDrags
	private let mounts: SidebarPagerMounts
	private let index: Int
	private let spaceID: UUID
	private let content: Content

	internal init(
		driver: SidebarTrackDriver,
		drags: SidebarPagerDrags,
		mounts: SidebarPagerMounts,
		index: Int,
		spaceID: UUID,
		@ViewBuilder content: () -> Content
	) {
		self.driver = driver
		self.drags = drags
		self.mounts = mounts
		self.index = index
		self.spaceID = spaceID
		self.content = content()
	}

	internal var body: some View {
		// Read here rather than by the pager, so a swipe crossing a space mounts the next one
		// without re-rendering the pager.
		let visible: ClosedRange<Int> = driver.visibleSpaces

		// A space the track only passes on its way to a selection made elsewhere isn't built.
		let isUncovered: Bool = visible.contains(index) && !driver.isPassingSpaces

		// A drag's source has to stay alive, or the drag ends when hover paging leaves it behind.
		if isUncovered || mounts.keeps(spaceID) || drags.source == spaceID {
			// A space mounted only to be ready doesn't fetch its rows' missing icons until the
			// track shows it.
			content.siteIconsShown(visible.contains(index))
		} else {
			Color.clear
		}
	}
}

/// A mounted space's page. It reads the space's state itself, so a change in another space's
/// tabs never reaches it, and hands what it read to a sidebar that renders only when that changed.
internal struct SidebarPagerPage: View {
	private let id: UUID
	private let space: (UUID) -> SidebarSpace?
	private let splitIDs: Set<SidebarItem.ID>
	private let isNewTabPending: Bool
	private let canClearTabs: Bool
	private let pinnedHeight: CGFloat
	private let spaceMenu: (() -> AnyView)?
	private let showsPinnedHint: Bool
	private let canRenameSpace: Bool
	private let onDragAtEdge: (SidebarDragEdge) -> Void
	private let onAction: (SidebarAction) -> Void

	/// The sidebar sends through this, so new handlers reach it without making it look changed.
	@SwiftUI.State
	private var relay: SidebarPageRelay

	internal init(
		id: UUID,
		space: @escaping (UUID) -> SidebarSpace?,
		splitIDs: Set<SidebarItem.ID>,
		isNewTabPending: Bool,
		canClearTabs: Bool,
		pinnedHeight: CGFloat,
		spaceMenu: (() -> AnyView)?,
		showsPinnedHint: Bool,
		canRenameSpace: Bool,
		onDragAtEdge: @escaping (SidebarDragEdge) -> Void,
		onAction: @escaping (SidebarAction) -> Void
	) {
		self.id = id
		self.space = space
		self.splitIDs = splitIDs
		self.isNewTabPending = isNewTabPending
		self.canClearTabs = canClearTabs
		self.pinnedHeight = pinnedHeight
		self.spaceMenu = spaceMenu
		self.showsPinnedHint = showsPinnedHint
		self.canRenameSpace = canRenameSpace
		self.onDragAtEdge = onDragAtEdge
		self.onAction = onAction
		self._relay = .init(initialValue: .init())
	}

	internal var body: some View {
		let _ = relay.update(
			spaceMenu: spaceMenu,
			dragAtEdge: onDragAtEdge,
			action: onAction
		)
		if let space = space(id) {
			SidebarPageContent(
				space: space,
				splitIDs: splitIDs,
				isNewTabPending: isNewTabPending,
				canClearTabs: canClearTabs,
				pinnedHeight: pinnedHeight,
				hasSpaceMenu: spaceMenu != nil,
				showsPinnedHint: showsPinnedHint,
				canRenameSpace: canRenameSpace,
				relay: relay
			)
			.equatable()
		}
	}
}

/// What a space's sidebar shows, compared by value, so an unchanged space skips its sidebar's
/// body when the window refreshes.
private struct SidebarPageContent: View, Equatable {
	private let name: String
	private let symbol: String
	private let isExpanded: Bool
	private let savedItems: [SidebarItem]
	private let unpinnedTabs: [SidebarItem]
	private let selectedID: SidebarItem.ID?
	private let splitIDs: Set<SidebarItem.ID>
	private let isNewTabPending: Bool
	private let canClearTabs: Bool
	private let pinnedHeight: CGFloat
	private let hasSpaceMenu: Bool
	private let showsPinnedHint: Bool
	private let canRenameSpace: Bool
	private let relay: SidebarPageRelay

	fileprivate init(
		space: SidebarSpace,
		splitIDs: Set<SidebarItem.ID>,
		isNewTabPending: Bool,
		canClearTabs: Bool,
		pinnedHeight: CGFloat,
		hasSpaceMenu: Bool,
		showsPinnedHint: Bool,
		canRenameSpace: Bool,
		relay: SidebarPageRelay
	) {
		self.name = space.name
		self.symbol = space.symbol
		self.isExpanded = space.isExpanded
		self.savedItems = space.savedItems
		self.unpinnedTabs = space.unpinnedTabs
		self.selectedID = space.selectedID
		self.splitIDs = splitIDs
		self.isNewTabPending = isNewTabPending
		self.canClearTabs = canClearTabs
		self.pinnedHeight = pinnedHeight
		self.hasSpaceMenu = hasSpaceMenu
		self.showsPinnedHint = showsPinnedHint
		self.canRenameSpace = canRenameSpace
		self.relay = relay
	}

	fileprivate var body: some View {
		BrowserSidebar(
			spaceName: name,
			spaceSymbol: symbol,
			isExpanded: isExpanded,
			savedItems: savedItems,
			unpinnedTabs: unpinnedTabs,
			selectedID: selectedID,
			splitIDs: splitIDs,
			isNewTabPending: isNewTabPending,
			canClearTabs: canClearTabs,
			pinnedHeight: pinnedHeight,
			spaceMenu: hasSpaceMenu ? AnyView(SidebarRelayedMenu(relay: relay)) : nil,
			showsPinnedHint: showsPinnedHint,
			canRenameSpace: canRenameSpace,
			onDragAtEdge: { [relay] in relay.dragAtEdge($0) },
			onAction: { [relay] in relay.action($0) }
		)
	}

	fileprivate nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
		return lhs.name == rhs.name
		&& lhs.symbol == rhs.symbol
		&& lhs.isExpanded == rhs.isExpanded
		&& lhs.selectedID == rhs.selectedID
		&& lhs.splitIDs == rhs.splitIDs
		&& lhs.isNewTabPending == rhs.isNewTabPending
		&& lhs.canClearTabs == rhs.canClearTabs
		&& lhs.pinnedHeight == rhs.pinnedHeight
		&& lhs.hasSpaceMenu == rhs.hasSpaceMenu
		&& lhs.showsPinnedHint == rhs.showsPinnedHint
		&& lhs.canRenameSpace == rhs.canRenameSpace
		&& lhs.relay === rhs.relay
		&& lhs.savedItems == rhs.savedItems
		&& lhs.unpinnedTabs == rhs.unpinnedTabs
	}
}

/// A space's ⋯ menu, built from the page's latest handler when the menu shows it. It reads the
/// window's state in its own body, so it stays current while the sidebar around it skips renders.
private struct SidebarRelayedMenu: View {
	private let relay: SidebarPageRelay

	fileprivate init(relay: SidebarPageRelay) {
		self.relay = relay
	}

	fileprivate var body: some View {
		if let spaceMenu = relay.spaceMenu {
			spaceMenu()
		}
	}
}

/// Hands a space's sidebar the page's latest handlers.
@MainActor
private final class SidebarPageRelay {
	fileprivate private(set) var spaceMenu: (() -> AnyView)?
	fileprivate private(set) var dragAtEdge: (SidebarDragEdge) -> Void
	fileprivate private(set) var action: (SidebarAction) -> Void

	fileprivate init() {
		self.spaceMenu = nil
		self.dragAtEdge = { _ in }
		self.action = { _ in }
	}

	fileprivate func update(
		spaceMenu: (() -> AnyView)?,
		dragAtEdge: @escaping (SidebarDragEdge) -> Void,
		action: @escaping (SidebarAction) -> Void
	) {
		self.spaceMenu = spaceMenu
		self.dragAtEdge = dragAtEdge
		self.action = action
	}
}

/// The spaces the pager keeps mounted while the track doesn't show them: the three nearest the
/// selected space on either side, so a swipe finds its page built, and the next one made before
/// the sidebar has rested, and the one after (DEV-1310).
///
/// Building a space's page is the dearest thing the sidebar does. Selecting a space used to
/// build its far neighbour and tear the space left behind down in the same frame, the one a
/// swipe lands on, which stuttered there (DEV-1235). Now a selection changes nothing by itself:
/// the pager calls `step` once the sidebar has come to rest, and each step builds or lets go of
/// one page at most.
@MainActor
@Observable
internal final class SidebarPagerMounts {
	/// How many spaces stay mounted at rest: the selected one and three on either side.
	internal static let capacity: Int = 7

	private var kept: Set<UUID>

	/// The kept spaces, least recently wanted first.
	@ObservationIgnored
	private var order: [UUID]

	internal init(_ spaces: [UUID]) {
		self.kept = Set(spaces)
		self.order = spaces
	}

	internal func keeps(_ spaceID: UUID) -> Bool {
		kept.contains(spaceID)
	}

	/// Keeps a space from now on: the one just selected, whose page has to be there before the
	/// sidebar slides to it.
	internal func keep(_ spaceID: UUID) {
		order.removeAll { $0 == spaceID }
		order.append(spaceID)
		if !kept.contains(spaceID) { kept.insert(spaceID) }
	}

	/// Moves one step toward keeping `wanted`, most wanted first, among the spaces that exist:
	/// keeps one more of them, or with all of them kept, lets go of the space wanted longest ago
	/// that is over `capacity`. Returns whether there may be more to do.
	internal func step(
		toward wanted: [UUID],
		among spaces: Set<UUID>
	) -> Bool {
		let plan = SidebarPagerMountPlan(order: order, capacity: Self.capacity)
			.step(toward: wanted, among: spaces)
		order = plan.order
		let kept = Set(plan.order)

		// Only a change in which spaces are kept reaches the slots.
		if kept != self.kept { self.kept = kept }
		return plan.hasMore
	}
}

/// The order `SidebarPagerMounts` keeps spaces in, least recently wanted first, and how one step
/// changes it.
internal struct SidebarPagerMountPlan: Equatable {
	internal var order: [UUID]
	internal var capacity: Int

	/// Whether another step would change anything.
	internal var hasMore: Bool

	internal init(
		order: [UUID],
		capacity: Int,
		hasMore: Bool = false
	) {
		self.order = order
		self.capacity = capacity
		self.hasMore = hasMore
	}

	internal func step(
		toward wanted: [UUID],
		among spaces: Set<UUID>
	) -> Self {
		var order: [UUID] = order.filter(spaces.contains)
		let wanted: [UUID] = wanted.filter(spaces.contains)

		// What's wanted is the most recent, the most wanted last.
		order.removeAll(where: wanted.contains)
		let missing: [UUID] = wanted.filter { !self.order.contains($0) }
		let present: [UUID] = wanted.filter(self.order.contains)
		order += present.reversed()

		if let next = missing.first {
			// One more page, and the rest on later steps.
			order.insert(next, at: order.count - present.count)
			return .init(order: order, capacity: capacity, hasMore: true)
		}
		let limit: Int = max(capacity, wanted.count)
		if order.count > limit {
			order.removeFirst()
			return .init(order: order, capacity: capacity, hasMore: order.count > limit)
		}
		return .init(order: order, capacity: capacity, hasMore: false)
	}
}

/// The space a sidebar drag started in, kept mounted by the pager until the drag ends.
@MainActor
@Observable
internal final class SidebarPagerDrags {
	internal private(set) var source: UUID?

	internal init() {
		self.source = nil
	}

	fileprivate func began(in spaceID: UUID) {
		if source != spaceID { source = spaceID }
	}

	fileprivate func ended(in spaceID: UUID) {
		if source == spaceID { source = nil }
	}
}

/// Where a sidebar drag starts: one of the pager's spaces.
internal struct SidebarDragOrigin: Equatable {
	private let drags: SidebarPagerDrags
	private let spaceID: UUID

	internal init(
		drags: SidebarPagerDrags,
		spaceID: UUID
	) {
		self.drags = drags
		self.spaceID = spaceID
	}

	@MainActor
	internal func phaseChanged(_ phase: DragSession.Phase) {
		switch phase {
		case .initial, .active: drags.began(in: spaceID)
		default: drags.ended(in: spaceID)
		}
	}

	internal nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.drags === rhs.drags && lhs.spaceID == rhs.spaceID
	}
}

/// Where each of the pager's spaces was scrolled, so a space mounted again opens where it was
/// left. Written as the list scrolls without re-rendering anything.
@MainActor
internal final class SidebarScrollMemory {
	private var offsets: [UUID: CGFloat]

	internal init() {
		self.offsets = [:]
	}

	fileprivate func offset(of spaceID: UUID) -> CGFloat? {
		offsets[spaceID]
	}

	fileprivate func remember(
		_ offset: CGFloat,
		of spaceID: UUID
	) {
		offsets[spaceID] = offset
	}
}

/// One space's entry in the pager's scroll memory.
internal struct SidebarScrollSlot: Equatable {
	private let memory: SidebarScrollMemory
	private let spaceID: UUID

	internal init(
		memory: SidebarScrollMemory,
		spaceID: UUID
	) {
		self.memory = memory
		self.spaceID = spaceID
	}

	@MainActor
	internal var offset: CGFloat? { memory.offset(of: spaceID) }

	@MainActor
	internal func remember(_ offset: CGFloat) {
		memory.remember(offset, of: spaceID)
	}

	internal nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.memory === rhs.memory && lhs.spaceID == rhs.spaceID
	}
}

/// Remembers how far a space's list is scrolled, for the pager to open it there when the space
/// is mounted again. Applied to the list's scroll view.
internal struct SidebarScrollRecording: ViewModifier {
	private let slot: SidebarScrollSlot?

	internal init(slot: SidebarScrollSlot?) {
		self.slot = slot
	}

	@ViewBuilder
	internal func body(content: Content) -> some View {
		if let slot {
			content.onScrollGeometryChange(for: CGFloat.self) { geometry in
				geometry.contentOffset.y + geometry.contentInsets.top
			} action: { _, offset in
				slot.remember(offset)
			}
		} else {
			content
		}
	}
}

/// Scrolls the list it sits in back to where its space was left, once the list has laid out.
/// Placed inside the list's content, where it can reach the scroll view.
internal struct SidebarScrollRestorer: NSViewRepresentable {
	private let offset: CGFloat?

	internal init(slot: SidebarScrollSlot?) {
		self.offset = slot?.offset.flatMap { $0 > 0 ? $0 : nil }
	}

	internal func makeNSView(context: Context) -> SidebarScrollRestorerView {
		let view = SidebarScrollRestorerView()
		view.pending = offset
		return view
	}

	internal func updateNSView(
		_ view: SidebarScrollRestorerView,
		context: Context
	) {}
}

internal final class SidebarScrollRestorerView: NSView {
	fileprivate var pending: CGFloat?

	internal override func hitTest(_ point: NSPoint) -> NSView? { nil }

	internal override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard window != nil else { return }

		// After the list's first layout, which starts it at the top.
		RunLoop.main.perform { [weak self] in
			MainActor.assumeIsolated { self?.restore() }
		}
	}

	private func restore() {
		guard
			let pending,
			let scrollView = enclosingScrollView,
			let document = scrollView.documentView,
			document.frame.height > 0
		else { return }
		let clip = scrollView.contentView
		let insets: NSEdgeInsets = clip.contentInsets
		let top: CGFloat = -insets.top
		let bottom: CGFloat = max(document.frame.height + insets.bottom - clip.bounds.height, top)
		let y: CGFloat = min(top + pending, bottom)
		self.pending = nil
		clip.scroll(to: .init(x: clip.bounds.origin.x, y: y))
		scrollView.reflectScrolledClipView(clip)
	}
}

extension EnvironmentValues {
	/// The pager's space around a sidebar, which a drag starting in it keeps mounted.
	@Entry
	internal var sidebarDragOrigin: SidebarDragOrigin? = nil

	/// The pager's memory of where this space was scrolled.
	@Entry
	internal var sidebarScrollSlot: SidebarScrollSlot? = nil
}
