import SwiftUI

/// Keeps the profile's entire ordered collection reachable without crowding out space tabs.
///
/// Tiles share each row equally, up to four. A drag over the grid opens a cell for the
/// dragged item and the others make room on a spring; a favorite dragged out leaves the grid.
internal struct FavoritesGrid: View {
	/// Off for a sidebar that isn't on screen, so it can't take a drop meant for the page (DEV-793).
	@Environment(\.sidebarAcceptsDrops)
	private var acceptsDrops

	private let items: [SidebarItem]

	/// The profile whose Favorites these are; a new one is a switch, which doesn't animate.
	private let profileID: UUID?
	private let selectedID: SidebarItem.ID?
	private let splitIDs: Set<SidebarItem.ID>
	private let availableHeight: CGFloat
	private let onAction: (SidebarAction) -> Void

	@FocusState
	private var focusedID: SidebarItem.ID?

	@SwiftUI.State
	private var width: CGFloat

	/// Where the hovering drag would land among the favorites that stay.
	@SwiftUI.State
	private var insertion: Int?

	/// Whether `insertion` is the cell a dragged favorite held when its drag began, rather than
	/// where a drag over the grid would land.
	@SwiftUI.State
	private var holdsCell: Bool

	@SwiftUI.State
	private var gridFrame: CGRect

	@SwiftUI.State
	private var dropOwner: UUID

	@SwiftUI.State
	private var isZoneTargeted: Bool

	@SwiftUI.State
	private var zoneFrame: CGRect

	/// The empty drop zone's ×. It stays hidden until the window closes.
	@SwiftUI.State
	private var isZoneDismissed: Bool

	/// What the grid showed when the drag ended, kept until the favorites come back in their new
	/// order, so the tiles never flash back to the old one and move again.
	@SwiftUI.State
	private var landing: FavoritesArrangement?

	/// The drag that dropped here, whose favorites show in their cells while its preview settles.
	@SwiftUI.State
	private var droppedHere: Int?

	@Environment(\.sidebarDragPreview)
	private var preview

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@Environment(\.sidebarRowMotion)
	private var rowMotion

	internal init(
		items: [SidebarItem],
		profileID: UUID? = nil,
		selectedID: SidebarItem.ID?,
		splitIDs: Set<SidebarItem.ID> = [],
		availableHeight: CGFloat,
		onAction: @escaping (SidebarAction) -> Void
	) {
		self.items = items
		self.profileID = profileID
		self.selectedID = selectedID
		self.splitIDs = splitIDs
		self.availableHeight = availableHeight
		self.onAction = onAction
		self._width = .init(initialValue: 0)
		self._insertion = .init(initialValue: nil)
		self._holdsCell = .init(initialValue: false)
		self._gridFrame = .init(initialValue: .zero)
		self._dropOwner = .init(initialValue: UUID())
		self._isZoneTargeted = .init(initialValue: false)
		self._zoneFrame = .init(initialValue: .zero)
		self._isZoneDismissed = .init(initialValue: false)
		self._landing = .init(initialValue: nil)
		self._droppedHere = .init(initialValue: nil)
	}

	internal var body: some View {
		VStack(spacing: 0) {
			if showsDropZone {
				FavoritesDropZone(isTargeted: isZoneTargeted) {
					isZoneDismissed = true
					isZoneTargeted = false
				}
				.sidebarDragFrame { zoneFrame = $0 }
				.sidebarDropArea(isEnabled: acceptsDrops) { area in
					area
						.dropDestination(for: SidebarTransfer.self) { transfers, _ in
							zoneDropped(transfers)
						}
						.dropConfiguration { _ in .init(operation: dragRefusesZone ? .forbidden : .move) }
						.onDropSessionUpdated(zoneDropUpdated)
				}
				.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
			}

			// Kept while every favorite is dragged out, so the dragged tiles' drags can end.
			if !items.isEmpty {
				grid.transition(.favoriteTile(isEnabled: rowMotion))
			}
		}
		.frame(maxWidth: .infinity)

		// Favorites coming, going and moving grow and shrink on the sidebar rows' spring
		// (DEV-1187), except a drop's: its preview settles into its cell while the grid shows the
		// new order, which the drop applies without animation and `landing` holds until it lands.
		.sidebarRowMotion(.init(owner: profileID, ids: items.map(\.id)), isLanding: landing != nil)
		.onChange(of: preview?.session) { _, _ in dragStarted() }
		.onChange(of: preview?.item) { previous, item in dragChanged(from: previous, to: item) }
		.onChange(of: items.map(\.id)) { _, _ in

			// The new order arrived and matches what's showing.
			guard landing != nil else { return }
			Self.withoutAnimation { landing = nil }
		}
		.task(id: landing) {
			// A drag that moved nothing, such as one cancelled, puts the tiles back.
			guard landing != nil else { return }
			try? await Task.sleep(for: .milliseconds(600))
			guard !Task.isCancelled else { return }
			withAnimation(reflow) { landing = nil }
		}
		.animation(reduceMotion ? nil : .snappy(duration: 0.22), value: showsDropZone)
	}

