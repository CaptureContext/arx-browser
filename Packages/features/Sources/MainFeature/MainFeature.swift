import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CommandBarFeature
import Foundation
import HistoryFeature
import SidebarFeature
import TabArchiveFeature
import ViewerFeature
import ViewerItemFeature
import _ComposableArchitecture

@Reducer
public struct MainFeature {
	@ObservableState
	public struct State: Equatable, Identifiable {
		public let id: UUID
		public let isPrivate: Bool

		/// The ordinary profile a private window belongs to, whose extensions allowed in private
		/// windows run there (DEV-956). AppFeature sets it when the window opens.
		public var privateOpenerProfileID: Profile.ID?
		public var downloadsAvailable: Bool
		public var mediaAvailable: Bool

		/// Tabs whose video can be presented in Media PiP now, which the app keeps current, for
		/// Present Media in Picture in Picture (DEV-1106).
		public var presentableMediaTabs: Set<BrowserCore.Tab.ID> = []
		public var captureAvailable: Bool

		/// A closed browser window can open again, for the command bar's Reopen Closed Window
		/// (DEV-908). AppFeature keeps it current.
		public var canReopenClosedWindow: Bool
		public var developerModeEnabled: Bool

		/// The `ARX_READING_MODE` feature flag, read at launch (DEV-1028).
		public var readingModeEnabled: Bool

		/// The `ARX_TRANSLATE` feature flag, so Translate Page works in a private window
		/// (DEV-1122). AppFeature keeps it current.
		public var pageTranslationEnabled: Bool

		/// Local development pages show the developer header: developer mode and its
		/// setting are both on (DEV-733).
		public var showsDeveloperHeader: Bool

		/// The `ARX_DEVICE_CAPTURE` feature flag: the developer header's Capture button opens
		/// the device capture popover (DEV-757).
		public var deviceCaptureEnabled: Bool

		/// Dark pages are offered: the feature flag, an engine that has them and a mode other than
		/// Off (DEV-1020). Shows the Dark Page command and the site menu's row.
		public var darkPagesOffered: Bool

		/// The device capture last taken in this window, which the popover opens with.
		public var deviceCaptureStyle: DeviceCaptureStyle
		public var isClosing: Bool
		public var sidebarWidth: Double
		public var sidebar: SidebarFeature.State
		public var commandBar: CommandBarFeature.State
		public var commandBarPaneID: UUID?
		public var commandBarContext: CommandBarContext?

		/// An empty split pane that closes if its command bar is dismissed without a destination.
		public var commandBarEmptyPaneID: UUID?

		/// The Split View group the panes showed after the last action, to notice it going away.
		public var shownSplitID: SplitGroup.ID?

		/// Within one `viewer.show` only: what its pane held before, so Split View can tell a
		/// new member filling an empty pane from a tab taking a member's place. Always nil
		/// between actions.
		internal var showReplacing: ShowReplacing?

		/// The page a chat tab took the place of when Open in Tab opened it (DEV-793). While the
		/// chat shows alone, dropping it on the page's edge splits it with that page.
		internal var chatTabOpenedOver: ChatTabOpenedOver?

		/// The tab a press selected and the tab selected before it, until that press ends with a
		/// click or another selection. A drag of the pressed tab into the page splits it with the
		/// previous tab (DEV-994).
		internal var pressSelection: PressSelection?

		public var isLibraryOpen: Bool
		public var librarySelection: LibrarySection

		/// Whether the chat panel shows in the right sidebar. The chats themselves belong to
		/// the profile, so hiding the panel never stops a turn. Private windows have no chat.
		public var isChatOpen: Bool

		/// The chat panel's width in this window, set by dragging its leading edge (DEV-761).
		/// Saved with the window's presentation; new windows start at the standard width.
		public var chatWidth: Double

		/// Chats pinned to this window's tabs (DEV-761), by tab. The panel on a pinned tab shows
		/// its chat; on any other tab it shows the window's global chat. Saved with the window's
		/// presentation, and a pin goes when its tab closes.
		public var chatPins: [BrowserCore.Tab.ID: UUID]

		public var browsingHistory: [Profile.ID: BrowsingHistorySnapshot]

		/// Profiles whose history couldn't be read, so `browsingHistory` has none for them.
		public var unreadableHistory: Set<Profile.ID>

		/// What the Library's History page keeps of its own: its search and a deletion awaiting
		/// confirmation. Its entries are always the profile's current history.
		public var historyQuery: String
		public var historyDeletion: HistoryFeature.Deletion?

		/// The profile `historyDeletion` was asked for. A confirmation never carries over to
		/// another profile when the window's space changes meanwhile.
		public var historyDeletionProfileID: Profile.ID?
		public var viewer: ViewerFeature.State
		public var pendingTabMove: TabMoveRequest?
		public var activeTabMove: TabMoveRequest?
		public var movePicker: TabMovePicker?
		public var transferInProgress: Bool
		public var pendingFolderDeletion: Folder.ID?
		public var automationCloseRequests: [BrowserCore.Tab.ID: UUID]
		public var knownTabIDs: Set<BrowserCore.Tab.ID>
		public var archive: TabArchiveFeature.State

		/// The URL bar's site menu (DEV-633).
		public var siteMenu: SiteMenuFeature.State

		/// Translation Available and its popover for each tab with something to offer; the app
		/// keeps them (DEV-996, behind `ARX_TRANSLATE`).
		public var translationOffers: [BrowserCore.Tab.ID: PageTranslationOffer]

		/// The pointer is over the sidebar's notice toast, which holds it (DEV-777).
		public var noticeIsHovered: Bool

		/// The color the shown pages offer the chrome, for a space that matches the site (DEV-1101).
		/// Kept apart from the panes' navigation, so the chrome redraws only when the color changes.
		public internal(set) var siteChromeColor: ChromePalette.RGB?

		/// The `ARX_RECENT_TAB_SWITCHER` feature flag, read when the window opens (DEV-544): ⌃Tab
		/// opens `tabSwitcher` instead of going to the next tab.
		public var recentTabSwitcherEnabled: Bool

		/// The `ARX_RETURN_TO_PREVIOUS_TAB` feature flag, read when the window opens (DEV-1228):
		/// closing or resetting the selected tab selects the one shown before it, from `recentTabs`.
		public var returnsToPreviousTab: Bool

		/// Within one action only: the selected tab being closed or reset, and the tab to select
		/// instead (DEV-1228). Always nil between actions.
		internal var leavingSelection: LeavingSelection?

		/// The tabs this window showed, most recent first, each with the space it showed it in
		/// (DEV-544). Closed tabs leave it; ⌃Tab's switcher lists them in this order.
		public var recentTabs: [RecentTab]

		/// The tab the window showed before the one it shows now (DEV-1228), kept with `recentTabs`:
		/// one tab back, and none once that tab closed, rather than an older one.
		public var previousRecentTab: RecentTab?

		/// The tab the window shows, or showed last, closed or not (DEV-1228): the one that becomes
		/// `previousRecentTab` when it shows another.
		public var lastShownRecentTab: RecentTab?

		/// ⌃Tab's switcher while ⌃ is held (DEV-544).
		public var tabSwitcher: TabSwitcher?
		private var requestedTabCloses: Set<BrowserCore.Tab.ID>

		/// Bindings shown beside commands, shared with Settings.
		@SharedReader
		public var keyboardShortcuts: [ShortcutBinding]

		/// Words that find commands, set in Settings.
		@SharedReader
		public var commandAliases: [CommandAlias]

		/// Proxy link rules, set in Settings: the proxy link commands need one that matches the
		/// page's site (DEV-1262).
		@SharedReader
		public var proxyLinkRules: [ProxyLinkRule]

		/// Where new tabs open among the space's open tabs, set in Settings (DEV-913), while
		/// `newTabsAtTop` is off; nothing while it's on (DEV-1174, DEV-1243).
		@SharedReader
		public var newTabPlacement: NewTabPlacement

		/// Where a tab from the New Tab button, ⌘T or ⌘K opens while `newTabsAtTop` is on, set in
		/// Settings › General › New tabs open (DEV-1174).
		@SharedReader
		public var openedTabSetting: NewTabPlacement

		/// Whether a tab opened from the New Tab button, ⌘T or the command bar goes where its own
		/// setting says (`ARX_NEW_TABS_AT_TOP`, DEV-1174).
		public var newTabsAtTop: Bool

		/// The main window's identity, which launch gives it.
		public static let mainWindowID: UUID = .init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

