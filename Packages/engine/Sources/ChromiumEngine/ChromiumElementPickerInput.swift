import AppKit

/// The view Arx's element picker lays over a page while it's open (DEV-1206): it takes the
/// mouse and the keys, so the page's document never gets an event a pick makes and none of the
/// page's own listeners, capture-phase ones on its window included, can act on it. What it sees
/// becomes ``ChromiumElementPicker/Command``s that the picker's session hands the page's script,
/// which finds and outlines what's under the pointer.
///
/// The wheel, trackpad scrolling and pinching still reach the page, so the person can scroll
/// to what they want to pick. It's the page view's topmost subview, so it moves with the page
/// from host to host and covers only the page, not DevTools docked beside it, and takes the
/// keyboard while it's in a window, giving it back when it goes. Whatever gives the keyboard to
/// the page meanwhile, the app focusing the page or the page focusing itself, gives it to this
/// view instead; something else in the window, such as the sidebar, keeps it until the person
/// clicks the page again.
@MainActor
internal final class ChromiumElementPickerInput: NSView {
	/// The identifier it goes by, so the app's Edit › Undo leaves ⌘Z to it while it has the
	/// keyboard in Hide Element's mode (DEV-1298).
	internal static let identifier: NSUserInterfaceItemIdentifier = .init(ChromiumElementPicker.inputIdentifier)

	/// What it saw since the session last looked, in order.
	internal private(set) var pending: [ChromiumElementPicker.Command] = []

	/// The pointer over the page while it's open: Hide Element's scope (DEV-1298), else a crosshair.
	internal var cursor: NSCursor = .crosshair {
		didSet { window?.invalidateCursorRects(for: self) }
	}

	/// Hide Element's mode (DEV-1298): some keys are the app's, for the toast's list and its Undo
	/// and Done, queued with the rest of the input so each is told in its turn. Off, every key is
	/// the script's, as in the one-pick picker.
	internal var takesAppKeys: Bool = false

	/// Whether the toast's list of hidden elements is open, which takes ↑, ↓ and Delete.
	internal var listIsOpen: Bool = false

	/// The lines the app asked about, by selector, so the replies name the very lines asked
	/// about: on `sub.example.com` the list holds `example.com##…` too (DEV-1298).
	internal var describedLines: [String: Set<String>] = [:]
	internal var unhiddenLines: [String: [String]] = [:]
	private weak var previousResponder: NSResponder?
	private var pressedAt: CGPoint?

	/// Whether the pointer was last over something covering the page, such as Hide Element's toast.
	private var pointerIsCovered: Bool = false
	private var trackingArea: NSTrackingArea?
	private var refreshAfterScroll: Task<Void, Never>?
	private var responderObservation: NSKeyValueObservation?

	/// Covers `pageView` and takes the keyboard. A page has one at a time: one an earlier session
	/// hasn't taken away yet gives way, handing on what had the keyboard before it.
	internal static func install(over pageView: NSView) -> ChromiumElementPickerInput {
		let input = ChromiumElementPickerInput(frame: pageView.bounds)
		input.identifier = identifier
		input.autoresizingMask = [.width, .height]
		for earlier in pageView.subviews.compactMap({ $0 as? ChromiumElementPickerInput }) {
			input.previousResponder = input.previousResponder ?? earlier.previousResponder
			earlier.retire()
		}
		pageView.addSubview(input, positioned: .above, relativeTo: nil)
		input.takeKeyboard()
		return input
	}

	/// Leaves the page for a newer one, which takes the keyboard on.
	private func retire() {
		refreshAfterScroll?.cancel()
		responderObservation?.invalidate()
		responderObservation = nil
		removeFromSuperview()
	}

	/// Leaves the page, giving the keyboard back to what had it.
	internal func remove() {
		guard superview != nil else { return }

		refreshAfterScroll?.cancel()
		responderObservation?.invalidate()
		responderObservation = nil
		if let window, window.firstResponder === self {
			let previous = previousResponder.flatMap { responder -> NSResponder? in
				guard let view = responder as? NSView else { return responder === window ? window : nil }
				return view.window === window ? view : nil
			}
			window.makeFirstResponder(previous ?? superview)
		}
		removeFromSuperview()
	}

	/// The commands seen since the last look; moves in a row count as the last of them.
	internal func drain() -> [ChromiumElementPicker.Command] {
		var drained: [ChromiumElementPicker.Command] = []
		for command in pending {
			if case .pointer = command, case .pointer = drained.last {
				drained[drained.count - 1] = command
			} else {
				drained.append(command)
			}
		}
		pending = []
		return drained
	}

