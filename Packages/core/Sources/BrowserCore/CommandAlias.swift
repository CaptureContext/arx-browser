import Foundation

/// A word that finds a command in the command bar, such as `pin` for Pin Tab.
///
/// Aliases are stored lowercased, without spaces, and never start with `!`, which bangs use.
public struct CommandAlias: Codable, Equatable, Sendable {
	public var command: BrowserCommand
	public var alias: String

	public init(
		command: BrowserCommand,
		alias: String
	) {
		self.command = command
		self.alias = alias
	}

	/// `text` as an alias: trimmed and lowercased, or `nil` when nothing is left.
	public static func normalized(_ text: String) -> String? {
		let alias = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		return alias.isEmpty ? nil : alias
	}

	public enum Failure: Error, Equatable, Sendable {
		/// Empty, with a space, or starting with `!`.
		case invalidAlias

		/// Another command already has it.
		case duplicateAlias
	}

	public var isValid: Bool {
		!alias.isEmpty
		&& alias == alias.lowercased()
		&& !alias.contains(where: \.isWhitespace)
		&& !alias.hasPrefix("!")
	}
}

extension Array where Element == CommandAlias {
	public func alias(for command: BrowserCommand) -> String? {
		first { $0.command == command }?.alias
	}

	/// The command `alias` finds, ignoring case.
	public func command(forAlias alias: String) -> BrowserCommand? {
		guard let alias = CommandAlias.normalized(alias) else { return nil }
		return first { $0.alias == alias }?.command
	}

	/// Gives `command` its alias, or removes it for `nil`.
	public mutating func setAlias(
		_ alias: String?,
		for command: BrowserCommand
	) {
		removeAll { $0.command == command }
		if let alias { append(.init(command: command, alias: alias)) }
	}

	public func validate() throws {
		var commands: Set<BrowserCommand> = []
		var aliases: Set<String> = []
		for entry in self {
			guard entry.isValid else { throw CommandAlias.Failure.invalidAlias }
			guard
				commands.insert(entry.command).inserted,
				aliases.insert(entry.alias).inserted
			else { throw CommandAlias.Failure.duplicateAlias }
		}
	}
}
