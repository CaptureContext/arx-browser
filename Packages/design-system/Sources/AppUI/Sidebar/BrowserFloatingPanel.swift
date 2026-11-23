import AppKit
import SwiftUI

extension View {
	/// Floats content beside this view, with no pointer, in a panel of its own so it can pass over a page or out of a sheet.
	/// It opens on the preferred edge where it fits, otherwise on the other one.
	public func floatingPanel<Content: View>(
		isPresented: Binding<Bool>,
		edge: VerticalEdge = .top,
		@ViewBuilder content: @escaping () -> Content
	) -> some View {
		background {
			BrowserFloatingPanelAnchor(
				isPresented: isPresented,
				placement: .vertical(edge),
				isMovable: false,
				content: { AnyView(content()) }
			)
		}
	}

	/// A floating panel the person can drag by the handle along its top edge, to see what it covers
	/// while choosing (DEV-1286). It opens at `placement` beside this view, stays open while it's
	/// dragged and keeps its place until it closes, and the next opening starts beside this view again.
	/// Esc or a click outside it closes it, and focus goes back to the window.
	///
	/// Unlike `floatingPanel`, its content follows this view's updates and inherits its color scheme
	/// and chrome appearance, as a popover's would.
	public func movableFloatingPanel<Content: View>(
		isPresented: Binding<Bool>,
		placement: FloatingPanelPlacement = .trailing,
		@ViewBuilder content: @escaping () -> Content
	) -> some View {
		background {
			BrowserFloatingPanelAnchor(
				isPresented: isPresented,
				placement: placement,
				isMovable: true,
				content: { AnyView(content()) }
			)
		}
	}
}

/// Where a floating panel first opens beside its anchor.
public enum FloatingPanelPlacement: Equatable, Sendable {
	/// Above or below the anchor, centered on it: the preferred edge where it fits, otherwise the other one.
	case vertical(VerticalEdge)

	/// Beside the anchor's trailing edge, centered on it, where a popover with a trailing arrow edge
	/// opens; on the leading side when the trailing one has no room.
	case trailing
}

/// A floating panel's place on screen (DEV-1286): beside its anchor and inside the screen's visible
/// frame when it opens, then wherever it's dragged, keeping its top edge as its content grows or
/// shrinks, until it closes.
internal struct FloatingPanelPosition: Equatable {
	/// The panel's frame while it's open, nil while it's closed.
	internal private(set) var frame: CGRect?

	internal init(frame: CGRect? = nil) {
		self.frame = frame
	}

	/// Opens beside the anchor, whatever place an earlier opening was dragged to.
	internal mutating func open(
		size: CGSize,
		anchor: CGRect,
		visible: CGRect,
		placement: FloatingPanelPlacement,
		layoutDirection: LayoutDirection = .leftToRight,
		gap: CGFloat = BrowserMetrics.FloatingPanel.anchorGap
	) -> CGPoint {
		let origin = Self.origin(
			of: size,
			beside: anchor,
			in: visible,
			placement: placement,
			layoutDirection: layoutDirection,
			gap: gap
		)
		frame = .init(origin: origin, size: size)
		return origin
	}

	/// The panel was dragged, or moved with its window.
	internal mutating func moved(to newFrame: CGRect) {
		guard frame != nil else { return }
		frame = newFrame
	}

	/// Where the panel goes once its content is `size`: its top-left corner kept, unless that would
	/// put its bottom below the visible frame, when it rises just enough to stay inside; nil while closed.
	internal mutating func resized(
		to size: CGSize,
		in visible: CGRect?,
		gap: CGFloat = BrowserMetrics.FloatingPanel.anchorGap
	) -> CGPoint? {
		guard let frame else { return nil }
		var y = frame.maxY - size.height
		if let visible {
			y = min(max(y, visible.minY + gap), max(frame.minY, visible.maxY - size.height))
		}
		let origin = CGPoint(x: frame.minX, y: y)
		self.frame = .init(origin: origin, size: size)
		return origin
	}

	/// Forgets the dragged place, so the next opening starts beside the anchor.
	internal mutating func close() {
		frame = nil
	}

