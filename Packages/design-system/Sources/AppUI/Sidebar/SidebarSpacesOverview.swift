import BrowserCore
import SwiftUI

/// Every space side by side, which the Library's Spaces section shows across the whole window.
/// Each column is the space's real list, so its rows can be used, edited and dragged to another column.
/// A column's move handle drags the whole space to another place in the row.
public struct SidebarSpacesOverview: View {
	private let spaces: [SidebarSpace]
	private let canEdit: Bool
	private let spaceMenu: (UUID) -> AnyView
	private let menuAnchor: (UUID) -> AnyView
	private let appearance: ((UUID) -> AppearanceOverride)?
	private let globalAppearance: ChromeAppearance?
	private let globalColorScheme: ColorScheme?
	private let profileMenu: (UUID) -> AnyView
	private let onAction: (UUID, SidebarAction) -> Void

	/// A nil icon resets the space's to the dot (DEV-1251).
	private let onChangeIcon: (UUID, SpaceIcon?) -> Void
	private let onMoveSpace: (UUID, UUID?) -> Void

	@SwiftUI.State
	private var nestedScroll: SidebarNestedScroll

	@SwiftUI.State
	private var pickingIconFor: UUID?

	@SwiftUI.State
	private var reorder: SidebarSpaceReorder?

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	/// Where the pointer is across the visible row while a column is dragged.
	@SwiftUI.State
	private var pointerX: CGFloat

	/// Where the dragged column's preview started, across the visible row, and how far it has moved since.
	@SwiftUI.State
	private var preview: (origin: CGPoint, translation: CGSize)

	@SwiftUI.State
	private var scrollPosition: ScrollPosition

	@SwiftUI.State
	private var scrollGeometry: OverviewScrollGeometry

	private static let coordinateSpace: String = "sidebar-spaces-overview"
	private static let autoscrollEdge: CGFloat = 64
	private static let autoscrollStep: CGFloat = 14

	public init(
		spaces: [SidebarSpace],
		canEdit: Bool = true,
		spaceMenu: @escaping (UUID) -> AnyView,
		menuAnchor: @escaping (UUID) -> AnyView = { _ in AnyView(EmptyView()) },
		appearance: ((UUID) -> AppearanceOverride)? = nil,
		globalAppearance: ChromeAppearance? = nil,
		globalColorScheme: ColorScheme? = nil,
		profileMenu: @escaping (UUID) -> AnyView,
		onAction: @escaping (UUID, SidebarAction) -> Void,
		onChangeIcon: @escaping (UUID, SpaceIcon?) -> Void,
		onMoveSpace: @escaping (UUID, UUID?) -> Void
	) {
		self.spaces = spaces
		self.canEdit = canEdit
		self.spaceMenu = spaceMenu
		self.menuAnchor = menuAnchor
		self.appearance = appearance
		self.globalAppearance = globalAppearance
		self.globalColorScheme = globalColorScheme
		self.profileMenu = profileMenu
		self.onAction = onAction
		self.onChangeIcon = onChangeIcon
		self.onMoveSpace = onMoveSpace
		self._nestedScroll = .init(initialValue: .init())
		self._pickingIconFor = .init(initialValue: nil)
		self._reorder = .init(initialValue: nil)
		self._pointerX = .init(initialValue: 0)
		self._preview = .init(initialValue: (.zero, .zero))
		self._scrollPosition = .init(initialValue: .init())
		self._scrollGeometry = .init(initialValue: .init())
	}

	private var displayedSpaces: [SidebarSpace] {
		guard let reorder else { return spaces }
		let byID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
		return reorder.order(spaces.map(\.id)).compactMap { byID[$0] }
	}

	/// Which way the row scrolls by itself while a dragged column is held near an edge.
	private var autoscrollDirection: CGFloat {
		guard reorder != nil else { return 0 }
		if pointerX < Self.autoscrollEdge, scrollGeometry.offset > 0.5 { return -1 }

		let isNearTrailingEdge = pointerX > scrollGeometry.viewport - Self.autoscrollEdge
		let canScrollForward = scrollGeometry.offset < scrollGeometry.maximumOffset - 0.5
		if isNearTrailingEdge, canScrollForward { return 1 }
		return 0
	}