		public init(
			organization: BrowserOrganization,
			spaceID: Space.ID,
			isPrivate: Bool = false,
			id: UUID = Self.mainWindowID,
			downloadsAvailable: Bool = false,
			mediaAvailable: Bool = false,
			captureAvailable: Bool = false,
			developerModeEnabled: Bool = false,
			readingModeEnabled: Bool = ReadingMode.isOn,
			recentTabSwitcherEnabled: Bool = RecentTabSwitcherFeatureFlag.isOn(),
			returnsToPreviousTab: Bool = ReturnToPreviousTabFeatureFlag.isOn(),
			newTabsAtTop: Bool = NewTabsAtTopFeatureFlag.atLaunch,
			sidebarWidth: Double = BrowserSidebarWidth.standard,
			isLibraryOpen: Bool = false,
			librarySelection: LibrarySection = .downloads,
			browsingHistory: [Profile.ID: BrowsingHistorySnapshot] = [:]
		) {
			self.id = id
			self.isPrivate = isPrivate
			self.privateOpenerProfileID = nil
			self.downloadsAvailable = downloadsAvailable
			self.mediaAvailable = mediaAvailable
			self.captureAvailable = captureAvailable
			self.canReopenClosedWindow = false
			self.developerModeEnabled = developerModeEnabled
			self.readingModeEnabled = readingModeEnabled
			self.pageTranslationEnabled = false
			self.showsDeveloperHeader = false
			self.deviceCaptureEnabled = false
			self.darkPagesOffered = false
			self.deviceCaptureStyle = .default
			self.isClosing = false
			self.sidebarWidth = sidebarWidth
			self.sidebar = .init(
				organization: organization,
				spaceID: spaceID
			)
			self.commandBar = .init()
			self.commandBarPaneID = nil
			self.commandBarContext = nil
			self.commandBarEmptyPaneID = nil
			self.shownSplitID = nil
			self.showReplacing = nil
			self.chatTabOpenedOver = nil
			self.pressSelection = nil
			self._keyboardShortcuts = SharedReader(.keyboardShortcuts)
			self._commandAliases = SharedReader(.commandAliases)
			self._proxyLinkRules = SharedReader(.proxyLinkRules)
			self._newTabPlacement = SharedReader(.newTabPlacement)
			self._openedTabSetting = SharedReader(.openedTabPlacement)
			self.newTabsAtTop = newTabsAtTop
			self.isLibraryOpen = isLibraryOpen
			self.librarySelection = librarySelection
			self.isChatOpen = false
			self.chatWidth = BrowserChatWidth.standard
			self.chatPins = [:]
			self.browsingHistory = browsingHistory
			self.unreadableHistory = []
			self.historyQuery = ""
			self.historyDeletion = nil
			self.historyDeletionProfileID = nil

			var viewer: ViewerFeature.State = .init()
			viewer.spaceID = spaceID
			viewer.requestedSpaceID = spaceID
			self.viewer = viewer

			self.pendingTabMove = nil
			self.activeTabMove = nil
			self.movePicker = nil
			self.transferInProgress = false
			self.pendingFolderDeletion = nil
			self.automationCloseRequests = [:]
			self.requestedTabCloses = []
			self.knownTabIDs = Set(organization.tabs.map(\.id))
			self.archive = .init()
			self.siteMenu = .init()
			self.translationOffers = [:]
			self.noticeIsHovered = false
			self.siteChromeColor = nil
			self.recentTabSwitcherEnabled = recentTabSwitcherEnabled
			self.returnsToPreviousTab = returnsToPreviousTab
			self.leavingSelection = nil
			self.previousRecentTab = nil

			// The tab it opens on is the first it showed, so the first action changes nothing.
			let opening = organization.spaces[id: spaceID]?.selectedTabID
			self.recentTabs = recentTabSwitcherEnabled || returnsToPreviousTab
			? opening.map { [.init(tabID: $0, spaceID: spaceID)] } ?? []
			: []
			self.lastShownRecentTab = recentTabs.first
			self.tabSwitcher = nil
		}

		public var pendingProfileMove: Space.ID? { pendingTabMove?.plan.destination }

		/// Whether the panes now offer the chrome another color than `siteChromeColor` (DEV-1101):
		/// the app changed this window's panes outside its reducer, as a selection in another window does.
		public var siteChromeColorIsStale: Bool { siteChromeColor != shownSiteColor }

		/// Takes the color the panes offer now. Writes only a change, so the chrome redraws only then.
		public mutating func refreshSiteChromeColor() {
			let color = shownSiteColor
			if siteChromeColor != color { siteChromeColor = color }
		}

		private var shownSiteColor: ChromePalette.RGB? {
			MatchSiteBackground.color(
				panes: viewer.panes.map(\.item.navigation),
				active: viewer.panes.index(id: viewer.activePaneID) ?? 0
			)
		}

		/// The Library's History page for the current space's profile (DEV-817), built from the
		/// history the app keeps, so it updates live whatever changes it.
		public var historyPage: HistoryFeature.State {
			get {
				let profileID = isPrivate ? nil : sidebar.space.profileID
				let snapshot = profileID.flatMap { browsingHistory[$0] }
				return .init(
					profileID: profileID,
					entries: snapshot?.entries ?? [],
					isUnavailable: snapshot == nil && profileID.map(unreadableHistory.contains) == true,
					query: historyQuery,
					pendingDeletion: historyDeletionProfileID == profileID ? historyDeletion : nil
				)
			}
			set {
				historyQuery = newValue.query
				historyDeletion = newValue.pendingDeletion
				historyDeletionProfileID = newValue.pendingDeletion == nil ? nil : newValue.profileID
			}
		}

		public var pendingTabCloses: Set<BrowserCore.Tab.ID> {
			get { requestedTabCloses.union(automationCloseRequests.keys) }
			set { requestedTabCloses = newValue.subtracting(automationCloseRequests.keys) }
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case sidebar(SidebarFeature.Action)
		case commandBar(CommandBarFeature.Action)
		case viewer(ViewerFeature.Action)
		case archive(TabArchiveFeature.Action)
		case historyPage(HistoryFeature.Action)
		case siteMenu(SiteMenuFeature.Action)
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)
		case synchronize
		case synchronizeSelecting(BrowserCore.Tab.ID)
		case unloadResetTab(TabPresentationReset)
		case applyResetTab(TabPresentationReset)
		case dispatchCommand(BrowserCommand, UUID, source: CommandBarContext? = nil)
		case present(BrowserCore.Tab.ID, in: UUID)

		/// The app's answer to `requestSplit` when the tab enters a new pane here: a pinned tab of
		/// this space becomes an open one first, then the pane takes it (DEV-992).
		case addPane(BrowserCore.Tab.ID)
		case openFolderTabs([BrowserCore.Tab.ID])
		case refreshArchive

		/// Archives these unpinned tabs because their profile archives unviewed tabs. Tabs whose
		/// page asks to stay open are left alone, and nothing is reported.
		case archiveInactiveTabs([BrowserCore.Tab.ID])
		case reconcile(BrowserOrganization)
		case transferTabs([SidebarItem.ID], SidebarDropTarget?, Space.ID)

		/// The same move as `transferTabs`, already confirmed elsewhere (an approved automation
		/// request), so it skips the move confirmation. `UUID` becomes the request's ID.
		case transferConfirmedTabs(UUID, [SidebarItem.ID], SidebarDropTarget?, Space.ID)
		case performTabMove(TabMoveRequest)

		/// A chat tab follows its chat (DEV-761): the chat it shows and its title.
		case retargetChatTab(BrowserCore.Tab.ID, ChatTabAddress, title: String)

		/// The app allowed the tab dropped outside every window to leave for Little Arx (DEV-793).
		case tearOff(BrowserCore.Tab.ID, CGPoint)

		/// Move to Window or Open in New Window, after this window let the tabs go: they join the
		/// other window's space, if it's another one, as they are, pinned or open, as one undo;
		/// this window stays on its space (DEV-883). With independent windows or `windowUndo`, the
		/// undo goes back to `previous` and gives back `handedOver`, the tabs the other window
		/// didn't already show (DEV-1156). With `windowUndo`, `target`, the window they went to,
		/// can take the step back too (DEV-1030).
		case completeWindowMove(
			[BrowserCore.Tab.ID],
			spaceID: Space.ID?,
			previous: BrowserOrganization?,
			handedOver: [BrowserCore.Tab.ID],
			target: UUID
		)

		/// The app allowed Move to Window or Open in New Window for these tabs: this window lets
		/// them go, closing their split panes and selecting a neighbour (DEV-883).
		case releaseTabsForWindowMove([BrowserCore.Tab.ID])

		/// A step another window, Settings or an agent made, which ⌘Z here takes back too
		/// (DEV-1030).
		case appendUndo(OrganizationUndo)

		/// Another window took this step back, or found it can't be: it goes from here too.
		case dropUndo(OrganizationUndo)

		/// These tabs went to another window again, by Move to Window or a drop: an earlier Move to
		/// Window of them, but `keeping`, is no longer a step, so ⌘Z never pulls them back from
		/// where they went last (DEV-1030).
		case dropWindowMoves([BrowserCore.Tab.ID], keeping: OrganizationUndo?)

		/// These open tabs went to another window: a step here that made them would close them
		/// there, so it's no longer one (DEV-1030).
		case dropStepsMaking([BrowserCore.Tab.ID])

		/// The tab's page settled on this URL and title while no pane of this window showed it,
		/// for example an agent's or a restored tab moved along its history. The tab keeps them,
		/// as it does for the page a pane shows.
		case takePageNavigation(BrowserCore.Tab.ID, BrowserNavigation)

		/// ⌃ was held for `MainFeature.tabSwitcherBeat`: the switcher shows (DEV-544).
		case tabSwitcherBeat

		@CasePathable
		public enum UI: Sendable {
			case task
			case openCommand(CommandBarFeature.Mode)
			case paneCommand(BrowserCommand, UUID)

			/// Next Tab, Previous Tab and Select Tab N: selects one of the space's tabs (DEV-795).
			case selectTab(BrowserCore.Tab.ID)

			/// ⌃Tab's recent-tab switcher, from the app's key monitor and the switcher's rows (DEV-544).
			case tabSwitcher(TabSwitcherAction)

			/// View Page Source and Open File: the address in a new tab after the space's tabs (DEV-795).
			case openInNewTab(URL)
			case splitTab(BrowserCore.Tab.ID?)
			case presentNewPaneCommand
			case splitURL(URL)
			case focusOtherPane
			case closePane
			case swapPanes
			case toggleSplitOrientation

			/// A sidebar tab dropped on one of the page's edges, as a new pane on that side.
			case dropTabInViewer(BrowserCore.Tab.ID, SplitDropEdge)

			/// A sidebar tab dropped outside every Arx window, at this point in screen coordinates:
			/// it moves into Little Arx there (DEV-793).
			case dropTabOutsideWindows(BrowserCore.Tab.ID, CGPoint)

