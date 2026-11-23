import Foundation

/// How Arx's own element picker ended on a tab (DEV-1201).
public enum BrowserElementPick: Equatable, Sendable {
	/// The engine can't run it on the tab's page.
	case unavailable

	/// Esc, ⇧⌘H again, or the page went away, with nothing picked.
	case closed

	/// The element went, and `filter`, `site##selector`, is on its way into My filters.
	case hidden(filter: String)

	/// The element went from the page, but the engine wouldn't save `filter`.
	case refused(filter: String)
}
