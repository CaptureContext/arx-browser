import AppKit
import SwiftUI

extension View {
	/// Shows `content` in a borderless panel beside this view, without the popover's arrow.
	/// The panel never takes key status, so the sidebar keeps the keyboard while it shows.
	/// `acceptsKeyboard` lets a click in it take key status, as for a folder's search field.
	/// `edge` is the side of this view the panel opens on. `drawsCard` puts the content on the
	/// previews' material; content that draws its own cards, as the Library's recent downloads do, turns it off.
	/// `keyboard` routes keys to a panel that accepts the keyboard, as a folder's search does (DEV-836).
	/// `margin` is clear room around the content for shadows it draws itself, as the raised glass
	/// previews do (DEV-1275): the panel then casts none, and the content still sits `anchorGap`
	/// from the row.
	/// `exclusivity` is what the window's one preview owner hears from this panel (DEV-1288): the
	/// panel shows only if the owner lets it, and showing closes any other in the window first.
	internal func sidebarHoverPanel(
		isPresented: Binding<Bool>,
		acceptsKeyboard: Bool = false,
		keyboard: SidebarHoverPanelKeyboard? = nil,
		edge: SidebarHoverPanelEdge = .trailing,
		drawsCard: Bool = true,
		margin: CGFloat = 0,
		exclusivity: SidebarHoverPanelExclusivity = .init(),
		@ViewBuilder content: @escaping () -> some View
	) -> some View {
		background {
			SidebarHoverPanelAnchor(
				isPresented: isPresented,
				acceptsKeyboard: acceptsKeyboard,
				keyboard: keyboard,
				edge: edge,
				drawsCard: drawsCard,
				margin: margin,
				exclusivity: exclusivity
			) { AnyView(content()) }
		}
	}
}

/// Keys a hover panel that accepts the keyboard handles itself (DEV-836).
internal enum SidebarHoverPanelKey: Equatable {
	/// Tab in the panel's window while the panel shows but doesn't have the keyboard yet.
	case tab
	case up
	case down
	case `return`
	case escape
}

/// How a hover panel hands keys to its content. `key` returns whether it used the key.
/// `keyStatusChanged` reports the panel taking the keyboard (by Tab or a click) and losing it to another window.
internal struct SidebarHoverPanelKeyboard {
	internal var key: @MainActor (SidebarHoverPanelKey) -> Bool
	internal var keyStatusChanged: @MainActor (Bool) -> Void

	internal init(
		key: @escaping @MainActor (SidebarHoverPanelKey) -> Bool,
		keyStatusChanged: @escaping @MainActor (Bool) -> Void
	) {
		self.key = key
		self.keyStatusChanged = keyStatusChanged
	}
}

/// How a hover panel takes part in its window's one preview (DEV-1288), as
/// `SidebarHoverPreviewExclusivity` describes.
internal struct SidebarHoverPanelExclusivity {
	/// The panel opened after the pointer rested on its row for the whole hover delay, or with
	/// Shift, so it replaces even a held preview.
	internal var isSettled: Bool

	/// The panel is being used, so only a settled preview replaces it.
	internal var isHeld: Bool

	/// The owner left the panel closed, or another preview replaced it. `isPresented` turns false
	/// either way; this tells the content which, so a refusal isn't taken for a close.
	internal var refused: (@MainActor () -> Void)?

	internal init(
		isSettled: Bool = true,
		isHeld: Bool = false,
		refused: (@MainActor () -> Void)? = nil
	) {
		self.isSettled = isSettled
		self.isHeld = isHeld
		self.refused = refused
	}
}

/// Where a hover panel opens: beside its row, or above it, as the Library's recent downloads do.
internal enum SidebarHoverPanelEdge {
	case trailing
	case top
}

private struct SidebarHoverPanelAnchor: NSViewRepresentable {
	internal let isPresented: Binding<Bool>
	internal let acceptsKeyboard: Bool
	internal let keyboard: SidebarHoverPanelKeyboard?
	internal let edge: SidebarHoverPanelEdge
	internal let drawsCard: Bool
	internal let margin: CGFloat
	internal let exclusivity: SidebarHoverPanelExclusivity
	internal let content: () -> AnyView

	internal func makeCoordinator() -> SidebarHoverPanelPresenter {
		.init()
	}

	internal func makeNSView(context: Context) -> NSView {
		NSView()
	}

	internal func updateNSView(
		_ view: NSView,
		context: Context
	) {
		context.coordinator.dismissed = { isPresented.wrappedValue = false }
		context.coordinator.keyboard = keyboard
		context.coordinator.exclusivity = exclusivity
		if isPresented.wrappedValue {
			// The panel is its own SwiftUI hierarchy: it carries the sidebar's environment, such
			// as its site icon loader and the space's light or dark, and redraws with each update,
			// as a popover's content does.
			context.coordinator.present(
				from: view,
				environment: context.environment,
				acceptsKeyboard: acceptsKeyboard,
				edge: edge,
				drawsCard: drawsCard,
				margin: margin,
				content: content
			)
		} else {
			context.coordinator.dismiss()
		}
	}

