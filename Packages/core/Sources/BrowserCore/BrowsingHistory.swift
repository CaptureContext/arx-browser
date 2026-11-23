import Foundation

/// Local browsing metadata. Private and temporary pages must be excluded by the host.
public struct BrowsingHistoryEntry: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var url: URL
	public var title: String
	public var lastVisited: Date

	/// How many times the page was opened: each new page, not reloads or title updates (DEV-1015).
	/// Imports bring the other browser's count.
	public var visitCount: Int

	/// How many of those visits were addresses typed in the command bar, in full or completed
	/// inline (DEV-1015).
	public var typedCount: Int

	/// The space of the latest visit, so the command bar ranks a space's own pages higher there.
	public var lastSpaceID: Space.ID?

	public init(
		id: UUID,
		url: URL,
		title: String,
		lastVisited: Date,
		visitCount: Int = 1,
		typedCount: Int = 0,
		lastSpaceID: Space.ID? = nil
	) {
		self.id = id
		self.url = url
		self.title = Self.boundedTitle(title)
		self.lastVisited = lastVisited
		self.visitCount = max(0, visitCount)
		self.typedCount = max(0, typedCount)
		self.lastSpaceID = lastSpaceID
	}

	private enum CodingKeys: String, CodingKey {
		case id
		case url
		case title
		case lastVisited
		case visitCount
		case typedCount
		case lastSpaceID
	}

	/// History written before DEV-1015 has no counts: each page counts as visited once.
	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try container.decode(UUID.self, forKey: .id)
		self.url = try container.decode(URL.self, forKey: .url)
		self.title = try container.decode(String.self, forKey: .title)
		self.lastVisited = try container.decode(Date.self, forKey: .lastVisited)
		self.visitCount = try container.decodeIfPresent(Int.self, forKey: .visitCount) ?? 1
		self.typedCount = try container.decodeIfPresent(Int.self, forKey: .typedCount) ?? 0
		self.lastSpaceID = try container.decodeIfPresent(Space.ID.self, forKey: .lastSpaceID)
	}

	/// Limits UTF-8 storage without splitting a Unicode scalar at the boundary.
	public static func boundedTitle(_ title: String) -> String {
		var result = ""
		var bytes = 0
		for scalar in title.unicodeScalars {
			let count = scalar.utf8.count
			guard bytes + count <= 4_096 else { break }
			result.unicodeScalars.append(scalar)
			bytes += count
		}
		return result
	}

	public static func accepts(_ url: URL) -> Bool {
		guard
			url.absoluteString.utf8.count <= 32_768,
			let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
			["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
			parts.host?.isEmpty == false,
			parts.user == nil,
			parts.password == nil
		else { return false }
		return true
	}
}

/// One page view to record in a profile's history.
public struct BrowsingVisit: Equatable, Sendable {
	public var url: URL
	public var title: String
	public var date: Date

	/// A new page view rather than a title update or reload of the one before (DEV-1015).
	public var isNew: Bool

	/// Opened from an address typed in the command bar, in full or completed inline.
	public var isTyped: Bool

	/// The space the page was viewed in.
	public var spaceID: Space.ID?

	public init(
		url: URL,
		title: String,
		date: Date,
		isNew: Bool = true,
		isTyped: Bool = false,
		spaceID: Space.ID? = nil
	) {
		self.url = url
		self.title = title
		self.date = date
		self.isNew = isNew
		self.isTyped = isTyped
		self.spaceID = spaceID
	}
}

public struct BrowsingHistorySnapshot: Codable, Equatable, Sendable {
	public static let limit: Int = 2_000

	public var profileID: Profile.ID
	public var entries: [BrowsingHistoryEntry]
	public var revision: Int

	public init(
		profileID: Profile.ID,
		entries: [BrowsingHistoryEntry] = [],
		revision: Int = 0
	) {
		self.profileID = profileID
		self.entries = entries
		self.revision = revision
	}

	/// A URL keeps its identity across revisits so an open result list stays stable.
	public mutating func record(
		url: URL,
		title: String,
		at date: Date,
		id: UUID
	) {
		record(.init(url: url, title: title, date: date), id: id)
	}

	/// Records a visit: a new one counts toward the page's visits, and a typed one toward its
	/// typed visits too (DEV-1015). A title update for the same visit only renames the page.
	public mutating func record(
		_ visit: BrowsingVisit,
		id: UUID
	) {
		guard BrowsingHistoryEntry.accepts(visit.url), visit.date.timeIntervalSince1970.isFinite
		else { return }

		// Decoded and constructed snapshots aren't guaranteed to be ordered; sort once if needed.
		if !isOrdered { entries.sort(by: Self.precedes) }

		let entry: BrowsingHistoryEntry
		if let index = entries.firstIndex(where: { $0.url == visit.url }) {
			// Recordings can arrive out of order: an older view still counts, but the newer title,
			// time and space stay.
			guard visit.date >= entries[index].lastVisited else {
				guard visit.isNew else { return }

				entries[index].visitCount = Self.adding(entries[index].visitCount, 1)
				if visit.isTyped { entries[index].typedCount = Self.adding(entries[index].typedCount, 1) }
				return
			}

			var updated = entries.remove(at: index)
			updated.lastVisited = visit.date
			if !visit.title.isEmpty { updated.title = BrowsingHistoryEntry.boundedTitle(visit.title) }
			if visit.isNew {
				updated.visitCount = Self.adding(updated.visitCount, 1)
				if visit.isTyped { updated.typedCount = Self.adding(updated.typedCount, 1) }
			}

			// A title update may come from an older tab in another space; only a view moves it.
			if visit.isNew, let spaceID = visit.spaceID { updated.lastSpaceID = spaceID }
			entry = updated

		} else {
			entry = .init(
				id: id,
				url: visit.url,
				title: visit.title,
				lastVisited: visit.date,
				// A title update that arrives before its view isn't a visit; the view adds it.
				visitCount: visit.isNew ? 1 : 0,
				typedCount: visit.isNew && visit.isTyped ? 1 : 0,
				lastSpaceID: visit.spaceID
			)
		}
		insert(entry)
	}