	// MARK: - Grid

	/// The grid is exactly as tall as the rows it lays out, so nothing below it is covered. Only a
	/// collection too tall for its share of the sidebar scrolls, without an indicator; whether it
	/// does follows the favorites at rest, so a drag never swaps the view its tiles are in.
	@ViewBuilder
	private var grid: some View {
		if restingLayout.contentHeight > Self.maximumHeight(availableHeight) {
			ScrollViewReader { proxy in
				ScrollView(.vertical) { tiles }
					.scrollIndicators(.never)
					.scrollEdgeEffectHidden(true)
					.frame(height: Self.maximumHeight(availableHeight))
					.onChange(of: focusedID) { _, id in
						if let id { proxy.scrollTo(id) }
					}
					.modifier(FavoritesGridBehavior(grid: self))
			}
		} else {
			tiles.modifier(FavoritesGridBehavior(grid: self))
		}
	}

	/// Favorites take at most this share of the sidebar before they scroll, and at least one row.
	internal static func maximumHeight(_ availableHeight: CGFloat) -> CGFloat {
		max(FavoritesGridLayout.tileHeight, (availableHeight.isFinite ? availableHeight : 0) * 0.3)
	}

	private var tiles: some View {
		FavoritesGridStack(cellCount: arrangement.cellCount) {
			ForEach(items) { item in
				tile(item)
			}
		}
		.contentShape(.rect)
		.sidebarDragFrame { gridFrame = $0 }
		.sidebarDropArea(isEnabled: acceptsDrops) { area in
			area
				.dropDestination(for: SidebarTransfer.self) { transfers, session in
					gridDropped(transfers, session: session)
				}
				.dropConfiguration { _ in .init(operation: .move) }
				.onDropSessionUpdated(gridDropUpdated)
		}
	}

	fileprivate func measured(_ width: CGFloat) { self.width = width }

	fileprivate func itemsChanged(_ ids: [SidebarItem.ID]) {
		if let focusedID, !ids.contains(focusedID) { self.focusedID = nil }
	}

	fileprivate func focusMoved(_ direction: FavoritesGridLayout.Direction) -> KeyPress.Result {
		moveFocus(direction)
	}

	fileprivate var itemIDs: [SidebarItem.ID] { items.map(\.id) }

	private func tile(_ item: SidebarItem) -> some View {
		let cell = arrangement.cells[item.id]

		// A favorite dragged out keeps its view, so its drag can still end, but takes no cell.
		return FavoriteTile(
			item: item,
			selected: selectedID == item.id || splitIDs.contains(item.id),
			isHidden: cell == nil,
			focus: $focusedID,
			onAction: onAction
		)
		.allowsHitTesting(cell != nil)
		.id(item.id)
		.layoutValue(key: FavoritesCellKey.self, value: cell)
		.transition(.favoriteTile(isEnabled: rowMotion))
	}

	// MARK: - Arrangement

	/// Favorites this drag carries out of the grid, whichever selected item it started from.
	private var draggedIDs: Set<SidebarItem.ID> {
		guard let item = preview?.item, preview?.session != droppedHere else { return [] }
		return Set(item.ids).intersection(items.map(\.id))
	}

	private var staying: [SidebarItem] {
		let dragged = draggedIDs
		return dragged.isEmpty ? items : items.filter { !dragged.contains($0.id) }
	}

	private var arrangement: FavoritesArrangement {
		landing ?? .init(staying: staying.map(\.id), insertion: openCell)
	}

