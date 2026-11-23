import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserHistoryClient
import BrowserPagePreviewClient
import CommandBarFeature
import Foundation
import MainFeature
import PageTextIndexClient
import _ComposableArchitecture

public struct ProfileHistoryState: Equatable {
	public var snapshots: [Profile.ID: BrowsingHistorySnapshot]
	public var failures: [Profile.ID: BrowserHistoryClient.Failure]
	public var loading: Set<Profile.ID>
	public var knownProfiles: Set<Profile.ID>
	public var epochs: [Profile.ID: Int]

	/// Moves with every clear or removal of a profile's history, so a page's text read before
	/// one isn't kept after it (DEV-1068).
	public var pageTextGenerations: [Profile.ID: Int] = [:]

	/// Each tab's page-text read still to come, for the page view it was asked for (DEV-1068).
	/// A load interrupts it; once the same page view settles again it's asked again.
	public var pageTextReads: [BrowserCore.Tab.ID: PageTextReadRequest] = [:]

	/// Profiles whose page text was matched to their history this launch (DEV-1068): a clear
	/// synced from another Mac while Arx was closed arrives in the first history it loads.
	public var pageTextReconciled: Set<Profile.ID> = []
	public var pendingClear: Set<Profile.ID>
	public var queuedVisits: [Profile.ID: [Visit]]
	public var lastNavigation: [BrowserCore.Tab.ID: NavigationKey]

	/// Removals the store hasn't answered yet (DEV-810). They stay applied to any snapshot that
	/// arrives meanwhile, so an older answer can't bring removed entries back.
	public var pendingRemovals: [Profile.ID: [PendingRemoval]]

	/// The page view each tab last counted, so a title update or reload isn't another visit
	/// (DEV-1015). Unlike `lastNavigation`, loading doesn't clear it.
	public var lastVisit: [BrowserCore.Tab.ID: VisitKey]

	/// Addresses just opened from what was typed in a command bar, by profile, until a visit
	/// to the same site takes them (DEV-1015).
	public var typedAddresses: [Profile.ID: [TypedAddress]]

	public init(
		snapshots: [Profile.ID: BrowsingHistorySnapshot] = [:],
		failures: [Profile.ID: BrowserHistoryClient.Failure] = [:],
		loading: Set<Profile.ID> = [],
		knownProfiles: Set<Profile.ID> = [],
		epochs: [Profile.ID: Int] = [:],
		pendingClear: Set<Profile.ID> = [],
		queuedVisits: [Profile.ID: [Visit]] = [:],
		lastNavigation: [BrowserCore.Tab.ID: NavigationKey] = [:],
		pendingRemovals: [Profile.ID: [PendingRemoval]] = [:],
		lastVisit: [BrowserCore.Tab.ID: VisitKey] = [:],
		typedAddresses: [Profile.ID: [TypedAddress]] = [:]
	) {
		self.snapshots = snapshots
		self.failures = failures
		self.loading = loading
		self.knownProfiles = knownProfiles
		self.epochs = epochs
		self.pendingClear = pendingClear
		self.queuedVisits = queuedVisits
		self.lastNavigation = lastNavigation
		self.pendingRemovals = pendingRemovals
		self.lastVisit = lastVisit
		self.typedAddresses = typedAddresses
	}

	/// A page view whose text is to be read, and whether a load cut its read short (DEV-1068).
	public struct PageTextReadRequest: Equatable, Sendable {
		public var visit: VisitKey
		public var isInterrupted: Bool

		public init(
			visit: VisitKey,
			isInterrupted: Bool = false
		) {
			self.visit = visit
			self.isInterrupted = isInterrupted
		}
	}

	/// A page view: the page and its place in the tab's back-forward list. The list's length
	/// tells a new entry for the same page from a reload where entry IDs are relative, as
	/// WebKit's are.
	public struct VisitKey: Equatable, Sendable {
		public var url: URL
		public var entryID: Int?
		public var historyLength: Int

		public init(
			url: URL,
			entryID: Int?,
			historyLength: Int
		) {
			self.url = url
			self.entryID = entryID
			self.historyLength = historyLength
		}
	}

	/// An address opened from typed text, waiting for its page to load.
	public struct TypedAddress: Equatable, Sendable {
		/// The address opened.
		public var url: URL

		/// The site, as a site removal compares hosts, so a redirect within it still counts.
		public var site: String

		/// The tab it opens in.
		public var tabID: BrowserCore.Tab.ID
		public var openedAt: Date

		public init(
			url: URL,
			site: String,
			tabID: BrowserCore.Tab.ID,
			openedAt: Date
		) {
			self.url = url
			self.site = site
			self.tabID = tabID
			self.openedAt = openedAt
		}
	}

	/// Whether two addresses name one page: a site's front page with or without its slash, and
	/// a host in any case.
	internal static func isSamePage(
		_ lhs: URL,
		_ rhs: URL
	) -> Bool {
		func normalized(_ url: URL) -> URLComponents? {
			guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

			let host = parts.host?.lowercased()
			parts.host = host
			if parts.path.isEmpty { parts.path = "/" }
			return parts
		}
		return normalized(lhs) == normalized(rhs)
	}

	/// How long a typed address waits for its page.
	public static let typedAddressLifetime: TimeInterval = 30

	/// Moves a profile's page-text generation on, for a clear, range or prune of its history
	/// (DEV-1068), and returns the new one.
	internal mutating func advancePageTextGeneration(_ profileID: Profile.ID) -> Int {
		pageTextGenerations[profileID, default: 0] += 1
		return pageTextGenerations[profileID, default: 0]
	}

	/// Takes the typed address waiting for `url`'s site in this tab, if any, and returns whether
	/// the visit was typed: a new view of the site, as after a redirect. A reload of exactly the
	/// typed page takes it without being a visit, so a later link on the site can't; another
	/// tab's page, or a title update from the page before, takes nothing.
	internal mutating func takeTypedAddress(
		for url: URL,
		isNew: Bool,
		tabID: BrowserCore.Tab.ID,
		profileID: Profile.ID,
		at now: Date
	) -> Bool {
		guard var waiting = typedAddresses[profileID] else { return false }

		waiting.removeAll { now.timeIntervalSince($0.openedAt) > Self.typedAddressLifetime }
		defer { typedAddresses[profileID] = waiting.isEmpty ? nil : waiting }
		guard
			let host = url.host(),
			let index = waiting.firstIndex(where: { address in
				address.site == BrowsingHistoryRemoval.siteKey(host)
				&& address.tabID == tabID
				&& (isNew || Self.isSamePage(address.url, url))
			})
		else { return false }

		waiting.remove(at: index)
		return isNew
	}

	public struct NavigationKey: Equatable, Sendable {
		public var url: URL
		public var title: String
		public var entryID: Int?

		public init(
			url: URL,
			title: String,
			entryID: Int?
		) {
			self.url = url
			self.title = title
			self.entryID = entryID
		}
	}

	/// A removal and when it was asked for: a visit after that moment stays (DEV-810).
	public struct PendingRemoval: Equatable, Sendable {
		public var removal: BrowsingHistoryRemoval
		public var requestedAt: Date

		public init(
			removal: BrowsingHistoryRemoval,
			requestedAt: Date
		) {
			self.removal = removal
			self.requestedAt = requestedAt
		}

		/// Whether the removal still hides `entry`: it matches and wasn't visited since.
		public func hides(_ entry: BrowsingHistoryEntry) -> Bool {
			entry.lastVisited <= requestedAt && removal.matches(entry)
		}
	}

	public typealias Visit = BrowsingVisit
}
