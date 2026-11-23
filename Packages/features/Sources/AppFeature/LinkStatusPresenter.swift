import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import SwiftUI
import _ComposableArchitecture

/// Shows where a hovered page link goes, and what a click with the held modifier keys will do
/// (DEV-1111), at the bottom-left corner of the hovered page: a main window's pane, a Split
/// View pane, Peek or Little Arx, private windows too.
///
/// The engine reports the hovered link (ABI60). The status shows after
/// ``LinkStatusToastMetrics/showDelay``, follows the keys as they're pressed and released, moves
/// to the bottom-right corner while the pointer is over its own spot, and goes when the pointer
/// leaves the link, the page or Arx. Nothing about the link is kept.
@MainActor
internal final class LinkStatusPresenter {
	private let store: StoreOf<AppFeature>
	private let view: @MainActor (BrowserCore.Tab.ID) -> NSView?
	private let opensInWebKit: @MainActor (URL) -> Bool
	private var link: BrowserHoveredLink?
	private var shown: LinkStatus?
	private var panel: LinkStatusPanel?
	private var pending: Task<Void, Never>?
	private var monitor: Any?
	private var observers: [any NSObjectProtocol] = []
	private var activation: (any NSObjectProtocol)?

	internal init(
		store: StoreOf<AppFeature>,
		view: @escaping @MainActor (BrowserCore.Tab.ID) -> NSView?,
		opensInWebKit: @escaping @MainActor (URL) -> Bool
	) {
		self.store = store
		self.view = view
		self.opensInWebKit = opensInWebKit

		// Back in Arx with the pointer still on a link: the engine reports nothing new, so the
		// status comes back from the link it kept.
		activation = NotificationCenter.default.addObserver(
			forName: NSApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.refresh() }
		}
	}

	/// The tab's page reported the link under the pointer, or nil when it left it.
	internal func receive(
		_ tabID: BrowserCore.Tab.ID,
		_ hovered: BrowserHoveredLink?
	) {
		guard isEnabled else { return stop() }

		guard let hovered else {
			// Another page's leave doesn't hide this one's status.
			guard link?.tabID == tabID else { return }
			link = nil
			schedule(after: LinkStatusToastMetrics.hideDelay) { $0.stop() }
			return
		}

		link = hovered

		// While a link is hovered, even with the status hidden: the pointer coming back over
		// the page shows it again, though the engine reports nothing new.
		startMonitoring()
		pending?.cancel()
		pending = nil
		if shown != nil {
			update()
		} else {
			schedule(after: LinkStatusToastMetrics.showDelay) { $0.update() }
		}
	}

	/// Forgets the hovered link and hides its status.
	internal func stop() {
		pending?.cancel()
		pending = nil
		link = nil
		hide()
		stopMonitoring()
	}

	/// The app is going away: nothing shows again.
	internal func finish() {
		stop()
		if let activation { NotificationCenter.default.removeObserver(activation) }
		activation = nil
	}

	private var isEnabled: Bool {
		store.settings.linkClicks.showsLinkStatus
	}

	private func schedule(
		after delay: Duration,
		_ body: @escaping @MainActor (LinkStatusPresenter) -> Void
	) {
		pending?.cancel()
		pending = Task { @MainActor [weak self] in
			try? await Task.sleep(for: delay)
			guard !Task.isCancelled, let self else { return }
			self.pending = nil
			body(self)
		}
	}

	/// The keys, the pointer, the window or Arx changed: the status follows them, unless it's
	/// still waiting to show or to go, which its own timer then decides.
	private func refresh() {
		guard pending == nil, link != nil else { return }

		update()
	}

	/// Shows the hovered link's status for the keys held now, or hides it when its page isn't
	/// on screen under the pointer any more.
	private func update() {
		guard
			isEnabled,
			let link,
			let view = view(link.tabID),
			let window = view.window,
			window.isVisible, !window.isMiniaturized,
			!view.isHiddenOrHasHiddenAncestor,
			NSApp.isActive,
			view.bounds.width >= LinkStatusToastMetrics.minimumWidth
		else { return hide() }

		let pageFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
		let pointer = NSEvent.mouseLocation
		guard pageFrame.contains(pointer) else { return hide() }

		let outcome = store.state.linkClickOutcome(
			for: link,
			modifiers: NSEvent.modifierFlags,
			opensInWebKit: opensInWebKit(link.url)
		)
		let status = LinkStatus(url: link.url, outcome: outcome)
		let panel = self.panel ?? makePanel()
		if status != shown {
			panel.host.rootView = status.view
			shown = status
		}
		let maximumWidth = pageFrame.width * LinkStatusToastMetrics.maximumWidthFraction
		let width = min(panel.naturalWidth(for: status), maximumWidth)
		let frame = Self.frame(
			size: .init(width: width, height: LinkStatusToastMetrics.height),
			in: pageFrame,
			pointer: pointer
		)

		// Narrowed beside the pointer with too little room, or narrower than its words with
		// the address cut to "…": nothing rather than covering the pointer or overflowing.
		guard
			frame.width >= min(width, LinkStatusToastMetrics.minimumBesidePointer),
			frame.width >= panel.minimumWidth(for: status)
		else { return hide() }

		panel.setFrame(frame, display: true)
		if panel.parent !== window {
			panel.parent?.removeChildWindow(panel)
			observe(window)
			window.addChildWindow(panel, ordered: .above)
		}
		panel.orderFront(nil)
	}

	/// At the page's bottom-left corner, or its bottom-right while the pointer is over the
	/// bottom-left spot, or beside the pointer when it's over both, so the status never covers
	/// what the pointer is on.
	internal static func frame(
		size: CGSize,
		in page: CGRect,
		pointer: CGPoint
	) -> CGRect {
		let inset: CGFloat = LinkStatusToastMetrics.edgeInset
		let leading = CGRect(
			origin: .init(x: page.minX + inset, y: page.minY + inset),
			size: size
		)

		// A little room around it, so the pointer resting at its edge moves it too.
		guard leading.insetBy(dx: -inset, dy: -inset).contains(pointer) else { return leading }

		let trailing = CGRect(
			origin: .init(x: max(page.maxX - inset - size.width, page.minX + inset), y: page.minY + inset),
			size: size
		)
		guard trailing.insetBy(dx: -inset, dy: -inset).contains(pointer) else { return trailing }

		// A wide status covers the pointer at both corners: it goes beside the pointer, on the
		// side with more room, as narrow as that room. Its address truncates to fit.
		let leftRoom = pointer.x - inset - (page.minX + inset)
		let rightRoom = page.maxX - inset - (pointer.x + inset)
		if rightRoom >= leftRoom {
			let width = max(min(size.width, rightRoom), 0)
			return CGRect(x: page.maxX - inset - width, y: page.minY + inset, width: width, height: size.height)
		}
		return CGRect(x: page.minX + inset, y: page.minY + inset, width: max(min(size.width, leftRoom), 0), height: size.height)
	}

	/// Hides the status and keeps the hovered link, which shows again when the pointer, the
	/// keys or Arx coming forward ask for it.
	private func hide() {
		shown = nil
		for observer in observers { NotificationCenter.default.removeObserver(observer) }
		observers.removeAll()
		guard let panel else { return }

		panel.parent?.removeChildWindow(panel)
		panel.orderOut(nil)
	}

	private func makePanel() -> LinkStatusPanel {
		let panel = LinkStatusPanel()
		self.panel = panel
		return panel
	}

	/// The keys and the pointer, only while a link is hovered.
	private func startMonitoring() {
		guard monitor == nil else { return }

		monitor = NSEvent.addLocalMonitorForEvents(
			matching: [.flagsChanged, .mouseMoved, .leftMouseDragged, .scrollWheel]
		) { [weak self] event in
			MainActor.assumeIsolated { self?.refresh() }
			return event
		}
	}

	private func stopMonitoring() {
		guard let monitor else { return }

		NSEvent.removeMonitor(monitor)
		self.monitor = nil
	}

	/// The window resizing places the status again; the window going away or Arx going to the
	/// back hides it until the pointer or Arx coming forward shows it again.
	private func observe(_ window: NSWindow) {
		for observer in observers { NotificationCenter.default.removeObserver(observer) }
		let center: NotificationCenter = .default
		observers = [
			center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.refresh() }
			},
		] + [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification].map { name in
			center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.hide() }
			}
		} + [
			center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.hide() }
			},
		]
	}
}