	/// The cell left open for a drag. A held cell closes once its favorite isn't carried any more,
	/// such as when the drag's move takes it out of Favorites before the drag ends; kept open, it
	/// was an empty cell after the favorites, a row's gap above the space's name (DEV-999).
	private var openCell: Int? {
		guard let insertion else { return nil }
		return holdsCell && draggedIDs.isEmpty ? nil : insertion
	}

	private var layout: FavoritesGridLayout {
		.init(itemCount: arrangement.cellCount, width: width, availableHeight: availableHeight)
	}

	/// Where each favorite sits with nothing dragged, for keyboard focus and hidden sources.
	private var restingLayout: FavoritesGridLayout {
		.init(itemCount: items.count, width: width, availableHeight: availableHeight)
	}

	/// The empty card shows whenever no favorite would be left in the grid, dragged or not, so
	/// starting and ending a drag doesn't move the rows under it (DEV-1230). While the last favorite
	/// is picked up and still holds its cell, the grid shows that cell instead.
	private var showsDropZone: Bool {
		guard !isZoneDismissed, insertion == nil else { return false }
		return staying.isEmpty
	}

	/// Folders can't be favorites, so the card stays as it is under one.
	private var dragRefusesZone: Bool {
		preview?.item?.isFolder == true
	}

	private func dragChanged(
		from previous: SidebarDragPreviewModel.Item?,
		to item: SidebarDragPreviewModel.Item?
	) {
		guard item == nil else {
			// Only a drag that just began holds its cell: one whose item changes as it goes, such as
			// a title counting what's unread, may already have left the grid (DEV-999).
			if previous?.id != item?.id { holdDraggedCell() }
			return
		}

		// The drag ended, here or in another window, so no destination here will clear its state.
		// It can end before its drop arrives: keep showing what it showed until the move lands.
		Self.withoutAnimation {
			if let previous, preview?.session != droppedHere, landing == nil {
				let carried = Set(previous.ids).intersection(items.map(\.id))

				// A held cell stays only while its favorite is still here to land in it.
				let open = holdsCell && carried.isEmpty ? nil : insertion
				if open != nil || !carried.isEmpty {
					landing = .init(staying: items.map(\.id).filter { !carried.contains($0) }, insertion: open)
				}
			}
			insertion = nil
			isZoneTargeted = false
		}
	}

	/// A new drag follows the pointer at once, whatever an earlier one left held.
	private func dragStarted() {
		Self.withoutAnimation {
			droppedHere = nil
			landing = nil
			insertion = nil
		}
		holdDraggedCell()
	}

	private static func withoutAnimation(_ body: () -> Void) {
		var transaction = Transaction()
		transaction.disablesAnimations = true
		withTransaction(transaction, body)
	}

	/// A favorite picked up keeps its cell open until the pointer moves off it, so nothing jumps.
	private func holdDraggedCell() {
		guard
			insertion == nil,
			let first = items.firstIndex(where: { draggedIDs.contains($0.id) })
		else { return }
		insertion = items[..<first].filter { !draggedIDs.contains($0.id) }.count
		holdsCell = true
	}

	// MARK: - Dropping

	private func gridDropUpdated(_ session: DropSession) {
		switch session.phase {
		case .entering, .active:
			guard preview?.item?.isFolder != true else { return }
			let index = FavoritesDrop.insertion(
				at: session.location,
				staying: staying.count,
				width: width,
				availableHeight: availableHeight
			)

			// Over the grid, the open cell follows the pointer rather than holding.
			holdsCell = false
			if insertion != index { withAnimation(reflow) { insertion = index } }
			let slot = layout.frame(at: index)
			preview?.update(
				owner: dropOwner,
				location: CGPoint(x: gridFrame.minX + session.location.x, y: gridFrame.minY + session.location.y),
				shape: .tile(slot.size)
			)

		case .exiting:
			// The pointer left: the others close the open cell on the spring.
			withAnimation(reflow) { insertion = nil }
			preview?.leave(owner: dropOwner)

		default:
			// The drop or the drag's end: the order lands without moving anything again.
			Self.withoutAnimation { insertion = nil }
			preview?.leave(owner: dropOwner)
		}
	}