	public var body: some View {
		ScrollView(.horizontal) {
			HStack(spacing: BrowserMetrics.Library.columnSpacing) {
				ForEach(displayedSpaces) { space in
					column(space)
				}
			}
			.padding(.horizontal, BrowserMetrics.Library.columnSpacing)
			.padding(.vertical, BrowserMetrics.Library.columnVerticalPadding)
		}
		.scrollPosition($scrollPosition)
		.scrollIndicators(.automatic)
		.scrollEdgeEffectHidden(true)
		.coordinateSpace(.named(Self.coordinateSpace))
		.pointerStyle(reorder == nil ? nil : .grabActive)
		.onScrollGeometryChange(for: OverviewScrollGeometry.self) { geometry in
			.init(
				offset: geometry.contentOffset.x,
				viewport: geometry.containerSize.width,
				content: geometry.contentSize.width,
				height: geometry.containerSize.height
			)
		} action: { _, geometry in
			scrollGeometry = geometry
			nestedScroll = .init(
				canMoveBack: geometry.offset > 0.5,
				canMoveForward: geometry.offset < geometry.maximumOffset - 0.5
			)

			// The row moves under a resting pointer while it scrolls by itself.
			trackPointer()
		}
		.task(id: autoscrollDirection) {
			let direction = autoscrollDirection
			guard direction != 0 else { return }
			while !Task.isCancelled {
				let proposed = scrollGeometry.offset + direction * Self.autoscrollStep
				let target = min(max(proposed, 0), scrollGeometry.maximumOffset)
				scrollPosition.scrollTo(x: target)
				try? await Task.sleep(for: .milliseconds(16))
			}
		}

		// The dragged column follows the pointer as a translucent copy, like a native drag image.
		.overlay(alignment: .topLeading) { dragPreview }
		.onChange(of: spaces.map(\.id)) { _, ids in
			if let reorder, !ids.contains(reorder.id) { self.reorder = nil }
		}

		// Each column's own scrolling says nothing about the pager's edges behind the Library.
		.transformPreference(SidebarFooterOverlapKey.self) { $0 = 0 }
		.preference(key: SidebarNestedScrollKey.self, value: nestedScroll)
	}

	@ViewBuilder
	private var dragPreview: some View {
		if let reorder, let space = spaces.first(where: { $0.id == reorder.id }) {
			tile(space)
				.frame(
					height: max(scrollGeometry.height - BrowserMetrics.Library.columnVerticalPadding * 2, 0)
				)
				.opacity(0.72)
				.shadow(color: .black.opacity(0.25), radius: 16, y: 6)
				.offset(
					x: preview.origin.x + preview.translation.width,
					y: preview.origin.y + preview.translation.height
				)
				.allowsHitTesting(false)
				.accessibilityHidden(true)
				.transition(.identity)
		}
	}

	private func column(_ space: SidebarSpace) -> some View {
		tile(space)

			// the dragged space leaves an empty slot where it will land.
			.opacity(reorder?.id == space.id ? 0 : 1)
			.accessibilityElement(children: .contain)
			.accessibilityLabel(String.localized(.appUI.sidebar.space(space.name)))
	}

	private func tile(_ space: SidebarSpace) -> some View {
		VStack(spacing: 0) {
			BrowserSidebar(
				spaceName: space.name,
				spaceSymbol: space.symbol,
				isExpanded: true,
				savedItems: space.savedItems,
				unpinnedTabs: space.unpinnedTabs,
				selectedID: nil,
				spaceMenu: spaceMenu(space.id),
				showsPinnedHint: false,
				canRenameSpace: canEdit,
				style: .column(
					pickingIcon: Binding(
						get: { pickingIconFor == space.id && reorder == nil },
						set: { pickingIconFor = $0 ? space.id : nil }
					),
					onPickIcon: { onChangeIcon(space.id, $0) },
					profile: profileMenu(space.id)
				),
				onAction: { onAction(space.id, $0) }
			)
			footer(space)
		}
		.frame(width: BrowserMetrics.Library.columnWidth)
		.frame(maxHeight: .infinity, alignment: .top)
		.padding(.top, BrowserMetrics.Sidebar.horizontalPadding)
		.background { columnBackground }
		.modifier(SpaceColumnAppearance(
			override: appearance?(space.id),
			global: globalAppearance,
			globalScheme: globalColorScheme,
			spaceID: space.id
		))
	}