			/// A sidebar row started dragging this tab. The first drag after a press that selected
			/// the tab is the press's own; any other ends the press (DEV-994).
			case tabDragStarted(BrowserCore.Tab.ID)

			/// A button in a local page's developer header (DEV-733), for that pane.
			case developerHeader(DeveloperHeaderAction, UUID)

			/// Automation's Split View of these open tabs, in pane order.
			case openSplit([BrowserCore.Tab.ID], BrowserSpacePresentation.Orientation?)
			case duplicateTab
			case pinTab
			case copyURL
			case closeTab
			case openArchive
			case libraryOpenChanged(Bool)

			/// The Chats command, the panel's close button and Hide Chat (⇧esc).
			case chatOpenChanged(Bool)
			case sidebarWidthCommitted(Double)

			/// The chat panel's edge was dragged or double-clicked.
			case chatWidthCommitted(Double)

			/// Pin to This Tab: the chat becomes the tab's (DEV-761). Also follows a pinned panel
			/// moving to another chat.
			case chatPinned(BrowserCore.Tab.ID, UUID)

			/// Unpin from This Tab, for the tab.
			case chatUnpinned(BrowserCore.Tab.ID)

			/// Open in Tab: a chat tab for the chat, or a new one, after the current tab.
			case openChatTab(ChatTabAddress, title: String)

			/// Pin Chat to This Tab or Open Chat in Tab from the command bar or a menu.
			case chatPlacement(ChatPlacementRequest)
			case librarySectionSelected(LibrarySection)

			/// Opens the Library at a section, showing the sidebar if it was hidden: the Media command does this.
			case openLibrary(LibrarySection)
			case manageSpaces
			case changeOrganization(OrganizationChange)

			/// Delete Space when another Mac syncs it (DEV-1336): from this Mac only, which the
			/// other Macs keep, or from iCloud, which asks them to remove it too.
			case removeSpace(Space.ID, keepingElsewhere: Bool)

			/// Keep on a space another Mac removed from iCloud (DEV-1336): clears the mark on every Mac
			/// and cancels the removal.
			case keepMarkedSpace(Space.ID)
			case reopenLastClosedTab

			/// Archive ▸ Recently Closed: one archived tab of the window's profile (DEV-908).
			case reopenArchivedTab(ArchivedTab.ID)
			case archiveSelectedTabs([BrowserCore.Tab.ID])
			case moveSelectedTab(Space.ID)
			case moveSpaceToProfile(Space.ID, Profile.ID)
			case dismissMovePicker
			case chooseMoveDestination(Space.ID, Folder.ID?)
			case confirmProfileMove
			case cancelProfileMove

			/// The URL bar's site menu.
			case siteMenu(SiteMenuAction)

			/// The URL bar's translation popover, for the page in the active pane (DEV-996).
			case pageTranslation(PageTranslationOfferAction)

			/// The toast shows the sidebar notice with this ID, which starts its timer.
			case noticeShown(Int)

			/// The pointer entered or left the notice toast.
			case noticeHovered(Bool)

			/// The toast showing the sidebar notice with this ID left the window.
			case noticeRemoved(Int)
		}

		@CasePathable
		public enum Event: Sendable {
			case closePermissionGranted(BrowserCore.Tab.ID, Bool, BrowserOrganization.TabLocation)
			case closePermissionDenied(BrowserCore.Tab.ID)
			case tabResetCompleted(BrowserCore.Tab.ID)
			case archiveApproved([ArchivedTab])
			case archiveClosed([ArchivedTab])
			case archiveRestored(BrowserOrganization, BrowserOrganization, [BrowserCore.Tab])
			case archiveFailed(String)

			/// Pages allowed these automatic archives to close, and the `refused` ones asked to
			/// stay. The app checks again that the tabs are still unviewed, then answers with
			/// `archiveApproved` or `archiveFailed`.
			case inactiveArchivePermitted([ArchivedTab], refused: [BrowserCore.Tab.ID])
			case movedAcrossProfiles(TabMoveRequest)
			case moveFailed(UUID, String)
			case folderDeletionApproved(Folder.ID, [Folder])
			case folderDeletionCancelled(Folder.ID)
			case folderTabOpened(BrowserCore.Tab.ID, remaining: [BrowserCore.Tab.ID])
			case folderTabFailed(String, remaining: [BrowserCore.Tab.ID])

			/// The time of the sidebar notice with this ID ran out.
			case noticeExpired(Int)

			/// Every page of a bulk close allowed it (DEV-883).
			case bulkCloseApproved(BulkTabClose)

			/// The pages of a bulk close closed, so it commits as one undo (DEV-883).
			case bulkCloseFinished(BulkTabClose)

			/// A page refused a bulk close, or its tabs moved meanwhile: nothing closes (DEV-883).
			case bulkCloseFailed(BulkTabClose, String)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case command(BrowserCommand)
			case commandFromPane(BrowserCommand, UUID, source: CommandBarContext? = nil)

			/// The developer header's device capture of a pane's page (DEV-757).
			case deviceCaptureFromPane(DeviceCaptureStyle, UUID)
			case requestSplit(BrowserCore.Tab.ID)
			case presentationChanged
			case sidebarWidthChanged(Double)
			case requestSpacePresentation(Space.ID, selected: BrowserCore.Tab.ID?, selectRequested: Bool)
			case organizationChanged(BrowserOrganization)
			case changeOrganization(OrganizationChange)

			/// Keep on a space marked for deletion, with everything in it (DEV-1336), which iCloud sync
			/// applies.
			case keepMarked(Set<UUID>)
			case copyURL(URL)

			/// Open in Peek from ⌘K's panel (DEV-810), over this pane.
			case openInPeek(URL, paneID: UUID)

			/// Open in Little Arx from ⌘K's panel (DEV-810), in this space.
			case openInLittleArx(URL, Space.ID)

			/// The group menu's Mute, which the app applies to the tab's audio.
			case toggleMute(BrowserCore.Tab.ID)

			/// A tab row's speaker or menu (DEV-800), which the app applies to the tab's audio.
			case setTabMuted(BrowserCore.Tab.ID, Bool)

			/// A tab's volume, 0 to 1, from its speaker's popover (DEV-800).
			case setTabVolume(BrowserCore.Tab.ID, Double)

			/// The panel opened; the parent makes sure the profile's chats are ready.
			case chatOpened(Profile.ID)

			/// Text + Tab in the command bar, for a new chat in the profile.
			case startChat(String, Profile.ID)

			/// Pin Chat to This Tab or Open Chat in Tab, from the command bar or a menu (DEV-761).
			/// The app knows which chat the window shows.
			case chatPlacement(ChatPlacementRequest)

			/// The site menu's Share, with the page's address.
			case shareURL(URL)

			/// The site menu's Manage Extensions, for the page's profile.
			case manageExtensions(Profile.ID)

			/// The profile's Extensions sheet, on this extension (DEV-801).
			case showExtension(Profile.ID, extensionID: String)

			/// The profile's Extensions sheet, with the review of this extension's update (DEV-1210).
			case reviewExtensionUpdate(Profile.ID, extensionID: String)

			/// This extension's options page (DEV-801).
			case openExtensionOptions(Profile.ID, extensionID: String)

			/// The site menu turned an extension off or removed it (DEV-891).
			case extensionsChanged(Profile.ID)

			/// The site menu's All Site Settings, for the page's profile.
			case openSiteSettings(Profile.ID)

			/// The site menu's Add Extension (DEV-1317): the Chrome Web Store in a new Little Arx of
			/// the page's profile.
			case openWebstore(Profile.ID)

			/// The site menu cleared a site's cookies or cache in this profile (DEV-1142).
			case clearedSiteData(Profile.ID)

			/// A Settings row chosen in the command bar, by its destination's ID (DEV-1015).
			case openSettingsRow(String)

			/// An `arx://settings/…` or `chrome://settings/…` address opened from this window
			/// (DEV-1189): Settings at its place, for the window's profile.
			case openSettingsAddress(SettingsAddress)

			/// Another app's link typed in the command bar (DEV-1189), such as `slack://open`: the
			/// app macOS assigns opens it. The engine never navigates to it.
			case openAppLink(URL)

			/// The command bar opened a typed address in this tab (DEV-1015): history counts the
			/// page's visit as typed.
			case typedAddressOpened(URL, BrowserCore.Tab.ID)

			/// Translate Page or Show Original, from the site menu (DEV-904).
			case translatePage(BrowserCore.Tab.ID)

			/// The URL bar's translation popover, for this tab (DEV-996).
			case pageTranslation(BrowserCore.Tab.ID, PageTranslationOfferAction)

			/// A tab dropped outside every window asks to leave for Little Arx at this screen point
			/// (DEV-793). The app answers with `tearOff` unless something else holds the tab.
			case requestTearOff(BrowserCore.Tab.ID, at: CGPoint)

			/// Delete from History (DEV-810): the app removes the entries from the profile's
			/// history and every window's list. The Library's History page sends it too (DEV-817).
			case removeHistory(Profile.ID, BrowsingHistoryRemoval)

			/// The tab left this window's space for a Little Arx window at this screen point
			/// (DEV-793). Its page stays open for Little Arx to show.
			case moveToLittleArx(BrowserCore.Tab, Space.ID, at: CGPoint)

			/// Move to Window: these tabs of this space go to that window, which shows the first.
			/// Without a window, Open in New Window: a new window on the space shows it (DEV-883).
			case moveTabsToWindow([BrowserCore.Tab.ID], window: UUID?, spaceID: Space.ID)

