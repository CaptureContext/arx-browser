/// Order keys for rows in an ordered list (ADR 0001, section 4).
///
/// A key is a base-62 fraction written with the digits `0-9A-Za-z`, never ending in `0`, so another
/// key always fits between any two. Plain string order (SQLite's `BINARY` collation, Swift's `<` on
/// these ASCII strings) is the list's order; equal keys, from two Macs inserting at the same place,
/// are ordered by ID. A move rewrites one row's key.
public enum FractionalIndex {
	/// Past this length a list's keys are spread out again.
	public static let rebalanceLength: Int = 64

	private static let digits: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
	private static let base: Int = 62

	/// A key strictly between `lower` and `upper`, where `nil` is the start or the end of the list.
	/// Appending and prepending grow keys slowly: one character per about thirty steps.
	public static func key(
		between lower: String?,
		and upper: String?
	) -> String {
		switch (lower, upper) {
		case (nil, nil):
			return string(after([]))

		case let (lower?, nil):
			return string(after(values(lower)))

		case let (nil, upper?):
			return string(before(values(upper)))

		case let (lower?, upper?):
			precondition(lower < upper, "FractionalIndex keys must be ordered")
			return string(midpoint(values(lower), values(upper)))
		}
	}

	/// `count` keys strictly between `lower` and `upper`, in order, splitting the gap in halves so
	/// keys grow by the logarithm of `count`.
	public static func keys(
		_ count: Int,
		between lower: String?,
		and upper: String?
	) -> [String] {
		guard count > 0 else { return [] }

		let middle: Int = count / 2
		let key: String = key(between: lower, and: upper)
		return keys(middle, between: lower, and: key)
		+ [key]
		+ keys(count - middle - 1, between: key, and: upper)
	}

	/// `count` short, evenly spread keys for a whole list.
	public static func evenlySpaced(_ count: Int) -> [String] {
		guard count > 0 else { return [] }

		var length: Int = 1
		var span: Int = base
		while span <= count {
			length += 1
			span *= base
		}
		return (1 ... count).map { index in
			var value: Int = index * span / (count + 1)
			var result: [Int] = .init(repeating: 0, count: length)
			for position in stride(from: length - 1, through: 0, by: -1) {
				result[position] = value % base
				value /= base
			}
			while result.last == 0 { result.removeLast() }
			return string(result)
		}
	}

	/// Whether `key` is a key this type could have made.
	public static func isValid(_ key: String) -> Bool {
		!key.isEmpty && key.last != "0" && key.allSatisfy { digits.contains($0) }
	}

	// MARK: - Digits

	private static func values(_ key: String) -> [Int] {
		key.map { character in
			digits.firstIndex(of: character) ?? 0
		}
	}

	private static func string(_ values: [Int]) -> String {
		String(values.map { digits[$0] })
	}

	/// After `lower`: its first digit plus one, or a longer key once that digit is the largest.
	private static func after(_ lower: [Int]) -> [Int] {
		guard let first = lower.first else { return [base / 2] }

		if first < base - 1 { return [first + 1] }
		return [first] + after(Array(lower.dropFirst()))
	}

	/// Before `upper` (never empty and never ending in zero): its first digit minus one, or a longer key.
	private static func before(_ upper: [Int]) -> [Int] {
		let first: Int = upper[0]
		if first > 1 { return [first - 1] }
		if first == 1 { return upper.count > 1 ? [1] : [0, base - 1] }
		return [0] + before(Array(upper.dropFirst()))
	}

	/// Between `lower` (empty for zero) and `upper`, as in David Greenspan's fractional indexing.
	private static func midpoint(
		_ lower: [Int],
		_ upper: [Int]
	) -> [Int] {
		var shared: Int = 0
		while shared < upper.count, (shared < lower.count ? lower[shared] : 0) == upper[shared] {
			shared += 1
		}
		if shared > 0 {
			return Array(upper.prefix(shared))
			+ midpoint(Array(lower.dropFirst(shared)), Array(upper.dropFirst(shared)))
		}

		let lowerDigit: Int = lower.first ?? 0
		let upperDigit: Int = upper.first ?? base
		if upperDigit - lowerDigit > 1 { return [(lowerDigit + upperDigit + 1) / 2] }
		if upper.count > 1 { return [upper[0]] }
		return [lowerDigit] + after(Array(lower.dropFirst()))
	}
}
