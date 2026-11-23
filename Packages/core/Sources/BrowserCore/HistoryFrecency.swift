import Foundation

/// How strongly the command bar suggests a page from history (DEV-1015): how often it was
/// visited, how often its address was typed, whether it belongs to the current space, and how
/// recently it was seen.
///
/// The score follows Firefox's frecency in spirit: visits earn points, a typed visit earns
/// several, and the total fades in steps as the last visit ages. History is kept per profile, so
/// every entry already belongs to the current profile.
///
/// ```swift
/// let score = HistoryFrecency.score(of: entry, at: now, in: spaceID)
/// ```
public enum HistoryFrecency {
	/// What a typed visit is worth next to an ordinary one, on top of counting as a visit.
	public static let typedWeight: Double = 4

	/// What a page last seen in the current space is worth next to one seen elsewhere.
	public static let spaceWeight: Double = 1.5

	/// How much of the score is left as the last visit ages: in full for four days, then less
	/// in steps, down to a tenth after three months.
	public static func recencyWeight(
		lastVisited: Date,
		at now: Date
	) -> Double {
		let days = max(0, now.timeIntervalSince(lastVisited)) / 86_400
		switch days {
		case ..<4: return 1
		case ..<14: return 0.7
		case ..<31: return 0.5
		case ..<90: return 0.3
		default: return 0.1
		}
	}

	/// The page's score; higher ranks first. Zero only for a page never visited.
	public static func score(
		of entry: BrowsingHistoryEntry,
		at now: Date,
		in spaceID: Space.ID? = nil
	) -> Double {
		let visits = Double(entry.visitCount) + typedWeight * Double(entry.typedCount)
		let space = spaceID != nil && entry.lastSpaceID == spaceID ? spaceWeight : 1
		return visits * space * recencyWeight(lastVisited: entry.lastVisited, at: now)
	}
}