			/// An open tab another window keeps was chosen here, from the command bar or a
			/// shortcut; the app brings that window forward with the tab (DEV-822).
			case selectTabInOtherWindow(BrowserCore.Tab.ID)

			/// Open tabs other windows keep were dropped among this window's open tabs; the app
			/// gives them to this window and lets the windows they left let them go (DEV-822).
			case takeOpenTabsFromOtherWindows([BrowserCore.Tab.ID])

			/// ⌘Z took this step back here, or found it can't be (DEV-1030). The app drops it from
			/// the other windows and, for Move to Window or Open in New Window, gives the tabs back
			/// to the window they left (DEV-1156).
			case undid(OrganizationUndo)

			/// Move to Window's step, which the window the tabs went to takes too (DEV-1030).
			case shareUndo(OrganizationUndo, windowID: UUID)

			/// The tab's own unread badges, or nil to inherit, which the app saves on this Mac
			/// (DEV-1258).
			case setTabUnreadBadges(BrowserCore.Tab.ID, UnreadBadgeVisibility?)

			/// Keep Tab: the tab an agent opened becomes the person's (DEV-1022).
			case keepAgentTab(BrowserCore.Tab.ID)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	@Dependency(\.commandBarSettingsRows)
	private var settingsRows

	@Dependency(\.sidebarSpaceSlide)
	private var sidebarSpaceSlide

	@Dependency(\.workspaceDocument)
	private var document

	public init() {}