	/// Beside the anchor at `placement`, on the other side when that one has no room, and always
	/// inside the visible frame by `gap`.
	internal static func origin(
		of size: CGSize,
		beside anchor: CGRect,
		in visible: CGRect,
		placement: FloatingPanelPlacement,
		layoutDirection: LayoutDirection = .leftToRight,
		gap: CGFloat = BrowserMetrics.FloatingPanel.anchorGap
	) -> CGPoint {
		switch placement {
		case let .vertical(edge):
			let above = anchor.maxY + gap
			let below = anchor.minY - gap - size.height
			let fitsAbove = above + size.height <= visible.maxY
			let fitsBelow = below >= visible.minY + gap
			let y = switch edge {
			case .top: fitsAbove ? above : below
			case .bottom: fitsBelow ? below : above
			}
			return .init(
				x: clamp(anchor.midX - size.width / 2, length: size.width, lower: visible.minX, upper: visible.maxX, gap: gap),
				y: max(y, visible.minY + gap)
			)

		case .trailing:
			let right = anchor.maxX + gap
			let left = anchor.minX - gap - size.width
			let fitsRight = right + size.width <= visible.maxX - gap
			let fitsLeft = left >= visible.minX + gap
			let x = switch layoutDirection {
			case .rightToLeft: fitsLeft || !fitsRight ? left : right
			default: fitsRight || !fitsLeft ? right : left
			}
			return .init(
				x: clamp(x, length: size.width, lower: visible.minX, upper: visible.maxX, gap: gap),
				y: clamp(anchor.midY - size.height / 2, length: size.height, lower: visible.minY, upper: visible.maxY, gap: gap)
			)
		}
	}

	/// `value` kept between `lower` and `upper` by `gap`, the low side winning when `length` doesn't fit.
	private static func clamp(
		_ value: CGFloat,
		length: CGFloat,
		lower: CGFloat,
		upper: CGFloat,
		gap: CGFloat
	) -> CGFloat {
		max(min(value, upper - length - gap), lower + gap)
	}
}

/// The floating panel's surface: the content on the popovers' material and hairline, under a
/// handle to drag it by when it's movable.
internal struct FloatingPanelChrome: View {
	private let isMovable: Bool
	private let content: AnyView

	internal init(
		isMovable: Bool,
		content: AnyView
	) {
		self.isMovable = isMovable
		self.content = content
	}

	internal var body: some View {
		let metrics = BrowserMetrics.FloatingPanel.self
		VStack(spacing: 0) {
			if isMovable {
				FloatingPanelMoveHandle()
			}
			content
		}
		.background(
			.regularMaterial,
			in: .rect(cornerRadius: metrics.cornerRadius, style: .continuous)
		)
		.overlay {
			RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
				.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth)
		}
	}
}

/// The strip along a movable panel's top edge, with a small capsule, that drags the panel. Only the
/// strip drags it, so the content's own drags (a color field, a slider, a dial) stay theirs.
internal struct FloatingPanelMoveHandle: View {
	internal init() {}

	internal var body: some View {
		let metrics = BrowserMetrics.FloatingPanel.self
		FloatingPanelDragArea()
			.frame(maxWidth: .infinity)
			.frame(height: metrics.handleHeight)
			.overlay {
				Capsule()
					.fill(.tertiary)
					.frame(width: metrics.handleWidth, height: metrics.handleThickness)
					.allowsHitTesting(false)
			}
			.accessibilityElement()
			.accessibilityLabel(Text(localized: .appUI.floatingPanel.move))
	}
}

private struct FloatingPanelDragArea: NSViewRepresentable {
	fileprivate func makeNSView(context: Context) -> FloatingPanelDragView {
		FloatingPanelDragView()
	}

	fileprivate func updateNSView(
		_ view: FloatingPanelDragView,
		context: Context
	) {}
}

/// Hands a press to the window server's own window drag, which follows the pointer without lag.
private final class FloatingPanelDragView: NSView {
	fileprivate override var mouseDownCanMoveWindow: Bool { true }

	fileprivate override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	fileprivate override func mouseDown(with event: NSEvent) {
		guard let window else { return super.mouseDown(with: event) }
		window.performDrag(with: event)
	}

	fileprivate override func resetCursorRects() {
		addCursorRect(bounds, cursor: .openHand)
	}
}

