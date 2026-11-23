import Foundation

/// Tabs of one space shown side by side, as one row in the sidebar.
///
/// Members are in pane order. Those in the sidebar's list share one list of `spaceID` (its open
/// tabs, its Pinned or one folder) and stay next to each other there; the others are Favorites of
/// the space's profile, which stay in the Favorites grid (DEV-1006).
/// `BrowserOrganization.normalizeSplits()` repairs everything else.
public struct SplitGroup: Identifiable, Equatable, Codable, Sendable {
	public let id: ID
	public var spaceID: Space.ID
	public var tabIDs: [Tab.ID]
	public var orientation: BrowserSpacePresentation.Orientation

	/// Each pane's share of the split's length, in `tabIDs` order. They add up to 1.
	public var fractions: [Double]

	/// A name chosen with Rename…, shown in place of the members' titles.
	public var title: String?

	/// A symbol name or a single emoji chosen with Change Icon….
	public var icon: String?

	public init(
		id: ID,
		spaceID: Space.ID,
		tabIDs: [Tab.ID],
		orientation: BrowserSpacePresentation.Orientation = .horizontal,
		fractions: [Double]? = nil,
		title: String? = nil,
		icon: String? = nil
	) {
		self.id = id
		self.spaceID = spaceID
		self.tabIDs = tabIDs
		self.orientation = orientation
		self.fractions = SplitLayout.sanitized(fractions, count: tabIDs.count)
		self.title = title
		self.icon = icon
	}
}

extension SplitGroup {
	public typealias ID = BrowserID<Self>

	/// Panes keep their order; every pane gets an equal share.
	public mutating func equalize() {
		fractions = SplitLayout.equal(tabIDs.count)
	}
}

/// Pure layout rules shared by the viewer, the sidebar and automation.
public enum SplitLayout {
	/// A split holds two to four tabs.
	public static let maximumPanes: Int = 4

	/// No pane may be narrower (or, in a vertical split, shorter) than this, in points.
	public static let minimumPaneLength: Double = 280

	/// The gap between two panes, which is also the divider's hit area.
	public static let dividerLength: Double = 8

	public static func equal(_ count: Int) -> [Double] {
		guard count > 0 else { return [] }
		return Array(repeating: 1 / Double(count), count: count)
	}

	/// Equal shares whenever the stored ones don't describe `count` usable panes.
	public static func sanitized(
		_ fractions: [Double]?,
		count: Int
	) -> [Double] {
		guard
			let fractions,
			fractions.count == count,
			fractions.allSatisfy({ $0.isFinite && $0 > 0 })
		else { return equal(count) }

		let total = fractions.reduce(0, +)
		guard total > 0 else { return equal(count) }

		// Already normalized shares stay as they are, so normalizing is idempotent: dividing by a
		// sum a rounding error off 1 could otherwise flip between two representations forever.
		if abs(total - 1) < 1e-9 { return fractions }
		return fractions.map { $0 / total }
	}

	/// How many panes fit in `length` points, each at least the minimum, up to four.
	public static func capacity(length: Double) -> Int {
		guard length.isFinite, length > 0 else { return 1 }
		let fitting = Int(((length + dividerLength) / (minimumPaneLength + dividerLength)).rounded(.down))
		return min(maximumPanes, max(1, fitting))
	}

	/// Each pane's length in points. Panes keep the minimum whenever `length` has room for it,
	/// taking what they need from the others in proportion to their share.
	public static func extents(
		_ fractions: [Double],
		length: Double
	) -> [Double] {
		let count = fractions.count
		guard count > 0 else { return [] }

		let available = max(0, length - dividerLength * Double(count - 1))
		let shares = sanitized(fractions, count: count)
		var extents = shares.map { $0 * available }
		guard available >= minimumPaneLength * Double(count) else { return extents }

		// Raise short panes to the minimum and take the difference from the rest by their share.
		var fixed: Set<Int> = []
		while let short = extents.indices.first(where: { !fixed.contains($0) && extents[$0] < minimumPaneLength - 0.0001 }) {
			fixed.insert(short)
			extents[short] = minimumPaneLength
			let flexible = extents.indices.filter { !fixed.contains($0) }
			let remaining = available - Double(fixed.count) * minimumPaneLength
			let flexibleShare = flexible.map { shares[$0] }.reduce(0, +)
			for index in flexible {
				extents[index] = flexibleShare > 0
				? remaining * shares[index] / flexibleShare
				: remaining / Double(flexible.count)
			}
		}
		return extents
	}

	/// Moves the divider after pane `index` by `delta` points, trading length only between
	/// that pane and the next, neither going below the minimum.
	public static func resize(
		_ fractions: [Double],
		divider index: Int,
		by delta: Double,
		length: Double
	) -> [Double] {
		let count = fractions.count
		guard
			count > 1,
			fractions.indices.contains(index),
			index + 1 < count,
			delta.isFinite
		else { return fractions }

		let available = max(0, length - dividerLength * Double(count - 1))
		var extents = extents(fractions, length: length)
		guard available > 0 else { return fractions }

		let pair = extents[index] + extents[index + 1]
		let minimum = min(minimumPaneLength, pair / 2)
		let leading = min(max(extents[index] + delta, minimum), pair - minimum)
		extents[index] = leading
		extents[index + 1] = pair - leading
		return extents.map { $0 / available }
	}
}