	/// Only the pointer moves tiles on a spring. The store's new order, the drop and the drag's
	/// end apply at once, or the grid would play the move again after the drop.
	private var reflow: Animation? {
		reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78)
	}

	private func gridDropped(
		_ transfers: [SidebarTransfer],
		session: DropSession
	) {
		let ids = SidebarTransfer.itemIDs(transfers)

		// From the drop itself: the drag's source may already have said it ended, which clears
		// the preview, and the favorites it carried would then count as staying in place.
		let drop = FavoritesDrop.resolve(
			dropping: ids,
			at: session.location,
			among: items.map(\.id),
			width: width,
			availableHeight: availableHeight
		)
		let slot = FavoritesGridLayout(itemCount: drop.cellCount, width: width, availableHeight: availableHeight)
			.frame(at: drop.insertion)
			.offsetBy(dx: gridFrame.minX, dy: gridFrame.minY)

		// One update, without animation: the grid already shows the new order, so the tiles stay
		// where the drag left them and only the preview settles into its cell.
		Self.withoutAnimation {
			landing = .init(order: FavoritesDrop.order(dropping: ids, at: drop.insertion, among: items.map(\.id)))
			insertion = nil
			droppedHere = preview?.session
			onAction(.moveItems(ids, drop.target))
		}
		preview?.drop(settlingInto: slot, reduceMotion: reduceMotion)
	}

	private func zoneDropUpdated(_ session: DropSession) {
		switch session.phase {
		case .entering, .active:
			guard !dragRefusesZone else { return }
			isZoneTargeted = true
			preview?.update(
				owner: dropOwner,
				location: CGPoint(x: zoneFrame.minX + session.location.x, y: zoneFrame.minY + session.location.y),
				shape: .tile(.init(width: zoneFrame.width, height: FavoritesGridLayout.tileHeight))
			)

		default:
			isZoneTargeted = false
			preview?.leave(owner: dropOwner)
		}
	}

	private func zoneDropped(_ transfers: [SidebarTransfer]) {
		guard !dragRefusesZone else {
			isZoneTargeted = false
			return
		}
		let slot = CGRect(
			x: zoneFrame.minX,
			y: zoneFrame.minY,
			width: zoneFrame.width,
			height: FavoritesGridLayout.tileHeight
		)
		isZoneTargeted = false
		let ids = SidebarTransfer.itemIDs(transfers)
		Self.withoutAnimation {
			droppedHere = preview?.session
			onAction(.moveItems(ids, .favoritesRoot))
		}
		preview?.drop(settlingInto: slot, reduceMotion: reduceMotion)
	}

	private func moveFocus(_ direction: FavoritesGridLayout.Direction) -> KeyPress.Result {
		guard
			let index = items.firstIndex(where: { $0.id == focusedID }),
			let next = restingLayout.neighbor(of: index, direction: direction)
		else { return .ignored }
		focusedID = items[next].id
		return .handled
	}
}

/// Which cell each staying favorite takes, with one left open where a drag would land.
internal struct FavoritesArrangement: Equatable {
	internal let cells: [SidebarItem.ID: Int]
	internal let cellCount: Int

	/// Every favorite in `order` takes its own cell; one not there yet leaves its cell open.
	internal init(order: [SidebarItem.ID]) {
		self.cells = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
		self.cellCount = order.count
	}

	internal init(
		staying: [SidebarItem.ID],
		insertion: Int?
	) {
		var cells: [SidebarItem.ID: Int] = [:]
		let open = insertion.map { min(max($0, 0), staying.count) }
		for (index, id) in staying.enumerated() {
			cells[id] = open.map { index >= $0 ? index + 1 : index } ?? index
		}
		self.cells = cells
		self.cellCount = staying.count + (open == nil ? 0 : 1)
	}
}

/// Where a drag over Favorites lands.
internal enum FavoritesDrop {
	/// The cell under `point` once one is opened for the drag, among `staying` favorites.
	internal static func insertion(
		at point: CGPoint,
		staying: Int,
		width: CGFloat,
		availableHeight: CGFloat
	) -> Int {
		FavoritesGridLayout(itemCount: staying + 1, width: width, availableHeight: availableHeight)
			.cell(at: point)
	}

	internal static func target(
		inserting index: Int,
		among staying: [SidebarItem.ID]
	) -> SidebarDropTarget {
		index < staying.count ? .before(staying[max(0, index)]) : .favoritesRoot
	}

	/// The favorites' order once `ids` land in cell `index`, as the move will leave them.
	internal static func order(
		dropping ids: [SidebarItem.ID],
		at index: Int,
		among favorites: [SidebarItem.ID]
	) -> [SidebarItem.ID] {
		var order = favorites.filter { !ids.contains($0) }
		order.insert(contentsOf: ids, at: min(max(index, 0), order.count))
		return order
	}

