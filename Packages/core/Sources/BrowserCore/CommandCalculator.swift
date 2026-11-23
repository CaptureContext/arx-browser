import Foundation

/// The command bar's calculator (DEV-895): typed arithmetic becomes a result row.
///
/// A small recursive-descent evaluator over numbers, `+ - * / ^ %`, `mod`, `x% of y`,
/// factorials, parentheses, the constants `pi`, `e` and `tau`, and a fixed set of functions.
/// It never looks anything up and never runs code: text that isn't an expression it fully
/// understands gives no result, so ordinary searches and addresses stay as they were.
public enum CommandCalculator {
	public struct Result: Equatable, Sendable {
		public var value: Double

		/// The value as it's shown and copied: up to 12 significant digits, no grouping, `.`
		/// as the decimal separator.
		public var text: String

		public init(
			value: Double,
			text: String
		) {
			self.value = value
			self.text = text
		}
	}

	/// The functions it knows, by name, with how many arguments each takes.
	public static let functions: [String: Int] = [
		"abs": 1, "acos": 1, "asin": 1, "atan": 1, "atan2": 2, "cbrt": 1, "ceil": 1, "cos": 1,
		"cosh": 1, "exp": 1, "floor": 1, "hypot": 2, "ln": 1, "log": 1, "log10": 1, "log2": 1,
		"max": 2, "min": 2, "pow": 2, "round": 1, "sign": 1, "sin": 1, "sinh": 1, "sqrt": 1,
		"tan": 1, "tanh": 1, "trunc": 1,
	]

	public static let constants: [String: Double] = [
		"pi": .pi,
		"π": .pi,
		"e": M_E,
		"tau": 2 * .pi,
		"τ": 2 * .pi,
	]

	/// The result of `text`, or nil when it isn't an expression worth a row: anything that
	/// fails to parse, a bare number or a lone `e`, or a result that isn't finite.
	public static func evaluate(_ text: String) -> Result? {
		let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard
			!input.isEmpty,
			input.count <= 200,
			let tokens = tokenize(input),
			isWorthARow(tokens)
		else { return nil }

		var parser: Parser = .init(tokens: tokens)
		guard
			let value = try? parser.expression(),
			parser.isAtEnd,
			value.isFinite
		else { return nil }

		return .init(value: value, text: format(value))
	}

