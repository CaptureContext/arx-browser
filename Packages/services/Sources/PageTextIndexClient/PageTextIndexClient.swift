import BrowserCore
import Foundation
import _Dependencies

/// The words of the pages a profile visited, for history search (DEV-1068). Kept on this Mac, in
/// a file of the profile's beside its history, never for private windows, and cleared with
/// history. At most `maximumPages` pages, each its first `maximumCharacters` characters.
public struct PageTextIndexClient: Sendable {
	public var isAvailable: Bool

	/// Keeps a page's text, replacing what the page had, unless it was read at an older
	/// `generation` than a clear, range or prune since: the page went with its history.
	public var save: @Sendable (Profile.ID, PageText, _ generation: Int) async -> Void

	/// The pages whose words begin with every word of the query, best first, each with its
	/// passage that matched.
	public var search: @Sendable (Profile.ID, String, _ limit: Int) async -> [PageTextHit]

	/// Forgets every page, as Clear History does. Each removal carries the generation history
	/// moved to, and a page read before it is never saved after it, whichever arrives first.
	public var clear: @Sendable (Profile.ID, _ generation: Int) async -> Void

	/// Forgets the pages visited at or after a moment, as Clear Browsing Data with a range does.
	public var clearSince: @Sendable (Profile.ID, Date, _ generation: Int) async -> Void

	/// Keeps only these pages, as history keeps them after Delete from History.
	public var retain: @Sendable (Profile.ID, Set<URL>, _ generation: Int) async -> Void

	/// The file's size in bytes, or nil when there's none.
	public var size: @Sendable (Profile.ID) async -> Int?

	public static let maximumPages: Int = BrowsingHistorySnapshot.limit

	/// About 19 MB of disk per 1,000 pages at most, measured with prose-like text
	/// (`PageTextIndexTests`), so a profile's index stays under 40 MB.
	public static let maximumCharacters: Int = 10_000

	public init(
		isAvailable: Bool = false,
		save: @escaping @Sendable (Profile.ID, PageText, Int) async -> Void = { _, _, _ in },
		search: @escaping @Sendable (Profile.ID, String, Int) async -> [PageTextHit] = { _, _, _ in [] },
		clear: @escaping @Sendable (Profile.ID, Int) async -> Void = { _, _ in },
		clearSince: @escaping @Sendable (Profile.ID, Date, Int) async -> Void = { _, _, _ in },
		retain: @escaping @Sendable (Profile.ID, Set<URL>, Int) async -> Void = { _, _, _ in },
		size: @escaping @Sendable (Profile.ID) async -> Int? = { _ in nil }
	) {
		self.isAvailable = isAvailable
		self.save = save
		self.search = search
		self.clear = clear
		self.clearSince = clearSince
		self.retain = retain
		self.size = size
	}

	/// Each profile's index in `directory`, the profile's history folder.
	public static func local(directory: URL) -> Self {
		let store = PageTextStore(directory: directory)
		return .init(
			isAvailable: true,
			save: { await store.save($1, profileID: $0, generation: $2) },
			search: { await store.search($1, limit: $2, profileID: $0) },
			clear: { await store.clear($0, generation: $1) },
			clearSince: { await store.clear($0, since: $1, generation: $2) },
			retain: { await store.retain($1, profileID: $0, generation: $2) },
			size: { await store.size($0) }
		)
	}
}

/// A visited page's words.
public struct PageText: Equatable, Sendable {
	public var url: URL
	public var title: String
	public var text: String
	public var visited: Date

	public init(
		url: URL,
		title: String,
		text: String,
		visited: Date
	) {
		self.url = url
		self.title = title
		self.text = text
		self.visited = visited
	}
}

/// A page whose words matched, with the passage around them.
public struct PageTextHit: Equatable, Sendable {
	public var url: URL
	public var passage: String

	public init(
		url: URL,
		passage: String
	) {
		self.url = url
		self.passage = passage
	}
}

extension PageTextIndexClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
}

extension DependencyValues {
	public var pageTextIndex: PageTextIndexClient {
		get { self[PageTextIndexClient.self] }
		set { self[PageTextIndexClient.self] = newValue }
	}
}
