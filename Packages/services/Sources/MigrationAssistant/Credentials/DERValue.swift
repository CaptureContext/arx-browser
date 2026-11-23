import Foundation

/// The few DER (ASN.1) shapes NSS stores its encrypted values in (DEV-896): sequences,
/// octet strings, object identifiers and integers. Anything else is kept as raw bytes.
internal indirect enum DERValue: Equatable, Sendable {
	case sequence([DERValue])
	case octetString(Data)
	case objectIdentifier(String)
	case integer(Data)
	case null
	case other(tag: UInt8, Data)

	internal enum Failure: Error, Equatable, Sendable {
		case malformed
	}

	/// Parses one value that fills `data` exactly.
	internal static func parse(_ data: Data) throws(Failure) -> Self {
		var reader: Reader = .init(bytes: [UInt8](data))
		let value = try reader.value()
		guard reader.isAtEnd else { throw .malformed }

		return value
	}

	internal var children: [DERValue] {
		if case let .sequence(values) = self { return values }
		return []
	}

	internal var octets: Data? {
		if case let .octetString(data) = self { return data }
		return nil
	}

	internal var identifier: String? {
		if case let .objectIdentifier(value) = self { return value }
		return nil
	}

	/// A non-negative integer that fits in `Int`.
	internal var intValue: Int? {
		guard case let .integer(data) = self, !data.isEmpty, data.count <= 8 else { return nil }
		guard data.first.map({ $0 & 0x80 == 0 }) == true else { return nil }

		return data.reduce(0) { ($0 << 8) | Int($1) }
	}

	/// The child at `index`, or `.null` when there's none, so lookups chain.
	internal subscript(_ index: Int) -> DERValue {
		let values = children
		return values.indices.contains(index) ? values[index] : .null
	}

	private struct Reader {
		internal var bytes: [UInt8]
		internal var offset: Int = 0

		internal var isAtEnd: Bool { offset == bytes.count }

		internal mutating func value() throws(Failure) -> DERValue {
			let tag = try byte()
			let length = try self.length()
			guard length <= bytes.count - offset else { throw .malformed }

			let content = Array(bytes[offset..<offset + length])
			offset += length
			switch tag {
			case 0x30:
				var nested: Reader = .init(bytes: content)
				var values: [DERValue] = []
				while !nested.isAtEnd {
					values.append(try nested.value())
				}
				return .sequence(values)

			case 0x04:
				return .octetString(Data(content))

			case 0x06:
				return .objectIdentifier(try Self.identifier(content))

			case 0x02:
				return .integer(Data(content))

			case 0x05:
				return .null

			default:
				return .other(tag: tag, Data(content))
			}
		}

		private mutating func byte() throws(Failure) -> UInt8 {
			guard offset < bytes.count else { throw .malformed }

			defer { offset += 1 }
			return bytes[offset]
		}

		private mutating func length() throws(Failure) -> Int {
			let first = try byte()
			guard first & 0x80 != 0 else { return Int(first) }

			let count = Int(first & 0x7F)
			guard (1...4).contains(count) else { throw .malformed }

			var length: Int = 0
			for _ in 0..<count {
				length = (length << 8) | Int(try byte())
			}
			return length
		}

		private static func identifier(_ content: [UInt8]) throws(Failure) -> String {
			guard let first = content.first else { throw .malformed }

			var parts: [String] = ["\(first / 40)", "\(first % 40)"]
			var value: Int = 0
			for byte in content.dropFirst() {
				guard value < Int.max >> 7 else { throw .malformed }

				value = (value << 7) | Int(byte & 0x7F)
				if byte & 0x80 == 0 {
					parts.append("\(value)")
					value = 0
				}
			}
			guard content.last.map({ $0 & 0x80 == 0 }) == true else { throw .malformed }

			return parts.joined(separator: ".")
		}
	}
}