	/// Up to 12 significant digits, without trailing zeros or grouping. `-0` reads as `0`;
	/// very large and very small values use an exponent.
	public static func format(_ value: Double) -> String {
		let value = value == 0 ? 0 : value
		let magnitude = Swift.abs(value)
		if magnitude != 0, magnitude >= 1e15 || magnitude < 1e-9 {
			return String(format: "%.11e", value)
				.replacingOccurrences(of: #"\.?0+e"#, with: "e", options: .regularExpression)
		}

		// Rounding to 12 significant digits first hides binary noise: 0.1 + 0.2 shows 0.3.
		let rounded = Double(String(format: "%.12g", value)) ?? value
		let formatter: NumberFormatter = .init()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.numberStyle = .decimal
		formatter.usesGroupingSeparator = false

		// Enough places for twelve significant digits down to the exponent threshold, 1e-9.
		formatter.maximumFractionDigits = 21
		formatter.minimumIntegerDigits = 1
		return formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
	}

	// MARK: - Tokens

	internal enum Token: Equatable {
		case number(Double)
		case name(String)
		case symbol(Character)
		case of
		case mod
	}

	internal static func tokenize(_ text: String) -> [Token]? {
		var tokens: [Token] = []
		var index = text.startIndex
		while index < text.endIndex {
			let character = text[index]
			if character.isWhitespace {
				index = text.index(after: index)
				continue
			}

			if character.isASCII, character.isNumber || character == "." {
				var end = index
				var hasDot = false
				var hasExponent = false
				while end < text.endIndex {
					let next = text[end]
					if next.isASCII, next.isNumber {
						end = text.index(after: end)
					} else if next == ".", !hasDot, !hasExponent {
						hasDot = true
						end = text.index(after: end)
					} else if next == "e" || next == "E", !hasExponent, isExponent(in: text, at: end) {
						hasExponent = true
						end = text.index(after: end)
						if end < text.endIndex, "+-".contains(text[end]) { end = text.index(after: end) }
					} else {
						break
					}
				}
				guard let value = Double(text[index..<end]) else { return nil }

				tokens.append(.number(value))
				index = end
				continue
			}

			if character.isLetter {
				var end = index
				while end < text.endIndex, text[end].isLetter || (text[end].isASCII && text[end].isNumber) {
					end = text.index(after: end)
				}
				let word = text[index..<end].lowercased()
				switch word {
				case "of": tokens.append(.of)
				case "mod": tokens.append(.mod)
				default:
					guard functions[word] != nil || constants[word] != nil else { return nil }

					tokens.append(.name(word))
				}
				index = end
				continue
			}

			let symbol: Character? = switch character {
			case "+", "-", "*", "/", "^", "%", "(", ")", ",", "!": character
			case "×", "·": "*"
			case "÷": "/"
			case "−": "-"
			default: nil
			}
			guard let symbol else { return nil }

			// `**` is a power, as in many languages.
			if symbol == "*", tokens.last == .symbol("*") {
				tokens[tokens.count - 1] = .symbol("^")
			} else {
				tokens.append(.symbol(symbol))
			}
			index = text.index(after: index)
		}
		return tokens
	}

	/// An `e` after digits starts an exponent only when digits (with an optional sign) follow.
	private static func isExponent(
		in text: String,
		at index: String.Index
	) -> Bool {
		var next = text.index(after: index)
		if next < text.endIndex, "+-".contains(text[next]) { next = text.index(after: next) }
		return next < text.endIndex && text[next].isASCII && text[next].isNumber
	}

	/// An operator, a function, `%` or a constant other than a lone `e`: a bare number such
	/// as a year, or a search for "e", isn't arithmetic.
	private static func isWorthARow(_ tokens: [Token]) -> Bool {
		if tokens.count == 1, case let .name(name) = tokens[0] { return name != "e" }

		return tokens.contains { token in
			switch token {
			case .symbol("("), .symbol(")"), .symbol(","), .number: false
			case .name: tokens.count > 1
			default: true
			}
		}
	}

	// MARK: - Parser

	private enum Failure: Error {
		case invalid
	}

	/// expression := term (("+" | "-") term)*
	/// term       := unary (("*" | "/" | "mod" | "of") unary)*
	/// unary      := ("-" | "+") unary | power
	/// power      := postfix ("^" unary)?
	/// postfix    := primary ("%" | "!")*
	/// primary    := number | constant | function "(" arguments ")" | "(" expression ")"
	private struct Parser {
		internal var tokens: [Token]
		internal var index: Int

		internal init(
			tokens: [Token],
			index: Int = 0
		) {
			self.tokens = tokens
			self.index = index
		}

		internal var isAtEnd: Bool { index == tokens.count }

		private var current: Token? { index < tokens.count ? tokens[index] : nil }

		private mutating func take(_ token: Token) -> Bool {
			guard current == token else { return false }

			index += 1
			return true
		}

		internal mutating func expression() throws -> Double {
			var value = try term()
			while true {
				if take(.symbol("+")) {
					value += try term()
				} else if take(.symbol("-")) {
					value -= try term()
				} else {
					return value
				}
			}
		}

		private mutating func term() throws -> Double {
			var value = try unary()
			while true {
				if take(.symbol("*")) || take(.of) {
					value *= try unary()
				} else if take(.symbol("/")) {
					value /= try unary()
				} else if take(.mod) {
					value = fmod(value, try unary())
				} else {
					return value
				}
			}
		}

		private mutating func unary() throws -> Double {
			if take(.symbol("-")) { return -(try unary()) }
			if take(.symbol("+")) { return try unary() }
			return try power()
		}

		private mutating func power() throws -> Double {
			let base = try postfix()

			// Right-associative, and binding tighter than a leading minus: -2^2 is -4.
			guard take(.symbol("^")) else { return base }

			return pow(base, try unary())
		}

		private mutating func postfix() throws -> Double {
			var value = try primary()
			while true {
				if take(.symbol("%")) {
					value /= 100
				} else if take(.symbol("!")) {
					value = try factorial(value)
				} else {
					return value
				}
			}
		}

		private mutating func primary() throws -> Double {
			guard let token = current else { throw Failure.invalid }

			index += 1
			switch token {
			case let .number(value):
				return value

			case .symbol("("):
				let value = try expression()
				guard take(.symbol(")")) else { throw Failure.invalid }

				return value

			case let .name(name):
				if let arity = CommandCalculator.functions[name] {
					guard take(.symbol("(")) else { throw Failure.invalid }

					var arguments: [Double] = [try expression()]
					while take(.symbol(",")) {
						arguments.append(try expression())
					}
					guard take(.symbol(")")), arguments.count == arity else { throw Failure.invalid }

					return try apply(name, arguments)
				}
				guard let value = CommandCalculator.constants[name] else { throw Failure.invalid }

				return value

			default:
				throw Failure.invalid
			}
		}

		private func factorial(_ value: Double) throws -> Double {
			guard value >= 0, value <= 170, value.rounded() == value else { throw Failure.invalid }

			return (0..<Int(value)).reduce(1) { $0 * Double($1 + 1) }
		}

		private func apply(
			_ name: String,
			_ arguments: [Double]
		) throws -> Double {
			let x = arguments[0]
			let y = arguments.count > 1 ? arguments[1] : 0
			return switch name {
			case "abs": Swift.abs(x)
			case "acos": acos(x)
			case "asin": asin(x)
			case "atan": atan(x)
			case "atan2": atan2(x, y)
			case "cbrt": cbrt(x)
			case "ceil": ceil(x)
			case "cos": cos(x)
			case "cosh": cosh(x)
			case "exp": exp(x)
			case "floor": floor(x)
			case "hypot": hypot(x, y)
			case "ln": log(x)
			case "log", "log10": log10(x)
			case "log2": log2(x)
			case "max": Swift.max(x, y)
			case "min": Swift.min(x, y)
			case "pow": pow(x, y)
			case "round": x.rounded()
			case "sign": x > 0 ? 1 : (x < 0 ? -1 : 0)
			case "sin": sin(x)
			case "sinh": sinh(x)
			case "sqrt": sqrt(x)
			case "tan": tan(x)
			case "tanh": tanh(x)
			case "trunc": trunc(x)
			default: throw Failure.invalid
			}
		}
	}
}
