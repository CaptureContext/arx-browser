import Foundation
import MCP

extension Value {
	/// The value `Value(_:)` makes of `value`, built from Foundation's JSON parser.
	///
	/// The SDK's own initializer decodes its JSON again through `Value.init(from:)`, which tries
	/// each kind in turn for every node and fails up to four decodes before it finds a string.
	/// A 100-item inventory page took tens of milliseconds that way, more than everything else a
	/// call does (DEV-934). This reads the same JSON with `JSONSerialization` instead. Strings stay
	/// strings: data URLs, which the SDK turns into `.data`, encode to the same text either way.
	internal init(encoding value: some Encodable) throws {
		if let value = value as? Value {
			self = value
			return
		}
		let data = try JSONEncoder().encode(value)
		self = Self(json: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
	}

	private init(json: Any) {
		switch json {
		case let string as String:
			self = .string(string)

		case let number as NSNumber:
			self = Self(number: number)

		case let array as [Any]:
			self = .array(array.map(Self.init(json:)))

		case let object as [String: Any]:
			self = .object(object.mapValues(Self.init(json:)))

		default:
			self = .null
		}
	}

	/// Matches `Value.init(from:)`: a boolean, then an integer that fits `Int`, then a double.
	private init(number: NSNumber) {
		let isUnsignedOverflow = String(cString: number.objCType) == "Q" && number.uint64Value > UInt64(Int.max)
		if CFGetTypeID(number) == CFBooleanGetTypeID() {
			self = .bool(number.boolValue)
		} else if CFNumberIsFloatType(number) || isUnsignedOverflow {
			self = .double(number.doubleValue)
		} else {
			self = .int(number.intValue)
		}
	}
}
