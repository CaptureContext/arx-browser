import Foundation

/// A JavaScript dialog a page is showing, or Arx's permission sheet for it.
public struct BrowserPageDialog: Codable, Equatable, Sendable {
	public enum Kind: String, Codable, CaseIterable, Sendable {
		case alert
		case confirm
		case prompt
		case beforeUnload
		case permission
	}

	/// Binds an answer to this exact dialog; a later dialog has another token.
	public var token: String
	public var kind: Kind

	/// Untrusted page text (Chromium's own wording for a permission).
	public var message: String

	/// A prompt's default text, untrusted page data.
	public var defaultPrompt: String?

	/// The requesting origin of a permission, formatted by Chromium.
	public var origin: String?

	public init(
		token: String,
		kind: Kind,
		message: String,
		defaultPrompt: String? = nil,
		origin: String? = nil
	) {
		self.token = token
		self.kind = kind
		self.message = message
		self.defaultPrompt = defaultPrompt
		self.origin = origin
	}
}

/// Reads, accepts or dismisses a tab's dialog. Accepting asks the user every
/// time; dismissing doesn't, and never blocks a permission.
public struct AutomationDialogRequest: Codable, Equatable, Sendable {
	public enum Action: String, Codable, CaseIterable, Sendable {
		case read
		case accept
		case dismiss
	}

	public var action: Action
	public var targetID: UUID
	public var expectedRevision: String

	/// Required to accept or dismiss.
	public var operationID: UUID?

	/// The token `read` returned; required to accept or dismiss.
	public var token: String?

	/// An accepted prompt's answer; retained only while pending and never echoed.
	public var text: String?

	public init(
		action: Action,
		targetID: UUID,
		expectedRevision: String,
		operationID: UUID? = nil,
		token: String? = nil,
		text: String? = nil
	) {
		self.action = action
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.operationID = operationID
		self.token = token
		self.text = text
	}

	public func validate() throws {
		let answers = action != .read
		guard
			expectedRevision.utf8.count == 64,
			expectedRevision.allSatisfy(\.isHexDigit),
			answers == (operationID != nil),
			answers == (token.map({ !$0.isEmpty && $0.utf8.count <= 32 }) ?? false),
			text == nil || action == .accept,
			text.map({ $0.utf8.count <= 4_096 && !$0.utf8.contains(0) }) ?? true
		else { throw AutomationFailure.invalidRequest }
	}
}

public struct AutomationDialogResult: Codable, Equatable, Sendable {
	public var targetID: UUID

	/// For `read`: the dialog showing, if any.
	public var dialog: BrowserPageDialog?

	/// For an answer: its operation, whether it reached the dialog, and why not.
	public var operationID: UUID?
	public var answered: Bool
	public var failure: AutomationFailure?

	public init(
		targetID: UUID,
		dialog: BrowserPageDialog? = nil,
		operationID: UUID? = nil,
		answered: Bool = false,
		failure: AutomationFailure? = nil
	) {
		self.targetID = targetID
		self.dialog = dialog
		self.operationID = operationID
		self.answered = answered
		self.failure = failure
	}

	/// A read carries only the dialog; an answer carries only its outcome.
	public func validate() throws {
		if let dialog {
			guard
				operationID == nil,
				!answered,
				failure == nil,
				!dialog.token.isEmpty,
				dialog.token.utf8.count <= 32
			else { throw AutomationFailure.invalidRequest }
			return
		}
		guard operationID == nil || answered == (failure == nil)
		else { throw AutomationFailure.invalidRequest }
	}
}

/// What the engine did with an answer.
public enum BrowserPageDialogAnswer: Equatable, Sendable {
	case answered

	/// The dialog was already answered (by the user, perhaps) or replaced.
	case stale

	/// Prompt text for a dialog that takes none, or too long.
	case invalid
	case denied
	case unavailable
}