	internal struct Resolution: Equatable {
		internal let insertion: Int
		internal let cellCount: Int
		internal let target: SidebarDropTarget
	}

	/// Where dropping `ids` at `point` lands among `favorites`, with the dropped ones taken out
	/// first, as the grid showed them while the drag hovered.
	internal static func resolve(
		dropping ids: [SidebarItem.ID],
		at point: CGPoint,
		among favorites: [SidebarItem.ID],
		width: CGFloat,
		availableHeight: CGFloat
	) -> Resolution {
		let staying = favorites.filter { !ids.contains($0) }
		let index = insertion(at: point, staying: staying.count, width: width, availableHeight: availableHeight)
		return .init(insertion: index, cellCount: staying.count + 1, target: target(inserting: index, among: staying))
	}
}

private struct FavoritesCellKey: LayoutValueKey {
	internal static let defaultValue: Int? = nil
}

/// Places favorites in the width it's offered, never wider: a width measured earlier, such as
/// before the sidebar narrowed, would otherwise size the grid and keep it too wide.
internal struct FavoritesGridStack: Layout {
	internal let cellCount: Int

	internal func sizeThatFits(
		proposal: ProposedViewSize,
		subviews: Subviews,
		cache: inout ()
	) -> CGSize {
		Self.size(proposedWidth: proposal.width, cellCount: cellCount)
	}

	internal func placeSubviews(
		in bounds: CGRect,
		proposal: ProposedViewSize,
		subviews: Subviews,
		cache: inout ()
	) {
		for subview in subviews {
			let frame = Self.frame(
				cell: subview[FavoritesCellKey.self],
				cellCount: cellCount,
				width: bounds.width
			)
			subview.place(
				at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
				proposal: .init(frame.size)
			)
		}
	}

	/// Exactly the offered width; nothing when none is offered, so the tiles never set it.
	internal static func size(
		proposedWidth: CGFloat?,
		cellCount: Int
	) -> CGSize {
		let width = proposedWidth.map { $0.isFinite ? max(0, $0) : 0 } ?? 0
		let layout = FavoritesGridLayout(itemCount: cellCount, width: width, availableHeight: .infinity)
		return .init(width: width, height: layout.contentHeight)
	}

	/// A tile's frame: its cell, or for a favorite dragged out, which draws nothing, the first
	/// cell. Its own resting place can be a row the grid no longer has, which would reach past
	/// the grid's height and over what's below it.
	internal static func frame(
		cell: Int?,
		cellCount: Int,
		width: CGFloat
	) -> CGRect {
		let layout = FavoritesGridLayout(itemCount: max(cellCount, 1), width: width, availableHeight: .infinity)
		return layout.frame(at: cell ?? 0)
	}
}

internal struct FavoritesGridLayout: Equatable {
	internal static let maximumColumns: Int = 4
	internal static let tileHeight: CGFloat = BrowserMetrics.Favorites.tileHeight
	internal static let spacing: CGFloat = BrowserMetrics.Favorites.spacing

	internal let itemCount: Int

	/// One favorite fills the row, two take half each, and so on up to four.
	internal let columns: Int
	internal let tileWidth: CGFloat

	/// Every row, which is how tall the grid is: favorites never scroll.
	internal let contentHeight: CGFloat

