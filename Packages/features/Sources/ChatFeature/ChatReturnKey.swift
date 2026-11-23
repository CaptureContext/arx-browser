import Foundation
import _ComposableArchitecture

/// What plain Return does in the chat composer, from Settings › Assistant (DEV-798).
/// Shift-Return always starts a new line and ⌘Return always sends, whatever this says.
public enum ChatReturnKeyBehavior: String, CaseIterable, Codable, Sendable {
	/// Return sends.
	case send

	/// Return starts a new line; ⌘Return sends.
	case newLine

	/// Return sends a one-line message and starts a new line once the message has several.
	case sendOneLiners
}

/// What a press of Return does in the composer.
public enum ChatReturnKeyAction: Equatable, Sendable {
	case send
	case newLine
}

extension ChatReturnKeyBehavior {
	/// What Return with `modifiers` does to `draft`.
	public func action(
		modifiers: ChatReturnKeyModifiers,
		draft: String
	) -> ChatReturnKeyAction {
		if modifiers.contains(.command) { return .send }
		if modifiers.contains(.shift) || modifiers.contains(.option) { return .newLine }

		switch self {
		case .send:
			return .send

		case .newLine:
			return .newLine

		case .sendOneLiners:
			return draft.contains(where: \.isNewline) ? .newLine : .send
		}
	}
}

/// The modifier keys held with Return.
public struct ChatReturnKeyModifiers: OptionSet, Hashable, Sendable {
	public let rawValue: Int

	public init(rawValue: Int) {
		self.rawValue = rawValue
	}

	public static let shift: Self = .init(rawValue: 1 << 0)
	public static let command: Self = .init(rawValue: 1 << 1)
	public static let option: Self = .init(rawValue: 1 << 2)
}

extension SharedKey where Self == AppStorageKey<ChatReturnKeyBehavior>.Default {
	/// Settings › Assistant › Return key. App-wide: it's how the person types, not a profile's data.
	public static var chatReturnKey: Self {
		Self[.appStorage("chatReturnKeyBehavior"), default: .send]
	}
}