	public var body: some ReducerOf<Self> {
		// Before the viewer replaces the pane's tab; SplitGroups reads it, and the last reducer clears it.
		Reduce { state, action in
			if case let .viewer(.show(_, id)) = action, let pane = state.viewer.panes[id: id] {
				state.showReplacing = .init(previousTabID: pane.item.tab?.id)
			}

			// Before the sidebar selects the pressed tab, while the previous one is still selected.
			switch action {
			case let .sidebar(.ui(.sidebar(.selectOnPress(.tab(uuid))))):
				state.pressSelection = state.pressSelection(of: .init(rawValue: uuid))

			case let .ui(.tabDragStarted(id)):
				// However the press's drag ended, a later drag isn't the press's.
				if state.pressSelection?.tab == id, state.pressSelection?.isDragging == false {
					state.pressSelection?.isDragging = true
				} else {
					state.pressSelection = nil
				}

			// The press ended another way: a click, another selection, or a drag that ended
			// somewhere other than the page.
			case .sidebar(.ui(.sidebar(.select))), .sidebar(.ui(.sidebar(.pressCompleted))), .sidebar(.ui(.spaceSelected)),
				.sidebar(.ui(.sidebar(.move))), .sidebar(.ui(.sidebar(.moveItems))), .sidebar(.ui(.move)),
				.sidebar(.ui(.moveItems)), .ui(.dropTabOutsideWindows):
				state.pressSelection = nil

			default:
				break
			}

			// Before the close commits, while the tab is still selected: what to select instead
			// (DEV-1228).
			let leaving: Set<BrowserCore.Tab.ID>? = switch action {
			case let .sidebar(.event(.closeApproved(id, _, _))): [id]
			case let .event(.bulkCloseFinished(request)): Set(request.tabIDs)
			default: nil
			}
			if let leaving, let previous = state.previousTab(leaving: leaving) {
				state.leavingSelection = .init(spaceID: state.sidebar.spaceID, tabs: leaving, previous: previous)
			}
			return .none
		}
		TabArchiving()
		RecentTabSwitching()
		Scope(state: \.archive, action: \.archive) { TabArchiveFeature() }
		Scope(state: \.historyPage, action: \.historyPage) { HistoryFeature() }

		Pullback(\.historyPage.delegate.open) { state, url in
			guard !state.isPrivate else { return .none }
			return .send(.ui(.openInNewTab(url)))
		}

		Pullback(\.historyPage.delegate.remove) { state, value in
			let (profileID, removal) = value
			guard !state.isPrivate else { return .none }
			return .send(.delegate(.removeHistory(profileID, removal)))
		}

		Scope(state: \.sidebar, action: \.sidebar) { SidebarFeature() }
		Scope(state: \.commandBar, action: \.commandBar) { CommandBarFeature() }
		Scope(state: \.viewer, action: \.viewer) { ViewerFeature() }
		Scope(state: \.siteMenu, action: \.siteMenu) { SiteMenuFeature() }

		ProfileTabTransfer()
		FolderLifecycle()
		SplitView()
		SplitGroups()
		TabTearOff()
		WindowUndo()
		TabResetPresentation()
		SidebarNotices()
		TabBulkActions()

		Pullback(\.sidebar.ui.sidebar.setMuted) { _, value in
			guard case let (.tab(id), isMuted) = value else { return .none }
			return .send(.delegate(.setTabMuted(.init(rawValue: id), isMuted)))
		}

		Pullback(\.sidebar.ui.sidebar.setTabUnreadBadges) { _, value in
			guard case let (.tab(id), visibility) = value else { return .none }
			return .send(.delegate(.setTabUnreadBadges(.init(rawValue: id), visibility)))
		}

		Pullback(\.sidebar.ui.sidebar.keepAgentTab) { _, id in
			guard case let .tab(rawValue) = id else { return .none }
			return .send(.delegate(.keepAgentTab(.init(rawValue: rawValue))))
		}

		// Always Keep This Site Loaded (DEV-932): the tab's profile adds its site, or drops every
		// entry that covers it. Private windows' tabs never unload.
		Pullback(\.sidebar.ui.sidebar.setSiteKeptLoaded) { state, value in
			let (itemID, kept) = value
			guard
				!state.isPrivate,
				case let .tab(id) = itemID,
				let tab = state.sidebar.organization.tabs[id: .init(rawValue: id)],
				let profile = state.sidebar.organization.profiles[id: tab.profileID],
				let site = KeptLoadedSite.site(of: tab.restoration.url)
			else { return .none }

			let entries = kept
			? [site]
			: (profile.keptLoadedSites ?? []).filter { KeptLoadedSite.matches(tab.restoration.url, site: $0) }
			return .merge(entries.map { entry in
				.send(.delegate(.changeOrganization(.setKeptLoadedSite(profile.id, site: entry, kept: kept))))
			})
		}

		Pullback(\.sidebar.ui.sidebar.setVolume) { _, value in
			guard case let (.tab(id), volume) = value else { return .none }
			return .send(.delegate(.setTabVolume(.init(rawValue: id), volume)))
		}

		Pullback(\.reconcile) { state, organization in
			var shared = organization

			// Every tab's location in one pass, not a search of the organization per space (DEV-947).
			let locations = organization.tabLocations
			for index in shared.spaces.indices {
				let space = shared.spaces[index]
				let previous = state.sidebar.organization
				let oldSelection = previous.spaces[id: space.id]?.selectedTabID
				let selection = shared.selection(oldSelection, from: previous, in: space)
				let valid = selection.map { id in
					switch locations[id] {
					case .favorite(space.profileID), .unpinned(space.id), .pinned(space.id, _): true
					default: false
					}
				} ?? false
				shared.spaces[index].selectedTabID = valid ? selection : nil
			}

			// Another window only changing what it shows, such as showing a tab this window just
			// moved there, leaves this window's undo standing (DEV-883). What another window or an
			// agent changed isn't this window's step: the step being made ends here (DEV-1030).
			if shared != state.sidebar.organization { state.sidebar.sealUndo() }
			state.sidebar.organization = shared
			let containsSelectedSpace = shared.spaces.ids.contains(state.sidebar.spaceID)
			if !containsSelectedSpace, let first = shared.spaces.first {
				state.sidebar.spaceID = first.id
			}
			state.knownTabIDs = Set(shared.tabs.map(\.id))
			let selected = state.sidebar.selectedTab
			return state.viewerSynchronization(selected: selected)
		}

		Pullback(\.ui.task) { state in

			// Another window took the selected tab while this one was closed (DEV-822): its
			// neighbour shows instead, in the kept layout too.
			var replacement: BrowserCore.Tab.ID?
			if let selected = state.sidebar.selectedTab?.id, !state.sidebar.windowShows(selected) {
				state.sidebar.selectNeighbour(leaving: [selected])
				replacement = state.sidebar.selectedTab?.id
			}
			guard state.viewer.preservesPresentation else {
				return .send(.viewer(.item(.show(state.sidebar.selectedTab))))
			}
			state.viewer.presentations = state.viewer.allPresentations
			state.viewer.requestedSpaceID = state.sidebar.spaceID
			return .send(.delegate(.requestSpacePresentation(
				state.sidebar.spaceID,
				selected: replacement,
				selectRequested: replacement != nil
			)))
		}

		Pullback(\.sidebar.ui) { _, action in
			switch action {
			// Keeping a site loaded is a Settings change, and Keep Tab an app change; a synchronize
			// queued ahead of either would publish this window's older copy over it (DEV-932, DEV-1022).
			case .sidebar(.toggleMoveSelection), .sidebar(.chooseMoveDestination), .sidebar(.setSiteKeptLoaded),
				.sidebar(.pressCompleted), .sidebar(.keepAgentTab), .sidebar(.changeIcon), .sidebar(.dismissIconPicker):
				return .none
			default: return .send(.synchronize)
			}
		}

		Pullback(\.sidebar.event.closeApproved) { _ in .send(.synchronize) }

		Pullback(\.sidebar.ui.spaceSelected) { state, _ in
			state.isLibraryOpen = false
			return .none
		}

		Pullback(\.sidebar.ui.newSpace) { state in
			state.isLibraryOpen = false
			return .none
		}

		Pullback(\.sidebar.ui.createSpace) { state, _ in
			state.isLibraryOpen = false
			return .none
		}

		Pullback(\.ui.libraryOpenChanged) { state, isOpen in
			state.isLibraryOpen = isOpen
			if isOpen, state.libraryPanel == .archive { state.prepareArchivePanel() }
			return .none
		}

		Pullback(\.ui.chatOpenChanged) { state, isOpen in
			guard !state.isPrivate || !isOpen
			else { return .none }

			state.isChatOpen = isOpen
			guard isOpen
			else { return .none }

			return .send(.delegate(.chatOpened(state.sidebar.space.profileID)))
		}

		Pullback(\.commandBar.delegate.startChat) { state, prompt in
			state.commandBarContext = nil
			if state.commandBar.focusRequest > 0 { state.commandBar.focusRequest += 1 }
			let closeEmptyPane: Effect<Action> = {
				guard
					let paneID = state.commandBarEmptyPaneID,
					state.viewer.panes[id: paneID]?.item.tab == nil
				else { return .none }

				return .send(.viewer(.ui(.closePane(paneID))))
			}()
			state.commandBarEmptyPaneID = nil
			guard !state.isPrivate
			else { return closeEmptyPane }

			state.isChatOpen = true
			return .merge(
				closeEmptyPane,
				.send(.delegate(.startChat(prompt, state.sidebar.space.profileID)))
			)
		}

		Pullback(\.ui.sidebarWidthCommitted) { state, width in
			let width = BrowserSidebarWidth.sanitized(width)
			guard width != state.sidebarWidth
			else { return .none }

			state.sidebarWidth = width
			return .send(.delegate(.sidebarWidthChanged(width)))
		}

		Pullback(\.ui.chatWidthCommitted) { state, width in
			let width = BrowserChatWidth.sanitized(width)
			guard width != state.chatWidth
			else { return .none }

			state.chatWidth = width
			return .send(.delegate(.presentationChanged))
		}

		Pullback(\.ui.chatPlacement) { state, request in
			guard !state.isPrivate
			else { return .none }

			return .send(.delegate(.chatPlacement(request)))
		}

		Pullback(\.ui.chatPinned) { state, value in
			let (tabID, conversationID) = value
			guard
				!state.isPrivate,
				let tab = state.sidebar.organization.tabs[id: tabID],
				!tab.isChat,
				state.chatPins[tabID] != conversationID
			else { return .none }

			state.chatPins[tabID] = conversationID
			return .send(.delegate(.presentationChanged))
		}

		Pullback(\.ui.chatUnpinned) { state, tabID in
			guard state.chatPins.removeValue(forKey: tabID) != nil
			else { return .none }

			return .send(.delegate(.presentationChanged))
		}

		Pullback(\.ui.openChatTab) { state, value in
			let (address, title) = value
			guard !state.isPrivate
			else { return .none }

			let page = state.viewer.item.tab.flatMap { $0.isChat ? nil : $0.id }
			let effect = openNewTab(address.url, title: title, in: state.viewer.activePaneID, state: &state)
			if let page, let chat = state.sidebar.selectedTab?.id, chat != page {
				state.chatTabOpenedOver = .init(chat: chat, page: page)
			} else {
				state.chatTabOpenedOver = nil
			}
			return effect
		}

		Pullback(\.retargetChatTab) { state, value in
			let (tabID, address, title) = value
			guard
				let index = state.sidebar.organization.tabs.index(id: tabID),
				state.sidebar.organization.tabs[index].isChat
			else { return .none }

			let restoration: BrowserCore.Tab.Restoration = .init(title: title, url: address.url)
			guard state.sidebar.organization.tabs[index].restoration != restoration
			else { return .none }

			state.sidebar.endOpenStep()
			state.sidebar.organization.tabs[index].restoration = restoration
			for pane in state.viewer.panes where pane.item.tab?.id == tabID {
				state.viewer.panes[id: pane.id]?.item.tab?.restoration = restoration
				state.viewer.panes[id: pane.id]?.item.navigation.url = address.url
				state.viewer.panes[id: pane.id]?.item.navigation.title = title
			}
			return .send(.delegate(.organizationChanged(state.sidebar.organization)))
		}

		Pullback(\.ui.manageSpaces) { state in
			state.librarySelection = .spaces
			state.isLibraryOpen = true
			return .none
		}

		Pullback(\.ui.changeOrganization) { _, change in
			.send(.delegate(.changeOrganization(change)))
		}

		Pullback(\.ui.removeSpace) { _, value in
			let (id, keepingElsewhere) = value
			let removal: Effect<Action> = .send(.delegate(.changeOrganization(.removeSpace(id))))
			guard keepingElsewhere else { return removal }

			return .concatenate(
				.run { [document] _ in document.keepRemovalOnThisMac([id.rawValue]) },
				removal
			)
		}

		Pullback(\.ui.keepMarkedSpace) { state, id in
			let items: Set<UUID> = state.sidebar.organization.itemsCovered(by: id.rawValue)
			return .send(.delegate(.keepMarked(items)))
		}

		Pullback(\.ui.librarySectionSelected) { state, section in
			guard state.librarySections.contains(section) else { return .none }
			state.librarySelection = section
			if section == .archive { state.prepareArchivePanel() }
			return .none
		}

		Pullback(\.ui.openLibrary) { state, section in
			guard state.librarySections.contains(section) else { return .none }
			state.librarySelection = section
			state.isLibraryOpen = true
			state.sidebar.sidebarIsVisible = true
			if section == .archive { state.prepareArchivePanel() }
			return .none
		}

		Pullback(\.sidebar.delegate.requestClose) { state, value in
			let (id, reset) = value
			guard
				let location = state.sidebar.organization.location(of: id),
				state.pendingTabCloses.insert(id).inserted
			else { return .none }

			return .run { [engine] send in
				guard await engine.permitsClosing(id), !Task.isCancelled else {
					await send(.event(.closePermissionDenied(id)))
					return
				}
				await send(.event(.closePermissionGranted(id, reset, location)))
			}
		}

		Pullback(\.event.closePermissionDenied) { state, id in
			state.pendingTabCloses.remove(id)
			return .none
		}

		Pullback(\.event.tabResetCompleted) { state, id in
			state.pendingTabCloses.remove(id)
			return .none
		}

		Pullback(\.sidebar.delegate.openCommandBar) { _ in .send(.ui(.openCommand(.newTab))) }

		Pullback(\.sidebar.delegate.resetTab) { state, id in
			state.pendingTabCloses.insert(id)
			let profile = state.sidebar.organization.tabs[id: id]?.profileID
			return .run { [engine] send in
				await engine.close(id)

				// It reopens at its saved page alone, without the history it had (DEV-878).
				if let profile { await engine.discardNavigation(id, profile) }
				await send(.event(.tabResetCompleted(id)))
			}
		}

		Pullback(\.ui.duplicateTab) { state in
			guard let source = state.sidebar.selectedTab else { return .none }
			let id = BrowserCore.Tab.ID(rawValue: uuid())
			let spaceID = state.sidebar.spaceID
			let navigation: BrowserNavigation = state.viewer.item.tab?.id == source.id
			? state.viewer.item.navigation
			: .init()
			state.sidebar.edit { organization in
				guard let index = organization.spaces.index(id: spaceID)
				else { return }
				organization.tabs.append(.init(
					id: id,
					profileID: source.profileID,
					restoration: .init(
						title: navigation.title.isEmpty ? source.restoration.title : navigation.title,
						url: navigation.url ?? source.restoration.url
					),
					customTitle: source.customTitle,
					icon: source.icon
				))

				// Directly below the tab it copies, or first for a bookmark's copy (DEV-1310, DEV-1325).
				organization.placeOpenedTab(id, inSpaceAt: index, opener: source.id)
				organization.spaces[index].selectedTabID = id
			}

			// The copy's first page takes the tab's back/forward history (DEV-878).
			return .concatenate(
				.run { @MainActor [engine] _ in engine.cloneNavigation(source, id) },
				.send(.synchronize)
			)
		}

		Pullback(\.ui.pinTab) { state in
			guard let tab = state.sidebar.selectedTab, tab.savedDestination == nil
			else { return .none }
			return .send(.sidebar(.ui(.sidebar(.move(.tab(tab.id.rawValue), .savedRoot)))))
		}

		// Resolved in the same turn, so the menu never acts on a page it no longer shows.
		Pullback(\.ui.pageTranslation) { state, action in
			guard let tabID = state.siteMenuContext?.tabID else { return .none }
			return .send(.delegate(.pageTranslation(tabID, action)))
		}

		Pullback(\.ui.siteMenu) { state, action in
			let child: SiteMenuFeature.Action
			if case .opened = action {
				guard let context = state.siteMenuContext else { return .none }
				child = .ui(.open(context))

			} else if case .runExtension = action {
				// Only for the page the menu opened over, while it's still shown.
				guard
					let menuContext = state.siteMenu.context,
					state.siteMenuContext?.tabID == menuContext.tabID
				else { return .none }

				child = .ui(.menu(action))

			} else if case .setDarkPage = action {
				// Only for the page and profile the menu opened over; the command may have changed
				// the site while the menu stayed open (DEV-1020).
				guard
					let menuContext = state.siteMenu.context,
					let live = state.siteMenuContext,
					live.tabID == menuContext.tabID,
					live.profileID == menuContext.profileID,
					live.url == menuContext.url
				else { return .none }

				state.siteMenu.context?.darkPage = live.darkPage
				child = .ui(.menu(action))

			} else {
				child = .ui(.menu(action))
			}
			return SiteMenuFeature()
				._reduce(into: &state.siteMenu, action: child)
				.map(Action.siteMenu)
		}

		Pullback(\.siteMenu.delegate) { state, delegate in
			switch delegate {
			case let .share(url):
				return .send(.delegate(.shareURL(url)))

			case let .command(command):
				return .send(.delegate(.command(command)))

			case let .manageExtensions(profileID):
				return .send(.delegate(.manageExtensions(profileID)))

			case let .showExtension(profileID, extensionID):
				return .send(.delegate(.showExtension(profileID, extensionID: extensionID)))

			case let .reviewExtensionUpdate(profileID, extensionID):
				return .send(.delegate(.reviewExtensionUpdate(profileID, extensionID: extensionID)))

			case let .openExtensionOptions(profileID, extensionID):
				return .send(.delegate(.openExtensionOptions(profileID, extensionID: extensionID)))

			case let .extensionsChanged(profileID):
				return .send(.delegate(.extensionsChanged(profileID)))

			case let .openSiteSettings(profileID):
				return .send(.delegate(.openSiteSettings(profileID)))

			case let .clearedSiteData(profileID):
				return .send(.delegate(.clearedSiteData(profileID)))

			case let .openWebstore(profileID):
				guard !state.isPrivate else { return .none }
				return .send(.delegate(.openWebstore(profileID)))

			case let .translatePage(tabID):
				return .send(.delegate(.translatePage(tabID)))
			}
		}

		Pullback(\.ui.copyURL) { state in
			let url = state.viewer.item.navigation.url
			?? state.sidebar.selectedTab?.restoration.url

			guard let url else { return .none }

			return .send(.delegate(.copyURL(url)))
		}

		Pullback(\.ui.closeTab) { state in
			guard let tab = state.sidebar.selectedTab else { return .none }
			let id = SidebarItem.ID.tab(tab.id.rawValue)

			return .send(.sidebar(.ui(.sidebar(tab.savedDestination == nil ? .close(id) : .reset(id)))))
		}

		Pullback(\.synchronize) { state in synchronize(&state) }
		Pullback(\.synchronizeSelecting) { state, id in synchronize(&state, selecting: id) }

		Pullback(\.viewer) { state, action in
			let id: BrowserCore.Tab.ID
			let navigation: BrowserNavigation
			switch action {
			case let .item(.delegate(.navigation(tabID, value))),
				let .panes(.element(_, .item(.delegate(.navigation(tabID, value))))):
				id = tabID
				navigation = value
			default: return .none
			}
			return takeNavigation(navigation, for: id, state: &state)
		}

		// A page no pane of this window shows, such as an agent's or a background tab's.
		Pullback(\.takePageNavigation) { state, value in
			let (id, navigation) = value
			return takeNavigation(navigation, for: id, state: &state)
		}

		Pullback(\.ui.openCommand) { state, mode in
			state.commandBarPaneID = state.viewer.activePaneID
			state.commandBarContext = .init(
				window: state,
				paneID: state.viewer.activePaneID,
				mode: mode
			)
			state.commandBarEmptyPaneID = state.emptySplitPane(state.viewer.activePaneID, mode: mode)
			let query = mode == .currentTab ? (state.viewer.item.navigation.url?.absoluteString ?? "") : ""

			state.prepareCommandBar()

			// Show History lists only history; its open tabs are there for Switch to Tab (DEV-810).
			let candidates: [CommandBarFeature.Entry] = switch mode {
			case .history:
				state.historyCandidates(profileID: state.sidebar.space.profileID, excludingOpenTabs: false)
				+ state.tabCandidates

			default:
				// Settings rows answer typed text, with each toggle's state as it is now (DEV-1015).
				state.commandCandidates + MainActor.assumeIsolated { [settingsRows] in settingsRows.entries() }
			}
			return .send(.commandBar(.present(mode, query, candidates)))
		}

		Pullback(\.ui.selectTab) { state, id in
			guard
				state.sidebar.organization.tabs[id: id]?.profileID == state.sidebar.space.profileID,
				state.sidebar.organization.tabOrder(in: state.sidebar.spaceID).contains(id)
			else { return .none }
			guard state.sidebar.windowShows(id) else { return .send(.delegate(.selectTabInOtherWindow(id))) }

			state.sidebar.select(id)
			return .merge(
				state.viewerSynchronization(selected: state.sidebar.selectedTab, paneID: state.viewer.activePaneID),
				.send(.delegate(.organizationChanged(state.sidebar.organization)))
			)
		}

		Pullback(\.ui.openInNewTab) { state, url in
			openNewTab(url, in: state.viewer.activePaneID, state: &state)
		}

		Pullback(\.commandBar.ui.dismissed) { state in
			guard !state.commandBar.isPresented else { return .none }
			state.commandBarContext = nil
			if state.commandBar.focusRequest > 0 { state.commandBar.focusRequest += 1 }
			guard let paneID = state.commandBarEmptyPaneID else { return .none }
			state.commandBarEmptyPaneID = nil
			guard state.viewer.panes[id: paneID]?.item.tab == nil else { return .none }
			return .send(.viewer(.ui(.closePane(paneID))))
		}

		Pullback(\.commandBar.delegate.removeHistory) { state, value in
			let (profileID, removal) = value
			guard
				!state.isPrivate,
				profileID == state.sidebar.space.profileID
			else { return .none }

			return .send(.delegate(.removeHistory(profileID, removal)))
		}

		Pullback(\.commandBar.delegate.execute) { state, execution in
			guard
				let context = state.commandBarContext,
				context.presentationID == execution.presentationID
			else { return .none }

			state.commandBarContext = nil
			let emptyPaneID = state.commandBarEmptyPaneID
			state.commandBarEmptyPaneID = nil
			guard context.matches(state, execution: execution) else { return .none }

			// Actions that open nothing in a new split's empty pane leave it, so it closes as
			// it would for Esc (DEV-810).
			let closeEmptyPane: Effect<Action> = emptyPaneID.flatMap { id in
				state.viewer.panes[id: id]?.item.tab == nil ? .send(.viewer(.ui(.closePane(id)))) : nil
			} ?? .none
			let mode = execution.mode
			var intent = execution.entry.intent

			// An action on a history result needs the entry to still stand, as Return does (DEV-810).
			if case let .openHistory(selection) = execution.origin?.intent {
				guard state.isCurrent(selection) else { return .none }
			}
			if case let .openHistory(selection) = intent {
				guard state.isCurrent(selection) else { return .none }
				intent = .open(selection.url)
			}

			// `chrome://downloads`, `history` and `extensions` run Arx's command for them (DEV-1189).
			if
				let url = intent.openedURL,
				case let .command(command)? = Self.settingsAddress(url)
			{
				intent = .command(command)
			}
			let paneID = context.paneID
			switch intent {
			case let .command(command):
				guard
					let available = state.commandContext(in: paneID),
					command.isEnabled(in: available)
				else { return .none }
				return .send(.delegate(.commandFromPane(command, paneID, source: context)))

			case let .selectTab(id):
				guard state.sidebar.organization.tabs[id: id]?.profileID == state.sidebar.space.profileID
				else { return .none }
				guard state.sidebar.windowShows(id) else {
					return .merge(.send(.delegate(.selectTabInOtherWindow(id))), closeEmptyPane)
				}

				// A tab chosen for a split's empty pane moves into the list the split's tabs share
				// (DEV-1006); the change is published below.
				if emptyPaneID == paneID, state.viewer.isSplit, state.viewer.panes[id: paneID]?.item.tab == nil {
					_ = state.gatherTabForPane(id)
				}
				state.sidebar.select(id)

			case let .selectSpace(id):
				// Another space slides in first and is selected once the slide lands, as from
				// a key or the switcher (DEV-1310); where the sidebar can't, it's selected now.
				guard
					id != state.sidebar.spaceID,
					let index = state.sidebar.organization.spaces.index(id: id)
				else {
					state.isLibraryOpen = false
					state.sidebar.selectSpace(id)
					break
				}
				let slide = sidebarSpaceSlide.slide
				return .run { send in
					if await slide(index) { return }
					await send(.sidebar(.ui(.spaceSelected(id))))
				}

			case let .revealFolder(id): state.sidebar.reveal(id)

			case .newFolder: return .send(.sidebar(.ui(.sidebar(.newFolder(nil)))))

			case .toggleSidebar: return .send(.sidebar(.ui(.sidebar(.toggleSidebar))))

			// The command bar copies the calculator's result itself (DEV-895), and a disabled
			// command does nothing (DEV-1262).
			case .useShortcut, .openHistory, .copyText, .disabledCommand: return .none

			case .undo: return .send(.sidebar(.ui(.undo)))

			case let .openInNewTab(url):
				if let opened = Self.openOutsidePages(url) {
					return .merge(opened, closeEmptyPane)
				}
				let opened = openNewTab(url, in: paneID, placement: state.openedTabPlacement, state: &state)
				return .merge(opened, typedAddressOpened(url, in: state.sidebar.selectedTab?.id, execution))

			case let .openInPeek(url):
				guard !state.isPrivate else { return .none }
				return .send(.delegate(.openInPeek(url, paneID: paneID)))

			case let .openInLittleArx(url):
				guard !state.isPrivate else { return closeEmptyPane }
				return .merge(.send(.delegate(.openInLittleArx(url, state.sidebar.spaceID))), closeEmptyPane)

			case let .copyURL(url):
				return .merge(.send(.delegate(.copyURL(url))), closeEmptyPane)

			case let .openSettings(id):
				return .merge(.send(.delegate(.openSettingsRow(id))), closeEmptyPane)

			case let .open(url):
				if let opened = Self.openOutsidePages(url) {
					return .merge(opened, closeEmptyPane)
				}
				if mode != .newTab, let tab = state.viewer.panes[id: paneID]?.item.tab {
					return .merge(
						.send(.viewer(.command(.navigate(url), in: paneID, tabID: tab.id))),
						typedAddressOpened(url, in: tab.id, execution)
					)
				}
				let opened = openNewTab(url, in: paneID, placement: state.openedTabPlacement, state: &state)
				return .merge(opened, typedAddressOpened(url, in: state.sidebar.selectedTab?.id, execution))
			}

			return .merge(
				state.viewerSynchronization(selected: state.sidebar.selectedTab, paneID: paneID),
				.send(.delegate(.organizationChanged(state.sidebar.organization)))
			)
		}

		Pullback(\.dispatchCommand) { state, value in
			let (command, paneID, source) = value
			let isSourceCurrent = source == nil
			|| (source?.paneID == paneID && source?.matches(state) == true)

			guard isSourceCurrent else { return .none }
			guard
				let available = state.commandContext(in: paneID),
				command.isEnabled(in: available)
			else { return .none }

			let action: Action
			switch command {
			case .newTab, .address, .commandBar, .closeTab, .copyURL, .duplicateTab, .pinTab,
				.archiveSelectedTabs, .findInPage, .findNext, .findPrevious, .goBack, .goForward,
				.reload, .clearCacheAndReload, .reloadBypassingCache, .zoomIn, .zoomOut, .actualSize,
				.developerTools, .inspectElement, .javaScriptConsole, .newSplit, .focusOtherPane, .closePane,
				.swapPanes, .toggleSplitOrientation, .stopLoading, .viewSource, .readingMode:
				action = .ui(.paneCommand(command, paneID))

			case .openArchive: action = .ui(.openArchive)

			case .reopenLastClosedTab: action = .ui(.reopenLastClosedTab)

			case .newFolder: action = .sidebar(.ui(.sidebar(.newFolder(nil))))

			case .undoOrganization: action = .sidebar(.ui(.undo))

			case .toggleSidebar: action = .sidebar(.ui(.sidebar(.toggleSidebar)))

			default:
				guard let organization = state.organizationAction(for: command) else { return .none }
				action = organization
			}

			// Resolve the local command in the same turn as the source check.
			return MainFeature()._reduce(into: &state, action: action)
		}

		// After every edit, including moves applied as a whole plan: a group keeps only open tabs
		// still next to each other in its space, so a committed move away takes a tab out.
		Reduce { state, _ in
			var changed: Effect<Action> = .none
			if !state.sidebar.organization.splits.isEmpty {
				var splits = state.sidebar.organization
				splits.normalizeSplits()
				if splits.splits != state.sidebar.organization.splits {
					state.sidebar.organization.splits = splits.splits
					changed = .send(.delegate(.organizationChanged(state.sidebar.organization)))
				}
			}

			// Tab groups the same way (DEV-911).
			if !state.sidebar.organization.tabGroups.isEmpty {
				var groups = state.sidebar.organization
				groups.normalizeTabGroups()
				if groups.tabGroups != state.sidebar.organization.tabGroups {
					state.sidebar.organization.tabGroups = groups.tabGroups
					changed = .send(.delegate(.organizationChanged(state.sidebar.organization)))
				}
			}
			state.showReplacing = nil
			return .merge(changed, state.followShownSplit())
		}

		// A pin goes with its tab (DEV-761): closing the tab unpins the chat, which stays in the
		// profile's chats.
		Reduce { state, _ in
			guard !state.chatPins.isEmpty
			else { return .none }

			let pins = state.chatPins.filter { state.sidebar.organization.tabs[id: $0.key] != nil }
			guard pins.count != state.chatPins.count
			else { return .none }

			state.chatPins = pins
			return .send(.delegate(.presentationChanged))
		}

		// Last, so it sees what every reducer above did, such as a reconciled profile: when the
		// profile turned suggestions off, or the bar now belongs to one that doesn't allow them,
		// nothing more may go out, in this same action.
		Reduce { state, _ in
			let reducer = CommandBarFeature()
			let privacy: Effect<CommandBarFeature.Action> = state.commandBar.suggestsRemotely && !state.suggestsRemotely
			? reducer._reduce(into: &state.commandBar, action: .allowSuggestions(false))
			: .none
			let profileEngine = state.profileSearchEngine
			let engine = reducer._reduce(into: &state.commandBar, action: .useSearchEngine(profileEngine))
			return Effect<CommandBarFeature.Action>.merge(privacy, engine).map(Action.commandBar)
		}

		PreviousTabSelection()
		RecentTabRecording()

		// Match site (DEV-1101), after every reducer that changes the panes or their pages.
		Reduce { state, _ in
			state.refreshSiteChromeColor()
			return .none
		}
	}

