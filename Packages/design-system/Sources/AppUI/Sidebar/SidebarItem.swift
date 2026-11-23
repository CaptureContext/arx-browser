import BrowserCore
import Foundation
import LocalUIExtensions

/// A presentation snapshot. Domain ownership remains with the caller.
public struct SidebarItem: Identifiable, Equatable, Sendable {
	/// The `symbol` of a chat tab's row (DEV-761): the row draws the assistant's face.
	public static let assistantSymbol: String = "arx.assistant"

	/// The `symbol` of a site tab's row. Rows draw a placeholder for it while the site has no icon.
	public static let siteSymbol: String = "globe"

	public let id: ID
	public var title: String
	public var symbol: String
	public var siteIcon: SiteIcon?
	public var tint: SidebarTint
	public var children: [SidebarItem]
	public var isExpanded: Bool
	public var isPinned: Bool
	public var isAtInitialState: Bool
	public var interactions: Interactions
	public var moveSelection: [ID]

	/// Set when this row stands for a Split View group; `id` is then its first member's.
	public var split: Split?

	/// The group of a tab whose split shows as its own row, its other tabs being Favorites
	/// (DEV-1006): how many panes it has and how they're laid out, for judging a drop on the row.
	public var splitPanes: SplitPanes?

	/// A tab on this computer or the local network: its host and port, such as `localhost:3000`.
	/// The row shows it under the title inside a construction-tape border (DEV-786).
	public var localHost: String?

	/// The tab's sound, when the window can mute it (DEV-800). The row shows a speaker while it
	/// plays, is muted or is turned down.
	public var audio: Audio?

	/// Arx unloaded the tab's page to free memory (DEV-873). The row shows it faded until the
	/// tab is shown again.
	public var isUnloaded: Bool

	/// The tab's page shows in WebKit (DEV-877): the row's icon carries a small Safari mark.
	public var usesWebKit: Bool

	/// An MCP client acting on the tab now or a moment ago (DEV-899). The row shows a small
	/// badge naming it until `Agent.fadesAt`.
	public var agent: Agent?

	/// Set on a tab row in a selection of several tabs, which then shows the bulk menu (DEV-883).
	public var selection: Selection?

	/// A group of open tabs (DEV-911): `id` is `.folder` with the group's identity and `children`
	/// are its tabs. It discloses and renames like a folder, with its own menu.
	public var isTabGroup: Bool

	/// What the tab's page has unread, when it shows (DEV-907).
	public var unread: Unread?

	/// The tab's own unread badges choice and what it inherits (DEV-1258), for its menu's Unread
	/// Badges item; nil for a row that isn't a web tab.
	public var unreadBadges: UnreadBadges?

	/// The tab's site for Always Keep This Site Loaded (DEV-932), when it's on the web.
	public var keepLoaded: KeepLoaded?

	/// The icon chosen for the tab, drawn instead of its site's (DEV-1251).
	public var customIcon: SpaceIcon?

	/// The tab's icon picker is open, from Change Icon… (DEV-1251).
	public var isPickingIcon: Bool

	public init(
		id: ID,
		title: String,
		symbol: String = "globe",
		siteIcon: SiteIcon? = nil,
		tint: SidebarTint = .white,
		children: [SidebarItem] = [],
		isExpanded: Bool = false,
		isPinned: Bool = true,
		isAtInitialState: Bool = true,
		moveSelection: [ID] = [],
		interactions: Interactions = .all,
		split: Split? = nil,
		localHost: String? = nil,
		audio: Audio? = nil,
		isUnloaded: Bool = false,
		usesWebKit: Bool = false,
		agent: Agent? = nil,
		selection: Selection? = nil,
		isTabGroup: Bool = false,
		unread: Unread? = nil,
		unreadBadges: UnreadBadges? = nil,
		keepLoaded: KeepLoaded? = nil,
		customIcon: SpaceIcon? = nil,
		isPickingIcon: Bool = false
	) {
		self.id = id
		self.title = title
		self.symbol = symbol
		self.siteIcon = siteIcon
		self.tint = tint
		self.children = children
		self.isExpanded = isExpanded
		self.isPinned = isPinned
		self.isAtInitialState = isAtInitialState
		self.interactions = interactions
		self.moveSelection = moveSelection
		self.split = split
		self.splitPanes = nil
		self.localHost = localHost
		self.audio = audio
		self.isUnloaded = isUnloaded
		self.usesWebKit = usesWebKit
		self.agent = agent
		self.selection = selection
		self.isTabGroup = isTabGroup
		self.unread = unread
		self.unreadBadges = unreadBadges
		self.keepLoaded = keepLoaded
		self.customIcon = customIcon
		self.isPickingIcon = isPickingIcon
	}