/// Never key and never under the pointer: the page keeps every click, scroll and hover.
internal final class LinkStatusPanel: NSPanel {
	internal let host: NSHostingView<LinkStatusToast>

	/// Measures a status: `host` has no sizing options, so its own fitting size is always zero.
	private let measure: NSHostingView<LinkStatusToast> = .init(rootView: LinkStatusToast(address: "…"))

	internal init() {
		host = NSHostingView(rootView: LinkStatusToast(address: ""))

		// The presenter sizes the panel; the toast never grows it past the room it was given.
		host.sizingOptions = []
		super.init(
			contentRect: .zero,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: true
		)
		isReleasedWhenClosed = false
		hidesOnDeactivate = true
		ignoresMouseEvents = true
		hasShadow = false
		isOpaque = false
		backgroundColor = .clear
		animationBehavior = .none
		contentView = host
		setAccessibilityElement(false)
	}

	override internal var canBecomeKey: Bool { false }
	override internal var canBecomeMain: Bool { false }

	/// The width a status takes with its whole address showing. Measured apart from `host`,
	/// which the presenter sizes and which so reports no size of its own: asking it left every
	/// status zero wide, narrower than its minimum, and so never shown.
	internal func naturalWidth(for status: LinkStatus) -> CGFloat {
		measure.rootView = status.view
		return measure.fittingSize.width
	}

	/// The narrowest a status gets: its words around an address cut to "…".
	internal func minimumWidth(for status: LinkStatus) -> CGFloat {
		measure.rootView = LinkStatusToast(verb: status.verb, address: "…", action: status.action)
		return measure.fittingSize.width
	}
}