	/// Tells history that `execution`, if typed, opened `url` in `tabID` (DEV-1015).
	private func typedAddressOpened(
		_ url: URL,
		in tabID: BrowserCore.Tab.ID?,
		_ execution: CommandBarFeature.Execution
	) -> Effect<Action> {
		guard execution.isTypedAddress, let tabID else { return .none }
		return .send(.delegate(.typedAddressOpened(url, tabID)))
	}

	/// A typed address that isn't a page (DEV-1189): Settings, or another app's link. Nil for a
	/// page, which opens as any other.
	///
	/// Settings opens for the window's profile. An app's link opens in its app, and no tab is
	/// made or changed for it.
	private static func openOutsidePages(_ url: URL) -> Effect<Action>? {
		if let address = Self.settingsAddress(url) {
			return .send(.delegate(.openSettingsAddress(address)))
		}
		guard
			FeatureFlag.schemeAddresses.isOn(),
			TypedSchemeAddress.opensInApp(url)
		else { return nil }

		return .send(.delegate(.openAppLink(url)))
	}

	/// The settings address `url` names, while the `ARX_SCHEME_ADDRESSES` feature flag is on.
	internal static func settingsAddress(_ url: URL) -> SettingsAddress? {
		guard FeatureFlag.schemeAddresses.isOn() else { return nil }
		return SettingsAddress(url)
	}

