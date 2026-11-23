import AppKit

/// Arx's own back and forward swipe on a WebKit page (DEV-1203), in place of WebKit's: the
/// Chromium pages' arrow, ring and history list, their thresholds, and the page's say over its
/// own sideways scrolling, as `arx::gestures::Controller` does for Chromium pages from scroll
/// events (`Packages/engine/Native/gestures/controller.mm`, `HandleScroll`).
///
/// It never asks the web view where Back goes. The router answers (`availability`, `entries`)
/// and navigates (`perform`) through the path ⌘[ and ⌘] take, so a swipe back from the first
/// WebKit entry reopens the Chromium page the tab came from.
@MainActor
internal final class WebKitHistorySwipe {
	/// Where a released swipe goes.
	internal enum Navigation: Equatable, Sendable {
		case back
		case forward

		/// A WebKit history entry, by its offset from the current one.
		case entry(Int)

		/// The Chromium page the tab came from, before the first WebKit entry.
		case returnToChromium

		/// The Chromium page the tab went back from, after the last WebKit entry (DEV-1293).
		case forwardToChromium
	}

	/// One row of the history list.
	internal struct Entry: Equatable, Sendable {
		internal var title: String

		/// The page's host, or its whole address without one: the row's second line (DEV-1276).
		internal var host: String
		internal var navigation: Navigation

		internal init(
			title: String,
			host: String = "",
			navigation: Navigation
		) {
			self.title = title
			self.host = host
			self.navigation = navigation
		}
	}

	internal enum Phase: Equatable, Sendable {
		case none
		case began
		case changed
		case ended
		case cancelled

		internal init(_ phase: NSEvent.Phase) {
			switch phase {
			case .began: self = .began
			case .changed: self = .changed
			case .ended: self = .ended
			case .cancelled: self = .cancelled
			default: self = .none
			}
		}
	}

	/// A scroll event, as the swipe reads it.
	internal struct Scroll: Equatable, Sendable {
		internal var phase: Phase
		internal var momentum: Bool = false
		internal var precise: Bool = true
		internal var inverted: Bool = true
		internal var deltaX: Double = 0
		internal var deltaY: Double = 0

		/// In the view; nil when the pointer isn't over it.
		internal var pointer: CGPoint?

		/// When it happened, in milliseconds since 1970, as the page's answers say.
		internal var time: Double = Date().timeIntervalSince1970 * 1000
	}

	/// Normalized trackpad travel per history row while the list is open (`kRowPitch`): 0.07,
	/// raised from 0.05 so a row takes a deliberate move (DEV-1292).
	internal static let rowPitch: Double = 0.07

	/// How long past the reveal distance the list waits, so a closed ring can be released as a
	/// single step without the list flashing open.
	internal static let revealDelay: Duration = .milliseconds(300)

	/// How much earlier than the gesture's first scroll a page's answer may be stamped and still
	/// count for it: the page's clock and AppKit's round differently.
	internal static let answerSlack: Double = 5

	/// Back and Forward as the router has them, the Chromium page included.
	internal var availability: @MainActor () -> (canGoBack: Bool, canGoForward: Bool) = { (false, false) }

	/// The history list for a direction, nearest first.
	internal var entries: @MainActor (WebKitSwipeDirection) -> [Entry] = { _ in [] }

	/// What the history looks like now; a release checks it hasn't changed since the swipe began.
	internal var historyIdentity: @MainActor () -> [ObjectIdentifier] = { [] }

	/// macOS's Swipe between pages, as on Chromium pages (`UpstreamAllows`).
	internal var isEnabled: @MainActor () -> Bool = { NSEvent.isSwipeTrackingFromScrollEventsEnabled }

	/// Navigates through the router.
	internal var perform: @MainActor (Navigation) -> Void = { _ in }

	internal private(set) var ownership = WebKitSwipeOwnership()
	private weak var view: NSView?
	private var began: Double = 0
	private var point: CGPoint = .zero
	private var totalVertical: Double = 0
	private var identity: [ObjectIdentifier] = []
	private var list: [Entry] = []
	private var hasList = false
	private var selected = 0
	private var selectionAnchorY: Double = 0
	private var selectionAnchorIndex = 0
	private var revealDue = false
	private var revealTask: Task<Void, Never>?
	private var monitor: Any?
	private var focus = Focus()
	private(set) var panel: WebKitSwipePanel?

	internal init() {}

	isolated deinit {
		invalidate()
	}