	public var isFolder: Bool {
		if case .folder = id { return true }
		return false
	}

	public func tabAction(isSelected: Bool) -> TabAction {
		guard isPinned else { return .close }
		return isSelected || !isAtInitialState ? .reset : .removePin
	}
}

extension SidebarItem {
	public enum TabAction: Equatable, Sendable {
		case reset
		case removePin
		case close
	}

	public enum ID: Hashable, Codable, Sendable {
		case tab(UUID)
		case folder(UUID)
	}
}

/// The side of the sidebar a dragged item is held against: the outermost strip on each side, inside
/// the sidebar. A point past either side is the page or the desktop, never an edge (DEV-793).
public enum SidebarDragEdge: Equatable, Sendable {
	case leading
	case trailing

	public init?(
		x: CGFloat,
		width: CGFloat
	) {
		guard width > 0, x >= 0, x <= width else { return nil }

		if x <= BrowserMetrics.Sidebar.dragEdgeWidth {
			self = .leading
		} else if x >= width - BrowserMetrics.Sidebar.dragEdgeWidth {
			self = .trailing
		} else {
			return nil
		}
	}
}

public enum SidebarDropTarget: Equatable, Sendable {
	/// Onto an open tab or a split's row: the dropped tabs join it in Split View.
	case split(SidebarItem.ID)
	case before(SidebarItem.ID)
	case after(SidebarItem.ID)
	case inside(SidebarItem.ID)
	case favoritesRoot
	case savedRoot
	case unpinnedRoot
}

@CasePathable
public enum SidebarAction: Sendable {
	case select(SidebarItem.ID)

	/// A plain press selected the tab as the mouse button went down (DEV-914). The window selects
	/// it as `select` does and remembers the tab shown before, which a drag of this tab into the
	/// page then splits with (DEV-994).
	case selectOnPress(SidebarItem.ID)

	/// The click that ended such a press, with no drag: the press is over (DEV-994).
	case pressCompleted(SidebarItem.ID)
	case toggle(SidebarItem.ID)
	case rename(SidebarItem.ID, String)
	case close(SidebarItem.ID)
	case reset(SidebarItem.ID)
	case removePin(SidebarItem.ID)
	case updateSavedURL(SidebarItem.ID)
	case openFolder(SidebarItem.ID, includingDescendants: Bool)
	case ungroupFolder(SidebarItem.ID)
	case deleteFolder(SidebarItem.ID)
	case move(SidebarItem.ID, SidebarDropTarget)
	case moveItems([SidebarItem.ID], SidebarDropTarget)
	case toggleMoveSelection(SidebarItem.ID)
	case clearMoveSelection
	case duplicate(SidebarItem.ID)
	case addSplit(SidebarItem.ID)
	case splitGroup(SplitGroupAction)
	case chooseMoveDestination(SidebarItem.ID?)
	case newFolder(SidebarItem.ID?)
	case newTab
	case clearTabs
	case openCommandBar
	case toggleSidebar
	case toggleSpace
	case renameSpace(String)

	/// The tab's speaker or its menu's Mute Tab and Unmute Tab (DEV-800).
	case setMuted(SidebarItem.ID, Bool)

	/// The tab's volume, 0 to 1, from its speaker's popover (DEV-800).
	case setVolume(SidebarItem.ID, Double)

	/// Close Other Tabs: the space's other open tabs, or every one outside the selection the row
	/// is in (DEV-883).
	case closeOtherTabs(SidebarItem.ID)

	/// Close Tabs Below: the open tabs after this one in the sidebar (DEV-883).
	case closeTabsBelow(SidebarItem.ID)

	/// Close N Tabs: open tabs close into the archive and pinned ones unload, as one undo (DEV-883).
	case closeTabs([SidebarItem.ID])

	/// Archive N Tabs: the open tabs among these, as one undo (DEV-883).
	case archiveTabs([SidebarItem.ID])

	/// Duplicate N Tabs: a copy of each after the space's open tabs, as one undo (DEV-883).
	case duplicateTabs([SidebarItem.ID])

	/// Pin N Tabs or Unpin N Tabs, as one undo (DEV-883).
	case setPinned([SidebarItem.ID], Bool)

	/// Move to Window: the tabs go to that window's space and it shows the first. With no window,
	/// Open in New Window: a new window shows the first (DEV-883).
	case moveToWindow([SidebarItem.ID], UUID?)

