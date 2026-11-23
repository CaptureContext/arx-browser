import AppKit

/// A press on a floating window's header that turns into a drag moves the window, whatever it
/// started on: the URL bar, a button or the background. Its release then never reaches the
/// control, while a click that doesn't move past `threshold` still works (DEV-1247).
///
/// Little Arx and Page PiP both run their header's mouse events through one of these from
/// `sendEvent(_:)`, so the two windows can't drift apart again. The decisions are plain values,
/// tested on their own; `filter(_:in:)` is the AppKit glue.
public struct WindowControlDrag: Equatable, Sendable {
	/// How far the mouse travels, in points, before a press becomes a drag.
	public static let threshold: CGFloat = 4

	public enum Decision: Equatable, Sendable {
		/// The window handles the event as usual.
		case deliver

		/// The press became a drag that started at this screen point: the control's press is
		/// cancelled and the window moves.
		case startDrag(from: CGPoint)

		/// Part of a drag the window already moved: nothing gets it.
		case drop
	}

	private enum Phase: Equatable, Sendable {
		case idle
		case pressed(at: CGPoint)
		case dragging
	}

	private var phase: Phase = .idle

	public init() {}

	/// Whether a press is being watched or a drag is under way.
	public var isTracking: Bool { phase != .idle }

	/// A press at `point`, in screen coordinates. Only a press on the header is watched.
	public mutating func mouseDown(
		at point: CGPoint,
		onHeader: Bool
	) -> Decision {
		phase = onHeader ? .pressed(at: point) : .idle
		return .deliver
	}

	/// The mouse moved to `point` with the button down.
	public mutating func mouseDragged(to point: CGPoint) -> Decision {
		switch phase {
		case .idle:
			return .deliver

		case let .pressed(start):
			guard hypot(point.x - start.x, point.y - start.y) >= Self.threshold else { return .deliver }
			phase = .dragging
			return .startDrag(from: start)

		case .dragging:
			return .drop
		}
	}

	/// The button came up. After a drag it never reaches the control. A move loop that took the
	/// release leaves the drag to end with the next press.
	public mutating func mouseUp() -> Decision {
		defer { phase = .idle }
		return phase == .dragging ? .drop : .deliver
	}
}

extension WindowControlDrag {
	/// Where a press lands in `window`, for `filter(_:in:)`.
	public struct Header: Equatable, Sendable {
		/// How tall the header is, from the top of the content.
		public var height: CGFloat

		/// The window shows no header now (page full screen, the launcher bar).
		public var isHidden: Bool

		public init(
			height: CGFloat,
			isHidden: Bool = false
		) {
			self.height = height
			self.isHidden = isHidden
		}
	}

	/// Runs `event` through the drag. Returns whether the window should handle it as usual.
	///
	/// - Parameters:
	///   - send: Hands an event to the window's own `sendEvent(_:)`, past this filter, to cancel
	///     the control's press.
	///   - move: Moves the window for a drag that started at the screen point, returning once the
	///     button is up, as `follow(_:from:)` does.
	@MainActor
	public mutating func filter(
		_ event: NSEvent,
		in window: NSWindow,
		header: Header,
		send: (NSEvent) -> Void,
		move: (NSEvent, CGPoint) -> Void
	) -> Bool {
		switch event.type {
		case .leftMouseDown:
			let point = window.convertPoint(toScreen: event.locationInWindow)
			return mouseDown(at: point, onHeader: isOnHeader(event, in: window, header: header)) == .deliver

		case .leftMouseDragged:
			switch mouseDragged(to: NSEvent.mouseLocation) {
			case .deliver:
				return true

			case let .startDrag(start):
				// The control sees its press end outside itself, so it doesn't act.
				if let cancel = Self.cancellation(of: event, in: window) { send(cancel) }

				// The move loop takes the release; one that ends without it leaves it to be dropped.
				move(event, start)
				return false

			case .drop:
				return false
			}

		case .leftMouseUp:
			return mouseUp() == .deliver

		default:
			return true
		}
	}

	/// Moves `window` 1:1 with the mouse from `start`, a screen point, until the button is up:
	/// Little Arx's move once a press on its header became a drag.
	@MainActor
	public static func follow(
		_ window: NSWindow,
		from start: CGPoint
	) {
		let origin = window.frame.origin
		func move() {
			let mouse = NSEvent.mouseLocation
			window.setFrameOrigin(.init(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y))
		}

		// The mouse has already left the press's point: the window catches up first.
		move()
		while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
			move()
			if next.type == .leftMouseUp { return }
		}
	}

	/// On the header and not in text being edited, where a drag selects text instead.
	@MainActor
	private func isOnHeader(
		_ event: NSEvent,
		in window: NSWindow,
		header: Header
	) -> Bool {
		guard
			!header.isHidden,
			!window.styleMask.contains(.fullScreen),
			let content = window.contentView
		else { return false }

		let point = content.convert(event.locationInWindow, from: nil)
		let fromTop = content.isFlipped ? point.y : content.bounds.height - point.y
		guard fromTop >= 0, fromTop <= header.height else { return false }

		return !(content.hitTest(point) is NSText)
	}

	/// A mouse up far outside the window, ending the control's press without its action.
	@MainActor
	private static func cancellation(
		of event: NSEvent,
		in window: NSWindow
	) -> NSEvent? {
		NSEvent.mouseEvent(
			with: .leftMouseUp,
			location: .init(x: -100_000, y: -100_000),
			modifierFlags: event.modifierFlags,
			timestamp: event.timestamp,
			windowNumber: window.windowNumber,
			context: nil,
			eventNumber: event.eventNumber,
			clickCount: 1,
			pressure: 0
		)
	}
}