	// MARK: - Events

	/// Reads a scroll over `view`. True when the swipe takes it from the page.
	internal func handle(
		_ event: NSEvent,
		in view: NSView
	) -> Bool {
		handle(Self.scroll(event, in: view), in: view)
	}

	internal func handle(
		_ scroll: Scroll,
		in view: NSView
	) -> Bool {
		if scroll.phase == .began, !scroll.momentum, scroll.precise {
			begin(scroll, in: view)
		}
		guard isCurrent else { return false }
		if scroll.momentum { return ownership.consumesWheel }

		if let pointer = scroll.pointer, view.bounds.contains(pointer) {
			if scroll.phase == .began || scroll.phase == .changed {
				let travel = WebKitSwipeOwnership.travel(
					deltaX: scroll.deltaX,
					deltaY: scroll.deltaY,
					inverted: scroll.inverted
				)
				move(by: travel)
			}
		} else {
			ownership.cancel()
			updateOverlay()
		}
		if scroll.phase == .ended || scroll.phase == .cancelled {
			// The page still gets the end of the scroll it saw begin.
			finish(cancelled: scroll.phase == .cancelled)
			return false
		}
		return ownership.consumesWheel
	}

	/// The page's answer for one of its wheels (`WebKitSwipeScript`).
	internal func acknowledge(_ answer: WebKitSwipeScript.Answer) {
		guard isCurrent, answer.time >= began - Self.answerSlack else { return }
		ownership.acknowledge(consumed: answer.consumed, propagatesX: answer.propagatesX)
		updateOverlay()
	}

	/// Ends any gesture without navigating: the page navigated, closed or left its window.
	internal func invalidate() {
		ownership.invalidate()
		revealTask?.cancel()
		revealTask = nil
		revealDue = false
		panel?.dismiss()
		panel = nil
		list = []
		hasList = false
		identity = []
		if let monitor { NSEvent.removeMonitor(monitor) }
		monitor = nil
		view = nil
	}

	// MARK: - Gesture

	/// Focus when a gesture began. A swipe over a window that isn't key, or a page without keyboard
	/// focus, is a gesture like any other; only losing the focus it began with cancels it, as on
	/// Chromium pages (`arx::gestures::Focus`).
	private struct Focus: Equatable {
		var isKey = false
		var hasResponder = false

		init() {}

		@MainActor
		init(_ view: NSView) {
			let window = view.window
			isKey = window?.isKeyWindow ?? false
			hasResponder = (window?.firstResponder as? NSView).map { $0 === view || $0.isDescendant(of: view) } ?? false
		}

		func keeps(_ now: Focus) -> Bool {
			(!isKey || now.isKey) && (!hasResponder || now.hasResponder)
		}
	}

	private var isCurrent: Bool {
		guard ownership.isCurrent, let view, let window = view.window, window.isVisible, !window.isMiniaturized,
			!view.isHiddenOrHasHiddenAncestor, focus.keeps(Focus(view)), isEnabled()
		else {
			if ownership.isCurrent { invalidate() }
			return false
		}
		return true
	}