	/// Adds a command the app asks for, such as showing an element again (DEV-1298).
	internal func enqueue(_ command: ChromiumElementPicker.Command) {
		pending.append(command)
	}

	/// The one over `pageView`, while a picker is open there.
	internal static func current(over pageView: NSView) -> ChromiumElementPickerInput? {
		pageView.subviews.last { $0 is ChromiumElementPickerInput } as? ChromiumElementPickerInput
	}

	/// Puts back commands a busy page didn't take, ahead of any seen since.
	internal func restore(_ commands: [ChromiumElementPicker.Command]) {
		pending = commands + pending
	}

	internal var hasPending: Bool { !pending.isEmpty }

	// MARK: - View

	override internal var isFlipped: Bool { true }
	override internal var acceptsFirstResponder: Bool { true }

	override internal func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	override internal func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		responderObservation?.invalidate()
		responderObservation = nil

		// Joining a window isn't being shown: a page staged under a space swipe joins one too. It
		// takes the keyboard when it's installed, clicked or focused.
		guard let window else { return }

		responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
			Task { @MainActor [weak self] in self?.reclaimKeyboard() }
		}
	}

	override internal func updateTrackingAreas() {
		if let trackingArea { removeTrackingArea(trackingArea) }
		let area = NSTrackingArea(
			rect: .zero,
			options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
			owner: self,
			userInfo: nil
		)
		addTrackingArea(area)
		trackingArea = area
		super.updateTrackingAreas()
	}

	override internal func resetCursorRects() {
		addCursorRect(bounds, cursor: cursor)
	}

	override internal func cursorUpdate(with event: NSEvent) {
		isCovered(at: event) ? NSCursor.arrow.set() : cursor.set()
	}

	// MARK: - Mouse

	override internal func mouseMoved(with event: NSEvent) {
		track(event)
	}

	override internal func mouseDragged(with event: NSEvent) {
		track(event)
	}

	override internal func mouseEntered(with event: NSEvent) {
		track(event)
	}

	override internal func mouseExited(with event: NSEvent) {
		pointerIsCovered = false
		pending.append(.leave)
	}

	/// The pointer over the page, unless something the window draws over the page is under it,
	/// such as Hide Element's toast (DEV-1315): a tracking area hears the pointer through
	/// whatever covers its view, so without this the page outlined what lay under the toast, and
	/// the toast moved out from under the pointer, or faded, just as it went to click it. There
	/// the pointer has left the page: nothing is outlined, and the pointer is the arrow.
	private func track(_ event: NSEvent) {
		let covered = isCovered(at: event)
		defer { pointerIsCovered = covered }
		guard !covered else {
			if !pointerIsCovered {
				pending.append(.leave)
				NSCursor.arrow.set()
			}
			return
		}

		if pointerIsCovered { cursor.set() }
		pending.append(.pointer(location(of: event)))
	}

	/// Whether the window's own hit-testing finds something other than this view at the event,
	/// such as a control floating over the page.
	private func isCovered(at event: NSEvent) -> Bool {
		guard let content = window?.contentView else { return false }

		// The frame view's points are the window's.
		let root = content.superview ?? content
		let point = root.superview.map { $0.convert(event.locationInWindow, from: nil) } ?? event.locationInWindow
		guard let hit = root.hitTest(point) else { return false }

		return hit !== self && !hit.isDescendant(of: self)
	}

	override internal func mouseDown(with event: NSEvent) {
		takeKeyboard()

		// A Control-click is a secondary click, which leaves.
		if event.modifierFlags.contains(.control) {
			pressedAt = nil
			pending.append(.menu)
			return
		}
		pressedAt = location(of: event)
	}

	/// A press and release in about the same place picks; a drag doesn't.
	override internal func mouseUp(with event: NSEvent) {
		let point = location(of: event)
		defer { pressedAt = nil }
		guard let pressedAt, hypot(point.x - pressedAt.x, point.y - pressedAt.y) <= 4
		else { return }

		pending.append(.click(point))
	}

	override internal func rightMouseDown(with event: NSEvent) {
		takeKeyboard()
		pending.append(.menu)
	}

	override internal func rightMouseUp(with event: NSEvent) {}

	override internal func otherMouseDown(with event: NSEvent) {}

	override internal func otherMouseUp(with event: NSEvent) {}

	// MARK: - Scrolling

	override internal func scrollWheel(with event: NSEvent) {
		pageView(at: event)?.scrollWheel(with: event)
		refreshNowAndSoon()
	}

	/// The page moves a moment after the wheel or the pinch does: look now and again once it has.
	private func refreshNowAndSoon() {
		pending.append(.refresh)
		refreshAfterScroll?.cancel()
		refreshAfterScroll = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .milliseconds(150))
			guard !Task.isCancelled else { return }
			self?.pending.append(.refresh)
		}
	}

	override internal func magnify(with event: NSEvent) {
		pageView(at: event)?.magnify(with: event)
		refreshNowAndSoon()
	}

	override internal func smartMagnify(with event: NSEvent) {
		pageView(at: event)?.smartMagnify(with: event)
		refreshNowAndSoon()
	}

	// MARK: - Keys

	/// Esc leaves, ↑ and ↓ widen and narrow, Return picks. Other keys go nowhere, so the page
	/// doesn't get them either; menu shortcuts still work, since they're matched before this.
	override internal func keyDown(with event: NSEvent) {
		if takesAppKeys {
			handleModeKey(event)
			return
		}
		switch event.keyCode {
		case 53: pending.append(.key("Escape"))
		case 126: pending.append(.key("ArrowUp"))
		case 125: pending.append(.key("ArrowDown"))
		case 36, 76: pending.append(.key("Enter"))
		default: break
		}
	}

	/// Hide Element's mode (DEV-1298): Esc is Done, Return opens and closes the list, Space hides
	/// what's outlined; ↑ and ↓ widen and narrow, or move through the list while it's open, where
	/// Delete shows the element again.
	private func handleModeKey(_ event: NSEvent) {
		let handler: (ChromiumElementPicker.Key) -> Void = { [weak self] key in self?.pending.append(.app(key)) }
		let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
		switch event.keyCode {
		case 53: handler(.escape)
		case 36, 76: handler(.return)
		case 49 where modifiers.isEmpty: pending.append(.key("Enter"))
		case 126: listIsOpen ? handler(.up) : pending.append(.key("ArrowUp"))
		case 125: listIsOpen ? handler(.down) : pending.append(.key("ArrowDown"))
		case 51, 117: if listIsOpen { handler(.delete) }
		default: break
		}
	}

	/// ⌘Z is Undo in Hide Element's mode while this view has the keyboard: it's answered here,
	/// before the menu bar's Edit › Undo, which would take back the window's last organization
	/// change (DEV-1298).
	override internal func performKeyEquivalent(with event: NSEvent) -> Bool {
		guard
			takesAppKeys,
			let window,
			window.firstResponder === self,
			event.type == .keyDown,
			event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
			event.charactersIgnoringModifiers?.lowercased() == "z"
		else { return super.performKeyEquivalent(with: event) }

		pending.append(.app(.undo))
		return true
	}

	/// Edit › Undo from the menu, which the app sends down the responder chain to this view.
	@objc
	internal func undo(_ sender: Any?) {
		if takesAppKeys { pending.append(.app(.undo)) }
	}

	override internal func keyUp(with event: NSEvent) {}

	override internal func flagsChanged(with event: NSEvent) {}

	// MARK: - Helpers

	/// Keeps the first thing it took the keyboard from, to give it back to.
	private func takeKeyboard() {
		guard let window, window.firstResponder !== self else { return }
		if previousResponder == nil, !(window.firstResponder is ChromiumElementPickerInput) {
			previousResponder = window.firstResponder
		}
		window.makeFirstResponder(self)
	}

	/// The keyboard went to the page's own view, or to the page itself: it's the picker's.
	private func reclaimKeyboard() {
		guard
			let window,
			let page = superview,
			let responder = window.firstResponder as? NSView,
			responder !== self,
			responder === page || responder.isDescendant(of: page)
		else { return }

		window.makeFirstResponder(self)
	}

	private func location(of event: NSEvent) -> CGPoint {
		convert(event.locationInWindow, from: nil)
	}

	/// The page's own view under the event, which scrolls and zooms as it would without this
	/// one over it.
	private func pageView(at event: NSEvent) -> NSView? {
		guard let host = superview else { return nil }

		let point = convert(location(of: event), to: host)
		let page = host.subviews.filter { !($0 is ChromiumElementPickerInput) && !$0.isHidden }
		for view in page.reversed() {
			if let hit = view.hitTest(point) { return hit }
		}
		return page.last ?? host
	}
}

extension ChromiumElementPickerInput: NSMenuItemValidation {
	internal func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		menuItem.action == #selector(undo(_:)) ? takesAppKeys : true
	}
}
