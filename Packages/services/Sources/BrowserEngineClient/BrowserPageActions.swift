import Foundation

/// ABI48 (DEV-819). The kind of document a tab shows.
public enum BrowserDocumentType: Equatable, Sendable {
	case web

	/// Chromium's PDF viewer shows it, also while it's still loading.
	case pdf
}

/// ABI48 (DEV-828). How running an extension's toolbar action went.
public enum BrowserExtensionActionRun: Equatable, Sendable {
	/// Its popup is opening.
	case popup

	/// It has no popup; the extension got the click.
	case clicked
}

/// ABI48 (DEV-828). Why an extension's action didn't run.
public enum BrowserExtensionActionFailure: Error, Equatable, Sendable {
	/// The tab can't run actions now: private, hidden, between documents, or an older engine.
	case unavailable

	/// No enabled extension with that ID and a visible action on the page.
	case invalid

	/// Chromium wouldn't run it here: the page needs a reload first, or it opens a side panel.
	case refused
}
