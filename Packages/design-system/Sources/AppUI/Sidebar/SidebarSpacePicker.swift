import BrowserCore
import SwiftUI

/// Where the footer's space picker draws each space.
///
/// The gaps follow the width continuously, from roomy down to tight. While every icon fits with
/// tight gaps, every space is an icon. Once they don't, the row collapses into dots and shows at
/// most one icon: the hovered space's, or with nothing hovered the selected space's.
///
/// Each space owns a cell: its icon or dot with half a gap on either side. The cells sit edge to
/// edge, so every point of the row belongs to exactly one space and the pointer passes straight
/// from one to the next. Among dots every cell is a dot's cell, and the one icon draws centered
/// on its dot, over the gaps; so a hover only swaps a dot for an icon in place and the row never
/// moves. Only when even the dots don't fit does the row scroll. Positions run from the row's
/// leading edge.
public struct SidebarSpacePickerLayout: Equatable, Sendable {
	/// Whether the row has collapsed into dots.
	public let isDotted: Bool

	/// The one space shown as an icon among dots, if any.
	public let iconIndex: Int?

	/// Spaces shown as dots, by index.
	public let collapsed: Set<Int>

	/// Each space's cell, the icon or dot with its padding, edge to edge.
	public let frames: [ClosedRange<CGFloat>]

	/// The room between two neighbouring icons or dots, split between their cells.
	public let spacing: CGFloat
	public let contentWidth: CGFloat

	/// Whether even the dots are wider than the room, so the row scrolls.
	public let scrolls: Bool

	/// - Parameters:
	///   - hoveredIndex: The space under the pointer, which shows its icon among dots.
	public init(
		count: Int,
		selectedIndex: Int?,
		available: CGFloat,
		hoveredIndex: Int? = nil,
		iconWidth: CGFloat = BrowserMetrics.SpaceSwitcher.buttonSize,
		dotWidth: CGFloat = BrowserMetrics.SpaceSwitcher.dotWidth,
		minimumSpacing: CGFloat = BrowserMetrics.SpaceSwitcher.minimumSpacing,
		maximumSpacing: CGFloat = BrowserMetrics.SpaceSwitcher.maximumSpacing
	) {
		let count = max(count, 0)

		// Half a gap on each side of every item, so the row has as many gaps as items.
		let gaps = CGFloat(count)
		let indices = 0 ..< count
		let isDotted = CGFloat(count) * iconWidth + gaps * minimumSpacing > available + 0.5
		let iconIndex: Int? = isDotted
		? [hoveredIndex, selectedIndex].lazy.compactMap { $0 }.first { indices.contains($0) }
		: nil
		let collapsed: Set<Int> = isDotted ? Set(indices).subtracting(iconIndex.map { [$0] } ?? []) : []

		// Every item takes the same room: an icon's among icons, a dot's among dots.
		let itemWidth = isDotted ? dotWidth : iconWidth
		let itemsWidth = CGFloat(count) * itemWidth
		let scrolls = itemsWidth + gaps * minimumSpacing > available + 0.5
		let spacing = gaps > 0
		? min(max((available - itemsWidth) / gaps, minimumSpacing), maximumSpacing)
		: 0

		var frames: [ClosedRange<CGFloat>] = []
		var x: CGFloat = 0
		for _ in indices {
			let width = itemWidth + spacing
			frames.append(x ... x + width)
			x += width
		}

		self.isDotted = isDotted
		self.iconIndex = iconIndex
		self.collapsed = collapsed
		self.frames = frames
		self.spacing = spacing

		// The last cell's edge, so the cells end exactly where the row does.
		self.contentWidth = x
		self.scrolls = scrolls
	}

	public func isCollapsed(_ index: Int) -> Bool {
		collapsed.contains(index)
	}

	/// How far a dot is drawn from its cell's center so the icon among the dots has room:
	/// the dots next to it move out a little, the ones after them half as much. Only the drawing
	/// moves; the cells, and so the hit areas and the icon's own center, stay where they are.
	public func nudge(_ index: Int) -> CGFloat {
		guard isDotted, let iconIndex, let cell = frames.first else { return 0 }
		let pitch = cell.upperBound - cell.lowerBound
		let room = max(Self.iconReach - pitch, 0)
		let distance = index - iconIndex
		let sign: CGFloat = distance < 0 ? -1 : 1
		switch abs(distance) {
		case 1: return sign * room
		case 2: return sign * room / 2
		default: return 0
		}
	}

