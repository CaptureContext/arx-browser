import Foundation

/// The keys a focused page gets before Arx (DEV-1264, DEV-1073), stated in one place.
///
/// Every key stays Arx's while its command's Conflict resolution is Arx (DEV-1332): its menu bar and
/// commands match a key before the page sees it, as Chrome keeps ⌘T, ⌘W, ⌘N and ⌘Q. Site and Both
/// give the page the key first, and Delayed gives it after a moment unless pressed again. The engine
/// reports whether the page used the key (preventDefault); a key the page left runs Arx's command
/// at once.
public enum PageFirstKey: Equatable, Hashable, Sendable {
	/// A command's current shortcut, whatever it's bound to, while its resolution isn't Arx.
	case command(BrowserCommand)

	/// ⌘Z, while no text is being edited in the page. Text keeps its own undo.
	case undo

	/// ⇧⌘Z, likewise.
	case redo

	/// What happens once the page used the key.
	public var rule: Rule {
		switch self {
		case .command: .secondPress
		case .undo, .redo: .settledFocus
		}
	}

	public enum Rule: Equatable, Sendable {
		/// Arx shows a toast, and pressing the key again right away runs Arx's command.
		case secondPress

		/// The page keeps the key once the person has been on it for more than
		/// `settledFocusInterval`; before that it's `secondPress`. ⌘Z and ⇧⌘Z are too common for
		/// a toast on every press in a canvas editor.
		case settledFocus
	}

	/// How long a page must have had focus before it keeps ⌘Z and ⇧⌘Z without a toast.
	public static let settledFocusInterval: TimeInterval = 2
}