	/// Opens `url` in a new tab of the current space and selects it: where `placement` says, or
	/// without one, as a tab the current tab opened, right below it or at the top of the open tabs
	/// when it's a Favorite or a pinned tab (DEV-1243).
	private func openNewTab(
		_ url: URL,
		title: String? = nil,
		in paneID: UUID,
		placement: NewTabPlacement? = nil,
		state: inout State
	) -> Effect<Action> {
		let tabID = BrowserCore.Tab.ID(rawValue: uuid())
		let spaceID = state.sidebar.spaceID

		// A new tab filling a split's empty pane goes into the list the split's tabs share, as a
		// tab chosen for it does: in Pinned or a folder it's pinned there (DEV-1006).
		let fillsEmptyPane = state.viewer.isSplit && state.viewer.panes[id: paneID].map { $0.item.tab == nil } == true
		let anchor = fillsEmptyPane ? state.paneAnchor(excluding: tabID) : nil

		// Without a placement, a tab the current tab opened, directly after it.
		let opener = placement == nil ? state.sidebar.organization.spaces[id: spaceID]?.selectedTabID : nil
		state.sidebar.edit { organization in
			guard let index = organization.spaces.index(id: spaceID)
			else { return }
			organization.tabs.append(.init(
				id: tabID,
				profileID: organization.spaces[index].profileID,
				restoration: .init(
					title: title ?? url.host() ?? url.absoluteString,
					url: url
				)
			))
			if let placement {
				organization.placeNewTab(
					tabID,
					inSpaceAt: index,
					placement: placement,
					current: organization.spaces[index].selectedTabID
				)
			} else {
				organization.placeOpenedTab(
					tabID,
					inSpaceAt: index,
					opener: opener
				)
			}
			organization.spaces[index].selectedTabID = tabID
			if let anchor { try? organization.gatherForSplit([tabID], joining: anchor) }
		}
		return .merge(
			state.viewerSynchronization(selected: state.sidebar.selectedTab, paneID: paneID),
			.send(.delegate(.organizationChanged(state.sidebar.organization)))
		)
	}

	/// The tab keeps the URL and title its page finished loading with, so the sidebar, an
	/// agent's inventory and the next launch see where the page is.
	private func takeNavigation(
		_ navigation: BrowserNavigation,
		for id: BrowserCore.Tab.ID,
		state: inout State
	) -> Effect<Action> {
		// Startup and provisional loads can report about:blank. Keep the last usable URL.
		guard !navigation.isLoading, navigation.errorCode == nil else { return .none }
		guard let index = state.sidebar.organization.tabs.index(id: id)
		else { return .none }
		let restoration = state.sidebar.organization.tabs[index].restoration
		let url = navigation.url ?? restoration.url
		let title = navigation.title.isEmpty ? restoration.title : navigation.title

		// Publishing reconciles every window and schedules a save; skip finished loads
		// that leave the restorable URL and title unchanged.
		guard url != restoration.url || title != restoration.title else { return .none }

		// What the page loaded isn't part of the step being made, so ⌘Z leaves it (DEV-1030).
		state.sidebar.endOpenStep()
		state.sidebar.organization.tabs[index].restoration.url = url
		state.sidebar.organization.tabs[index].restoration.title = title
		return .send(.delegate(.organizationChanged(state.sidebar.organization)))
	}

	private func synchronize(
		_ state: inout State,
		selecting id: BrowserCore.Tab.ID? = nil
	) -> Effect<Action> {
		let ids = Set(state.sidebar.organization.tabs.map(\.id))
		let removed = state.knownTabIDs.subtracting(ids)
		state.knownTabIDs = ids
		let selected = state.sidebar.selectedTab

		// A later selection must not be replaced by a queued move completion.
		let paneID = id != nil && selected?.id == id ? state.viewer.activePaneID : nil
		let changeViewer = state.viewerSynchronization(selected: selected, paneID: paneID)

		return .merge(
			changeViewer,
			.run { [engine] _ in
				for id in removed { await engine.close(id) }
			},
			.send(.delegate(.organizationChanged(state.sidebar.organization)))
		)
	}
}

extension MainFeature.State {
	internal struct ShowReplacing: Equatable, Sendable {
		internal var previousTabID: BrowserCore.Tab.ID?
	}