private struct BrowserFloatingPanelAnchor: NSViewRepresentable {
	private let isPresented: Binding<Bool>
	private let placement: FloatingPanelPlacement
	private let isMovable: Bool
	private let content: () -> AnyView

	fileprivate init(
		isPresented: Binding<Bool>,
		placement: FloatingPanelPlacement,
		isMovable: Bool,
		content: @escaping () -> AnyView
	) {
		self.isPresented = isPresented
		self.placement = placement
		self.isMovable = isMovable
		self.content = content
	}

	fileprivate func makeCoordinator() -> BrowserFloatingPanelPresenter {
		.init()
	}

	fileprivate func makeNSView(context: Context) -> NSView {
		NSView()
	}

	fileprivate func updateNSView(
		_ view: NSView,
		context: Context
	) {
		let presenter = context.coordinator
		presenter.dismissed = { isPresented.wrappedValue = false }
		if isPresented.wrappedValue {
			presenter.present(
				from: view,
				placement: placement,
				isMovable: isMovable,
				environment: context.environment,
				content: content
			)
		} else {
			presenter.dismiss()
		}
	}

	fileprivate static func dismantleNSView(
		_ view: NSView,
		coordinator: BrowserFloatingPanelPresenter
	) {
		coordinator.dismiss()
	}
}

@MainActor
private final class BrowserFloatingPanelPresenter {
	fileprivate var dismissed: (() -> Void)?
	private var panel: BrowserFloatingPanel?
	private var host: NSHostingView<AnyView>?
	private var position: FloatingPanelPosition = .init()
	private var observer: (any NSObjectProtocol)?

	/// A movable panel's moves and resizes, so it keeps its place.
	private var frameObservers: [any NSObjectProtocol] = []

	/// Follow the color panel a picker in this panel opened while it has key status (DEV-1117).
	private var colorPanelObservers: [any NSObjectProtocol] = []

	fileprivate func present(
		from view: NSView,
		placement: FloatingPanelPlacement,
		isMovable: Bool,
		environment: EnvironmentValues,
		content: () -> AnyView
	) {
		if let panel, let host {
			// A movable panel shows the anchor's current state, as a popover's content would.
			guard isMovable else { return }
			host.rootView = Self.root(content(), isMovable: true, environment: environment)
			panel.appearance = Self.appearance(environment.colorScheme)
			return
		}
		guard let parent = view.window else { return }

		let host = NSHostingView(rootView: Self.root(content(), isMovable: isMovable, environment: environment))
		host.safeAreaRegions = []
		let size = host.fittingSize

		let panel = BrowserFloatingPanel(
			contentRect: .init(origin: .zero, size: size),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.appearance = isMovable ? Self.appearance(environment.colorScheme) : parent.effectiveAppearance
		panel.isReleasedWhenClosed = false
		panel.onCancel = { [weak self] in self?.dismissed?() }
		panel.contentView = host
		panel.setFrameOrigin(position.open(
			size: size,
			anchor: parent.convertToScreen(view.convert(view.bounds, to: nil)),
			visible: parent.screen?.visibleFrame ?? parent.frame,
			placement: placement,
			layoutDirection: environment.layoutDirection
		))

		parent.addChildWindow(panel, ordered: .above)
		panel.makeKeyAndOrderFront(nil)
		self.panel = panel
		self.host = host

		// A click anywhere else takes key status, which is how the panel knows to leave.
		observer = NotificationCenter.default.addObserver(
			forName: NSWindow.didResignKeyNotification,
			object: panel,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.resignedKey() }
		}
		if isMovable { followFrame(of: panel) }
	}

	private static func root(
		_ content: AnyView,
		isMovable: Bool,
		environment: EnvironmentValues
	) -> AnyView {
		let chrome = FloatingPanelChrome(isMovable: isMovable, content: content)
		guard isMovable else { return AnyView(chrome) }
		return AnyView(chrome.floatingPanelEnvironment(environment))
	}

	private static func appearance(_ colorScheme: ColorScheme) -> NSAppearance? {
		NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
	}