	/// From the icon's center to the center of a neighbouring dot that sits clear of it.
	public static let iconReach: CGFloat = 19

	/// The space whose cell holds `x`, clamped to the row. The cells leave no gaps, so this is
	/// both the hovered space and a drag's slot: a drag that stays over its own icon leaves the
	/// row as it was.
	public func slot(at x: CGFloat) -> Int {
		guard !frames.isEmpty else { return 0 }
		let index = frames.firstIndex { x < $0.upperBound } ?? frames.count - 1
		return min(max(index, 0), frames.count - 1)
	}

	/// The space to hover at `x`. The space already hovered keeps it while the pointer is within
	/// half a point of its cell, so a pointer resting on a boundary never flips between two.
	public func hoveredSlot(
		at x: CGFloat,
		current: Int?
	) -> Int {
		if let current, frames.indices.contains(current) {
			let frame = frames[current]
			if (frame.lowerBound - Self.hoverTolerance) ... (frame.upperBound + Self.hoverTolerance) ~= x {
				return current
			}
		}
		return slot(at: x)
	}

	private static let hoverTolerance: CGFloat = 0.5

	/// A space's cell width, its icon or dot with its padding.
	public func cellWidth(_ index: Int) -> CGFloat {
		frames.indices.contains(index) ? frames[index].upperBound - frames[index].lowerBound : 0
	}
}

/// A space as the footer's picker lists it.
public struct SidebarSpacePickerEntry: Identifiable, Equatable, Sendable {
	public let id: UUID
	public let name: String

	/// The space's icon, as `SpaceIconImage` reads it, for the drag preview.
	public let symbol: String

	/// The profile the space belongs to, shown in the hint.
	public let profileName: String?

	/// The keys that switch to the space, such as ["⌃", "4"], shown in the hint when it has any.
	public let shortcut: [String]

	public init(
		id: UUID,
		name: String,
		symbol: String = SpaceIcon.stack.rawValue,
		profileName: String? = nil,
		shortcut: [String] = []
	) {
		self.id = id
		self.name = name
		self.symbol = symbol
		self.profileName = profileName
		self.shortcut = shortcut
	}
}

/// How the picker asks an item to draw itself.
public struct SidebarSpacePickerItemState: Equatable, Sendable {
	/// The space shows as a dot.
	public var isCollapsed: Bool

	/// How far the dot is drawn from its cell's center, to make room for a neighbouring icon.
	public var nudge: CGFloat

	/// The item's cell: its icon or dot centered, with its share of the gaps on either side.
	/// The whole cell is the button, so the row has no dead space between items.
	public var width: CGFloat

	public init(
		isCollapsed: Bool,
		width: CGFloat,
		nudge: CGFloat = 0
	) {
		self.isCollapsed = isCollapsed
		self.width = width
		self.nudge = nudge
	}
}

/// The spaces between the Library button and + in the sidebar footer, centered in the room
/// they have.
///
/// Each item follows the width on its own: the gaps shrink as the sidebar narrows, and spaces
/// turn into dots one at a time. Resting on a dot shows its icon; resting a second longer
/// shows a hint with the space, its profile and its shortcut. Dragging lifts a preview that
/// follows the pointer while the others make room, in the same order as the Library.
public struct SidebarSpacePicker<Item: View>: View {
	private let spaces: [SidebarSpacePickerEntry]
	private let selectedID: UUID?
	private let canReorder: Bool
	private let onMove: (UUID, UUID?) -> Void
	private let item: (SidebarSpacePickerEntry, SidebarSpacePickerItemState) -> Item

	@SwiftUI.State
	private var available: CGFloat

	@SwiftUI.State
	private var reorder: SidebarSpaceReorder?

	@SwiftUI.State
	private var dragX: CGFloat?

	@SwiftUI.State
	private var hovered: UUID?

