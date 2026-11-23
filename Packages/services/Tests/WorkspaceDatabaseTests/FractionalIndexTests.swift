import Testing
@testable import WorkspaceDatabase

internal struct FractionalIndexTests {
	@Test
	internal func aKeyFitsBetweenAnyTwo() async throws {
		let pairs: [(String?, String?)] = [
			(nil, nil), (nil, "V"), ("V", nil), ("V", "W"), ("V", "V1"), ("Vz", "W"),
			("1", "2"), (nil, "1"), (nil, "01"), ("z", nil), ("zz", nil), ("a", "a00001"),
		]
		for (lower, upper) in pairs {
			let key: String = FractionalIndex.key(between: lower, and: upper)
			#expect(FractionalIndex.isValid(key), "\(key)")
			if let lower { #expect(lower < key, "\(lower) < \(key)") }
			if let upper { #expect(key < upper, "\(key) < \(upper)") }
		}
	}

	@Test
	internal func appendingAndPrependingStayShort() async throws {
		var appended: [String] = []
		var prepended: [String] = []
		for _ in 0 ..< 1000 {
			appended.append(FractionalIndex.key(between: appended.last, and: nil))
			prepended.insert(FractionalIndex.key(between: nil, and: prepended.first), at: 0)
		}

		#expect(appended == appended.sorted())
		#expect(prepended == prepended.sorted())
		#expect(Set(appended).count == 1000)
		#expect(appended.allSatisfy { $0.count <= 40 })
		#expect(prepended.allSatisfy { $0.count <= 40 })
	}

	@Test
	internal func runsAndSpreadsAreOrderedAndDistinct() async throws {
		for count in [1, 2, 61, 62, 3000] {
			let spread: [String] = FractionalIndex.evenlySpaced(count)
			#expect(spread == spread.sorted())
			#expect(Set(spread).count == count)
			#expect(spread.allSatisfy(FractionalIndex.isValid))
		}
		let run: [String] = FractionalIndex.keys(500, between: "V", and: "W")
		#expect(run == run.sorted())
		#expect(Set(run).count == 500)
		#expect(run.allSatisfy { "V" < $0 && $0 < "W" && $0.count <= 12 })
	}

	// MARK: - Assigning positions

	@Test
	internal func anUnchangedListKeepsEveryKey() async throws {
		let items: [Int] = Array(0 ..< 20)
		let keys: [String] = OrderedPositions.assign(items, previous: [:])

		#expect(keys == FractionalIndex.evenlySpaced(20))
		#expect(OrderedPositions.assign(items, previous: previous(items, keys)) == keys)
	}

	@Test
	internal func aMoveRewritesOnlyTheMovedKey() async throws {
		let items: [Int] = Array(0 ..< 20)
		let keys: [String] = OrderedPositions.assign(items, previous: [:])
		var moved: [Int] = items
		moved.remove(at: 3)
		moved.insert(3, at: 14)

		let next: [String] = OrderedPositions.assign(moved, previous: previous(items, keys))

		#expect(next == next.sorted())
		#expect(changes(items, keys, moved, next) == [3])
	}

	@Test
	internal func insertionsRewriteOnlyTheNewKeys() async throws {
		let items: [Int] = Array(0 ..< 10)
		let keys: [String] = OrderedPositions.assign(items, previous: [:])
		let edited: [Int] = [100] + items.prefix(5) + [101, 102] + items.suffix(5) + [103]

		let next: [String] = OrderedPositions.assign(edited, previous: previous(items, keys))

		#expect(next == next.sorted())
		#expect(changes(items, keys, edited, next) == [100, 101, 102, 103])
	}

	@Test
	internal func keysPastTheLimitAreSpreadAgain() async throws {
		var items: [Int] = [0, 1]
		var keys: [String] = OrderedPositions.assign(items, previous: [:])
		var rebalanced: Bool = false

		// Inserting at the same spot over and over makes the keys there grow.
		for item in 2 ..< 800 {
			let before: [Int: String] = previous(items, keys)
			items.insert(item, at: 1)
			keys = OrderedPositions.assign(items, previous: before)
			rebalanced = rebalanced || changes(Array(before.keys), Array(before.values), items, keys) != [item]
			#expect(keys == keys.sorted())
			#expect(keys.allSatisfy { $0.count <= FractionalIndex.rebalanceLength })
		}
		#expect(rebalanced)
	}

	@Test
	internal func equalKeysFromTwoMacsKeepOneAndRekeyTheOther() async throws {
		let next: [String] = OrderedPositions.assign(["a", "b", "c"], previous: ["a": "V", "b": "V", "c": "k"])

		#expect(next == next.sorted())
		#expect(Set(next).count == 3)
		#expect(next.filter { $0 == "V" }.count == 1)
		#expect(next[2] == "k")
	}

	// MARK: - Helpers

	private func previous(
		_ items: [Int],
		_ keys: [String]
	) -> [Int: String] {
		Dictionary(uniqueKeysWithValues: zip(items, keys))
	}

	/// The items whose key changed or is new.
	private func changes(
		_ items: [Int],
		_ keys: [String],
		_ next: [Int],
		_ nextKeys: [String]
	) -> [Int] {
		let before: [Int: String] = previous(items, keys)
		return zip(next, nextKeys).filter { before[$0.0] != $0.1 }.map(\.0).sorted()
	}
}
