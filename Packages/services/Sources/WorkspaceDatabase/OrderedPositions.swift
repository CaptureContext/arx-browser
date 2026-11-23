import Foundation

/// Assigns ``FractionalIndex`` keys to an ordered list while rewriting as few as possible.
internal enum OrderedPositions {
	/// Keys for `items`, in order. The longest run of items whose previous keys are still in order
	/// keeps those keys; every other item gets a key between its kept neighbors. A list with nothing to
	/// keep, or whose keys grew past ``FractionalIndex/rebalanceLength``, is spread out again.
	///
	/// - Parameters:
	///   - previous: each item's key in this same list before the change, if it was in it.
	internal static func assign<Item: Hashable>(
		_ items: [Item],
		previous: [Item: String]
	) -> [String] {
		let anchors: Set<Int> = keptIndices(items, previous: previous)
		guard !anchors.isEmpty else { return FractionalIndex.evenlySpaced(items.count) }

		var result: [String] = []
		result.reserveCapacity(items.count)
		var lower: String?
		var pending: Int = 0
		for index in items.indices {
			guard anchors.contains(index) else {
				pending += 1
				continue
			}
			let key: String = previous[items[index]]!
			result += FractionalIndex.keys(pending, between: lower, and: key)
			result.append(key)
			lower = key
			pending = 0
		}
		result += FractionalIndex.keys(pending, between: lower, and: nil)

		guard result.allSatisfy({ $0.count <= FractionalIndex.rebalanceLength })
		else { return FractionalIndex.evenlySpaced(items.count) }

		return result
	}

	/// The indices of the longest strictly increasing run of valid previous keys.
	private static func keptIndices<Item: Hashable>(
		_ items: [Item],
		previous: [Item: String]
	) -> Set<Int> {
		var candidates: [(index: Int, key: String)] = []
		for (index, item) in items.enumerated() {
			guard let key = previous[item], FractionalIndex.isValid(key) else { continue }

			candidates.append((index, key))
		}

		// Patience sorting: `tails[length]` is the candidate ending the best run of `length + 1`.
		var tails: [Int] = []
		var parents: [Int?] = .init(repeating: nil, count: candidates.count)
		for (candidate, entry) in candidates.enumerated() {
			var low: Int = 0
			var high: Int = tails.count
			while low < high {
				let middle: Int = (low + high) / 2
				if candidates[tails[middle]].key < entry.key {
					low = middle + 1
				} else {
					high = middle
				}
			}
			parents[candidate] = low > 0 ? tails[low - 1] : nil
			if low == tails.count {
				tails.append(candidate)
			} else {
				tails[low] = candidate
			}
		}

		var kept: Set<Int> = []
		var cursor: Int? = tails.last
		while let current = cursor {
			kept.insert(candidates[current].index)
			cursor = parents[current]
		}
		return kept
	}
}
