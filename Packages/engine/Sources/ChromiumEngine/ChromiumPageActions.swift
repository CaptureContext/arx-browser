import ChromiumBridge
import CoreGraphics
import Foundation

/// ABI48 (DEV-828). How running an extension's toolbar action for a page went.
public enum ChromiumExtensionActionRun: Equatable, Sendable {
	/// The extension's popup is opening at the point.
	case popup

	/// The action had no popup; the extension got its click.
	case clicked
}

/// ABI48 (DEV-828). Why an extension's action didn't run.
public enum ChromiumExtensionActionFailure: Error, Equatable, Sendable {
	/// The page can't run actions now: private with no loaded opener, hidden, between documents,
	/// or no engine support.
	case unavailable

	/// No enabled extension with that ID and a visible action on the page.
	case invalid

	/// Chromium wouldn't run it here: a page reload is needed first, or it opens a side panel.
	case refused
}

/// ABI48 (DEV-819). The kind of document a page shows.
public enum ChromiumDocumentType: Equatable, Sendable {
	case web

	/// The PDF viewer hosts it, also while it's still loading.
	case pdf
}

/// ABI48 (DEV-828, DEV-819): the engine's page-level calls for extension actions and
/// document types, validated before they reach native and mapped after.
internal struct ChromiumPageActions {
	private let api: ArxEngineAPI

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var supportsExtensionActions: Bool {
		api.run_extension_action != nil
	}

	internal var supportsDocumentTypes: Bool {
		api.page_document_type != nil
	}

	/// `point` is in AppKit screen coordinates, origin at the primary screen's bottom left.
	internal func runExtensionAction(
		page: UInt64,
		extensionID: String,
		at point: CGPoint
	) throws(ChromiumExtensionActionFailure) -> ChromiumExtensionActionRun {
		guard let run = api.run_extension_action else { throw .unavailable }
		guard
			ChromiumExtension.validID(extensionID),
			point.x.isFinite,
			point.y.isFinite
		else { throw .invalid }

		let status = run(page, extensionID, Double(point.x), Double(point.y))
		switch status {
		case ARX_EXTENSION_ACTION_RUN_POPUP: return .popup
		case ARX_EXTENSION_ACTION_RUN_CLICKED: return .clicked
		case ARX_EXTENSION_ACTION_RUN_INVALID: throw .invalid
		case ARX_EXTENSION_ACTION_RUN_REFUSED: throw .refused
		default: throw .unavailable
		}
	}

	/// False without an ABI50 engine: nothing is known to be current.
	internal func externalLinkIsCurrent(
		page: UInt64,
		token: UInt64
	) -> Bool {
		guard let read = api.external_link_is_current else { return false }
		return read(page, token)
	}

	/// Nil when the engine can't tell, or the page has no committed document.
	internal func documentType(page: UInt64) -> ChromiumDocumentType? {
		guard let read = api.page_document_type else { return nil }

		switch read(page) {
		case ARX_PAGE_DOCUMENT_WEB: return .web
		case ARX_PAGE_DOCUMENT_PDF: return .pdf
		default: return nil
		}
	}
}

extension ChromiumRuntime {
	/// ABI48 (DEV-828): whether the app can run an extension's action for a page.
	public var supportsExtensionActions: Bool {
		state == .running && ChromiumPageActions(api: api).supportsExtensionActions
	}

	/// Runs an extension's toolbar action for a page, as a click on its toolbar button: its
	/// popup opens anchored at `point` (AppKit screen coordinates), or the extension gets the
	/// click. Only for the person's own click. A private page runs its opener's extensions
	/// allowed in private windows (DEV-956); the engine refuses the rest, as older engines
	/// refuse every private page.
	public func runExtensionAction(
		_ extensionID: String,
		on page: ChromiumPage,
		at point: CGPoint
	) throws(ChromiumExtensionActionFailure) -> ChromiumExtensionActionRun {
		guard state == .running, isCurrent(page) else { throw .unavailable }
		return try ChromiumPageActions(api: api).runExtensionAction(
			page: page.id,
			extensionID: extensionID,
			at: point
		)
	}

	/// ABI48 (DEV-819): whether the engine tells a page's document type.
	public var supportsDocumentTypes: Bool {
		state == .running && ChromiumPageActions(api: api).supportsDocumentTypes
	}

	/// The kind of the page's committed main document, known for a PDF before it has
	/// loaded. Nil when the engine can't tell or nothing has committed yet.
	public func documentType(of page: ChromiumPage) -> ChromiumDocumentType? {
		guard state == .running, isCurrent(page) else { return nil }
		return ChromiumPageActions(api: api).documentType(page: page.id)
	}

	/// ABI50 (DEV-857): whether the link `page` took last with `token` still comes from a
	/// current source: the same document, and the frame that asked is still there. Check it
	/// right before running a handler's script or opening the app.
	public func isExternalLinkCurrent(
		_ page: ChromiumPage,
		token: UInt64
	) -> Bool {
		guard state == .running, isCurrent(page) else { return false }
		return ChromiumPageActions(api: api).externalLinkIsCurrent(page: page.id, token: token)
	}
}
