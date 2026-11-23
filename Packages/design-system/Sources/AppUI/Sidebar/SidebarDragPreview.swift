import AppKit
import Observation
import SwiftUI

/// What a sidebar drag shows under the pointer.
///
/// While a window hosts this, sidebar drags hide the system's drag image and the window draws
/// the preview instead, so it can change shape with what it's over: a row pill over
/// the tab list, a site-colored tile over Favorites.
@MainActor
@Observable
public final class SidebarDragPreviewModel {
	public struct Item: Equatable, Sendable {
		public let id: SidebarItem.ID
		public let title: String
		public let symbol: String
		public let siteIcon: SidebarItem.SiteIcon?
		public let tint: SidebarTint
		public let isFolder: Bool

		/// Every dragged item, `id` included, when it was dragged as part of a selection.
		public let ids: [SidebarItem.ID]
		public let fromFavorites: Bool

		public init(
			item: SidebarItem,
			fromFavorites: Bool
		) {
			self.id = item.id
			self.title = item.title
			self.symbol = item.symbol
			self.siteIcon = item.siteIcon
			self.tint = item.tint
			self.isFolder = item.isFolder
			let selection = item.moveSelection.contains(item.id) ? item.moveSelection : [item.id]
			self.ids = selection
			self.fromFavorites = fromFavorites
		}
	}

	public enum Shape: Equatable, Sendable {
		case row(width: CGFloat)
		case tile(CGSize)

		public var isTile: Bool {
			if case .tile = self { return true }
			return false
		}
	}

	internal struct Hover: Equatable {
		internal let owner: UUID
		internal let location: CGPoint?
		internal let shape: Shape
	}

	/// The coordinate space destinations report locations in: the window's content.
	public nonisolated static let space: String = "arx.sidebarDragPreview"

	/// Where the pointer sits on a row pill, from the pill's leading edge.
	internal nonisolated static let rowGrab: CGFloat = 28

	public private(set) var item: Item? = nil

	/// Counts drags, so one that picks up the same item again is still a new one.
	public private(set) var session: Int = 0
	internal private(set) var hover: Hover? = nil
	internal private(set) var pointer: CGPoint? = nil
	internal private(set) var settling: CGRect? = nil

	/// The tab list's row width, kept so the pill fits wherever the pointer is.
	internal var rowWidth: CGFloat = 240

	@ObservationIgnored
	internal weak var anchor: NSView?

	/// Every window's preview: a drag can cross into another window, which then draws it.
	private static let hosts: NSHashTable<SidebarDragPreviewModel> = .weakObjects()

	public nonisolated init() {}

	/// Lets drags that start in other windows show here too.
	internal func register() {
		Self.hosts.add(self)
	}

	private var everyHost: [SidebarDragPreviewModel] {
		let hosts = Self.hosts.allObjects
		return hosts.contains { $0 === self } ? hosts : hosts + [self]
	}

	/// A drag started, or its source says it's still going.
	public func begin(
		_ item: Item,
		isNew: Bool = true
	) {
		for host in everyHost where host.item != item || host.settling != nil {
			// The source can still report its drag after the drop: that drop keeps settling.
			if !isNew, host.settling != nil, host.item?.id == item.id { continue }

			// A title or address that changes mid-drag is the same drag.
			if host.item?.id != item.id || host.settling != nil { host.session += 1 }
			host.item = item
			host.settling = nil
		}
	}

	/// The source says its drag ended. A drop that's settling finishes on its own.
	public func end(_ id: SidebarItem.ID) {
		for host in everyHost where host.item?.id == id && host.settling == nil {
			host.reset()
		}
	}

	/// A destination is under the pointer and says what the preview should look like there.
	public func update(
		owner: UUID,
		location: CGPoint?,
		shape: Shape
	) {
		guard item != nil, settling == nil else { return }
		let hover = Hover(owner: owner, location: location, shape: shape)
		if self.hover != hover { self.hover = hover }
		if case let .row(width) = shape, width > 0 { rowWidth = width }
	}

	/// The pointer left a destination. Another one may already have taken over.
	public func leave(owner: UUID) {
		guard hover?.owner == owner else { return }
		hover = nil
	}

	/// The drop landed: the preview glides into `frame` and fades, or just fades without one.
	public func drop(
		settlingInto frame: CGRect?,
		reduceMotion: Bool
	) {
		guard item != nil else { return }
		for host in everyHost where host !== self { host.reset() }
		guard let frame, !reduceMotion else {
			reset()
			return
		}
		hover = nil
		settling = frame
		Task { @MainActor [weak self] in
			try? await Task.sleep(for: .milliseconds(260))
			guard let self, self.settling == frame else { return }
			self.reset()
		}
	}