	private func begin(
		_ scroll: Scroll,
		in view: NSView
	) {
		invalidate()
		guard isEnabled(), let pointer = scroll.pointer, view.bounds.contains(pointer), view.window != nil else { return }

		let (canGoBack, canGoForward) = availability()
		ownership.begin(inverted: scroll.inverted, canGoBack: canGoBack, canGoForward: canGoForward)
		self.view = view
		focus = Focus(view)
		began = scroll.time
		point = .init(x: 0.5, y: 0.5)
		totalVertical = 0
		identity = historyIdentity()

		// The scroll may end where the pointer left the page, which this view never hears.
		monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
			MainActor.assumeIsolated { self?.observe(event) }
			return event
		}
	}

	private func observe(_ event: NSEvent) {
		guard isCurrent, let view else { return }
		if event.type == .keyDown, event.keyCode == 53 {
			ownership.cancel()
			updateOverlay()
			return
		}
		guard event.type == .scrollWheel, event.momentumPhase == [] else { return }
		let phase = Phase(event.phase)
		guard phase == .ended || phase == .cancelled else { return }
		if let pointer = Self.scroll(event, in: view).pointer, view.bounds.contains(pointer) { return }
		ownership.cancel()
		finish(cancelled: true)
	}

	private func move(by travel: (x: Double, y: Double)) {
		totalVertical += abs(travel.y)
		point.x += travel.x
		point.y += travel.y
		ownership.update(horizontal: point.x - 0.5, totalVertical: totalVertical)
		updateOverlay()
	}

	private func finish(cancelled: Bool) {
		guard isCurrent else { return }
		if cancelled { ownership.cancel() }
		let historyIsCurrent = historyIdentity() == identity

		if ownership.owner == .scrubber {
			let target = list.indices.contains(selected) ? list[selected] : nil
			let commits = ownership.releaseScrubber()
			invalidate()
			if commits, historyIsCurrent, let target { perform(target.navigation) }
			return
		}

		let direction = ownership.release()
		invalidate()
		guard let direction, historyIsCurrent else { return }
		let (canGoBack, canGoForward) = availability()
		switch direction {
		case .back where canGoBack: perform(.back)
		case .forward where canGoForward: perform(.forward)
		default: break
		}
	}

	// MARK: - Indicator

	private func updateOverlay() {
		guard
			let view,
			let direction = ownership.direction,
			ownership.admitted,
			ownership.owner == .history || ownership.owner == .scrubber
		else {
			revealTask?.cancel()
			revealTask = nil
			revealDue = false
			panel?.dismiss()
			panel = nil
			return
		}

		if !hasList {
			hasList = true
			list = entries(direction)
		}
		if panel == nil {
			let panel = WebKitSwipePanel(source: view, direction: direction)
			panel.setEntries(list.map { WebKitSwipePanel.Row(title: $0.title, host: $0.host) })
			self.panel = panel
		}
		if ownership.owner == .scrubber || !ownership.revealReached {
			revealTask?.cancel()
			revealTask = nil
			revealDue = false
		} else if !revealDue, revealTask == nil {
			revealTask = Task { [weak self] in
				try? await Task.sleep(for: Self.revealDelay)
				guard !Task.isCancelled, let self else { return }
				self.revealTask = nil
				guard self.isCurrent else { return }
				self.revealDue = true
				self.updateOverlay()
			}
		}
		if ownership.owner != .scrubber, revealDue, !list.isEmpty, ownership.revealScrubber() {
			revealDue = false
			selectionAnchorY = point.y
			selectionAnchorIndex = 0
			selected = 0
		}
		if ownership.owner == .scrubber {
			let rows = Self.selection(
				anchorIndex: selectionAnchorIndex,
				anchorY: selectionAnchorY,
				y: point.y,
				direction: direction
			)
			guard rows.isFinite else {
				invalidate()
				return
			}
			selected = Int(min(max(rows.rounded(), 0), Double(list.count - 1)))
			panel?.update(progress: 1, armed: true, selected: selected)
			return
		}
		selected = 0
		panel?.update(progress: ownership.progress, armed: false, selected: 0)
	}

	/// The selected row, unrounded, for finger travel since the anchor (`Controller::UpdateSelection`).
	/// Down goes back through history and up goes forward (DEV-1292): the back list runs down from
	/// the arrow, nearest on top, and the forward list runs up from it, nearest at the bottom, so
	/// moving away from the arrow moves away from the current page in both.
	internal static func selection(
		anchorIndex: Int,
		anchorY: Double,
		y: Double,
		direction: WebKitSwipeDirection
	) -> Double {
		let travel = direction == .back ? anchorY - y : y - anchorY
		return Double(anchorIndex) + travel / rowPitch
	}

	// MARK: - Reading events

	internal static func scroll(
		_ event: NSEvent,
		in view: NSView
	) -> Scroll {
		// A scroll the view gets directly may come without a window (a synthesized one), and is
		// then taken to be over the view.
		let pointer: CGPoint?
		if let window = event.window {
			pointer = window == view.window ? view.convert(event.locationInWindow, from: nil) : nil
		} else {
			pointer = .init(x: view.bounds.midX, y: view.bounds.midY)
		}

		// AppKit's timestamps count from boot; the page's from 1970.
		let age = ProcessInfo.processInfo.systemUptime - event.timestamp
		return .init(
			phase: .init(event.phase),
			momentum: event.momentumPhase != [],
			precise: event.hasPreciseScrollingDeltas,
			inverted: event.isDirectionInvertedFromDevice,
			deltaX: event.scrollingDeltaX,
			deltaY: event.scrollingDeltaY,
			pointer: pointer,
			time: (Date().timeIntervalSince1970 - age) * 1000
		)
	}
}