	/// Group N Tabs, or Add Tab to New Group: the open tabs among these form a group (DEV-911).
	case groupTabs([SidebarItem.ID])

	/// Ungroup Tabs: the group's tabs stay where they are (DEV-911).
	case ungroupTabGroup(SidebarItem.ID)

	/// Pin Group: the group becomes a pinned folder (DEV-911).
	case pinTabGroup(SidebarItem.ID)

	/// The tab's own unread badges (DEV-1258): show or hide them on this tab whatever its site,
	/// profile or the browser default chooses, or nil to inherit again.
	case setTabUnreadBadges(SidebarItem.ID, UnreadBadgeVisibility?)

	/// Always Keep This Site Loaded, on or off: the tab's profile never unloads its site (DEV-932).
	case setSiteKeptLoaded(SidebarItem.ID, Bool)

	/// Keep Tab: a tab an agent opened becomes the person's, and is never tidied (DEV-1022).
	case keepAgentTab(SidebarItem.ID)

	/// Change Icon…: the tab's icon picker opens at its row or Favorite (DEV-1251).
	case changeIcon(SidebarItem.ID)

	/// The icon picker closed without a choice (DEV-1251).
	case dismissIconPicker

	/// An icon from the tab's picker, or nil from its reset button for the site's icon (DEV-1251).
	case setIcon(SidebarItem.ID, SpaceIcon?)
}

extension SidebarItem {
	/// A web tab's site, and whether its profile keeps it loaded (DEV-932).
	public struct KeepLoaded: Equatable, Sendable {
		/// The tab's site, such as `music.example.com`.
		public var site: String

		/// Whether its profile's list covers the site, by the site itself or a parent domain.
		public var isKept: Bool

		public init(
			site: String,
			isKept: Bool
		) {
			self.site = site
			self.isKept = isKept
		}
	}
}

extension SidebarItem {
	/// A Split View group shown as one row with a segment per member.
	public struct Split: Equatable, Sendable {
		public let id: UUID

		/// The tabs the row shows: the group's tabs in this list, without its Favorites.
		public var members: [SidebarItem]

		/// Every tab of the group in pane order, its Favorites included (DEV-1006).
		public var paneIDs: [SidebarItem.ID]
		public var title: String?
		public var icon: String?
		public var isVertical: Bool

		public init(
			id: UUID,
			members: [SidebarItem],
			paneIDs: [SidebarItem.ID]? = nil,
			title: String? = nil,
			icon: String? = nil,
			isVertical: Bool = false
		) {
			self.id = id
			self.members = members
			self.paneIDs = paneIDs ?? members.map(\.id)
			self.title = title
			self.icon = icon
			self.isVertical = isVertical
		}

		public var memberIDs: [SidebarItem.ID] { members.map(\.id) }

		/// Every tab of the group, Favorites included, as sharing its links takes them.
		public var paneTabIDs: [UUID] {
			paneIDs.compactMap { id in
				guard case let .tab(id) = id else { return nil }
				return id
			}
		}
	}
}

extension SidebarItem {
	/// A Split View group's panes, for a row that shows only one of its tabs (DEV-1006).
	public struct SplitPanes: Equatable, Sendable {
		public var count: Int
		public var isVertical: Bool

		public init(
			count: Int,
			isVertical: Bool
		) {
			self.count = count
			self.isVertical = isVertical
		}
	}
}

/// The group context menu's actions. Each names the group by its identity.
@CasePathable
public enum SplitGroupAction: Equatable, Sendable {
	case separate(group: UUID, tab: UUID)
	case separateAll(UUID)
	case addTab(UUID)
	case toggleOrientation(UUID)
	case rename(UUID, String?)
	case changeIcon(UUID, String?)
	case duplicate(UUID)
	case toggleMute(tab: UUID)
	case duplicateTab(UUID)
	case focus(group: UUID, tab: UUID)

	/// Move to… for the group's tabs in its list, which move as one block (DEV-1006).
	case chooseMoveDestination(UUID)
}

extension SidebarItem {
	public struct Interactions: OptionSet, Equatable, Sendable {
		public let rawValue: Int

		public init(rawValue: Int) {
			self.rawValue = rawValue
		}

		public static let select: Self = .init(rawValue: 1 << 0)
		public static let rename: Self = .init(rawValue: 1 << 1)
		public static let move: Self = .init(rawValue: 1 << 2)
		public static let trailingAction: Self = .init(rawValue: 1 << 3)
		public static let disclose: Self = .init(rawValue: 1 << 4)
		public static let createChild: Self = .init(rawValue: 1 << 5)
		public static let folderLifecycle: Self = .init(rawValue: 1 << 6)
		public static let updateSavedURL: Self = .init(rawValue: 1 << 7)
		public static let all: Self = [
			.select,
			.rename,
			.move,
			.trailingAction,
			.disclose,
			.createChild,
			.folderLifecycle,
			.updateSavedURL
		]
	}
}

