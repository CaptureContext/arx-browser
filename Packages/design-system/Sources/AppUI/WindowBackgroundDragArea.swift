import AppKit
import SwiftUI

/// A background a floating panel moves by, in the app's own event loop (DEV-1335). Little Arx's
/// launcher bar sits behind its field, rows and pills on one of these.
///
/// SwiftUI's `WindowDragGesture` hands the move to the window server, and the launcher bar, a
/// non-activating panel that closes when it loses the keyboard, lost it as that move began, so it
/// closed instead of moving. Here the panel follows the pointer itself, as Little Arx's header
/// does (`WindowControlDrag.follow`): it keeps the keyboard, and the field keeps its focus, since
/// this view never takes it. A press that doesn't move past `WindowControlDrag.threshold` does
/// nothing.
public struct WindowBackgroundDragArea: NSViewRepresentable {
	public init() {}

	public func makeNSView(context: Context) -> WindowBackgroundDragView {
		WindowBackgroundDragView()
	}

	public func updateNSView(_ view: WindowBackgroundDragView, context: Context) {}
}

/// `WindowBackgroundDragArea`'s view.
public final class WindowBackgroundDragView: NSView {
	public override var acceptsFirstResponder: Bool { false }
	public override var mouseDownCanMoveWindow: Bool { false }

	public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	public override func mouseDown(with event: NSEvent) {
		guard let window else { return }

		Self.track(window, from: event)
	}

	/// One step of a drag: where the pointer is on the screens, and whether the button came up.
	internal struct Step: Equatable {
		internal var location: CGPoint
		internal var isRelease: Bool
	}

	/// A drag's next step, from AppKit's queue, with the pointer's position on the screens: an
	/// event's position in the window would move with the window. Tests hand their steps over
	/// directly, since queued synthetic events end a test host's run early: it never runs
	/// `NSApplication.run()`.
	internal static var nextStep: (NSWindow) -> Step? = { window in
		window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]).map {
			.init(location: NSEvent.mouseLocation, isRelease: $0.type == .leftMouseUp)
		}
	}

	/// Moves `window` with the pointer from the press `down` until the button is up, once the
	/// pointer has gone past the drag threshold. Returns whether it moved.
	@discardableResult
	public static func track(
		_ window: NSWindow,
		from down: NSEvent
	) -> Bool {
		// The window hasn't moved yet, so the press's position in it places it on the screens.
		let start = window.convertPoint(toScreen: down.locationInWindow)
		let origin = window.frame.origin
		var isDragging = false
		while let step = nextStep(window), !step.isRelease {
			let offset = CGVector(dx: step.location.x - start.x, dy: step.location.y - start.y)
			if !isDragging {
				guard hypot(offset.dx, offset.dy) >= WindowControlDrag.threshold else { continue }
				isDragging = true
			}
			window.setFrameOrigin(.init(x: origin.x + offset.dx, y: origin.y + offset.dy))
		}
		return isDragging
	}
}