	/// The drag `track()` follows: its session while there's an item, and nothing between drags.
	internal var trackedDrag: Int? { item == nil ? nil : session }

	internal var location: CGPoint? { hover?.location ?? pointer }

	internal var shape: Shape {
		if let settling { return .tile(settling.size) }
		return hover?.shape ?? .row(width: rowWidth)
	}

	/// The preview's frame in the window, or `nil` while the pointer is outside it.
	internal var frame: CGRect? {
		if let settling { return settling }
		guard let location else { return nil }
		switch shape {
		case let .row(width):
			return .init(
				x: location.x - Self.rowGrab,
				y: location.y - BrowserMetrics.Row.height / 2,
				width: width,
				height: BrowserMetrics.Row.height
			)

		case let .tile(size):
			return .init(
				x: location.x - size.width / 2,
				y: location.y - size.height / 2,
				width: size.width,
				height: size.height
			)
		}
	}

	/// Follows the pointer while a drag lasts, and ends one whose source never said so.
	internal func track() async {
		var released = 0
		while item != nil, !Task.isCancelled {
			pointer = anchorLocation()
			released = NSEvent.pressedMouseButtons & 1 == 0 ? released + 1 : 0

			// Gone a couple of frames after the button goes up, wherever it dropped: some drop
			// targets never report to the preview, and none read it to land the drop.
			if released > 2, settling == nil {
				reset()
				return
			}
			try? await Task.sleep(for: .milliseconds(16))
		}
	}

	private func anchorLocation() -> CGPoint? {
		guard let anchor, let window = anchor.window else { return nil }
		let screenPoint = NSEvent.mouseLocation

		// Only the frontmost of this app's windows under the pointer draws it. The drag image's
		// own window sits under the pointer too, so asking the window server would find that one.
		let front = NSApp.orderedWindows.first { $0.isVisible && $0.frame.contains(screenPoint) }
		guard front === window else { return nil }
		let point = anchor.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
		return anchor.bounds.contains(point) ? point : nil
	}

	private func reset() {
		item = nil
		hover = nil
		pointer = nil
		settling = nil
	}
}

extension EnvironmentValues {
	/// Set by a window that draws sidebar drag previews itself.
	@Entry
	public var sidebarDragPreview: SidebarDragPreviewModel? = nil
}

extension View {
	/// Draws sidebar drag previews over this view, which should fill the window.
	public func sidebarDragPreviewHost() -> some View {
		modifier(SidebarDragPreviewHost())
	}

	/// Reports this view's frame in the preview host's space.
	internal func sidebarDragFrame(_ action: @escaping (CGRect) -> Void) -> some View {
		onGeometryChange(for: CGRect.self) { geometry in
			geometry.frame(in: .named(SidebarDragPreviewModel.space))
		} action: { action($0) }
	}
}

private struct SidebarDragPreviewHost: ViewModifier {
	@SwiftUI.State
	private var model: SidebarDragPreviewModel

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	internal init() {
		self._model = .init(initialValue: .init())
	}

	internal func body(content: Content) -> some View {
		content
			.environment(\.sidebarDragPreview, model)
			.coordinateSpace(.named(SidebarDragPreviewModel.space))
			.background { SidebarDragAnchor(model: model) }
			.onAppear { model.register() }
			.overlay(alignment: .topLeading) {
				SidebarDragPreviewOverlay(model: model, reduceMotion: reduceMotion)
					.allowsHitTesting(false)
			}

			// Every drag, each time it begins: one begun again by a late report, in the same update
			// as its reset, keeps its item's id and would otherwise go untracked (DEV-999).
			.task(id: model.trackedDrag) { await model.track() }
	}
}

/// An AppKit view under the window's content, to read the pointer while AppKit runs the drag.
private struct SidebarDragAnchor: NSViewRepresentable {
	internal let model: SidebarDragPreviewModel

	internal func makeNSView(context: Context) -> NSView {
		let view = FlippedView()
		model.anchor = view
		return view
	}

	internal func updateNSView(
		_ view: NSView,
		context: Context
	) {
		model.anchor = view
	}

	private final class FlippedView: NSView {
		internal override var isFlipped: Bool { true }

		internal override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}
}

private struct SidebarDragPreviewOverlay: View {
	internal let model: SidebarDragPreviewModel
	internal let reduceMotion: Bool

	internal var body: some View {
		ZStack(alignment: .topLeading) {
			if let item = model.item, let frame = model.frame {
				SidebarDragPreviewCard(item: item, shape: model.shape)
					.frame(width: frame.width, height: frame.height)
					.offset(x: frame.minX, y: frame.minY)
					.opacity(model.settling == nil ? 1 : 0)
					.transition(.opacity)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: model.shape)
		.animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: model.settling)
		.accessibilityHidden(true)
	}
}