	@SwiftUI.State
	private var ownHintTimer: SidebarSpaceHintTimer

	@Environment(\.sidebarFooterHintTimer)
	private var footerHintTimer



	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	private static var coordinateSpace: String { "SidebarSpacePicker" }

	/// The delay between neighbouring items when the row collapses into dots or expands.
	private static var stagger: Double { 0.025 }


	/// - Parameters:
	///   - onMove: Moves a space before another, or to the end for `nil`.
	///   - item: A space's button, given whether it shows as a dot and whether the dot is revealed.
	public init(
		spaces: [SidebarSpacePickerEntry],
		selectedID: UUID?,
		canReorder: Bool,
		onMove: @escaping (UUID, UUID?) -> Void,
		@ViewBuilder item: @escaping (SidebarSpacePickerEntry, SidebarSpacePickerItemState) -> Item
	) {
		self.spaces = spaces
		self.selectedID = selectedID
		self.canReorder = canReorder
		self.onMove = onMove
		self.item = item
		self._available = .init(initialValue: 0)
		self._reorder = .init(initialValue: nil)
		self._dragX = .init(initialValue: nil)
		self._hovered = .init(initialValue: nil)
		self._ownHintTimer = .init(initialValue: .init())
	}

	/// The footer's shared timer when there is one, so hints pass to and from the Library button.
	private var hintTimer: SidebarSpaceHintTimer {
		footerHintTimer ?? ownHintTimer
	}

	private var shown: [SidebarSpacePickerEntry] {
		let ids = spaces.map(\.id)
		let order = reorder?.order(ids) ?? ids
		let byID = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		return order.compactMap { byID[$0] }
	}

	private func layout(_ shown: [SidebarSpacePickerEntry]) -> SidebarSpacePickerLayout {
		.init(
			count: shown.count,
			selectedIndex: shown.firstIndex { $0.id == selectedID },
			// Room is kept at both ends for an icon or a nudged dot drawn past its cell.
			available: max(available - 2 * BrowserMetrics.SpaceSwitcher.edgeInset, 0),
			hoveredIndex: reorder == nil ? shown.firstIndex { $0.id == hovered } : nil
		)
	}