	internal init(
		itemCount: Int,
		width: CGFloat = 0,
		availableHeight: CGFloat
	) {
		let count = max(0, itemCount)
		let columns = min(max(count, 1), Self.maximumColumns)
		let rows = (count + columns - 1) / columns
		let contentHeight = max(0, CGFloat(rows) * (Self.tileHeight + Self.spacing) - Self.spacing)
		let width = width.isFinite ? max(0, width) : 0
		self.itemCount = count
		self.columns = columns
		self.tileWidth = max(0, (width - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
		self.contentHeight = contentHeight
	}

	internal var rows: Int { (itemCount + columns - 1) / columns }

	internal func frame(at index: Int) -> CGRect {
		let index = max(0, index)
		return .init(
			x: CGFloat(index % columns) * (tileWidth + Self.spacing),
			y: CGFloat(index / columns) * (Self.tileHeight + Self.spacing),
			width: tileWidth,
			height: Self.tileHeight
		)
	}

	/// The cell nearest `point`, splitting each gap between its neighbours.
	internal func cell(at point: CGPoint) -> Int {
		guard itemCount > 0 else { return 0 }
		let column = Int(((point.x + Self.spacing / 2) / (tileWidth + Self.spacing)).rounded(.down))
		let row = Int(((point.y + Self.spacing / 2) / (Self.tileHeight + Self.spacing)).rounded(.down))
		let clampedColumn = min(max(column, 0), columns - 1)
		let clampedRow = min(max(row, 0), max(rows - 1, 0))
		return min(clampedRow * columns + clampedColumn, itemCount - 1)
	}

	internal enum Direction {
		case left, right, up, down
	}

	/// Horizontal navigation follows reading order; vertical navigation retains the column when possible.
	internal func neighbor(
		of index: Int,
		direction: Direction
	) -> Int? {
		guard (0..<itemCount).contains(index) else { return nil }
		switch direction {
		case .left:
			return index > 0 ? index - 1 : nil

		case .right:
			return index < itemCount - 1 ? index + 1 : nil

		case .up:
			return index >= columns ? index - columns : nil

		case .down:
			guard index / columns < (itemCount - 1) / columns else { return nil }
			return min(index + columns, itemCount - 1)
		}
	}
}

/// Shown while there are no favorites, with nothing dragged or during a drag, in one look: a drag
/// over it only adds the accent highlight (DEV-1230).
internal struct FavoritesDropZone: View {
	internal let isTargeted: Bool
	internal let dismiss: () -> Void

	internal var body: some View {
		VStack(spacing: 4) {
			Image(systemName: "star.circle.fill")
				.font(.system(size: 18))
				.foregroundStyle(BrowserTheme.onAccent, BrowserTheme.accent)
				.padding(.bottom, 2)
			Text(localized: .appUI.sidebar.favoritesDropTitle)
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(BrowserTheme.text)
			Text(localized: .appUI.sidebar.favoritesDropSubtitle)
				.font(.system(size: 11))
				.foregroundStyle(BrowserTheme.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
		}
		.opacity(isTargeted ? 0.55 : 1)
		.padding(.horizontal, 20)
		.padding(.vertical, 14)
		.frame(maxWidth: .infinity)
		.background {
			let shape = RoundedRectangle(cornerRadius: BrowserMetrics.Favorites.cornerRadius, style: .continuous)
			ZStack {
				shape.fill(isTargeted ? AnyShapeStyle(BrowserTheme.accent.opacity(0.08)) : AnyShapeStyle(Color.clear))
				shape.strokeBorder(
					isTargeted ? AnyShapeStyle(BrowserTheme.accent) : AnyShapeStyle(BrowserTheme.secondary.opacity(0.45)),
					style: .init(
						lineWidth: isTargeted ? 1.5 : 1,
						dash: isTargeted ? [] : BrowserMetrics.Favorites.emptyDash
					)
				)
			}
		}
		.overlay(alignment: .topTrailing) {
			Button(action: dismiss) {
				Image(systemName: "xmark")
					.font(.system(size: 9, weight: .bold))
					.foregroundStyle(BrowserTheme.secondary)
					.frame(width: 18, height: 18)
					.contentShape(.rect)
			}
			.buttonStyle(.plain)
			.padding(6)
			.help(String.localized(.appUI.sidebar.favoritesDropDismiss))
			.accessibilityLabel(String.localized(.appUI.sidebar.favoritesDropDismiss))
		}
		.contentShape(.rect)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.sidebar.favorites))
	}
}

/// What the grid does in either form: tracks its width for the drop math, drops focus from a
/// favorite that's gone, and moves focus with the arrow keys.
private struct FavoritesGridBehavior: ViewModifier {
	internal let grid: FavoritesGrid

	internal func body(content: Content) -> some View {
		content

			// For the drop math only: the tiles take their width from the stack, which never
			// grows past what it's offered, so this can't feed a stale width back into them.
			.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { grid.measured($0) }
			.onChange(of: grid.itemIDs) { _, ids in grid.itemsChanged(ids) }
			.onKeyPress(.leftArrow) { grid.focusMoved(.left) }
			.onKeyPress(.rightArrow) { grid.focusMoved(.right) }
			.onKeyPress(.upArrow) { grid.focusMoved(.up) }
			.onKeyPress(.downArrow) { grid.focusMoved(.down) }
			.accessibilityLabel(String.localized(.appUI.sidebar.favorites))
	}
}