/// The dragged item as a row pill, or as a Favorites tile in its site's color.
internal struct SidebarDragPreviewCard: View {
	private let item: SidebarDragPreviewModel.Item
	private let shape: SidebarDragPreviewModel.Shape

	@Environment(\.colorScheme)
	private var colorScheme

	@Environment(\.siteColors)
	private var siteColors

	internal init(
		item: SidebarDragPreviewModel.Item,
		shape: SidebarDragPreviewModel.Shape
	) {
		self.item = item
		self.shape = shape
	}

	internal var body: some View {
		let isTile = shape.isTile

		// One shape for the tile and the row it morphs into: the radius follows the preview's
		// size every frame, so the corners never jump while it changes shape.
		let outline = ArxControlShape()
		let highlight = siteColors.highlight(for: item.siteIcon).style(scheme: colorScheme)
		HStack(spacing: BrowserMetrics.Row.iconSpacing) {
			icon
			if !isTile {
				Text(item.title)
					.font(.system(size: BrowserMetrics.Row.fontSize))
					.foregroundStyle(BrowserTheme.text)
					.lineLimit(1)
					.truncationMode(.tail)
					.transition(.opacity)
			}
		}
		.padding(.horizontal, isTile ? 0 : BrowserMetrics.Row.horizontalPadding)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isTile ? .center : .leading)
		.background {
			ZStack {
				if isTile {
					// The glow: the border again, wider and blurred, spreading out past the tile.
					outline
						.stroke(highlight, lineWidth: 6)
						.blur(radius: 6)
						.opacity(0.6)
						.transition(.opacity)
				}
				outline
					.fill(BrowserTheme.selection)
					.shadow(color: .black.opacity(isTile ? 0.08 : 0.16), radius: 6, y: 2)
			}
		}
		.overlay {
			if isTile {
				outline
					.strokeBorder(highlight, lineWidth: 2)
					.transition(.opacity)
			}
		}
		.overlay(alignment: .topTrailing) {
			if item.ids.count > 1 {
				Text(verbatim: "\(item.ids.count)")
					.font(.system(size: 10, weight: .semibold))
					.monospacedDigit()
					.foregroundStyle(BrowserTheme.onAccent)
					.padding(.horizontal, 5)
					.frame(minWidth: 16, minHeight: 16)
					.background(BrowserTheme.accent, in: .capsule)
					.offset(x: 4, y: -4)
			}
		}
	}

	@ViewBuilder
	private var icon: some View {
		if item.isFolder {
			SidebarFolderIcon(isExpanded: false)
				.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
		} else {
			FavoriteSiteIcon(
				key: item.siteIcon,
				fallback: item.symbol,
				tint: item.tint,
				size: BrowserMetrics.Row.iconSize,
				fallbackSize: BrowserMetrics.Row.iconSize - 2,
				fallbackWeight: .medium,
				showsPlaceholder: true
			)
			.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
		}
	}
}

/// Makes a sidebar item draggable. Under a preview host the system image is hidden and the host
/// draws the preview instead.
internal struct SidebarDragSource: ViewModifier {
	private let item: SidebarItem
	private let fromFavorites: Bool

	/// A Split View segment's whole row, which moves with it in the sidebar (DEV-1006).
	private let group: [SidebarItem.ID]?
	private let onPhase: (DragSession.Phase) -> Void

	@Environment(\.sidebarDragPreview)
	private var preview

	@Environment(\.sidebarDragOrigin)
	private var origin

	internal init(
		item: SidebarItem,
		fromFavorites: Bool,
		group: [SidebarItem.ID]? = nil,
		onPhase: @escaping (DragSession.Phase) -> Void = { _ in }
	) {
		self.item = item
		self.fromFavorites = fromFavorites
		self.group = group
		self.onPhase = onPhase
	}

	@ViewBuilder
	internal func body(content: Content) -> some View {
		let transfer = SidebarTransfer(id: item.id, selection: item.moveSelection, group: group)
		if let preview {
			content
				.draggable(transfer) {
					// AppKit still needs an image; this one shows nothing.
					Color.clear.frame(width: 1, height: 1)
				}
				.onDragSessionUpdated { session in
					switch session.phase {
					case .initial: preview.begin(.init(item: item, fromFavorites: fromFavorites))
					case .active: preview.begin(.init(item: item, fromFavorites: fromFavorites), isNew: false)
					default: preview.end(item.id)
					}
					origin?.phaseChanged(session.phase)
					onPhase(session.phase)
				}
		} else {
			content
				.draggable(transfer)
				.onDragSessionUpdated { session in
					origin?.phaseChanged(session.phase)
					onPhase(session.phase)
				}
		}
	}
}
