import BrowserCore
import SwiftUI

/// The side of the page a dragged tab joins as a new pane.
public enum SplitDropEdge: Equatable, Sendable, CaseIterable {
	case leading
	case trailing
	case top
	case bottom

	public var isHorizontal: Bool { self == .leading || self == .trailing }

	/// The edge whose triangle holds `point` (DEV-793): each edge takes the triangle between its two
	/// corners and the page's center, so every point over the page picks an edge and no thin band
	/// has to be hit. A point on a diagonal, a corner included, goes to the side; the center goes to the
	/// trailing side. Points off the page count from the nearest point on it.
	public init(
		point: CGPoint,
		size: CGSize
	) {
		guard size.width > 0, size.height > 0 else {
			self = .trailing
			return
		}

		let x = min(max(point.x / size.width, 0), 1)
		let y = min(max(point.y / size.height, 0), 1)

		// In page-relative units the diagonals are where the distance to the nearest side equals
		// the distance to the nearest of top and bottom.
		let toSide = min(x, 1 - x)
		let toTopOrBottom = min(y, 1 - y)
		if toTopOrBottom < toSide {
			self = y < 0.5 ? .top : .bottom
		} else {
			self = x < 0.5 ? .leading : .trailing
		}
	}
}

/// Why a drop that would add a pane does nothing.
public enum SplitDropRefusal: Equatable, Sendable {
	/// A split already holds four tabs.
	case full

	/// The window has no room for another pane of the minimum size.
	case tooNarrow

	/// The tab can't join, such as a pinned tab or one already shown.
	case unavailable

	public var message: String {
		switch self {
		case .full: String.localized(.appUI.split.refusedFull)
		case .tooNarrow: String.localized(.appUI.split.refusedNarrow)
		case .unavailable: String.localized(.appUI.split.refusedTab)
		}
	}
}

/// The tab a sidebar row is dragging, so the page can offer drop zones only while it lasts.
/// The window owns it as view state; the store never sees the hover.
private enum SidebarTabDragKey: EnvironmentKey {
	internal static var defaultValue: (@MainActor (UUID?) -> Void)? { nil }
}

extension EnvironmentValues {
	public var sidebarTabDragChanged: (@MainActor (UUID?) -> Void)? {
		get { self[SidebarTabDragKey.self] }
		set { self[SidebarTabDragKey.self] = newValue }
	}
}

/// How many panes fit in this window side by side and stacked, up to four, so the sidebar can
/// refuse a drop onto a split before it lands.
public struct SplitPaneLimits: Equatable, Sendable {
	public var horizontal: Int
	public var vertical: Int

	public init(
		horizontal: Int = SplitLayout.maximumPanes,
		vertical: Int = SplitLayout.maximumPanes
	) {
		self.horizontal = horizontal
		self.vertical = vertical
	}

	public func panes(vertical isVertical: Bool) -> Int {
		min(SplitLayout.maximumPanes, isVertical ? vertical : horizontal)
	}
}

private enum SplitPaneLimitsKey: EnvironmentKey {
	internal static var defaultValue: SplitPaneLimits { .init() }
}

extension EnvironmentValues {
	public var splitPaneLimits: SplitPaneLimits {
		get { self[SplitPaneLimitsKey.self] }
		set { self[SplitPaneLimitsKey.self] = newValue }
	}
}

/// Drop zones on the page, shown while a sidebar tab is dragged over it. Each edge takes the
/// triangle between its two corners and the page's center (DEV-793).
public struct SplitDropZones: View {
	private let draggedTabID: UUID?
	private let refusal: (UUID, SplitDropEdge) -> SplitDropRefusal?
	private let onDrop: (UUID, SplitDropEdge) -> Void

	@SwiftUI.State
	private var hoveredEdge: SplitDropEdge?

	@SwiftUI.State
	private var size: CGSize

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	public init(
		draggedTabID: UUID?,
		refusal: @escaping (UUID, SplitDropEdge) -> SplitDropRefusal?,
		onDrop: @escaping (UUID, SplitDropEdge) -> Void
	) {
		self.draggedTabID = draggedTabID
		self.refusal = refusal
		self.onDrop = onDrop
		self._hoveredEdge = .init(initialValue: nil)
		self._size = .init(initialValue: .zero)
	}

	public var body: some View {
		ZStack(alignment: .topLeading) {
			// Measures the page before a drag starts, so the first hover already has a size.
			Color.clear
			if let draggedTabID {
				Color.clear
					.contentShape(.rect)
					.overlay { zone(for: draggedTabID) }

					// One destination over the whole page: the pointer's triangle picks the edge,
					// so the highlight and the drop always agree.
					.dropDestination(for: SidebarTransfer.self) { transfers, session in
						let edge = SplitDropEdge(point: session.location, size: size)
						hoveredEdge = nil

						// One tab becomes one pane; a multi-tab selection is not a pane.
						let ids = SidebarTransfer.itemIDs(transfers)
						guard
							ids.count == 1,
							case let .tab(id) = ids[0],
							refusal(id, edge) == nil
						else { return }

						onDrop(id, edge)
					}
					.dropConfiguration { session in
						let edge = SplitDropEdge(point: session.location, size: size)
						return .init(operation: refusal(draggedTabID, edge) == nil ? .move : .forbidden)
					}
					.onDropSessionUpdated { session in
						switch session.phase {
						case .entering, .active:
							hoveredEdge = SplitDropEdge(point: session.location, size: size)

						default:
							hoveredEdge = nil
						}
					}
					.transition(.opacity)
			}
		}
		.onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
		.animation(reduceMotion ? nil : .snappy(duration: 0.16), value: hoveredEdge)
		.animation(reduceMotion ? nil : .snappy(duration: 0.16), value: draggedTabID)
	}

	@ViewBuilder
	private func zone(for tabID: UUID) -> some View {
		if let edge = hoveredEdge {
			let refused = refusal(tabID, edge)
			let tint: AnyShapeStyle = refused == nil ? AnyShapeStyle(BrowserTheme.accent) : AnyShapeStyle(BrowserTheme.secondary)
			RoundedRectangle(cornerRadius: BrowserMetrics.PageCard.cornerRadius, style: .continuous)
				.fill(tint.opacity(refused == nil ? 0.22 : 0.14))
				.overlay {
					RoundedRectangle(cornerRadius: BrowserMetrics.PageCard.cornerRadius, style: .continuous)
						.strokeBorder(tint.opacity(0.7), style: .init(lineWidth: 2, dash: refused == nil ? [] : [6, 4]))
				}
				.overlay {
					if let refused {
						Label(refused.message, systemImage: "nosign")
							.font(.system(size: 12, weight: .medium))
							.foregroundStyle(BrowserTheme.text)
							.padding(.horizontal, 10)
							.padding(.vertical, 6)
							.background(.regularMaterial, in: .capsule)
							.multilineTextAlignment(.center)
							.padding(8)
					}
				}
				.frame(
					maxWidth: edge.isHorizontal ? max(0, size.width / 2) : .infinity,
					maxHeight: edge.isHorizontal ? .infinity : max(0, size.height / 2)
				)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.alignment)
				.padding(6)
				.allowsHitTesting(false)
				.accessibilityElement()
				.accessibilityLabel(refused?.message ?? String.localized(.appUI.split.dropHere))
		}
	}
}

extension SplitDropEdge {
	fileprivate var alignment: Alignment {
		switch self {
		case .leading: .leading
		case .trailing: .trailing
		case .top: .top
		case .bottom: .bottom
		}
	}
}
