import ChromiumBridge
import Foundation

/// ABI31. A JavaScript dialog the page is showing, or Arx's permission sheet for it.
public struct ChromiumPageDialog: Equatable, Sendable {
	public enum Kind: Equatable, Sendable {
		case alert
		case confirm
		case prompt
		case beforeUnload
		case permission
	}

	public let token: UInt64
	public let kind: Kind

	/// Untrusted page text, or Chromium's wording for a permission.
	public let message: String
	public let defaultPrompt: String
	public let origin: String

	public init(
		token: UInt64,
		kind: Kind,
		message: String,
		defaultPrompt: String,
		origin: String
	) {
		self.token = token
		self.kind = kind
		self.message = message
		self.defaultPrompt = defaultPrompt
		self.origin = origin
	}
}

public enum ChromiumPageDialogFailure: Error, Equatable, Sendable {
	/// Already answered, by the user perhaps, or replaced by another dialog.
	case stale

	/// Prompt text for a dialog that takes none, or too long.
	case invalid
	case unavailable
}

extension ChromiumPage {
	/// The dialog the page is showing, if any.
	public func dialog() -> ChromiumPageDialog? {
		let value = openOwner?.performIfOpen(on: self) { api, id -> ChromiumPageDialog? in

			// An engine without dialog support has none to show.
			guard let read = api.page_dialog else { return nil }
			var dialog = ArxPageDialog()
			guard read(id, &dialog) else { return nil }
			let kind: ChromiumPageDialog.Kind
			switch dialog.kind {
			case ARX_PAGE_DIALOG_ALERT: kind = .alert
			case ARX_PAGE_DIALOG_CONFIRM: kind = .confirm
			case ARX_PAGE_DIALOG_PROMPT: kind = .prompt
			case ARX_PAGE_DIALOG_BEFORE_UNLOAD: kind = .beforeUnload
			case ARX_PAGE_DIALOG_PERMISSION: kind = .permission
			default: return nil
			}
			return ChromiumPageDialog(
				token: dialog.token,
				kind: kind,
				message: dialog.message.map { String(cString: $0) } ?? "",
				defaultPrompt: dialog.default_prompt.map { String(cString: $0) } ?? "",
				origin: dialog.origin.map { String(cString: $0) } ?? ""
			)
		}
		return value ?? nil
	}

	/// Accepts or dismisses that exact dialog. `text` answers an accepted prompt.
	public func answerDialog(
		_ dialog: ChromiumPageDialog,
		accept: Bool,
		text: String? = nil
	) throws(ChromiumPageDialogFailure) {
		let status: ArxPageDialogStatus
		do {
			status = try owner().perform(on: self) { api, id in
				guard let answer = api.answer_page_dialog else { throw ChromiumError.incompatibleBridge }
				guard let text else { return answer(id, dialog.token, accept, nil) }
				return text.withCString { answer(id, dialog.token, accept, $0) }
			}
		} catch {
			throw .unavailable
		}
		switch status {
		case ARX_PAGE_DIALOG_OK: return
		case ARX_PAGE_DIALOG_INVALID: throw .invalid
		default: throw .stale
		}
	}
}
