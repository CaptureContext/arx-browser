import AppKit
import Carbon.HIToolbox

/// Where Edit › Undo (⌘Z) goes with `ARX_WINDOW_UNDO` (DEV-1030).
///
/// Text being edited keeps its own undo: a page's text field or editor, the address field or
/// the chat's box with words in it. Everywhere else ⌘Z takes back the window's last step: a
/// tab closed or moved, a space deleted, an agent's change.
internal enum UndoRoute: Equatable {
	/// The responder chain's `undo:`, for the text or page that has focus.
	case responder

	/// The window's ⌘Z history.
	case window

	/// - Parameters:
	///   - firstResponder: The key window's first responder.
	///   - isSecureInput: Whether secure input is on, as it is while a page's password field has
	///     focus. The field keeps ⌘Z.
	///   - windowCanUndo: Whether the window has a step to take back.
	@MainActor
	internal static func route(
		firstResponder: NSResponder?,
		isSecureInput: Bool,
		windowCanUndo: Bool
	) -> Self {
		guard windowCanUndo, !isSecureInput else { return .responder }

		// Hide Element's mode has the keyboard: ⌘Z shows the last element it hid (DEV-1298).
		if let view = firstResponder as? NSView, view.identifier?.rawValue == hideElementInput {
			return .responder
		}

		if let text = firstResponder as? NSTextView {
			let hasHistory = text.undoManager?.canUndo == true
			return text.isEditable && (hasHistory || !text.string.isEmpty) ? .responder : .window
		}

		// A page's view has an input context only while a text field, a text area or an
		// editable element on the page has focus, so IME and typing reach it; with focus
		// anywhere else on the page it has none.
		if let view = firstResponder as? NSView, view is NSTextInputClient, view.inputContext != nil {
			return .responder
		}
		return .window
	}

	/// The identifier of the view Hide Element's mode lays over a page, which has the keyboard
	/// while the mode is on (`ChromiumElementPicker.inputIdentifier`, DEV-1298).
	internal static let hideElementInput: String = "dev.capturecontext.arx.elementPicker"

	/// The route for the key window as it is now.
	@MainActor
	internal static func current(windowCanUndo: Bool) -> Self {
		route(
			firstResponder: NSApplication.shared.keyWindow?.firstResponder,
			isSecureInput: IsSecureEventInputEnabled(),
			windowCanUndo: windowCanUndo
		)
	}
}