	/// Keeps a drag's place, and the top edge where it is while the content changes size.
	private func followFrame(of panel: NSPanel) {
		let center = NotificationCenter.default
		frameObservers = [
			center.addObserver(
				forName: NSWindow.didMoveNotification,
				object: panel,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.panelMoved() }
			},
			center.addObserver(
				forName: NSWindow.didResizeNotification,
				object: panel,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.panelResized() }
			},
		]
	}

	private func panelMoved() {
		guard let panel else { return }
		position.moved(to: panel.frame)
	}

	private func panelResized() {
		guard
			let panel,
			let origin = position.resized(to: panel.frame.size, in: panel.screen?.visibleFrame),
			origin != panel.frame.origin
		else { return }
		panel.setFrameOrigin(origin)
	}

	/// A click elsewhere dismisses the panel. The color panel its color well opened takes key status
	/// too, and that's still the panel being used: while the color panel has it, the panel stays;
	/// when focus moves on from the color panel to anywhere but this panel, it goes.
	private func resignedKey() {
		// Which window took key status is known once the switch settles.
		Task { @MainActor [weak self] in self?.keyMoved() }
	}

	private func keyMoved() {
		guard let panel, !panel.isKeyWindow else { return }
		guard NSColorPanel.sharedColorPanelExists, NSApp.keyWindow === NSColorPanel.shared else {
			dismissed?()
			return
		}
		followColorPanel()
	}

	private func followColorPanel() {
		guard colorPanelObservers.isEmpty else { return }

		let center = NotificationCenter.default
		colorPanelObservers = [
			center.addObserver(
				forName: NSWindow.didResignKeyNotification,
				object: NSColorPanel.shared,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.colorPanelResignedKey() }
			},
			center.addObserver(
				forName: NSWindow.willCloseNotification,
				object: NSColorPanel.shared,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.colorPanelClosed() }
			},
		]
	}

	private func colorPanelResignedKey() {
		Task { @MainActor [weak self] in
			guard let self, let panel = self.panel else { return }

			// Closing the color panel is handled when it closes.
			guard NSColorPanel.shared.isVisible else { return }

			self.stopFollowingColorPanel()
			if !panel.isKeyWindow { self.dismissed?() }
		}
	}

	/// Back to the panel, so the next click elsewhere dismisses it.
	private func colorPanelClosed() {
		stopFollowingColorPanel()
		panel?.makeKey()
	}

	private func stopFollowingColorPanel() {
		for observer in colorPanelObservers { NotificationCenter.default.removeObserver(observer) }
		colorPanelObservers = []
	}

	fileprivate func dismiss() {
		if let observer { NotificationCenter.default.removeObserver(observer) }
		observer = nil
		for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
		frameObservers = []
		stopFollowingColorPanel()
		position.close()
		host = nil
		guard let panel else { return }
		self.panel = nil
		let parent = panel.parent
		let wasKey = panel.isKeyWindow
		parent?.removeChildWindow(panel)
		panel.orderOut(nil)

		// Closed with Esc or from inside: the window it floated over takes the keyboard back.
		if wasKey { parent?.makeKey() }
	}
}

extension View {
	/// The anchor's color scheme and chrome appearance, for content hosted in a panel of its own,
	/// which a popover's content would have inherited.
	fileprivate func floatingPanelEnvironment(_ environment: EnvironmentValues) -> some View {
		self
			.environment(\.colorScheme, environment.colorScheme)
			.environment(\.layoutDirection, environment.layoutDirection)
			.environment(\.browserChromeTint, environment.browserChromeTint)
			.environment(\.browserChromeGradient, environment.browserChromeGradient)
			.environment(\.browserChromeMatchesSite, environment.browserChromeMatchesSite)
			.environment(\.browserChromeSiteColor, environment.browserChromeSiteColor)
			.environment(\.browserChromeAccent, environment.browserChromeAccent)
			.environment(\.browserAccentIsEnabled, environment.browserAccentIsEnabled)
			.environment(\.browserFilmGrain, environment.browserFilmGrain)
	}
}

private final class BrowserFloatingPanel: NSPanel {
	fileprivate var onCancel: (() -> Void)?

	fileprivate override var canBecomeKey: Bool { true }

	fileprivate override func cancelOperation(_ sender: Any?) {
		onCancel?()
	}
}