	internal struct ChatTabOpenedOver: Equatable, Sendable {
		internal var chat: BrowserCore.Tab.ID
		internal var page: BrowserCore.Tab.ID
	}

	internal struct PressSelection: Equatable, Sendable {
		/// The tab the press selected.
		internal var tab: BrowserCore.Tab.ID

		/// The tab selected before the press.
		internal var previous: BrowserCore.Tab.ID

		/// What the page showed before the press, in pane order: the previous tab, its group or
		/// the pinned tabs and Favorites sharing its panes.
		internal var panes: [BrowserCore.Tab.ID]
		internal var orientation: ViewerFeature.Orientation
		internal var fractions: [Double]

		/// Whether the press's drag has started; a second drag ends the press.
		internal var isDragging: Bool = false
	}

	/// What a press on `pressed` records before it selects: the page it's about to replace, unless
	/// the press changes nothing the page shows.
	fileprivate func pressSelection(of pressed: BrowserCore.Tab.ID) -> PressSelection? {
		guard
			viewer.spaceID == sidebar.spaceID,
			let previous = sidebar.selectedTab?.id,
			previous != pressed,
			!viewer.panes.contains(where: { $0.item.tab?.id == pressed })
		else { return nil }

		let shown = viewer.panes.enumerated().compactMap { index, pane in
			pane.item.tab.map { (id: $0.id, share: viewer.fractions.indices.contains(index) ? viewer.fractions[index] : nil) }
		}
		guard !shown.isEmpty else { return nil }
		let shares = shown.compactMap(\.share)
		return .init(
			tab: pressed,
			previous: previous,
			panes: shown.map(\.id),
			orientation: viewer.orientation,
			fractions: SplitLayout.sanitized(shares.count == shown.count ? shares : nil, count: shown.count)
		)
	}
}

extension MainFeature.State {
	internal var profileSearchEngine: SearchEngine {
		sidebar.organization.profiles[id: sidebar.space.profileID]?.searchEngine ?? .google
	}

	/// Whether the address bar shows the whole URL, as the current space's profile chose.
	public var showsFullURL: Bool {
		sidebar.organization.profiles[id: sidebar.space.profileID]?.showsWholeURL ?? false
	}

	/// Whether the command bar may ask the search provider for suggestions: the current
	/// space's profile allows it and the window isn't private.
	internal var suggestsRemotely: Bool {
		!isPrivate && (sidebar.organization.profiles[id: sidebar.space.profileID]?.suggestsRemotely ?? true)
	}

	/// What the command bar lists, with history ranked as of the profile's latest visit: what
	/// was seen together keeps its order however long the Mac sat idle, and nothing reads the
	/// clock.
	public var commandCandidates: [CommandBarFeature.Entry] {
		let latest = browsingHistory[sidebar.space.profileID]?.entries.lazy.map(\.lastVisited).max()
		return commandCandidates(at: latest ?? .distantPast)
	}

	/// What the command bar lists: tabs, then history by frecency as of `now` (DEV-1015), then
	/// spaces, folders and commands. An open tab carries its page's score, so the address match
	/// weighs it as the page.
	public func commandCandidates(at now: Date) -> [CommandBarFeature.Entry] {
		let profile = sidebar.space.profileID
		let history = historyCandidates(profileID: profile, excludingOpenTabs: false, rankedAt: now)
		var scores: [URL: Double] = [:]
		for entry in history where entry.frecency > 0 {
			guard let url = entry.pageURL else { continue }
			scores[url] = max(scores[url] ?? 0, entry.frecency)
		}

		// A page open as a tab is listed again as history, so Return there opens it afresh (DEV-810).
		var entries: [CommandBarFeature.Entry] = tabCandidates.map { tab in
			var tab = tab
			if let url = tab.pageURL, let score = scores[url] { tab.frecency = score }
			return tab
		}
		entries += history
		entries += spaceAndFolderCandidates
		entries += CommandBarFeature.Entry.commands(in: commandContext, bindings: keyboardShortcuts, aliases: commandAliases)
		return entries
	}

	/// The current profile's tabs, the selected one first.
	internal var tabCandidates: [CommandBarFeature.Entry] {
		let profile = sidebar.space.profileID
		let locations = sidebar.organization.tabLocations
		return sidebar.organization.tabs
			.filter { $0.profileID == profile }
			.sorted { $0.id == sidebar.selectedTab?.id && $1.id != sidebar.selectedTab?.id }
			.map { tab in
				.init(
					presentation: .init(
						id: tab.id.rawValue.uuidString,
						title: tab.displayTitle,
						subtitle: [tab.restoration.url.absoluteString, otherSpaceName(at: locations[tab.id])]
							.filter { !$0.isEmpty }
							.joined(separator: " · "),
						actionTitle: String.localized(.appUI.command.switchToTab),
						symbol: "globe",
						siteIcon: .init(
							profileID: tab.profileID.rawValue,
							pageURL: tab.restoration.url
						)
					),
					intent: .selectTab(tab.id),
					destination: locations[tab.id].map { .tab(tab.profileID, $0) }
				)
			}
	}

	private var spaceAndFolderCandidates: [CommandBarFeature.Entry] {
		let profile = sidebar.space.profileID
		var entries: [CommandBarFeature.Entry] = sidebar.organization.spaces.map { space in
			.init(
				presentation: .init(
					id: space.id.rawValue.uuidString,
					title: space.name,
					subtitle: sidebar.organization.profiles[id: space.profileID]?.name ?? "",
					actionTitle: String.localized(.appUI.command.switchToSpace),
					symbol: (space.icon ?? .dot).symbolName
				),
				intent: .selectSpace(space.id),
				destination: .space(space.profileID)
			)
		}
		entries += sidebar.organization.folders.filter { $0.spaceID == sidebar.spaceID }.map { folder in
			.init(
				presentation: .init(
					id: folder.id.rawValue.uuidString,
					title: folder.name,
					subtitle: sidebar.space.name,
					actionTitle: String.localized(.appUI.command.openFolder),
					symbol: "folder"
				),
				intent: .revealFolder(folder.id),
				destination: .folder(folder.spaceID, profile)
			)
		}
		return entries
	}

	/// The tab the person is looking at in this window: the focused pane's, or the selected one
	/// before the viewer shows it. Every page-context request (the chat's suggestions, its current
	/// tab, the assistant's focused-tab alias) reads this when it's made (DEV-835).
	public var focusedPageTab: BrowserCore.Tab? {
		viewer.item.tab ?? sidebar.selectedTab
	}

	/// The tabs shown by the current split, which the sidebar highlights as one group.
	public var splitTabIDs: Set<SidebarItem.ID> {
		guard viewer.isSplit, viewer.spaceID == sidebar.spaceID else { return [] }
		return Set(viewer.panes.compactMap { $0.item.tab.map { .tab($0.id.rawValue) } })
	}

	/// Where a tab opened from the New Tab button, ⌘T or the command bar goes: where Settings ›
	/// General › New tabs open says (at the top by default) while `newTabsAtTop` is on
	/// (DEV-1174), else where the one setting for every new tab says. Tabs links open follow
	/// their opener either way (DEV-1243).
	internal var openedTabPlacement: NewTabPlacement {
		newTabsAtTop ? openedTabSetting : newTabPlacement
	}

	internal func emptySplitPane(
		_ paneID: UUID,
		mode: CommandBarFeature.Mode
	) -> UUID? {
		guard mode == .newTab, viewer.isSplit, viewer.panes[id: paneID]?.item.tab == nil
		else { return nil }
		return paneID
	}

	/// The window's settings the command bar reads, set before every presentation, whichever
	/// way it opens: ⌘T, ⌘L and ⌘K arrive as pane commands, the sidebar and the address as
	/// `ui.openCommand` (DEV-779).
	internal mutating func prepareCommandBar() {
		commandBar.searchEngine = profileSearchEngine
		commandBar.suggestsRemotely = suggestsRemotely

		// History search reads the profile's page text, never in a private window (DEV-1068).
		commandBar.pageTextProfileID = isPrivate ? nil : sidebar.space.profileID

		// Bangs show the profile's stored site icons, never in a private window (DEV-1311).
		commandBar.bangIconProfileID = isPrivate ? nil : sidebar.space.profileID
		commandBar.isChatAvailable = !isPrivate
		commandBar.actionAvailability = .init(
			opensNewTabs: true,
			// Peek opens over the bar's pane, which a new split hasn't filled yet.
			opensPeek: !isPrivate && commandBarEmptyPaneID == nil,
			opensLittleArx: !isPrivate,
			removesHistory: !isPrivate && browsingHistory[sidebar.space.profileID] != nil
		)
		commandBar.useShortcuts(keyboardShortcuts)
	}
}

extension MainFeature.State {
	/// Candidates are limited to the current profile, so only a different space needs naming.
	fileprivate func otherSpaceName(at location: BrowserOrganization.TabLocation?) -> String {
		switch location {
		case let .unpinned(id), let .pinned(id, _):
			guard id != sidebar.spaceID else { return "" }
			return sidebar.organization.spaces[id: id]?.name ?? ""

		default: return ""
		}
	}
}

extension CommandBarFeature.Intent {
	/// The address this opens in a tab, here or new.
	fileprivate var openedURL: URL? {
		switch self {
		case let .open(url), let .openInNewTab(url): url
		default: nil
		}
	}
}
