import BrowserCore
import Foundation

/// JSON for text columns: sorted keys, so an unchanged value is always the same text and the diff
/// writer never rewrites it. Saved appearance overrides use their storage coding (DEV-1170).
internal enum JSONColumn {
	internal static func encode<Value: Encodable>(_ value: Value) throws -> String {
		let encoder: JSONEncoder = .init()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		encoder.userInfo[AppearanceOverride.storageCoding] = true
		return String(decoding: try encoder.encode(value), as: UTF8.self)
	}

	internal static func encode<Value: Encodable>(_ value: Value?) throws -> String? {
		try value.map { try encode($0) }
	}

	internal static func decode<Value: Decodable>(
		_ type: Value.Type,
		from text: String
	) throws -> Value {
		let decoder: JSONDecoder = .init()
		decoder.userInfo[AppearanceOverride.storageCoding] = true
		return try decoder.decode(type, from: Data(text.utf8))
	}

	internal static func decode<Value: Decodable>(
		_ type: Value.Type,
		from text: String?
	) throws -> Value? {
		try text.map { try decode(type, from: $0) }
	}

	/// Re-serializes a JSON fragment from `JSONSerialization` with sorted keys.
	internal static func serialize(_ object: Any) throws -> String {
		let data: Data = try JSONSerialization.data(
			withJSONObject: object,
			options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
		)
		return String(decoding: data, as: UTF8.self)
	}

	internal static func deserialize(_ text: String) throws -> Any {
		try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
	}
}