	/// The space's own chrome, tint and grain included, when the caller supplies its appearance.
	@ViewBuilder
	private var columnBackground: some View {
		let shape = RoundedRectangle(cornerRadius: BrowserMetrics.Library.tileCornerRadius, style: .continuous)
		if appearance == nil {
			shape.fill(BrowserTheme.hover)
		} else {
			BrowserChromeBackground(textured: true)
				.clipShape(shape)
				.overlay { shape.strokeBorder(BrowserTheme.divider.opacity(0.18), lineWidth: 0.5) }
		}
	}

	private func footer(_ space: SidebarSpace) -> some View {
		HStack {
			Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
				.font(.system(size: 13, weight: .medium))
				.frame(
					width: BrowserMetrics.Toolbar.buttonSize,
					height: BrowserMetrics.Toolbar.buttonSize
				)
				.contentShape(.rect)
				.pointerStyle(canEdit ? .grabIdle : nil)
				.gesture(moveGesture(space.id), isEnabled: canEdit && spaces.count > 1)
				.accessibilityHidden(true)
			Spacer(minLength: 0)
			Menu { spaceMenu(space.id) } label: {
				Image(systemName: "ellipsis")
					.frame(
						width: BrowserMetrics.Toolbar.buttonSize,
						height: BrowserMetrics.Toolbar.buttonSize
					)
					.contentShape(.rect)
			}
			.menuStyle(.button)
			.buttonStyle(.plain)
			.menuIndicator(.hidden)
			.fixedSize()

			// What the menu opens, such as the appearance panel, appears over this button.
			.background { menuAnchor(space.id) }
			.accessibilityLabel(String.localized(.appUI.sidebar.spaceActions))
		}
		.foregroundStyle(BrowserTheme.secondary)
		.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
		.frame(height: BrowserMetrics.Library.columnFooterHeight)
		.padding(.bottom, BrowserMetrics.Sidebar.horizontalPadding)
	}

	private func moveGesture(_ id: UUID) -> some Gesture {
		DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.coordinateSpace))
			.onChanged { value in
				if reorder == nil, let started = SidebarSpaceReorder(id: id, in: spaces.map(\.id)) {
					let stride = BrowserMetrics.Library.columnWidth + BrowserMetrics.Library.columnSpacing
					let columnX = BrowserMetrics.Library.columnSpacing + CGFloat(started.origin) * stride
					preview.origin = .init(
						x: columnX - scrollGeometry.offset,
						y: BrowserMetrics.Library.columnVerticalPadding
					)
					reorder = started
				}
				preview.translation = value.translation
				pointerX = value.location.x
				trackPointer()
			}
			.onEnded { _ in
				guard let reorder else { return }
				let destination = reorder.destination(in: spaces.map(\.id))
				var transaction = Transaction()
				transaction.disablesAnimations = true
				withTransaction(transaction) {
					if let destination { onMoveSpace(reorder.id, destination) }
					self.reorder = nil
				}
			}
	}

	/// Moves the empty slot to the column under the pointer, sliding the others aside.
	private func trackPointer() {
		guard var next = reorder else { return }
		let changed = next.track(
			x: pointerX + scrollGeometry.offset,
			count: spaces.count,
			columnWidth: BrowserMetrics.Library.columnWidth,
			spacing: BrowserMetrics.Library.columnSpacing,
			leadingInset: BrowserMetrics.Library.columnSpacing
		)
		guard changed else { return }
		let animation: Animation? = reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)
		withAnimation(animation) { reorder = next }
	}
}