	internal static func dismantleNSView(
		_ view: NSView,
		coordinator: SidebarHoverPanelPresenter
	) {
		coordinator.dismiss()
	}
}

@MainActor
private final class SidebarHoverPanelPresenter: SidebarHoverPreviewPresentation {
	internal var dismissed: (() -> Void)?
	internal var keyboard: SidebarHoverPanelKeyboard?
	internal var exclusivity: SidebarHoverPanelExclusivity = .init()
	private var panel: NSPanel?

	/// The window's preview owner, while this panel shows.
	private var owner: SidebarHoverPreviewOwner?

	/// The owner refused this panel or replaced it, and `isPresented` hasn't turned false yet: it
	/// doesn't ask again until it has (DEV-1288).
	private var isTurnedAway: Bool = false
	private var host: NSHostingView<AnyView>?
	private weak var anchor: NSView?
	private var edge: SidebarHoverPanelEdge = .trailing
	private var margin: CGFloat = 0
	private var observer: (any NSObjectProtocol)?
	private var keyObservers: [any NSObjectProtocol] = []
	private var keyMonitor: Any?

	internal func present(
		from view: NSView,
		environment: EnvironmentValues,
		acceptsKeyboard: Bool,
		edge: SidebarHoverPanelEdge,
		drawsCard: Bool,
		margin: CGFloat,
		content: () -> AnyView
	) {
		anchor = view
		self.edge = edge
		self.margin = margin
		let root = Self.root(content(), environment: environment, drawsCard: drawsCard, margin: margin)
		let appearance = NSAppearance(named: environment.colorScheme == .dark ? .darkAqua : .aqua)
		if let host {
			host.rootView = root
			panel?.appearance = appearance
			owner?.hold(self, isHeld)
			return
		}
		guard !isTurnedAway, panel == nil, let parent = view.window else { return }

		// The window shows one preview: any other goes now, before this one is ordered in.
		let owner = SidebarHoverPreviewOwner.owner(for: parent)
		guard owner.request(self, isSettled: exclusivity.isSettled) else { return turnAway() }
		self.owner = owner

		let host = NSHostingView(rootView: root)
		self.host = host
		host.safeAreaRegions = []
		host.postsFrameChangedNotifications = true

		let panel = HoverPanel(acceptsKeyboard: acceptsKeyboard,
			contentRect: .init(origin: .zero, size: host.fittingSize),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.isOpaque = false
		panel.backgroundColor = .clear

		// Content with room for its own shadows draws them; the window's would trace its margin.
		panel.hasShadow = margin == 0
		panel.appearance = appearance
		panel.onCancel = { [weak self] in self?.dismissed?() }
		panel.isReleasedWhenClosed = false
		panel.contentView = host
		self.panel = panel
		place()
		parent.addChildWindow(panel, ordered: .above)
		panel.orderFront(nil)

		// The card grows once its picture loads: keep it beside the row.
		observer = NotificationCenter.default.addObserver(
			forName: NSView.frameDidChangeNotification,
			object: host,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.place() }
		}
		if acceptsKeyboard { observeKeyboard(of: panel) }
		owner.hold(self, isHeld)
	}

	/// Held while its content says so or while it has the keyboard.
	private var isHeld: Bool {
		exclusivity.isHeld || panel?.isKeyWindow == true
	}

	/// Another preview in the window replaces this one: it goes now, and its content hears of it
	/// after this update.
	internal func evict() {
		close()
		turnAway()
	}

	/// Tells the content, after the update that asked, that the panel isn't showing.
	private func turnAway() {
		isTurnedAway = true
		let refused = exclusivity.refused
		let dismissed = dismissed
		Task { @MainActor in
			refused?()
			dismissed?()
		}
	}

	internal func dismiss() {
		isTurnedAway = false
		close()
	}

	private func close() {
		owner?.release(self)
		owner = nil
		if let observer { NotificationCenter.default.removeObserver(observer) }
		observer = nil
		keyObservers.forEach(NotificationCenter.default.removeObserver)
		keyObservers = []
		if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		keyMonitor = nil
		host = nil
		guard let panel else { return }
		self.panel = nil

		// A panel closed from the keyboard (Return, Escape) hands it back to its window.
		if panel.isKeyWindow { panel.parent?.makeKey() }
		panel.parent?.removeChildWindow(panel)
		panel.orderOut(nil)
	}