	public var body: some View {
		let shown = self.shown
		let layout = self.layout(shown)

		ScrollViewReader { reader in
			ScrollView(.horizontal) {
				// No spacing: each item's cell carries its own padding, so the hit areas meet.
				HStack(spacing: 0) {
					ForEach(Array(shown.enumerated()), id: \.element.id) { index, space in
						row(
							space,
							state: .init(
								isCollapsed: layout.isCollapsed(index),
								width: layout.cellWidth(index),
								nudge: layout.nudge(index)
							),
							isDotted: layout.isDotted,
							distance: abs(index - (shown.firstIndex { $0.id == selectedID } ?? index))
						)
					}
				}
				.coordinateSpace(name: Self.coordinateSpace)

				// One hover for the whole row: the cell under the pointer, never nothing between two.
				.onContinuousHover(coordinateSpace: .named(Self.coordinateSpace)) { phase in
					guard reorder == nil else { return }
					switch phase {
					case let .active(location):
						let current = shown.firstIndex { $0.id == hovered }
						let id = shown[layout.hoveredSlot(at: location.x, current: current)].id
						if hovered != id { hovered = id }

						// Every movement counts: before the first hint, it starts the rest over.
						hintTimer.pointerMoved(over: id)

					case .ended:
						let left = hovered
						hovered = nil
						if let left {
							hintTimer.pointerLeft(left)
						} else {
							hintTimer.pointerMoved(over: nil)
						}
					}
				}
				.overlay(alignment: .leading) { dragPreview(shown: shown) }

				// Centered while the row fits; leading once it scrolls.
				.padding(.horizontal, BrowserMetrics.SpaceSwitcher.edgeInset)
				.frame(minWidth: available, alignment: .center)
			}
			.scrollIndicators(.never)
			.scrollDisabled(!layout.scrolls)
			.scrollClipDisabled(reorder != nil)
			.onAppear { reveal(selectedID, scrolls: layout.scrolls, reader: reader) }
			.onChange(of: selectedID) { _, id in reveal(id, scrolls: layout.scrolls, reader: reader) }
			.onChange(of: layout.scrolls) { _, scrolls in reveal(selectedID, scrolls: scrolls, reader: reader) }
		}
		.frame(maxWidth: .infinity)
		.frame(height: BrowserMetrics.SpaceSwitcher.height)
		.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
		.sidebarTrackExclusion()

		// The hint is drawn by `sidebarSpaceHintHost()` above the window, so the sidebar can't clip it.
		.transformAnchorPreference(key: SidebarSpaceHintKey.self, value: .bounds) { request, row in
			request?.row = row
		}
		.animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: reorder)
	}

	private func row(
		_ space: SidebarSpacePickerEntry,
		state: SidebarSpacePickerItemState,
		isDotted: Bool,
		distance: Int
	) -> some View {
		let isDragged = reorder?.id == space.id

		// The inner animation wins when both values change, so the stagger comes first.
		return item(space, state)

			// Collapsing or expanding the row runs outward from the selected space, one item
			// after another, so a resize changes the items one at a time.
			.animation(
				reduceMotion ? nil : .snappy(duration: 0.22).delay(Double(distance) * Self.stagger),
				value: isDotted
			)

			// A hover alone trades the one icon between two spaces straight away.
			.animation(reduceMotion ? nil : .snappy(duration: 0.18), value: state.isCollapsed)
			.anchorPreference(key: SidebarSpaceHintKey.self, value: .bounds) { item in
				hintTimer.hinted == space.id && reorder == nil ? .init(space: space, item: item) : nil
			}

		// The lifted space leaves an empty slot where it would land.
		.opacity(isDragged ? 0 : 1)

		// High priority: with a plain gesture, the space's Button tracked the press itself and
		// held the drag's updates until release, so nothing lifted or made room while dragging.
		// A press that doesn't move still reaches the Button.
		.highPriorityGesture(moveGesture(space.id), isEnabled: canReorder && spaces.count > 1)
		.id(space.id)
	}

	/// The lifted space, following the pointer above the row.
	@ViewBuilder
	private func dragPreview(shown: [SidebarSpacePickerEntry]) -> some View {
		if let reorder, let dragX, let space = shown.first(where: { $0.id == reorder.id }) {
			SpaceIconImage(rawValue: space.symbol)
				.font(.system(size: BrowserMetrics.SpaceSwitcher.iconSymbolSize, weight: .medium))
				.foregroundStyle(BrowserTheme.text)
				.frame(width: BrowserMetrics.SpaceSwitcher.buttonSize, height: BrowserMetrics.SpaceSwitcher.buttonSize)
				.background(
					BrowserTheme.selection,
					in: ArxControlShape()
				)
				.shadow(color: .black.opacity(0.2), radius: 6, y: 3)
				.scaleEffect(1.12)
				.offset(x: dragX - BrowserMetrics.SpaceSwitcher.buttonSize / 2, y: -4)
				.allowsHitTesting(false)
				.accessibilityHidden(true)
				.transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
		}
	}

	private func reveal(
		_ id: UUID?,
		scrolls: Bool,
		reader: ScrollViewProxy
	) {
		guard let id, scrolls else { return }
		reader.scrollTo(id, anchor: .center)
	}

	private func moveGesture(_ id: UUID) -> some Gesture {
		DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.coordinateSpace))
			.onChanged { value in
				if reorder == nil {
					reorder = SidebarSpaceReorder(id: id, in: spaces.map(\.id))
					hovered = nil
					hintTimer.hide()
				}
				dragX = value.location.x
				guard var next = reorder else { return }
				let slot = layout(shown).slot(at: value.location.x)
				guard next.track(slot: slot, count: spaces.count) else { return }
				reorder = next
			}
			.onEnded { _ in
				guard let reorder else { return }
				let destination = reorder.destination(in: spaces.map(\.id))
				var transaction = Transaction()
				transaction.disablesAnimations = true
				withTransaction(transaction) {
					if let destination { onMove(reorder.id, destination) }
					self.reorder = nil
					dragX = nil
				}
			}
	}
}
