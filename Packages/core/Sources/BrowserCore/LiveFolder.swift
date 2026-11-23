import Foundation

/// Where a live folder's items come from (DEV-926). GitHub's pull requests are the first
/// source; calendars, documents and shared folders come later, each a case of its own.
public enum LiveFolderSource: Codable, Hashable, Sendable {
	case gitHubPullRequests(GitHubPullRequestFilter)

	/// Which of the signed-in account's pull requests a folder lists.
	public enum GitHubPullRequestFilter: String, CaseIterable, Codable, Hashable, Sendable {
		/// Open pull requests the account opened.
		case authored

		/// Open pull requests waiting for the account's review.
		case reviewRequested
	}

	/// The service a source needs an account for, so one sign-in covers every folder using it.
	public var service: LiveFolderService {
		switch self {
		case .gitHubPullRequests: .gitHub
		}
	}
}

public enum LiveFolderService: String, CaseIterable, Codable, Hashable, Sendable {
	case gitHub
}

/// A pinned folder made live: which folder, and where it fills from. Saved with the
/// browser's preferences; the items themselves are fetched again after a relaunch.
public struct LiveFolderConfiguration: Codable, Equatable, Hashable, Identifiable, Sendable {
	public var folderID: Folder.ID
	public var source: LiveFolderSource

	public var id: Folder.ID { folderID }

	public init(
		folderID: Folder.ID,
		source: LiveFolderSource
	) {
		self.folderID = folderID
		self.source = source
	}
}

/// One thing a live folder lists, such as a pull request.
public struct LiveFolderItem: Codable, Equatable, Hashable, Identifiable, Sendable {
	/// Stable across refreshes, so a refresh can tell new items from ones already listed.
	public var id: String
	public var title: String
	public var url: URL

	/// A short second line, such as `owner/repo #12`.
	public var detail: String

	public init(
		id: String,
		title: String,
		url: URL,
		detail: String = ""
	) {
		self.id = id
		self.title = title
		self.url = url
		self.detail = detail
	}
}

/// What a live folder shows now: its items in the source's order, which of them the user
/// hasn't seen, and how the last refresh went.
public struct LiveFolderContents: Equatable, Sendable {
	public var items: [LiveFolderItem]

	/// Items that arrived since the user last looked: the folder's badge.
	public var unseen: Set<LiveFolderItem.ID>
	public var refreshedAt: Date?
	public var failure: LiveFolderFailure?

	public init(
		items: [LiveFolderItem] = [],
		unseen: Set<LiveFolderItem.ID> = [],
		refreshedAt: Date? = nil,
		failure: LiveFolderFailure? = nil
	) {
		self.items = items
		self.unseen = unseen
		self.refreshedAt = refreshedAt
		self.failure = failure
	}

	/// The badge: how many listed items are new.
	public var badgeCount: Int {
		items.count { unseen.contains($0.id) }
	}

	/// The contents after a refresh fetched `fetched`.
	///
	/// The first refresh fills the folder without a badge: everything is new, so nothing
	/// stands out. Later, an item not listed before is unseen; one that's gone takes its
	/// badge with it; an item already listed keeps whether it was seen.
	public func refreshed(
		with fetched: [LiveFolderItem],
		at date: Date
	) -> Self {
		var seenIDs: Set<LiveFolderItem.ID> = []
		let items = fetched.filter { seenIDs.insert($0.id).inserted }
		guard refreshedAt != nil else { return .init(items: items, refreshedAt: date) }

		let listed = Set(self.items.map(\.id))
		let fresh = items.map(\.id).filter { !listed.contains($0) }
		let unseen = self.unseen.union(fresh).intersection(items.map(\.id))
		return .init(items: items, unseen: unseen, refreshedAt: date)
	}

	/// The contents after a refresh failed: the items stay, with the failure beside them.
	public func failed(_ failure: LiveFolderFailure) -> Self {
		var contents = self
		contents.failure = failure
		return contents
	}

	/// The user looked at the folder: the badge clears.
	public func markingSeen() -> Self {
		var contents = self
		contents.unseen = []
		return contents
	}
}

public enum LiveFolderFailure: Error, Equatable, Sendable {
	/// No account for the source's service. Signing in is the user's choice (DEV-926).
	case notSignedIn

	/// The service refused the account: signed out, expired or without access.
	case unauthorized

	/// The service asked to slow down; the next refresh waits.
	case rateLimited
	case unreachable
	case unexpectedResponse
}
