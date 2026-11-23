import Foundation

/// Durable tab metadata. Loaded pages and their presentation belong elsewhere.
public struct Tab: Identifiable, Equatable, Codable, Sendable {
	public let id: ID
	public let profileID: Profile.ID
	public var savedDestination: SavedDestination?
	public var restoration: Restoration
	public var customTitle: String?

	/// An icon chosen from the icon picker, drawn instead of the site's (DEV-1251). It belongs to
	/// the tab: moves keep it, and closing or archiving the tab drops it.
	public var icon: SpaceIcon?
	public var automationClientID: UUID?

	/// The tabs this one copies into another profile, latest first, when moves made it: a page can't
	/// change profile, so a move gives the tab a new ID, and moves before a save chain. The workspace
	/// store reads them to tell a move from a deletion beside an identical new tab, which stays on this
	/// Mac only with iCloud sync (DEV-1089). Kept in memory only: it isn't saved and doesn't count for
	/// equality.
	public var movedFrom: [ID] = []

	public init(
		id: ID,
		profileID: Profile.ID,
		savedDestination: SavedDestination? = nil,
		restoration: Restoration,
		customTitle: String? = nil,
		icon: SpaceIcon? = nil,
		automationClientID: UUID? = nil,
		movedFrom: [ID] = []
	) {
		self.id = id
		self.profileID = profileID
		self.savedDestination = savedDestination
		self.restoration = restoration
		self.customTitle = customTitle
		self.icon = icon
		self.automationClientID = automationClientID
		self.movedFrom = movedFrom
	}

	private enum CodingKeys: String, CodingKey {
		case id
		case profileID
		case savedDestination
		case restoration
		case customTitle
		case icon
		case automationClientID
	}

	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.id == rhs.id
		&& lhs.profileID == rhs.profileID
		&& lhs.savedDestination == rhs.savedDestination
		&& lhs.restoration == rhs.restoration
		&& lhs.customTitle == rhs.customTitle
		&& lhs.icon == rhs.icon
		&& lhs.automationClientID == rhs.automationClientID
	}

	/// An explicit name is independent of the renderer's latest page title.
	public var displayTitle: String { customTitle ?? savedDestination?.title ?? restoration.title }

	/// A closed pin starts at its saved destination; unpinned tabs resume their last URL.
	public var reopeningURL: URL { savedDestination?.url ?? restoration.url }

	/// The page whose site icon the tab shows: the one it has loaded, as for any tab. A saved tab
	/// browsing away from its saved page shows where it is, and closing it returns it to its
	/// saved page and that page's icon (DEV-1294).
	public var siteIconURL: URL { restoration.url }

	/// Every page whose icon the tab may show: where it is, and a saved tab's saved page, which
	/// it shows again once closed (DEV-1294).
	public var siteIconURLs: [URL] {
		guard
			let saved = savedDestination?.url,
			saved != restoration.url
		else { return [restoration.url] }

		return [restoration.url, saved]
	}
}

extension Tab {
	public typealias ID = BrowserID<Self>

	public struct SavedDestination: Equatable, Codable, Sendable {
		public var title: String
		public var url: URL
		public var iconURL: URL?

		public init(
			title: String,
			url: URL,
			iconURL: URL? = nil
		) {
			self.title = title
			self.url = url
			self.iconURL = iconURL
		}
	}

	/// Last-known metadata, not a serialized renderer or a promise of form restoration.
	public struct Restoration: Equatable, Codable, Sendable {
		public var title: String
		public var url: URL

		public init(
			title: String,
			url: URL
		) {
			self.title = title
			self.url = url
		}
	}
}