	/// Tab in the window takes the keyboard into the panel and its first field; ↑, ↓, Return and
	/// Escape in the panel go to its content. A field composing text keeps its keys.
	private func observeKeyboard(of panel: NSPanel) {
		keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
			NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] note in
				let isKey = note.name == NSWindow.didBecomeKeyNotification
				MainActor.assumeIsolated {
					guard let self else { return }
					self.owner?.hold(self, self.isHeld)
					self.keyboard?.keyStatusChanged(isKey)
				}
			}
		}
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
			return handled ? nil : event
		}
	}

	private func handle(_ event: NSEvent) -> Bool {
		guard let panel, let keyboard else { return false }
		guard
			let key = Self.key(for: event, in: panel),
			keyboard.key(key)
		else { return false }
		if key == .tab {
			panel.makeKey()
			if let field = Self.firstField(in: panel.contentView) {
				panel.makeFirstResponder(field)
			}
		}
		return true
	}

	private static func key(
		for event: NSEvent,
		in panel: NSPanel
	) -> SidebarHoverPanelKey? {
		let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
		guard modifiers.isEmpty else { return nil }
		if let parent = panel.parent, event.window === parent, !panel.isKeyWindow {
			return event.keyCode == 48 && !isComposing(in: parent) ? .tab : nil
		}
		guard event.window === panel, !isComposing(in: panel) else { return nil }
		return switch event.keyCode {
		case 126: .up
		case 125: .down
		case 36, 76: .return
		case 53: .escape
		default: nil
		}
	}

	/// Whether the window's focused text input, a field or a web page, is composing with an input method.
	private static func isComposing(in window: NSWindow) -> Bool {
		(window.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true
	}

	private static func firstField(in view: NSView?) -> NSTextField? {
		guard let view else { return nil }
		if let field = view as? NSTextField, field.isEditable { return field }
		for subview in view.subviews {
			if let field = firstField(in: subview) { return field }
		}
		return nil
	}

	private func place() {
		guard let panel, let anchor, let parent = anchor.window else { return }
		let row = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
		let size = panel.contentView?.fittingSize ?? panel.frame.size
		let visible = parent.screen?.visibleFrame ?? parent.frame

		// The content is placed; its margin lies around it.
		let content = CGSize(width: max(size.width - margin * 2, 0), height: max(size.height - margin * 2, 0))
		let contentOrigin = switch edge {
		case .trailing:
			SidebarHoverPanelPlacement.origin(
				of: content,
				beside: row,
				within: visible,
				gap: BrowserMetrics.FloatingPanel.anchorGap
			)

		case .top:
			SidebarHoverPanelPlacement.origin(
				of: content,
				above: row,
				within: visible,
				gap: BrowserMetrics.FloatingPanel.anchorGap
			)
		}
		let origin = CGPoint(x: contentOrigin.x - margin, y: contentOrigin.y - margin)
		panel.setFrame(.init(origin: origin, size: size), display: true)
	}

	/// The card on its material, all in the sidebar's environment so both share one scheme.
	private static func root(
		_ content: AnyView,
		environment: EnvironmentValues,
		drawsCard: Bool,
		margin: CGFloat
	) -> AnyView {
		guard drawsCard else { return AnyView(content.padding(margin).environment(\.self, environment)) }

		let radius = BrowserMetrics.FloatingPanel.cornerRadius
		return AnyView(
			content
				.background(.regularMaterial, in: .rect(cornerRadius: radius, style: .continuous))
				.overlay {
					RoundedRectangle(cornerRadius: radius, style: .continuous)
						.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth)
				}
				.environment(\.self, environment)
		)
	}

	private final class HoverPanel: NSPanel {
		private let acceptsKeyboard: Bool
		internal var onCancel: (() -> Void)?

		internal init(
			acceptsKeyboard: Bool,
			contentRect: NSRect,
			styleMask: NSWindow.StyleMask,
			backing: NSWindow.BackingStoreType,
			defer flag: Bool
		) {
			self.acceptsKeyboard = acceptsKeyboard
			super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)

			// Hovering never takes key; only a click in a field that needs typing does.
			becomesKeyOnlyIfNeeded = true
		}

		internal override var canBecomeKey: Bool { acceptsKeyboard }

		/// Escape in the folder's search field closes the preview, as it closed the popover.
		internal override func cancelOperation(_ sender: Any?) {
			onCancel?()
		}
		internal override var canBecomeMain: Bool { false }
	}
}

/// Where a hover card goes: after the row, centered on it, or before it when it doesn't fit,
/// always on the row's screen. Screen coordinates, with y growing upward.
internal enum SidebarHoverPanelPlacement {
	internal static func origin(
		of size: CGSize,
		beside row: CGRect,
		within visible: CGRect,
		gap: CGFloat
	) -> CGPoint {
		let after = row.maxX + gap
		let before = row.minX - gap - size.width
		let x = after + size.width <= visible.maxX - gap || before < visible.minX + gap ? after : before
		let y = row.midY - size.height / 2
		return .init(
			x: min(max(x, visible.minX + gap), visible.maxX - size.width - gap),
			y: min(max(y, visible.minY + gap), visible.maxY - size.height - gap)
		)
	}

	/// Above the row, its leading edge in line with the row's, as the Library's recent downloads
	/// fan out over the footer.
	internal static func origin(
		of size: CGSize,
		above row: CGRect,
		within visible: CGRect,
		gap: CGFloat
	) -> CGPoint {
		.init(
			x: min(max(row.minX, visible.minX + gap), visible.maxX - size.width - gap),
			y: min(max(row.maxY + gap, visible.minY + gap), visible.maxY - size.height - gap)
		)
	}
}