extension SidebarItem {
	public struct SiteIcon: Hashable, Sendable {
		public let profileID: UUID
		public let pageURL: URL

		public init(
			profileID: UUID,
			pageURL: URL
		) {
			self.profileID = profileID
			self.pageURL = pageURL
		}

		/// Navigating within a site keeps its icon on screen until the new page's arrives.
		public func isSameSite(as other: Self) -> Bool {
			profileID == other.profileID && pageURL.host == other.pageURL.host
		}
	}
}

extension SidebarItem {
	/// An MCP client acting on a tab (DEV-899).
	public struct Agent: Equatable, Sendable {
		/// The client's name, as the user set it in Settings.
		public var name: String

		/// When the badge hides, or nil while the client is still acting.
		public var fadesAt: Date?

		/// The client that opened the tab, while the tab is still its: once nothing acts on it the
		/// row says so quietly, and its menu offers Keep Tab (DEV-1022).
		public var openedBy: String?

		public init(
			name: String,
			fadesAt: Date? = nil,
			openedBy: String? = nil
		) {
			self.name = name
			self.fadesAt = fadesAt
			self.openedBy = openedBy
		}

		/// A tab its client opened and nothing acts on: only the opener shows.
		public static func opener(_ name: String) -> Self {
			.init(name: name, fadesAt: .distantPast, openedBy: name)
		}
	}
}

extension SidebarItem {
	/// A selection of several tabs, counted for its bulk menu (DEV-883).
	public struct Selection: Equatable, Sendable {
		/// The selected tabs, in selection order.
		public var tabIDs: [ID]

		/// Of them, the open (unpinned) tabs, which close into the archive.
		public var openTabCount: Int

		/// Of them, pinned tabs and Favorites.
		public var savedTabCount: Int

		public init(
			tabIDs: [ID],
			openTabCount: Int,
			savedTabCount: Int
		) {
			self.tabIDs = tabIDs
			self.openTabCount = openTabCount
			self.savedTabCount = savedTabCount
		}

		public var tabCount: Int { tabIDs.count }
	}
}

extension SidebarItem {
	/// A tab's unread badge (DEV-907): a dot or a count, and the site Settings hides it for.
	public struct Unread: Equatable, Sendable {
		public var badge: UnreadBadge
		public var host: String?

		public init(
			badge: UnreadBadge,
			host: String?
		) {
			self.badge = badge
			self.host = host
		}
	}
}

extension SidebarItem {
	/// A tab's unread badges choice (DEV-1258): its own, or nil when it inherits, and what it
	/// inherits from its site, its profile or the browser default.
	public struct UnreadBadges: Equatable, Sendable {
		public var tab: UnreadBadgeVisibility?
		public var inherited: UnreadBadgeVisibility

		public init(
			tab: UnreadBadgeVisibility?,
			inherited: UnreadBadgeVisibility
		) {
			self.tab = tab
			self.inherited = inherited
		}

		/// What the tab shows.
		public var resolved: UnreadBadgeVisibility { tab ?? inherited }
	}
}

extension SidebarItem {
	/// A tab's sound (DEV-800).
	public struct Audio: Equatable, Sendable {
		/// Whether the tab's media is playing.
		public var isPlaying: Bool
		public var isMuted: Bool

		/// 0 to 1, on top of the page's own volume, or nil when the engine can't turn a tab down.
		public var volume: Double?

		public init(
			isPlaying: Bool = false,
			isMuted: Bool = false,
			volume: Double? = nil
		) {
			self.isPlaying = isPlaying
			self.isMuted = isMuted
			self.volume = volume
		}

		/// The row shows its speaker while the tab plays, is muted or is turned down.
		public var showsIndicator: Bool {
			isPlaying || isMuted || (volume ?? 1) < 1
		}

		/// The speaker, its waves following the volume.
		public var symbol: String {
			Self.symbol(isMuted: isMuted, volume: volume ?? 1)
		}

		public static func symbol(
			isMuted: Bool,
			volume: Double
		) -> String {
			if isMuted { return "speaker.slash.fill" }
			if volume <= 0 { return "speaker.fill" }
			if volume < 1 / 3 { return "speaker.wave.1.fill" }
			if volume < 2 / 3 { return "speaker.wave.2.fill" }
			return "speaker.wave.3.fill"
		}
	}
}