	/// Adds an imported entry (DEV-1015). A page already listed keeps one entry with the later
	/// visit and the larger counts, so importing the same history twice counts nothing twice.
	public mutating func merge(
		_ imported: BrowsingHistoryEntry,
		id: UUID
	) {
		guard BrowsingHistoryEntry.accepts(imported.url), imported.lastVisited.timeIntervalSince1970.isFinite
		else { return }

		if !isOrdered { entries.sort(by: Self.precedes) }

		var entry: BrowsingHistoryEntry
		if let index = entries.firstIndex(where: { $0.url == imported.url }) {
			entry = entries.remove(at: index)
			if imported.lastVisited > entry.lastVisited {
				entry.lastVisited = imported.lastVisited
				if !imported.title.isEmpty { entry.title = BrowsingHistoryEntry.boundedTitle(imported.title) }
			}
			entry.visitCount = max(entry.visitCount, imported.visitCount)
			entry.typedCount = max(entry.typedCount, imported.typedCount)
		} else {
			entry = imported
			entry.id = id
			entry.title = BrowsingHistoryEntry.boundedTitle(imported.title)
			entry.lastSpaceID = nil
		}
		insert(entry)
	}

	private mutating func insert(_ entry: BrowsingHistoryEntry) {
		entries.insert(entry, at: insertionIndex(of: entry))
		if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
	}

	private static func adding(
		_ count: Int,
		_ amount: Int
	) -> Int {
		count.addingReportingOverflow(amount).overflow ? Int.max : count + amount
	}

	private var isOrdered: Bool {
		zip(entries, entries.dropFirst()).allSatisfy { !Self.precedes($1, $0) }
	}

	/// Entries stay sorted newest first, ties ordered by identifier; keeps `record` at O(n)
	/// instead of re-sorting the whole list on every visit.
	private func insertionIndex(of entry: BrowsingHistoryEntry) -> Int {
		var lower = entries.startIndex
		var upper = entries.endIndex
		while lower < upper {
			let middle = (lower + upper) / 2
			if Self.precedes(entries[middle], entry) {
				lower = middle + 1
			} else {
				upper = middle
			}
		}
		return lower
	}

	private static func precedes(
		_ lhs: BrowsingHistoryEntry,
		_ rhs: BrowsingHistoryEntry
	) -> Bool {
		lhs.lastVisited == rhs.lastVisited
		? lhs.id.uuidString < rhs.id.uuidString
		: lhs.lastVisited > rhs.lastVisited
	}

	public var isValid: Bool {
		revision >= 0
		&& revision < Int.max
		&& entries.count <= Self.limit
		&& Set(entries.map(\.id)).count == entries.count
		&& Set(entries.map(\.url)).count == entries.count
		&& entries.allSatisfy { entry in
			BrowsingHistoryEntry.accepts(entry.url)
			&& entry.title.utf8.count <= 4_096
			&& entry.lastVisited.timeIntervalSince1970.isFinite
			&& entry.visitCount >= 0
			&& entry.typedCount >= 0
		}
	}
}

/// What a person removes from a profile's history: chosen entries, or everything from one
/// site. The command bar's Delete from History and the Library's History page share it.
public enum BrowsingHistoryRemoval: Equatable, Hashable, Sendable {
	case entries(Set<BrowsingHistoryEntry.ID>)

	/// Every entry whose host is this one, ignoring case and a leading `www.`.
	case site(String)

	/// Whether the removal takes `entry`.
	public func matches(_ entry: BrowsingHistoryEntry) -> Bool {
		switch self {
		case let .entries(ids):
			return ids.contains(entry.id)

		case let .site(host):
			guard let entryHost = entry.url.host() else { return false }
			return Self.siteKey(entryHost) == Self.siteKey(host)
		}
	}

	/// A host as a site removal compares it: lowercased, without `www.`.
	public static func siteKey(_ host: String) -> String {
		let host = host.lowercased()
		return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
	}
}

extension BrowsingHistorySnapshot {
	/// Drops what `removal` matches. Returns whether anything was removed.
	@discardableResult
	public mutating func remove(_ removal: BrowsingHistoryRemoval) -> Bool {
		let count = entries.count
		entries.removeAll(where: removal.matches)
		return entries.count != count
	}
}
