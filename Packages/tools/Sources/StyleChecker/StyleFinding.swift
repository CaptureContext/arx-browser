import Foundation

/// One place where the source departs from a rule.
public struct StyleFinding: Hashable, Sendable {
	public let rule: StyleRule
	public let path: String
	public let line: Int
	public let column: Int
	public let message: String

	public init(
		rule: StyleRule,
		path: String,
		line: Int,
		column: Int,
		message: String
	) {
		self.rule = rule
		self.path = path
		self.line = line
		self.column = column
		self.message = message
	}

	/// The finding as one line of output.
	///
	/// - Parameters:
	///   - format: `.plain` prints `path:line:column: warning: [rule-id] message`, the shape compilers and
	///     editors read; `.github` prints a GitHub workflow command that annotates the line.
	public func formatted(_ format: StyleOutputFormat) -> String {
		switch format {
		case .plain:
			"\(path):\(line):\(column): warning: [\(rule.id)] \(message)"

		case .github:
			"::warning file=\(Self.escapedProperty(path)),line=\(line),col=\(column),"
			+ "title=\(Self.escapedProperty(rule.id))::\(Self.escapedData(message))"
		}
	}

	// Workflow commands treat `%`, carriage returns and newlines specially in the message,
	// and `:` and `,` too in properties.
	private static func escapedData(_ value: String) -> String {
		value
			.replacingOccurrences(of: "%", with: "%25")
			.replacingOccurrences(of: "\r", with: "%0D")
			.replacingOccurrences(of: "\n", with: "%0A")
	}

	private static func escapedProperty(_ value: String) -> String {
		escapedData(value)
			.replacingOccurrences(of: ":", with: "%3A")
			.replacingOccurrences(of: ",", with: "%2C")
	}
}

/// How findings are printed.
public enum StyleOutputFormat: Sendable {
	case plain
	case github
}