private struct OverviewScrollGeometry: Equatable {
	fileprivate var offset: CGFloat
	fileprivate var viewport: CGFloat
	fileprivate var content: CGFloat
	fileprivate var height: CGFloat

	fileprivate init(
		offset: CGFloat = 0,
		viewport: CGFloat = 0,
		content: CGFloat = 0,
		height: CGFloat = 0
	) {
		self.offset = offset
		self.viewport = viewport
		self.content = content
		self.height = height
	}

	fileprivate var maximumOffset: CGFloat { max(content - viewport, 0) }
}

/// A space column being dragged by its handle to another place in the row's Library.
///
/// The dragged column leaves the row and an empty slot takes its place under the pointer,
/// so the other columns slide aside while the drag moves and the drop lands in that slot.
public struct SidebarSpaceReorder: Equatable, Sendable {
	public let id: UUID
	public let origin: Int
	public private(set) var slot: Int

	public init?(
		id: UUID,
		in order: [UUID]
	) {
		guard let origin = order.firstIndex(of: id) else { return nil }
		self.id = id
		self.origin = origin
		self.slot = origin
	}

	/// The slot under a point along the row, measured from the row's leading edge.
	public static func slot(
		at x: CGFloat,
		count: Int,
		columnWidth: CGFloat,
		spacing: CGFloat,
		leadingInset: CGFloat
	) -> Int {
		guard count > 0 else { return 0 }
		let stride = columnWidth + spacing
		guard stride > 0 else { return 0 }
		let raw = ((x - leadingInset + spacing / 2) / stride).rounded(.down)
		guard raw.isFinite else { return 0 }
		return min(max(Int(raw), 0), count - 1)
	}

	/// Moves the slot to the one under `x`. Returns whether it changed.
	@discardableResult
	public mutating func track(
		x: CGFloat,
		count: Int,
		columnWidth: CGFloat,
		spacing: CGFloat,
		leadingInset: CGFloat
	) -> Bool {
		let next = Self.slot(
			at: x,
			count: count,
			columnWidth: columnWidth,
			spacing: spacing,
			leadingInset: leadingInset
		)
		guard next != slot else { return false }
		slot = next
		return true
	}

	/// Moves the slot to `slot`, kept within the row. Returns whether it changed.
	@discardableResult
	public mutating func track(
		slot next: Int,
		count: Int
	) -> Bool {
		let next = min(max(next, 0), max(count - 1, 0))
		guard next != slot else { return false }
		slot = next
		return true
	}

	/// The row as it shows while dragging: the dragged space sits in the slot.
	public func order(_ order: [UUID]) -> [UUID] {
		guard let from = order.firstIndex(of: id) else { return order }
		var result = order
		result.remove(at: from)
		result.insert(id, at: min(slot, result.count))
		return result
	}

	/// The space to insert the dragged one before when it drops, `nil` for the end of the row.
	/// The outer `nil` means the drop leaves the row as it was.
	public func destination(in order: [UUID]) -> UUID?? {
		let result = self.order(order)
		guard result != order, let index = result.firstIndex(of: id) else { return nil }
		return .some(index + 1 < result.count ? result[index + 1] : nil)
	}
}

/// A column drawn as its space's sidebar: its theme, tint and grain, which follow edits live.
private struct SpaceColumnAppearance: ViewModifier {
	internal let override: AppearanceOverride?
	internal let global: ChromeAppearance?
	internal let globalScheme: ColorScheme?
	internal let spaceID: UUID

	@Environment(\.colorScheme)
	private var colorScheme

	@ViewBuilder
	internal func body(content: Content) -> some View {
		if let override, let global {
			// Keyed by the column's space, so one column's change never animates another's.
			// It starts from the app's appearance: the window around it wears the selected space's.
			content
				.appearanceOverride(override, transitionKey: spaceID)
				.browserChromeAppearance(global)

				// The app's light or dark, which a column inheriting its theme follows.
				.environment(\.colorScheme, globalScheme ?? colorScheme)
		} else if let override {
			content.appearanceOverride(override, transitionKey: spaceID)
		} else {
			content
		}
	}
}
