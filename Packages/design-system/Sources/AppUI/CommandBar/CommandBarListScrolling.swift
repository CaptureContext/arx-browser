import AppKit

/// Decides what may move a command bar list besides the person's own scrolling (DEV-1265).
///
/// Both of the bar's lists, its results and ⌘K's actions, highlight the row the pointer is over
/// and scroll the highlight into view. Together, those two fought the trackpad. Rows sliding under
/// a resting pointer as the list scrolled took the highlight, and the list then scrolled to that
/// row. A row reached at the list's edge pulled the list along, which slid another row under the
/// pointer, which took the highlight and pulled it back. Now:
///
/// - the pointer highlights a row only by moving, never by a row sliding under it, and moving
///   within a row that slid under it is enough;
/// - the list scrolls to a highlight only when the keyboard or the bar's host moved it, since the
///   pointer's own highlight is already under the pointer;
/// - while a scroll gesture is in progress, only the keyboard's highlight scrolls the list.
@MainActor
internal final class CommandBarListScrolling {
	/// Whether a scroll gesture or its momentum is moving the list.
	internal var isScrolling: Bool = false

	/// Where the pointer last moved over the list, in screen coordinates. It starts where the
	/// pointer rests as the list opens, so a pointer already over it highlights nothing.
	private var pointerLocation: CGPoint?
	private var pointerHighlight: String?
	private var keyboardHighlight: String?

	internal init(pointerLocation: CGPoint? = NSEvent.mouseLocation) {
		self.pointerLocation = pointerLocation
	}

	/// Whether the pointer, now at `location` over the row `id`, moved there and so may highlight
	/// that row. Rows report the pointer continuously, and also as they slide under it, which
	/// leaves `location` as it was. The caller skips a row that's already the highlight, and the
	/// host may still refuse one, so this keeps no row of its own.
	internal func pointerMoved(
		over id: String,
		at location: CGPoint = NSEvent.mouseLocation
	) -> Bool {
		guard location != pointerLocation else { return false }

		pointerLocation = location
		pointerHighlight = id
		return true
	}

	/// Notes that an arrow key moved the highlight to `id`.
	internal func keyboardMoved(to id: String) {
		keyboardHighlight = id
	}

	/// Whether the list scrolls to `id`, its new highlight. Called once for each change.
	internal func scrolls(to id: String) -> Bool {
		defer {
			pointerHighlight = nil
			keyboardHighlight = nil
		}
		if id == keyboardHighlight { return true }
		return !isScrolling && id != pointerHighlight
	}
}
