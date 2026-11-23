import AppUI
import BrowserAutomationClient
import BrowserCore
import BrowserSurfaceClient
import BrowserEngineClient
import BrowserExtensionsClient
import BrowserMediaClient
import BrowserDownloadsClient
import BrowserPagePreviewClient
import BrowserSiteIconClient
import BrowserWorkspaceClient
import WorkspaceDatabase
import ChatFeature
import CommandBarFeature
import DownloadsFeature
import FeedbackFeature
import MainFeature
import MediaFeature
import LittleArxFeature
import MemoryPressureClient
import OnboardingFeature
import WorkspaceSync
import OutsideAgentsFeature
import PageCaptureFeature
import PeekFeature
import SettingsFeature
import TaskManagerFeature
import Foundation
import _ComposableArchitecture

@Reducer
public struct AppFeature {
	@ObservableState
	public struct State: Equatable {
		public var captureAvailable: Bool
		public var captureSessions: IdentifiedArrayOf<PageCaptureFeature.State>

		/// Hide Element's mode, one per page (DEV-1298).
		public var hideElementSessions: IdentifiedArrayOf<HideElementFeature.State>

		/// The `ARX_DEVICE_CAPTURE` feature flag, read at launch: the developer header's device
		/// capture popover (DEV-757). On by default (DEV-1143); off in a new state until
		/// BrowserWindow reads it.
		public var deviceCaptureEnabled: Bool

		/// The `ARX_HIDE_ELEMENT` feature flag, read at launch: View › Hide Element…, its shortcut
		/// and command bar entry, and the site menu's Hidden Elements (DEV-1019). On by default
		/// (DEV-1143); off in a new state until BrowserWindow reads it.
		public var hideElementEnabled: Bool

		/// The `ARX_ELEMENT_PICKER` feature flag, read at launch: Hide Element opens Arx's own
		/// element picker, where the engine has it, instead of uBlock Origin's (DEV-1201). On by
		/// default (DEV-1143); off in a new state until BrowserWindow reads it.
		public var elementPickerEnabled: Bool

		/// The `ARX_CAPTURE_BEYOND_VIEWPORT` feature flag, read at launch: Capture Page's frame shows
		/// the whole page it took, and Capture Area scrolls the page near its edges (DEV-1208). On by
		/// default (DEV-1143); off in a new state until BrowserWindow reads it.
		public var captureBeyondViewportEnabled: Bool

		/// The `ARX_INDEPENDENT_WINDOWS` feature flag, read at launch: each browser window keeps its
		/// own open tabs (DEV-822). Set it through `setIndependentWindows(_:)`.
		public internal(set) var independentWindows: Bool

		/// The additional window each of their open tabs is in, while windows are independent
		/// (DEV-822). An open tab without one is the main window's.
		public internal(set) var windowTabOwners: [BrowserCore.Tab.ID: UUID]
		public var globalShortcutGeneration: Int
		public var globalShortcutBinding: BrowserCore.KeyboardShortcut?
		public var automation: AutomationState

		/// The command, MCP switch and agent apps in the Local assistants sheet.
		public var outsideAgents: OutsideAgents.State
		public var downloads: DownloadsFeature.State

		/// Window ▸ Task Manager (DEV-898).
		public var taskManager: TaskManagerFeature.State
		public var downloadsReady: Bool
		public var downloadsFocusRequest: Int

		/// The newest downloads configuration. Only its effect may reach the client.
		public var downloadsConfiguration: Int
		public var media: MediaFeature.State

		/// Muted tabs and their last media source, read from the engine when media changes. A muted
		/// page can leave its media session, so the Media page keeps its row to unmute it.
		public var mutedMedia: [BrowserCore.Tab.ID: BrowserMediaSource]

		/// The order of the sidebar's media stack and the Media page: by when each tab's media
		/// was opened (DEV-1245).
		public var mediaStackOrder: MediaStackOrder

		/// Every muted tab, with media or without, as the sidebar's speakers show it (DEV-800).
		public var mutedTabs: Set<BrowserCore.Tab.ID>

		/// Tabs playing sound or in a call, private ones included, for sound feedback only
		/// (DEV-1256). Nothing renders it.
		public var tabsMakingSound: TabsMakingSound

		/// Tabs turned down from 100%, 0 to 1, kept while the app runs (DEV-800).
		public var tabVolumes: [BrowserCore.Tab.ID: Double]

		/// Whether the engine can turn a tab down. Engines built before DEV-800 can't.
		public var supportsTabVolume: Bool
		public var mediaSourceFocusRequest: Int
		internal var mediaSurfaces: [UUID: MediaSurfaceRecord]
		internal var mediaSourceVisibility: [BrowserMediaSource.ID: Bool]
		internal var mediaRehostingSources: Set<BrowserCore.Tab.ID>

		/// Windows in a macOS full-screen transition, or settling after one, whose pages'
		/// visibility automatic Picture in Picture doesn't read yet (DEV-991).
		internal var fullScreenTransitionWindows: Set<UUID>

		/// Browser and Little Arx windows on the display: visible, not minimised, on the active OS
		/// workspace. Nil until AppKit first reports. A window on it whose page reads as covered
		/// keeps its video in place rather than floating it (DEV-1246).
		internal var windowsOnDisplay: Set<UUID>?

		/// The tab whose Page PiP automatic PiP opened (DEV-1246): it goes back to its tab once that
		/// shows again on the display, as a video's PiP does. One the person opened stays.
		internal var automaticPagePictureInPicture: BrowserCore.Tab.ID?

		/// The browser window that last showed each media tab's page, where an automatic Page PiP
		/// floats from after a tab switch (DEV-1246). Windows share their organization, so it
		/// can't tell which one held the tab.
		internal var mediaHostWindows: [BrowserCore.Tab.ID: UUID]
		internal var pendingMediaReturn: MediaReturnIntent?
		internal var mediaReturnFailure: MediaReturnFailure?
		internal var windowActivationRevision: Int
		public var history: ProfileHistoryState
		public var peeks: IdentifiedArrayOf<PeekFeature.State>

		/// The page in HTML full screen and the window it fills (DEV-949). One at a time.
		public var pageFullScreen: PageFullScreen?

		/// The tab whose live page floats in Page PiP (DEV-950). One at a time.
		public var pagePictureInPicture: PagePictureInPicture?
		public var peekTransitions: [UUID: PeekTransition]
		public var peekReplacements: [UUID: PeekRequest]
		public var closingPeekHosts: Set<UUID>
		public var privateWindowCloseRequests: [UUID: PrivateWindowCloseRequest]

		/// Ordinary windows asking their pages with unsaved input before closing (DEV-1107).
		public var windowCloseRequests: [UUID: WindowCloseRequest]

		/// Numbers each ordinary window's close request, so a late answer can't finish a newer one.
		public var windowCloseRequestCount: Int

		/// The link each private window opened by Open Link in Private Window shows once ready
		/// (DEV-815).
		public var privateWindowURLs: [UUID: URL]

		/// The ordinary profile each private profile was opened from (DEV-729), so a private
		/// window opened from a private one follows the same downloads settings.
		public var privateProfileOpeners: [Profile.ID: Profile.ID]
		internal var savedPageResets: [UUID: [BrowserCore.Tab.ID: SavedPageResetRequest]]
		public var routingInbox: RoutingInbox

		/// Spaces in the order they were last in front, most recent first, for routes that open
		/// in a profile's most recent space. Kept for this session only.
		public var recentSpaceIDs: [Space.ID]

		/// Browser windows closed in this session, newest last, for Reopen Closed Window
		/// (DEV-908). Never saved.
		public var recentlyClosedWindows: [RecentlyClosedWindow]

		/// An `arx://` link a page opened, waiting for confirmation (DEV-929).
		public var arxLinkConfirmation: ArxLinkConfirmation?
		public var routePreview: RoutePreview?

		/// Arx's prompt for a page's link to another app, on that page's window (DEV-857).
		public var appLinkPrompt: AppLinkPrompt.State?

		/// Site permission prompts the engine handed over (DEV-963), each on its page's window.
		public var pagePermissionPrompts: IdentifiedArrayOf<PagePermissionPrompt.State>

		/// The offer to play a page's protected media in WebKit, on that page's window (DEV-877).
		public var webKitPrompt: WebKitPrompt.State?

		/// "Open in Arx or in Chrome?" or "Arx can't open this" for a `chrome://` or `arc://` link,
		/// on the window it came from (DEV-1193).
		public var browserLinkPrompt: BrowserLinkPrompt.State?

		/// Tabs whose page WebKit shows, for the sidebars' engine mark (DEV-877).
		public var webKitTabs: Set<BrowserCore.Tab.ID>

		/// The FairPlay sites Arx's helper can play in Chromium tabs now, before Settings'
		/// Protected media: none without the bridge, and none whose track failed this run
		/// (DEV-1151). The app keeps it; every window's site menu reads it.
		public var fairPlayOrigins: Set<String>

		/// A page's request for a device, on that page's window (DEV-905).
		public var deviceChooser: DeviceChooserPrompt.State?

		/// Each translated tab's languages and progress (DEV-904).
		public var translations: [BrowserCore.Tab.ID: TabTranslation]

		/// Tabs whose Show Original may still be waiting for a busy page. The next translation
		/// of the tab restores the original text first, so none of the old one stays (DEV-1121).
		public var pendingTranslationRestores: Set<BrowserCore.Tab.ID>

		/// The `ARX_TRANSLATE` feature flag, read at launch (DEV-996). On by default (DEV-1143); off
		/// in a new state until BrowserWindow reads it, so tests and in-app smokes turn it on
		/// themselves (`.translation(.featureFlag)`).
		public var translationFeatureFlag: Bool

		/// Each Chromium page's language, read after it loads (DEV-996).
		public var pageLanguages: [BrowserCore.Tab.ID: PageLanguage]

		/// Private windows' own Never Translate This Site choices, by private profile; never
		/// saved, and gone with the window (DEV-996).
		public var privateTranslationChoices: [Profile.ID: ProfileTranslationPreferences]

		/// What the provider translates into, for Choose Another Language (DEV-996).
		public var translationLanguages: TranslationLanguages?

		/// The target and options as last seen; a change reads availability again (DEV-996).
		public var translationSettings: TranslationSettingsSnapshot?

		/// A tab's Cast picker, on that tab's window (DEV-927).
		public var castPicker: CastPicker.State?

		/// The window that asked for a tab's picker, until the engine opens it.
		public var castPickerRequest: CastPickerRequest?

		/// The engine casts and the app listens: Cast… shows in the media controls.
		public var castIsAvailable: Bool

		/// Help › Report a Problem…, on the main window (DEV-887).
		public var problemReport: ProblemReportFeature.State?

		/// Help › Send Feedback (DEV-1284), on the window it was asked from.
		public var feedback: SendFeedbackFeature.State?

		/// The window the Send Feedback card is on: a browser window or Settings (DEV-1308).
		public var feedbackHost: FeedbackHost?
		public var linkActionFeedback: LinkActionFeedback?
		public var linkActionGeneration: Int

		/// The pointer is over the link toast, which holds it on screen.
		public var linkFeedbackIsHovered: Bool

		/// The keys a site may take before Arx, and the toast for one it took (DEV-1264, DEV-1073).
		public var siteShortcuts: SiteShortcutState
		public var settings: SettingsFeature.State
		public var settingsIsOpen: Bool
		public var settingsFocusRequest: Int

		/// Non-nil while the onboarding window is presented.
		public var onboarding: OnboardingFeature.State?
		public var onboardingFocusRequest: Int

		/// Raised when onboarding ends in the main window, so the window can animate into it.
		public var onboardingHandOffRequest: Int

		/// The import commit waiting for its save to land.
		internal var migrationCommit: UUID?

		/// "Clear Arx data first" while it runs (DEV-833).
		internal var migrationClearing: MigrationClearing?
		public var browserDataExport: BrowserDataExportState

		/// Raised when a Little Arx page moves into a normal window, the one time it
		/// should bring Arx forward.
		public var appActivationRequest: Int
		public var main: MainFeature.State
		public var littleWindows: IdentifiedArrayOf<LittleArxFeature.State>

		/// Private Little Arx windows waiting for their profile, with the address each opens
		/// (DEV-1323).
		public var privateLittleArxPending: [UUID: URL] = [:]

		/// Each open private Little Arx's own private profile, released when it closes.
		public var privateLittleArxProfiles: [UUID: Profile.ID] = [:]

		/// The member number's sign-in with Apple while its private Little Arx is open (DEV-1323).
		/// One at a time.
		public var memberSignIn: MemberSignInSession? = nil

		/// The site menus of Little Arx and Page PiP windows (DEV-1257), each opened over its page.
		public var floatingSiteMenus: IdentifiedArrayOf<FloatingSiteMenu.State>

		/// Little Arx windows on a macOS desktop Space other than the active one (DEV-931).
		/// Arx never brings one of them forward on its own: that would move it, or switch Spaces.
		public var littleWindowsOnOtherDesktopSpaces: Set<UUID>

		/// The main and additional windows on another macOS desktop Space (DEV-1186). A closing
		/// popup gives the keyboard back to the window it came from only while that one is here.
		public var windowsOnOtherDesktopSpaces: Set<UUID>

		/// DEV-1138: the Little Arx window that's key now. `focusedWindowID` stays set after a
		/// window resigns key, so it can't tell an idle window from one in use.
		public var littleArxKeyWindowID: UUID?

		/// When each Little Arx window stopped being used, for archiving idle ones (DEV-1138).
		public var littleArxIdleSince: [UUID: Date]

		/// Little Arx windows Arx is checking or asking before it archives them.
		public var littleArxArchiving: Set<UUID>

		/// The `ARX_LITTLE_ARX_AUTO_ARCHIVE` feature flag, read at launch (DEV-1138); on by default.
		public var littleArxAutoArchiveEnabled: Bool

		/// Tabs a window tore off that Little Arx doesn't show yet (DEV-793): their chat surfaces
		/// stay while their pages' old hosts let go.
		internal var tabsTearingOff: Set<BrowserCore.Tab.ID>
		public var windows: IdentifiedArrayOf<MainFeature.State>

		/// The tab each window shows once Move to Window or Open in New Window brought it there and
		/// no other window shows it any more (DEV-883).
		internal var pendingWindowSelections: [UUID: BrowserCore.Tab.ID]

		/// What each tab's live page last reported unread (DEV-907). Kept after its page closes,
		/// dropped with the tab, and not saved.
		internal var unreadBadges: [BrowserCore.Tab.ID: UnreadBadge]

		/// iCloud sync changed the database while an edit here waited to be saved: the workspace is
		/// read again after that save (DEV-977).
		internal var syncReloadPending: Bool = false

		/// Onboarding's "Sync with iCloud" found a workspace, adopted once the read of it lands
		/// (DEV-1215). Not saved.
		internal var iCloudAdoption: ICloudAdoption?

		/// Onboarding went on without waiting for iCloud: Default stays held until the background
		/// wait hears what iCloud had (DEV-1215). Not saved: a relaunch lets Default sync.
		internal var waitsForICloudInBackground: Bool = false

		/// `ARX_ONBOARDING_ICLOUD` with iCloud sync possible, read at launch (DEV-1215).
		internal var onboardingICloudEnabled: Bool = false

		/// Open pages a reload would close, because another Mac moved their space to another profile,
		/// are being asked whether they may close; the reload runs again once they all agree (DEV-1004).
		internal var syncReloadAwaitingApproval: Bool = false

		/// Open tabs whose pages agreed to close for the next reload, with each page as it agreed: one
		/// that shows another document by then is asked again (DEV-1071).
		internal var syncApprovedTabCloses: [BrowserCore.Tab.ID: SyncClosingPage] = [:]

		/// A Preferences group is being kept on this Mac or synced again (DEV-982): its write saves the
		/// workspace, and other saves and reloads wait for it, so none writes under the old choice.
		/// Kept in Settings' state, whose group toggles wait for it too.
		internal var isChangingPreferenceGroup: Bool {
			get { settings.iCloudSync.isChangingPreferenceGroup }
			set { settings.iCloudSync.isChangingPreferenceGroup = newValue }
		}
		internal var initialExtensionOptions: [BrowserCore.Tab.ID: InitialExtensionOptions]
		public var focusedWindowID: UUID?

		/// The additional window that had the keyboard last, of the ordinary ones, kept while
		/// Little Arx, Peek or Settings has it, so Open in Arx goes there; nil when it was the
		/// main window (DEV-1155).
		internal var lastOrdinaryWindowID: UUID?
		public var workspace: BrowserOrganization
		public var profileRetirement: ProfileRetirementState
		public var checkingQuit: Bool
		public var discardUnsavedChangesOnQuit: Bool
		public var windowIsOpen: Bool

		/// The main window is held back while launch onboarding is up, and opens when it ends
		/// (DEV-838).
		internal var mainWindowWaitsForOnboarding: Bool = false
		public var shouldQuit: Bool
		public var persistenceError: String?
		public var unsavedOrganization: BrowserOrganization?
		public var quitAfterSaving: Bool

		/// The quit in progress was started by Sparkle's Install and Relaunch (DEV-859).
		public var quitsToInstallUpdate: Bool

		/// The quit in progress was started by Feature Flags' Relaunch (DEV-1115).
		public var quitsToRelaunch: Bool = false

		/// A person's ⌘Q in progress, with how many downloads it would lose that they already
		/// accepted: after pages agree to close, a quit that would now lose more asks again
		/// (DEV-1130). Nil for an unattended or agent quit, which never asks.
		internal var quitAcceptedLosses: Int? = nil

		/// Assistant grants, clients and sign-in locks. Owned here, never a shared key: they need
		/// immediate, synchronized saves and must never be writable through MCP.
		public var automationPreferences: AutomationPreferences

		/// Each ordinary profile's chats with the built-in assistant, added when first needed.
		/// They live outside windows, so hiding a panel or closing a window never stops a turn.
		public var chats: IdentifiedArrayOf<ChatFeature.State>

		/// Profiles whose Allow is waiting for the MCP server to issue a credential.
		internal var pendingAssistantProfiles: Set<Profile.ID>

		/// Spaces Arx removes itself, such as onboarding's untouched Default, which ⌘Z doesn't
		/// bring back (DEV-1030).
		internal var unrecordedSpaceRemovals: Set<Space.ID>

		/// The windows open tabs a step being taken back brings back go to, once they're published
		/// (DEV-1030).
		internal var restoredOpenTabOwners: [BrowserCore.Tab.ID: UUID]

		/// Saved window layouts and the sidebar width new windows start with.
		@Shared
		public var windowLayout: WindowPreferences

		/// Introduction dismissal and finished setup steps.
		@Shared
		public var onboardingProgress: OnboardingPreferences

		/// When unpinned tabs were last on screen, for profiles that archive automatically.
		@Shared
		public var tabsLastViewed: [BrowserCore.Tab.ID: Date]

		/// Automatic archiving runs in this launch (`startTabArchiving`), so tabs entering and
		/// leaving the screen are stamped (DEV-1326). Never saved.
		internal var archivesInactiveTabs: Bool = false

		/// Hidden tabs' clocks, memory pressure and the unloaded tabs (DEV-873). Never saved.
		public var tabUnloading: TabUnloadingState

		/// What this Mac already imported. Changed only by migration commits.
		@SharedReader
		public var migrationLedger: MigrationLedger

		public init(
			main: MainFeature.State,
			windowIsOpen: Bool = true,
			shouldQuit: Bool = false,
			persistenceError: String? = nil,
			automation: AutomationPreferences = .init(),
			retirementIntents: [ProfileRetirementIntent] = []
		) {
			let settings = SettingsFeature.State()

			self.captureAvailable = false
			self.captureSessions = []
			self.hideElementSessions = []
			self.deviceCaptureEnabled = false
			self.hideElementEnabled = false
			self.elementPickerEnabled = false
			self.captureBeyondViewportEnabled = false
			self.independentWindows = false
			self.windowTabOwners = [:]
			self.globalShortcutGeneration = 0
			self.globalShortcutBinding = nil
			self.automation = .init()
			self.downloads = .init()
			self.taskManager = .init()
			self.downloadsReady = false
			self.downloadsFocusRequest = 0
			self.downloadsConfiguration = 0
			self.media = .init(
				profileID: main.sidebar.space.profileID,
				includesAllOrdinaryProfiles: true,
				automatic: settings.automaticPictureInPicture
			)
			self.mutedMedia = [:]
			self.mediaStackOrder = .init()
			self.mutedTabs = []
			self.tabsMakingSound = .init()
			self.tabVolumes = [:]
			self.supportsTabVolume = false
			self.mediaSourceFocusRequest = 0
			self.mediaSurfaces = [:]
			self.windowsOnDisplay = nil
			self.automaticPagePictureInPicture = nil
			self.mediaHostWindows = [:]
			self.mediaSourceVisibility = [:]
			self.mediaRehostingSources = []
			self.fullScreenTransitionWindows = []
			self.pendingMediaReturn = nil
			self.mediaReturnFailure = nil
			self.windowActivationRevision = 0
			self.history = .init()
			self.peeks = []
			self.pageFullScreen = nil
			self.pagePictureInPicture = nil
			self.peekTransitions = [:]
			self.peekReplacements = [:]
			self.closingPeekHosts = []
			self.privateWindowCloseRequests = [:]
			self.windowCloseRequests = [:]
			self.windowCloseRequestCount = 0
			self.privateWindowURLs = [:]
			self.privateProfileOpeners = [:]
			self.savedPageResets = [:]
			self.routingInbox = .init()
			self.recentSpaceIDs = []
			self.recentlyClosedWindows = []
			self.arxLinkConfirmation = nil
			self.routePreview = nil
			self.appLinkPrompt = nil
			self.pagePermissionPrompts = []
			self.webKitPrompt = nil
			self.browserLinkPrompt = nil
			self.webKitTabs = []
			self.fairPlayOrigins = []
			self.deviceChooser = nil
			self.translations = [:]
			self.pendingTranslationRestores = []
			self.translationFeatureFlag = false
			self.pageLanguages = [:]
			self.privateTranslationChoices = [:]
			self.translationLanguages = nil
			self.translationSettings = nil
			self.castPicker = nil
			self.castPickerRequest = nil
			self.castIsAvailable = false
			self.problemReport = nil
			self.feedback = nil
			self.feedbackHost = nil
			self.linkActionFeedback = nil
			self.linkActionGeneration = 0
			self.linkFeedbackIsHovered = false
			self.siteShortcuts = .init()
			self.settings = settings
			self.settingsIsOpen = false
			self.settingsFocusRequest = 0
			self.onboarding = nil
			self.outsideAgents = .init()
			self.onboardingFocusRequest = 0
			self.onboardingHandOffRequest = 0
			self.migrationCommit = nil
			self.migrationClearing = nil
			self.browserDataExport = .init()
			self.appActivationRequest = 0
			self.main = main
			self.littleWindows = []
			self.floatingSiteMenus = []
			self.littleWindowsOnOtherDesktopSpaces = []
			self.windowsOnOtherDesktopSpaces = []
			self.littleArxKeyWindowID = nil
			self.littleArxIdleSince = [:]
			self.littleArxArchiving = []
			self.littleArxAutoArchiveEnabled = LittleArxAutoArchiveFeatureFlag.isEnabled()
			self.tabsTearingOff = []
			self.windows = []
			self.pendingWindowSelections = [:]
			self.unreadBadges = [:]
			self.initialExtensionOptions = [:]
			self.focusedWindowID = main.id
			self.workspace = main.sidebar.organization
			self.profileRetirement = .init(intents: retirementIntents)
			self.checkingQuit = false
			self.discardUnsavedChangesOnQuit = false
			self.windowIsOpen = windowIsOpen
			self.shouldQuit = shouldQuit
			self.persistenceError = persistenceError
			self.unsavedOrganization = nil
			self.quitAfterSaving = false
			self.quitsToInstallUpdate = false
			self.automationPreferences = automation
			self.chats = []
			self.pendingAssistantProfiles = []
			self.unrecordedSpaceRemovals = []
			self.restoredOpenTabOwners = [:]
			self._windowLayout = Shared(.windows)
			self._onboardingProgress = Shared(.onboarding)
			self._tabsLastViewed = Shared(.tabsLastViewed)
			self.tabUnloading = .init()
			self._migrationLedger = SharedReader(.migrationLedger)
			self.restoreWindowPresentations()
			self.updateRetirementRows()
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case profileRetirement(ProfileRetirementAction)
		case routePreview(RoutePreviewAction)
		case profilePicker(RoutingProfilePickerAction)
		case appLinkPrompt(AppLinkPrompt.Action)
		case pagePermissionPrompts(IdentifiedActionOf<PagePermissionPrompt>)
		case webKitPrompt(WebKitPrompt.Action)
		case browserLinkPrompt(BrowserLinkPrompt.Action)

		/// `chrome://` and `arc://` links from pages and other apps (DEV-1193).
		case browserLinks(BrowserLinksAction)

		/// The page engines' reports and the fallback prompt's answers (DEV-877).
		case webKitPages(WebKitPagesAction)

		/// Battery Saver turned on or off (DEV-915).
		case batterySaver(BatterySaverAction)
		case deviceChooser(DeviceChooserPrompt.Action)

		/// Pages' device requests from the engine (DEV-905).
		case deviceChoosers(DeviceChooserAction)

		/// Translate Page, Show Original and Always translate (DEV-904).
		case translation(PageTranslationAction)
		case castPicker(CastPicker.Action)

		/// Pages' Cast pickers from the engine, and Cast… from the app (DEV-927).
		case cast(CastAction)
		case problemReport(ProblemReportFeature.Action)
		case feedback(SendFeedbackFeature.Action)

		/// The engine handed Arx a page's link for another app; its prompt goes on that window.
		case presentAppLink(AppLinkPresentation)
		case downloads(DownloadsFeature.Action)
		case taskManager(TaskManagerFeature.Action)
		case media(MediaFeature.Action)

		/// The command bar Page PiP's address opens (DEV-1124).
		case pagePictureInPictureCommandBar(CommandBarFeature.Action)
		case configureMedia
		case resumeTabPresentation(TabPresentationContext)
		case configureCapture
		case prepareCapture(UUID)
		case captureSessions(IdentifiedActionOf<PageCaptureFeature>)

		/// Hide Element's mode on its pages (DEV-1298).
		case hideElementSessions(IdentifiedActionOf<HideElementFeature>)
		case configureGlobalShortcut

		/// Reads the bundled !bang list once, off the main actor.
		case loadBangs

		/// Starts checking for tabs to archive automatically, now and then every few minutes.
		case startTabArchiving

		/// Archives unpinned tabs left unviewed longer than their profile allows.
		case archiveInactiveTabs

		/// A Little Arx window due for archiving had its page read for something typed (DEV-1138).
		case littleArxArchiveChecked(UUID, BrowserCore.Tab.ID, holdsDraft: Bool)

		/// Prepares the profiles windows show, then looks for idle profiles to release every
		/// sweep interval (DEV-880). Sent once at launch.
		case startProfileRelease(ProfileRelease)

		/// Releases the loaded profiles nothing has used for the grace period.
		case releaseIdleProfiles(ProfileRelease)

		/// Starts unloading idle tabs: every minute, and when memory pressure turns critical
		/// (DEV-873).
		case startTabUnloading

		/// Unloads the tabs closed windows held that no open window, Peek, Little Arx or agent
		/// holds now (DEV-1104).
		case releaseWindowlessTabs

		/// Unloads hidden tabs past Settings' delay, or every one the rules allow while memory
		/// pressure is critical.
		case unloadIdleTabs

		/// Starts tracking the tabs agents opened and tidying unused ones, every minute the Mac
		/// is awake (DEV-1022). Sent once at launch, with `ARX_AGENT_TABS` on.
		case startAgentTabs

		/// A minute of awake time passed: agent tabs unused past Settings' delay go to the archive.
		case tidyAgentTabs
		case automation(AutomationAction)
		case history(ProfileHistoryAction)
		case peeks(IdentifiedActionOf<PeekFeature>)
		case resetPeekPresentation(UUID, tabID: BrowserCore.Tab.ID, generation: Int)
		case finishResetPeekPresentation(UUID, tabID: BrowserCore.Tab.ID, generation: Int)

		/// Shows a page's new tab, the engine's own page with its opener, in a Peek over `source`
		/// (DEV-1312).
		case peekNewContents(BrowserCore.Tab, PeekFeature.Source, origin: CGPoint?)
		case finishSavedPageReset(
			sourceID: UUID,
			tabID: BrowserCore.Tab.ID,
			requestID: UUID,
			wasUnloaded: Bool
		)
		case processRouteQueue

		/// Writes the coalesced workspace snapshot.
		case flushWorkspaceSave

		/// Starts saving edits made through shared preference keys. Sent once at launch.
		case observeWorkspaceDocument

		/// Records when this Arx was first installed on this Mac, unless it already is (DEV-1323).
		/// Sent once at launch.
		case recordInstallDate

		/// Starts receiving the Chrome Web Store's install requests (DEV-765).
		case observeWebstoreInstalls

		/// Opens the Chrome Web Store in a new Little Arx of this profile, in front (DEV-765, DEV-801,
		/// DEV-1317).
		case openWebstore(Profile.ID)

		/// Share…: the page's plain address, with its title as the subject (DEV-818).
		case sharePage(LinkCopyItem, sourceWindowID: UUID)

		/// Open Link in New Window: a window on that space with the link in a new tab (DEV-815).
		case openInNewWindow(URL, Space.ID)

		/// Open in New Tab from the link menu, kept behind the page (DEV-952): a new tab right
		/// after the tab `opener` names, loading without being shown.
		case openLinkInBackgroundTab(URL, opener: BrowserCore.Tab.ID, windowID: UUID)

		/// Open in Main Window, from a link in Little Arx: a new tab on that space in the main
		/// window, the one way a Little Arx link reaches it (DEV-855).
		case openInMainWindow(URL, Space.ID)

		/// Open Link in Private Window (DEV-815). Its downloads follow the source's ordinary
		/// profile, when known, as a private window opened from that window's would.
		case openInPrivateWindow(URL, opener: Profile.ID?)

		/// Download Linked File, Download Image, Video or Audio, in an ordinary profile (DEV-814, DEV-815).
		case downloadURL(URL, Profile.ID)

		/// Download Linked File from the link menu, with the link's page as its referrer (DEV-851).
		case downloadLink(BrowserLinkContext)
		case littleWindows(IdentifiedActionOf<LittleArxFeature>)

		/// Private Little Arx windows, an internal capability (DEV-1323).
		case privateLittleArx(PrivateLittleArxAction)

		/// The member number's sign-in window (DEV-1323).
		case memberSignIn(MemberSignInAction)
		case floatingSiteMenus(IdentifiedActionOf<FloatingSiteMenu>)
		case settings(SettingsFeature.Action)
		case onboarding(OnboardingFeature.Action)
		case outsideAgents(OutsideAgents.Action)
		case migrationWorkspace(MigrationWorkspaceAction)
		case migrationClearing(MigrationClearingAction)
		case provisionalProfile(ProvisionalProfileAction)
		case browserDataExport(BrowserDataExportAction)

		/// Presents onboarding on launch until the user finishes, skips or closes it.
		case presentOnboardingIfNeeded
		case main(MainFeature.Action)
		case windows(IdentifiedActionOf<MainFeature>)
		case chats(IdentifiedActionOf<ChatFeature>)
		case chat(AppChatAction)
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case peekTab(BrowserCore.Tab.ID, sourceWindowID: UUID, sourcePaneID: UUID)
			case peekURL(URL, sourceWindowID: UUID, sourcePaneID: UUID)
			case peekURLFromSource(URL, PeekFeature.Source, origin: CGPoint? = nil)
			case dismissPeek(windowID: UUID)
			case promotePeek(windowID: UUID, destination: PeekDestination)
			case copyLinks(
				LinkCopyMode,
				items: [LinkCopyItem]? = nil,
				preferredRuleID: UUID? = nil,
				sourceWindowID: UUID? = nil,
				sourcePaneID: UUID? = nil
			)
			case shareProxyLinks(
				items: [LinkCopyItem]? = nil,
				preferredRuleID: UUID? = nil,
				sourceWindowID: UUID? = nil,
				sourcePaneID: UUID? = nil
			)

			/// Shares links as they are, as the site menu's Share does.
			case shareLinks(items: [LinkCopyItem], sourceWindowID: UUID)

			/// The site menu of a Little Arx or Page PiP window (DEV-1257).
			case floatingSiteMenu(FloatingSiteMenu.ID, SiteMenuAction)
			case routeURLs([URL], override: RoutingDestination? = nil, sourceWindowID: UUID? = nil)
			case openURLInSpace(URL, Space.ID, RoutingWindowMode)

			/// An `arx://` address from another app, or a Shortcuts action (DEV-929).
			case arxURLCommand(ArxURLCommand)

			/// Open in the `arx://` link confirmation (DEV-929).
			case confirmArxLink(UUID)

			/// Cancel in the `arx://` link confirmation (DEV-929).
			case cancelArxLink(UUID)

			/// A script's `show tab`, `reload tab` or `close tab` (DEV-909).
			case scriptTab(BrowserCore.Tab.ID, ScriptTabAction)
			case cancelRoute(UUID)
			case retryRoute(UUID)
			case chooseRouteDestination(UUID, RoutingDestination)
			case dismissLinkFeedback

			/// The link toast came on screen, or changed to new feedback: its timer starts.
			case linkFeedbackShown

			/// The pointer entered or left the link toast; while it's over it, the toast stays.
			case linkFeedbackHovered(Bool)

			/// A page's view took keyboard focus: the tab was selected, its window became key, or
			/// focus came back from the sidebar or command bar (DEV-1073).
			case pageTookKeyFocus(SiteShortcutState.Page)

			/// A key a site may take was pressed on its page (DEV-1264, DEV-1073). Afterwards
			/// `siteShortcuts.letsThrough` says whether it goes to the page.
			case pageFirstKeyPressed(SiteShortcutState.Press)

			/// The page used the key it was offered.
			case pageUsedKey(SiteShortcutState.Key)

			/// The page left the key it was offered; Arx's command runs.
			case pageLeftKey(SiteShortcutState.Key)

			/// The key monitor gave a held Delayed press to its page (DEV-1332).
			case heldKeyDelivered(SiteShortcutState.Press)

			/// A held press whose page lost focus or navigated meanwhile: never delivered.
			case heldKeyDropped(SiteShortcutState.Key)
			case dismissSiteShortcutNotice

			case openDownloads(UUID? = nil)
			case downloadsPanelAppeared(UUID)

			/// The Media command: opens the Library's Media page in this window, or the nearest ordinary one.
			case openMediaLibrary(UUID?)

			/// The mute button on a Media row.
			case toggleMediaMute(BrowserCore.Tab.ID)

			/// A click on a muted Media row whose page left its media session.
			case returnToMutedMedia(BrowserCore.Tab.ID)

			/// A tab's speaker, menu or Media row mutes or unmutes it (DEV-800).
			case setTabMuted(BrowserCore.Tab.ID, Bool)

			/// A tab's volume slider, 0 to 1 (DEV-800).
			case setTabVolume(BrowserCore.Tab.ID, Double)

			/// Capture Page… (the whole page, or its visible area when the engine can't take it whole)
			/// or, with `region`, Capture Area….
			case capturePage(CommandTarget, source: CaptureSource? = nil, region: Bool)

			/// The developer header's device capture: the visible page, framed as a device on a
			/// gradient, or a phone-shaped slice of it in Portrait Mode (DEV-757).
			case captureDevice(CommandTarget, DeviceCaptureStyle)

			/// Capture Visible Area or Capture Area… in a window's chat + menu: the capture goes
			/// straight to that window's chat (DEV-798).
			case capturePageForChat(windowID: UUID, region: Bool)
			case closeCapture(UUID)

			/// Page Setup… for the paper and orientation Print uses (DEV-795).
			case pageSetup

			/// Print…: the page as PDF, or the PDF document it shows, in the print panel (DEV-795).
			case printPage(CaptureSource)

			/// Save Page As… (DEV-795).
			case savePage(CaptureSource)

			/// Open File… in this window (DEV-795).
			case openFile(UUID)

			/// An item chosen in a tab's page menu, carried out as that command for the tab (DEV-795).
			case pageMenu(BrowserCore.Tab.ID, BrowserCommand)

			/// An app item chosen in a tab's context menu, carried out for the host showing the tab
			/// (DEV-814).
			case pageContextMenu(BrowserCore.Tab.ID, PageContextAction)
			case command(BrowserCommand, CommandTarget, source: CommandSource? = nil)

			/// ⌃Tab's recent-tab switcher in this browser window, from the key monitor (DEV-544).
			case tabSwitcher(TabSwitcherAction, window: UUID)
			case openWindow
			case newWindow
			case newWindowInSpace(Space.ID)
			case newPrivateWindow
			case requestClosePrivateWindow(UUID)

			/// Closing the main or an additional ordinary window: its pages with unsaved input
			/// are asked first, and it closes once they agree (DEV-1107).
			case requestCloseWindow(UUID)
			case closeWindow

			/// The user's Quit command: asks first when Settings say so.
			case confirmQuit
			case quit
			case retrySave
			case exportWorkspace
			case exportBrowserData(BrowserDataExportFormat)
			case openImport
			case cancelQuit
			case discardAndQuit
			case closeAdditionalWindow(UUID)

			/// Reopen Closed Window: the closed window with this ID, or the newest (DEV-908).
			case reopenClosedWindow(UUID?)

			/// Archive ▸ Recently Closed: one archived tab, restored as ⇧⌘T restores (DEV-908).
			case reopenArchivedTab(ArchivedTab.ID)
			case focusWindow(UUID)
			case windowBecameKey
			case openLittleArx(Space.ID? = nil, URL? = nil)
			case openSettings

			/// Opens Settings at a listed profile's extensions (the site menu and `arx://extensions`).
			case openExtensions(Profile.ID)

			/// Opens a listed profile's Extensions sheet on one extension (the site menu, DEV-801).
			case showExtension(Profile.ID, extensionID: String)

			/// Opens a listed profile's Extensions sheet with the review of an extension's update
			/// that waits for it (the site menu, DEV-1210).
			case reviewExtensionUpdate(Profile.ID, extensionID: String)

			/// Opens one extension's options page in its profile (the site menu, DEV-801).
			case openExtensionOptions(Profile.ID, extensionID: String)

			/// Opens Settings at a listed profile's Site Settings (the site menu).
			case openSiteSettings(Profile.ID)
			case closeSettings
			case openOnboarding

			/// Help › Report a Problem… (DEV-887).
			case reportProblem

			/// Help › Send Feedback… (DEV-1284), on the window it was asked from, Settings included
			/// (DEV-1308), or the main one.
			case sendFeedback(FeedbackHost?)

			/// Opens one onboarding step on its own, from Settings.
			case openOnboardingStep(OnboardingStep)
			case closeOnboarding

			/// Leaves page full screen (DEV-949): macOS full screen ended under it, or its window
			/// is going away.
			case exitPageFullScreen

			/// Floats the tab's live page in Page PiP (DEV-950), or brings the one floating back
			/// first.
			case openPagePictureInPicture(BrowserCore.Tab.ID)

			/// Ends Page PiP; its page returns to its tab, which comes to the front with
			/// `focusesTab` (Return to Tab).
			case closePagePictureInPicture(focusesTab: Bool)

			/// Present Tab in Picture in Picture from a tab's menu in `windowID` (DEV-1105): floats
			/// the tab's page whether or not a window shows it. The tab keeps its place.
			case presentTabInPictureInPicture(BrowserCore.Tab.ID, windowID: UUID)

			/// Page PiP's Back (DEV-1105).
			case pagePictureInPictureBack

			/// Page PiP's Forward (DEV-1105).
			case pagePictureInPictureForward

			/// Page PiP's profile picker (DEV-1105): reopens the floating page in that profile.
			case pagePictureInPictureSelectProfile(Profile.ID)

			/// Page PiP's Copy, from its address (DEV-1105).
			case copyPagePictureInPictureURL

			/// A click on Page PiP's address (DEV-1124): edits it in a command bar over it.
			case editPagePictureInPictureAddress

			/// Page PiP's space picker, or ⌘1–9 while Page PiP is key (DEV-1184): moves the floating
			/// tab to the space through its window, asking first for a space of another profile.
			case pagePictureInPictureMoveToSpace(Space.ID)

			/// Move, in Page PiP's question before a move to another profile (DEV-1184).
			case confirmPagePictureInPictureSpaceMove

			/// Cancel or Escape, in Page PiP's question before a move to another profile (DEV-1184).
			case cancelPagePictureInPictureSpaceMove
		}

		@CasePathable
		public enum Event: Sendable {
			/// The app became active again; state mirrored from the system, such as the
			/// default browser, is read again because it may have changed meanwhile.
			case applicationBecameActive

			/// The active macOS desktop Space changed, or a Little Arx opened: the Little Arx
			/// windows (DEV-931), and the main and additional windows (DEV-1186), that are now on
			/// another desktop Space.
			case desktopSpaceChanged(littleWindowsElsewhere: Set<UUID>, windowsElsewhere: Set<UUID> = [])

			/// The browser and Little Arx windows now on the display: visible, not minimised, on
			/// the active OS workspace (DEV-1246).
			case windowsOnDisplayChanged(Set<UUID>)

			/// Automatic PiP asked for the tab's Page PiP; it's Arx's own if it's opening now.
			case automaticPagePictureInPictureRequested(BrowserCore.Tab.ID)

			/// Arx stopped being the active app, or became active again with one of its browser
			/// windows key. Clicking ArxPiP itself activates Arx without a browser window, so it
			/// doesn't count as coming back to the video (DEV-848).
			case browserActivityChanged(isActive: Bool)

			/// A browser or Little Arx window began (true) or ended (false) a macOS full-screen
			/// transition. While its Space moves it can read as covered (DEV-991).
			case windowFullScreenTransition(UUID, isTransitioning: Bool)

			/// A window's full-screen transition ended a moment ago, long enough for its pages
			/// to report where they are now.
			case windowFullScreenTransitionSettled(UUID)
			case windowGeometryChanged(UUID, BrowserWindowGeometry)
			case captureCapability(Bool)

			/// A page opened a tab, window or popup. `shiftHeld`: Shift was down when it arrived,
			/// which with a new tab means ⇧⌘-click or Shift with the middle button (DEV-952).
			/// `modified`: Shift, Option, Command or Control was down, so the person chose the tab
			/// themselves. `origin`: the pointer, in screen coordinates, for a Peek to grow from.
			case browserNewContents(
				BrowserNewContents,
				shiftHeld: Bool = false,
				modified: Bool = false,
				origin: CGPoint? = nil
			)

			/// The tab's page called `window.close()`, which Blink allows only for a window a
			/// script opened (ABI49, DEV-855).
			case pageCloseRequested(BrowserCore.Tab.ID)

			/// A page opened an `arx://` link; Arx asks before following it (DEV-929).
			case arxLinkFromPage(BrowserExternalLink)

			/// The tab's page entered (true) or left (false) HTML full screen (ABI54, DEV-949).
			case pageFullScreenChanged(BrowserCore.Tab.ID, Bool)

			/// The tab's site permission prompt for Arx to draw became current (its token), or
			/// went away (0), while the engine hands prompts over (ABI56, DEV-963).
			case pagePermissionPromptChanged(BrowserCore.Tab.ID, UInt64)

			/// The tab's window let go of its page, which Page PiP's window now takes (DEV-950).
			case pagePictureInPictureReleased(BrowserCore.Tab.ID)

			/// Page PiP's window let go of the page, which its tab now takes back (DEV-950).
			case pagePictureInPictureClosed(BrowserCore.Tab.ID)

			/// The floating page's address, loading and history changed (DEV-1105).
			case pagePictureInPictureNavigation(BrowserCore.Tab.ID, BrowserNavigation)

			/// A tab no window showed couldn't load to float in Page PiP (DEV-1105).
			case pagePictureInPictureFailed(BrowserCore.Tab.ID)

			/// Page PiP's address bar opened a typed address in its page (DEV-1124), which history
			/// counts as typed.
			case pagePictureInPictureTypedAddressOpened(URL, BrowserCore.Tab.ID)

			/// A click on a notification from the tab's site asked for the tab (ABI55, DEV-885).
			case pageActivationRequested(BrowserCore.Tab.ID)

			/// A service worker opened this tab from a click on its notification (ABI55, DEV-885).
			case notificationWindowOpened(BrowserCore.Tab)

			/// A click on a site's notification finished (ABI55, DEV-885).
			case notificationClicked(BrowserNotificationClick)

			/// The system's memory pressure changed (DEV-873).
			case memoryPressureChanged(MemoryPressureLevel)

			/// A tab unloading sweep is about to read and unload, unless a newer one replaced it.
			case tabUnloadSweepStarted(Int)

			/// A tab unloading sweep read which tabs are loaded and which unloaded (DEV-873).
			case tabUnloadSweepFinished(
				loaded: Set<BrowserCore.Tab.ID>,
				unloaded: Set<BrowserCore.Tab.ID>,
				at: Date
			)

			/// A release of closed windows' tabs is about to unload, unless a newer one replaced it.
			case windowlessTabReleaseStarted(Int)

			/// The wait before asking the engine again about kept tabs is about to start, unless
			/// a window opening or a newer release replaced it.
			case windowlessTabReleaseRetryStarted(Int)

			/// A release of closed windows' tabs finished: the tabs no longer waiting (unloaded, or
			/// with no page), and which tabs are loaded and which unloaded (DEV-1104).
			case windowlessTabsReleased(
				released: Set<BrowserCore.Tab.ID>,
				loaded: Set<BrowserCore.Tab.ID>,
				unloaded: Set<BrowserCore.Tab.ID>,
				at: Date
			)

			/// The tab's page reports a different unread badge (DEV-907).
			case unreadBadgeChanged(BrowserCore.Tab.ID, UnreadBadge)

			/// The tab's ordinary page finished loading at a different URL or title, shown or not.
			case pageSettled(BrowserCore.Tab.ID, BrowserNavigation)
			case extensionViewCreated(BrowserExtensionViewOffer)
			case extensionOptionsRevoked(BrowserExtensionViewOffer)
			case extensionOptionsSettled(BrowserExtensionViewOffer)

			/// Add to Chrome on the Chrome Web Store, in a page of this request's profile.
			case webstoreInstallRequested(BrowserWebstoreInstallRequest)

			/// Time for the periodic Chrome Web Store update check (DEV-776).
			case webstoreUpdateCheckDue

			/// The periodic check let go of the extensions it held.
			case webstoreUpdateCheckFinished

			/// One profile's periodic check is done (DEV-1210): the updates it turned down for asking
			/// more permissions, the extensions the store had nothing newer for, and the inventory it
			/// left, if it could read one.
			case webstoreUpdatesChecked(
				Profile.ID,
				needsReview: [ExtensionUpdateReviews.Review],
				upToDate: [String],
				inventory: BrowserExtensionInventory?
			)

			/// The site menu read a profile's extensions to open one's options page, which
			/// replaced the authority a sheet on that profile holds; that sheet reads again.
			case extensionInventoryRead(Profile.ID)
			case capturePrepared(UUID, UUID, BrowserSessionSnapshot?)
			case additionalWindowClosed(UUID)
			case peekPromotionReady(UUID, PeekDestination, automationRequestID: UUID? = nil)
			case peekPromotionFailed(UUID, String, automationRequestID: UUID? = nil)
			case peekReleased(UUID, automationRequestID: UUID? = nil)
			case mediaSurfaceVisibility(UUID, BrowserSurfaceVisibility)
			case mediaMuteChanged(BrowserCore.Tab.ID, Bool)

			/// The engine refused a volume; the tab's slider goes back to this one (DEV-800).
			case tabVolumeChanged(BrowserCore.Tab.ID, Double)
			case downloadsReady
			case downloadsConfigurationStarted(Int)
			case retryQuit
			case quitConfirmed(stopAsking: Bool, acceptedLosses: Int)

			/// Quit, and Don't Ask Again, chosen in the question a quit in progress asks again
			/// about downloads it would lose (DEV-1130): the warning goes off, and the quit goes on.
			case quitWarningTurnedOff

			/// The person accepted losing this many downloads in that question, so a retry of the
			/// same quit, after saving or a tab that changed, doesn't ask about them again.
			case quitLossesAccepted(Int)

			/// Relaunch's question about downloads it would lose was cancelled (DEV-1115).
			case relaunchDeclined
			case globalShortcut(Int, GlobalShortcutEvent)
			case globalShortcutStarted(Int)
			case bangsLoaded(BangCatalog)
			case routingReady
			case routedSessionReady(UUID, RoutingTarget, BrowserCore.Tab)
			case routedSessionFailed(UUID, BrowserCore.Tab.ID, String)
			case linkActionFinished(Int, LinkActionFeedback)

			/// The link toast's time ran out.
			case linkFeedbackExpired(Int)

			/// The site shortcut toast's time ran out (DEV-1264).
			case siteShortcutNoticeExpired(Int)

			/// A held Delayed press's window ended without a second press (DEV-1332).
			case siteShortcutHeldKeyExpired(Int)

			/// The engine's answer to Open Focused Link in Peek.
			case focusedLinkRead(BrowserFocusedLink)

			/// The window, its private profile and space, and the opener its context was made a
			/// child of (DEV-956): nil when the opener couldn't be prepared, so the window shows no
			/// extensions, as its context runs none of that profile's.
			case privateWindowReady(UUID, Profile.ID, Space.ID, linkedOpener: Profile.ID?)

			/// The window, the private profile it would have had, and why it didn't open.
			case privateWindowFailed(UUID, Profile.ID, String)
			case organizationChangeApproved(BrowserOrganization, BrowserOrganization, [BrowserCore.Tab.ID])
			case privateWindowCloseDecision(UUID, PrivateWindowCloseRequest, Bool)

			/// The pages an ordinary window's close asked agreed, these with unsaved input among
			/// them by the document that agreed, or one refused (nil) (DEV-1107).
			case windowCloseDecision(UUID, WindowCloseRequest, answered: [BrowserCore.Tab.ID: UInt64]?)
			case saveFailed(String)

			/// A Preferences group's change saved this workspace, and these preferences (DEV-982).
			/// `tookSyncedValues` when the group took iCloud's values rather than this Mac's.
			case preferenceGroupSaved(
				PreferenceGroup,
				tookSyncedValues: Bool,
				BrowserOrganization,
				BrowserPreferences
			)
			case preferenceGroupFailed(String)

			/// A shared preference key changed the workspace document.
			case workspaceDocumentChanged

			/// iCloud sync changed rows in the workspace database (DEV-977).
			case workspaceSyncChanged

			/// iCloud sync changed the history mirror or its clears (DEV-984).
			case historySyncChanged

			/// What iCloud sync changed is published; services that follow the workspace catch up.
			case workspaceSyncApplied

			/// A sync reload couldn't read the workspace database, so what's shown stays as it was
			/// (DEV-1221).
			case workspaceSyncReadFailed

			/// The wait onboarding kept after Continue without waiting heard what iCloud had, or
			/// that sync was turned off (`nil`) (DEV-1215).
			case onboardingICloudFetched(OnboardingSyncResult?)

			/// Whether every open page a reload would close agreed to (DEV-1004).
			case workspaceSyncTabClosesDecided([BrowserCore.Tab.ID: SyncClosingPage], approved: Bool)

			/// The old profile's pages of these pinned tabs closed after a sync reload (DEV-1071).
			case workspaceSyncPagesClosed(Set<BrowserCore.Tab.ID>)

			/// A window's pane showing a tab whose page a sync reload closed, with its page then: it
			/// opens again unless that page is in the tab's profile now.
			case workspaceSyncPaneChecked(BrowserCore.Tab.ID, window: UUID, pane: UUID, page: SyncCheckedPage)

			/// This Mac's starter profiles that iCloud sync found a copy of, to offer removing (DEV-989).
			case duplicateStarterProfilesFound([Profile.ID])
			case saveSucceeded(
				BrowserOrganization,
				BrowserPreferences = .init()
			)
			case quitDecision(Bool, [BrowserCore.Tab.ID] = [])
			case littlePromotionReady(
				UUID,
				BrowserCore.Tab,
				BrowserCore.Tab,
				Space.ID,
				automationRequestID: UUID? = nil
			)
			case littlePromotionReleased(BrowserCore.Tab, TabPresentationContext)
			case littlePromotionFailed(UUID, String, automationRequestID: UUID? = nil)

			/// A tab dropped outside every window left it, and its page's old host let go: a Little
			/// Arx window shows it at this screen point (DEV-793).
			case tabTornOff(BrowserCore.Tab, Space.ID, CGPoint)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case commandFailed(String)
			case save(BrowserOrganization)
			case copyURL(URL)
			case exportWorkspace(BrowserOrganization)
			case browserDataExported(BrowserDataExportOutcome)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserDownloads)
	private var downloads

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.browserPagePreviews)
	private var pagePreviews

	@Dependency(\.browserSiteIcons)
	private var siteIcons


	@Dependency(\.quitAuthorization)
	private var quitAuthorization

	@Dependency(\.featureFlags)
	private var featureFlags

	@Dependency(\.quitConfirmation)
	private var quitConfirmation

	@Dependency(\.uuid)
	private var uuid

	private enum Cancellation: Hashable { case quit }

	public init() {}

	public var body: some ReducerOf<Self> {
		Reduce { state, action in

			// Clearing Arx before an import (DEV-833) holds the same line from its first close
			// question on, so no old page reopens while the clear checks they're all closed.
			let isRetiring = state.profileRetirement.isBusy || state.migrationClearing != nil
			guard !isRetiring || action.permittedDuringRetirement else {
				state.settings.organizationError = String.localized(.appUI.retirement.busy)
				return .none
			}

			// Before the window lays out a group, so it never takes a tab another window or Peek shows.
			state.prepareGroupLayout(for: action)
			let effect = behavior._reduce(into: &state, action: action)

			// After every window reduced the action, so a moved tab shows once its old window let go.
			let selections = state.applyPendingWindowSelections()
			state.rememberOrdinaryWindow()
			state.refreshSiteChromeColors()
			return .merge(effect, selections)
		}
		.followingAutomaticPictureInPicture()
		.exitingHiddenPageFullScreen()
		.endingPagePictureInPictureOfClosedTabs()
		.followingPresentableMedia()
		.publishingTabAudio()
		.reportingPageActivityToSoundFeedback()
		.publishingUnloadedTabs()
		.filteringWindowTabs()
		.publishingAgentPresence()
		.publishingUnreadBadges()
		.reconfiguringGlobalShortcut()
		.mirroringIntoWorkspaceDocument()
	}

	private var behavior: some ReducerOf<Self> {
		CombineReducers {
			autofillPreferences
			windowLifecycle
			quitAndPersistence
		}
		.forEach(\.captureSessions, action: \.captureSessions) { PageCaptureFeature() }
		.forEach(\.peeks, action: \.peeks) { PeekFeature() }
		.forEach(\.windows, action: \.windows) { MainFeature() }
		.forEach(\.littleWindows, action: \.littleWindows) { LittleArxFeature() }
		.forEach(\.chats, action: \.chats) { ChatFeature() }
		.ifLet(\.onboarding, action: \.onboarding) { OnboardingFeature() }
		.recordingViewedTabs()
		.restartingLittleArxClocks()
		.recordingUse()
		.handingLocalProfilesToHistory()
		.preparingShownProfiles()
		.trackingTabUnloading()
		.recordingRecentSpaces()

		// Reopen Closed Window in every window's command bar (DEV-908).
		.onChange(of: \.canReopenClosedWindow) { _, state in
			let canReopen = state.canReopenClosedWindow
			state.main.canReopenClosedWindow = canReopen
			for id in state.windows.ids { state.windows[id: id]?.canReopenClosedWindow = canReopen }
			return .none
		}
		.onChange(of: \.settings.general.fetchesUnloadedSiteIcons) { _, state in
			let client = siteIcons
			let enabled = state.settings.general.fetchesUnloadedSiteIcons
			MainActor.assumeIsolated { client.setFetchesUnloadedIcons(enabled) }
			return .none
		}

		// The profiles' own ID list, compared without building a set for every action.
		.onChange(of: \.workspace.profiles.ids) { previous, state in
			let profiles = Set(state.workspace.profiles.ids)

			// Reordering keeps the same profiles.
			guard Set(previous) != profiles else { return .none }

			let removed = Set(previous).subtracting(profiles)
			let client = siteIcons
			MainActor.assumeIsolated {
				client.configureProfiles(profiles)

				// A deleted profile's stored icons go with it (DEV-809).
				if !removed.isEmpty { client.removeProfiles(removed) }
			}

			// And its saved page pictures and fetched site details (DEV-730), and its tabs'
			// back/forward history (DEV-878).
			guard !removed.isEmpty else { return .none }
			return .run { [pagePreviews, engine] _ in
				await SidebarPageDetails.shared.forget(removed)
				await pagePreviews.removeProfiles(removed)
				for profile in removed { await engine.forgetNavigation(profile) }
			}
		}
	}

	/// Settings › General › Autofill reaches the engine (DEV-875, DEV-893). Observed around
	/// the reducers that hold Settings, so the switches' changes are seen.
	private var autofillPreferences: some ReducerOf<Self> {
		featureComposition
			.onChange(of: \.settings.general.autofillSwitches) { _, state in
				let engine = engine
				let general = state.settings.general
				MainActor.assumeIsolated { engine.configureAutofill(general) }
				return .none
			}
	}

		private var featureComposition: some ReducerOf<Self> {
		CombineReducers {
			ProfileRetirement()
			MigrationDataClearing()
			CaptureSessions()
			HideElementSessions()
			PageDocuments()
			PageContextMenus()
			PageFullScreenPresentation()
			PagePictureInPicturePresentation()
			PagePictureInPictureSpaces()
			AppDownloads()
			AppTaskManager()
			AppMedia()
			RecentlyClosed()
			AppTabAudio()
			AppSoundFeedback()
			NativeContentsPresentation()
			WebNotifications()
			ArxURLCommands()
			ArxLinkConfirmations()
			ScriptedTabs()
			OrdinaryTabPresentation()
			GlobalShortcuts()
			BundledBangs()
			TabAutoArchiving()
			LittleArxAutoArchiving()
			ProfileLifetime()
			TabUnloading()
			BrowserAutomation()
			AppChats()
			AutomationSignIn()
			AutomationPasswords()
			IncomingURLRouting()
			RoutingProfilePicking()
			LinkActions()
			SiteShortcuts()
			SiteMenuRouting()
			FloatingSiteMenuRouting()
			WebstoreRouting()
			LittleArxWindows()
			PrivateLittleArx()
			MemberSignInWindows()
			WindowTabMoves()
			WindowUndoSharing()
			IndependentWindows()
			AppUnreadBadges()
			AgentTabTidying()
			AppPageNavigation()
			PrivateWindows()
			WindowCloseQuestions()
			OrganizationManagement()
			CommandRouting()
			SplitPresentation()
			WindowPresentationPersistence()
			SavedPageReset()
			OnboardingPresentation()
			WhatsNewPresentation()
			ProblemReportPresentation()
			SendFeedbackPresentation()
			ProvisionalProfileSettlement()
			DefaultBrowserRefresh()
			MigrationWorkspace()
			BrowserDataExporting()
			SharedPreferences()
			Scope(state: \.settings, action: \.settings) { SettingsFeature() }
			Scope(state: \.outsideAgents, action: \.outsideAgents) { OutsideAgents() }
			Scope(state: \.main, action: \.main) { MainFeature() }

			// Last, so it sees every change the reducers above made to the MCP server.
			OutsideAgentsBridge()
		}
	}

	private var windowLifecycle: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.main) { state, _ in
				state.resolvePresentationConflict(source: state.main.id)
				return .none
			}

			Pullback(\.windows) { state, action in
				if case let .element(id, _) = action {
					state.resolvePresentationConflict(source: id)
				}
				return .none
			}

			Pullback(\.ui.openWindow) { state in
				guard state.openMainWindow() else { return .none }

				state.focusedWindowID = state.main.id

				return .send(.main(.ui(.task)))
			}

			Pullback(\.ui.closeWindow) { state in
				if let close = state.requestPeekHostClose(state.main.id) { return close }
				state.main.commandBarContext = nil
				state.main.commandBar.isPresented = false
				if state.main.commandBar.focusRequest > 0 { state.main.commandBar.focusRequest += 1 }
				state.discardLinkFeedback(in: state.main.id)
				state.windowIsOpen = false

				// Closed here rather than through the bar, so its pending request is cancelled here too.
				let stopSuggestions = CommandBarFeature()._reduce(into: &state.main.commandBar, action: .stopSuggestions)
				return .merge(
					stopSuggestions.map { .main(.commandBar($0)) },
					.send(.main(.viewer(.suspend)))
				)
			}

			Pullback(\.ui.newWindowInSpace) { state, spaceID in
				guard !state.mainWindowWaitsForOnboarding, state.workspace.spaces[id: spaceID] != nil
				else { return .none }
				state.appendBrowserWindow(uuid(), spaceID: spaceID)
				return .none
			}

			Pullback(\.ui.newWindow) { state in

				// Launch onboarding comes first; a browser window opens when it ends (DEV-838).
				guard !state.mainWindowWaitsForOnboarding else {
					state.bringOnboardingForward()
					return .none
				}

				state.appendBrowserWindow(uuid(), spaceID: state.newWindowSpaceID)
				return .none
			}

			Pullback(\.ui.focusWindow) { state, id in
				let isKnownWindow = id == state.main.id
				|| state.windows[id: id] != nil
				|| state.littleWindows[id: id] != nil

				guard isKnownWindow else { return .none }

				state.focusedWindowID = id
				return .none
			}

			Pullback(\.ui.windowBecameKey) { state in
				state.windowActivationRevision += 1
				return .none
			}

			Pullback(\.ui.closeAdditionalWindow) { state, id in
				if let close = state.requestPeekHostClose(id) { return close }
				if state.windows[id: id]?.isPrivate == true {
					return .send(.ui(.requestClosePrivateWindow(id)))
				}
				state.discardLinkFeedback(in: id)
				state.windows.remove(id: id)
				if state.focusedWindowID == id { state.focusedWindowID = nil }
				return .send(.event(.additionalWindowClosed(id)))
			}
		}
	}

	/// Turns Warn before quitting off, saved before quitting rather than when the document's change
	/// arrives.
	private func stopWarningBeforeQuitting(_ state: inout State) -> Effect<Action> {
		state.settings.$general.withLock { $0.warnsBeforeQuitting = false }
		state.unsavedOrganization = state.workspace
		return .send(.delegate(.save(state.workspace)))
	}

	/// Asks before a person's quit while `warns`, or when it would lose a download, and quits once
	/// they agree. A cancel sends `cancelled`, if there is one.
	private func confirmingQuit(warns: Bool, cancelled: Action? = nil) -> Effect<Action> {
		.run { @MainActor [quitConfirmation, downloads] send in
			let transfers = QuitConfirmation.Downloads(
				active: downloads.activeCount(),
				unresumable: downloads.unresumableCount()
			)
			guard warns || transfers.unresumable > 0 else {
				send(.event(.quitConfirmed(stopAsking: false, acceptedLosses: 0)))
				return
			}

			switch quitConfirmation.confirm(transfers) {
			case .cancel:
				if let cancelled { send(cancelled) }
			case .quit:
				send(.event(.quitConfirmed(stopAsking: false, acceptedLosses: transfers.unresumable)))
			case .quitAndStopAsking:
				send(.event(.quitConfirmed(stopAsking: true, acceptedLosses: transfers.unresumable)))
			}
		}
	}

	private var quitAndPersistence: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.quit) { state in
				guard state.unsavedOrganization == nil || state.discardUnsavedChangesOnQuit else {
					state.quitAfterSaving = true

					return .send(.ui(.retrySave))
				}
				guard !state.checkingQuit else { return .none }
				state.checkingQuit = true
				let ids = state.allTabIDs
				let acceptedLosses = state.quitAcceptedLosses

				// Downloads in progress aren't cancelled: the engine's shutdown leaves them interrupted,
				// to be resumed from Downloads next time, as a headless quit always has (DEV-966).
				return .run { @MainActor [engine, quitAuthorization, quitConfirmation, downloads] send in
					for id in ids {
						guard !Task.isCancelled else { return }
						let permitted = await engine.permitsClosing(id)
						guard !Task.isCancelled else { return }
						guard permitted else {
							send(.event(.quitDecision(false, ids)))
							return
						}
					}
					guard !Task.isCancelled else { return }

					// The native count, decision and cancellation share one actor turn. A modal
					// confirmation can run a nested event loop, so revalidate its page approvals.
					guard quitAuthorization.check(ids) else {
						send(.event(.retryQuit))
						return
					}

					// A person's quit asks again about downloads it would lose that started while
					// pages agreed, read in this same turn, and again after each answer, since the
					// question runs its own event loop (DEV-1130).
					if var accepted = acceptedLosses {
						while true {
							let transfers = QuitConfirmation.Downloads(
								active: downloads.activeCount(),
								unresumable: downloads.unresumableCount()
							)
							guard transfers.unresumable > accepted else { break }

							let answer = quitConfirmation.confirm(transfers)
							guard answer != .cancel else {
								send(.event(.quitDecision(false, ids)))
								return
							}

							// Before anything can retry the quit, so the retry knows what was accepted.
							send(.event(.quitLossesAccepted(transfers.unresumable)))
							if answer == .quitAndStopAsking { send(.event(.quitWarningTurnedOff)) }
							guard !Task.isCancelled else { return }
							guard quitAuthorization.check(ids) else {
								send(.event(.retryQuit))
								return
							}
							accepted = transfers.unresumable
						}
					}
					send(.event(.quitDecision(true, ids)))
				}.cancellable(id: Cancellation.quit, cancelInFlight: true)
			}

			// ⌘Q asks while the warning is on, saying which downloads quitting stops; a download quitting
			// would lose makes it ask with the warning off too (DEV-966).
			Pullback(\.ui.confirmQuit) { state in
				guard !state.checkingQuit else { return .send(.ui(.quit)) }

				return confirmingQuit(warns: state.settings.general.warnsBeforeQuitting)
			}

			Pullback(\.event.quitConfirmed) { state, value in
				let (stopAsking, acceptedLosses) = value
				state.quitAcceptedLosses = acceptedLosses
				guard stopAsking else { return .send(.ui(.quit)) }
				return .concatenate(stopWarningBeforeQuitting(&state), .send(.ui(.quit)))
			}

			// The quit already under way goes on, and saves first, as it would after any change.
			Pullback(\.event.quitWarningTurnedOff) { state in
				stopWarningBeforeQuitting(&state)
			}

			Pullback(\.event.quitLossesAccepted) { state, accepted in
				state.quitAcceptedLosses = max(state.quitAcceptedLosses ?? 0, accepted)
				return .none
			}

			// Sparkle's Install and Relaunch quits the usual way, so pages, downloads and the
			// workspace close as they always do; the update installs once Arx exits (DEV-859).
			Pullback(\.settings.delegate.quitToInstallUpdate) { state in
				state.quitsToInstallUpdate = true
				return .send(.ui(.quit))
			}

			// Feature Flags' Relaunch quits the usual way too (DEV-1115). The button is the person's
			// answer to the quit warning, so it asks only about downloads quitting would lose, and a
			// cancel there ends the relaunch.
			Pullback(\.settings.delegate.quitToRelaunch) { state in
				state.quitsToRelaunch = true
				guard !state.checkingQuit else { return .send(.ui(.quit)) }

				return confirmingQuit(warns: false, cancelled: .event(.relaunchDeclined))
			}

			Pullback(\.event.relaunchDeclined) { state in
				state.quitsToRelaunch = false
				return .none
			}

			// The person's quit is decided either way; the next one starts over (DEV-1130).
			// A declined quit forgets what it accepted; one that goes on keeps it, since saving or a
			// tab that changed meanwhile sends it again.
			Pullback(\.event.quitDecision) { state, decision in
				if !decision.0 { state.quitAcceptedLosses = nil }
				return .none
			}

			Pullback(\.ui.cancelQuit) { state in
				state.quitAcceptedLosses = nil
				return .none
			}

			// A page or download kept Arx open: Sparkle's window closes and the update waits.
			Pullback(\.event.quitDecision) { state, decision in
				guard !decision.0, state.quitsToInstallUpdate else { return .none }
				state.quitsToInstallUpdate = false
				return .send(.settings(.event(.updateQuitCancelled)))
			}

			// Keep Open after the workspace couldn't be saved.
			Pullback(\.ui.cancelQuit) { state in
				guard state.quitsToInstallUpdate else { return .none }
				state.quitsToInstallUpdate = false
				return .send(.settings(.event(.updateQuitCancelled)))
			}

			Pullback(\.event.retryQuit) { state in
				guard state.checkingQuit, !state.shouldQuit else { return .none }
				state.checkingQuit = false
				return .send(.ui(.quit))
			}

			Pullback(\.event.quitDecision) { state, decision in
				let (proceed, approvedTabs) = decision
				state.checkingQuit = false
				state.quitAfterSaving = false
				guard proceed else {
					state.discardUnsavedChangesOnQuit = false
					return state.routingInbox.requests.isEmpty ? .none : .send(.processRouteQueue)
				}

				let currentTabs = state.allTabIDs
				guard currentTabs == approvedTabs else { return .send(.ui(.quit)) }
				guard state.unsavedOrganization == nil || state.discardUnsavedChangesOnQuit
				else { return .send(.ui(.quit)) }

				let peekIDs = state.peeks.map(\.id)
				state.shouldQuit = true
				state.peeks.removeAll()
				state.peekTransitions.removeAll()
				state.peekReplacements.removeAll()
				state.closingPeekHosts.removeAll()
				state.windows.removeAll()
				state.littleWindows.removeAll()

				let peekCancellations: [Effect<Action>] = peekIDs.flatMap { id in
					[
						.cancel(id: PeekPromotionID(id: id)),
						.cancel(id: PeekHandoffID(id: id)),
					]
				}

				return .merge([.send(.main(.viewer(.suspend)))] + peekCancellations)
			}

			// Relaunch: once the quit goes ahead, Arx opens again after it exits; if a page, a
			// download or unsaved changes keep it open, nothing reopens.
			Pullback(\.event.quitDecision) { state, decision in
				guard state.quitsToRelaunch, !state.checkingQuit else { return .none }
				guard decision.0, state.shouldQuit else {
					if !decision.0 { state.quitsToRelaunch = false }
					return .none
				}

				state.quitsToRelaunch = false
				return .run { [featureFlags] _ in featureFlags.reopenAfterQuit() }
			}

			Pullback(\.ui.cancelQuit) { state in
				state.quitsToRelaunch = false
				return .none
			}

			Pullback(\.main.delegate.organizationChanged) { state, _ in
				state.publishOrganization(from: state.main.id)
			}

			Pullback(\.windows) { state, action in
				guard case let .element(id, .delegate(.organizationChanged)) = action
				else { return .none }

				return state.publishOrganization(from: id)
			}

			Pullback(\.main.delegate.changeOrganization) { _, change in
				.send(.settings(.delegate(.changeOrganization(change))))
			}

			Pullback(\.windows) { _, action in
				guard case let .element(_, .delegate(.changeOrganization(change))) = action
				else { return .none }

				return .send(.settings(.delegate(.changeOrganization(change))))
			}

			Pullback(\.windows) { _, action in
				guard case let .element(_, .delegate(.copyURL(url))) = action else { return .none }

				return .send(.delegate(.copyURL(url)))
			}

			Pullback(\.ui.openSettings) { state in
				state.settingsIsOpen = true
				state.settingsFocusRequest += 1
				return SettingsFeature()
					._reduce(
						into: &state.settings,
						action: .configureExtensions(Array(state.workspace.profiles))
					)
					.map(Action.settings)
			}

			Pullback(\.ui.closeSettings) { state in
				state.settingsIsOpen = false
				state.settings.recordingCommand = nil
				return SettingsFeature()
					._reduce(into: &state.settings, action: .extensions(.ui(.dismiss)))
					.map(Action.settings)
			}


			Pullback(\.ui.retrySave) { state in
				guard let organization = state.unsavedOrganization else { return .none }

				return .send(.delegate(.save(organization)))
			}

			Pullback(\.ui.exportWorkspace) { state in
				.send(.delegate(.exportWorkspace(state.workspace)))
			}

			Pullback(\.ui.cancelQuit) { state in
				state.checkingQuit = false
				state.quitAfterSaving = false
				state.discardUnsavedChangesOnQuit = false
				return .merge(
					.cancel(id: Cancellation.quit),
					state.routingInbox.requests.isEmpty ? .none : .send(.processRouteQueue)
				)
			}

			Pullback(\.ui.discardAndQuit) { state in
				state.discardUnsavedChangesOnQuit = true

				return .send(.ui(.quit))
			}

			Pullback(\.event.saveSucceeded) { state, value in
				let (organization, preferences) = value
				guard

					// An earlier save landing during a Preferences group's change doesn't save the change:
					// it stays unsaved, so quitting waits for it (DEV-982).
					!state.isChangingPreferenceGroup,
					state.persistedPreferences == preferences,
					state.unsavedOrganization == organization
				else { return .none }
				state.unsavedOrganization = nil
				state.persistenceError = nil
				return state.quitAfterSaving ? .send(.ui(.quit)) : .none
			}

			Pullback(\.main.delegate.copyURL) { _, url in .send(.delegate(.copyURL(url))) }

			// Open in Peek and Open in Little Arx from the command bar's actions (DEV-810).
			Pullback(\.main.delegate.openInPeek) { state, value in
				let (url, paneID) = value
				guard let source = state.peekSource(windowID: state.main.id, paneID: paneID)
				else { return .none }

				return .send(.ui(.peekURLFromSource(url, source, origin: nil)))
			}

			Pullback(\.main.delegate.openInLittleArx) { _, value in
				let (url, spaceID) = value
				return .send(.ui(.openLittleArx(spaceID, url)))
			}

			Pullback(\.windows) { state, action in
				switch action {
				case let .element(id, .delegate(.openInPeek(url, paneID))):
					guard let source = state.peekSource(windowID: id, paneID: paneID)
					else { return .none }

					return .send(.ui(.peekURLFromSource(url, source, origin: nil)))

				case let .element(_, .delegate(.openInLittleArx(url, spaceID))):
					return .send(.ui(.openLittleArx(spaceID, url)))

				default:
					return .none
				}
			}

			Pullback(\.main.delegate.toggleMute) { _, tabID in toggleMute(tabID) }

			Pullback(\.windows) { _, action in
				guard case let .element(_, .delegate(.toggleMute(tabID))) = action else { return .none }

				return toggleMute(tabID)
			}

			Pullback(\.event.preferenceGroupSaved) { state, value in
				let (group, tookSyncedValues, organization, saved) = value
				state.isChangingPreferenceGroup = false

				// Using iCloud's values changed the group's. An edit to another part made meanwhile stays;
				// keeping this Mac's values changed nothing here, so an edit to the group itself stays too.
				let current: BrowserPreferences = state.persistedPreferences
				if tookSyncedValues, let updated = try? current.replacing(group, with: saved), updated != current {
					@Dependency(\.workspaceDocument)
					var document

					document.updatePreferences(requestsSave: false) { $0 = updated }
				}

				// An edit made meanwhile waited for this write; it's saved now.
				guard state.workspace == organization, state.persistedPreferences == saved else {
					return state.saveWorkspace()
				}

				// This write made earlier saves obsolete: it lands as theirs, for whatever waits on one.
				return .send(.event(.saveSucceeded(organization, saved)))
			}

			Pullback(\.event.preferenceGroupFailed) { state, error in
				state.isChangingPreferenceGroup = false

				// Shown with the toggles, where the choice stays as it was: a save of the workspace
				// doesn't retry the change, so its banner and its success would be the wrong answer.
				state.settings.iCloudSync.preferenceGroupError = error

				// What waited for it is saved now.
				return state.saveWorkspace()
			}

			Pullback(\.event.saveFailed) { state, error in
				state.persistenceError = error

				let reopensWindowForFailedQuit = state.quitAfterSaving
				&& state.windows.isEmpty
				&& state.littleWindows.isEmpty
				&& !state.settingsIsOpen

				guard reopensWindowForFailedQuit else { return .none }

				// The save error and its Retry, Keep Open and Discard controls live in the main
				// window, so a failed quit opens it even while launch onboarding holds it back.
				if state.mainWindowWaitsForOnboarding { return state.revealMainWindowAfterOnboarding() }
				state.openMainWindow()
				return .none
			}

			ProfileHistory()
			PeekPresentation()
			ExplicitURLRouting()
			AppLinkRouting()
			PagePermissionPromptRouting()
			WebKitPageRouting()
			BrowserLinkRouting()
			BatterySaverNotice()
			DeviceChooserRouting()
			PageTranslationRouting()
			CastRouting()

			// After `saveSucceeded` above clears what was saved, so a reload waiting on it runs.
			WorkspaceSyncReload()
			DuplicateStarterProfiles()
			ICloudRemovalStatus()
			OnboardingICloudAdoption()
			Reduce { state, _ in state.reconcileAutomaticMediaVisibility() }
			Reduce { state, _ in
				state.reconcileDarkPages()
				return state.reconcileDeveloperMode()
			}
		}
	}
}

extension WorkProbe.Work {
	/// A listing of every tab of every window (`AppFeature.State.allTabIDs`).
	internal static let allTabIDs: Self = .init("AppFeature.allTabIDs")
}

extension AppFeature.State {
	/// Every tab of every window, in order. It lists the whole workspace, so code that runs for
	/// every action asks `containsTab(_:)` instead (DEV-945).
	internal var allTabIDs: [BrowserCore.Tab.ID] {
		WorkProbe.record(.allTabIDs)
		return workspace.tabs.map(\.id)
		+ peeks.filter(\.isTemporary).map { $0.tab.id }
		+ littleWindows.map { $0.tab.id }
		+ windows.filter(\.isPrivate).flatMap { $0.sidebar.organization.tabs.map(\.id) }
	}

	/// Whether `allTabIDs` has `id`, found by ID in the workspace and private windows.
	internal func containsTab(_ id: BrowserCore.Tab.ID) -> Bool {
		workspace.tabs[id: id] != nil
		|| peeks.contains { $0.isTemporary && $0.tab.id == id }
		|| littleWindows.contains { $0.tab.id == id }
		|| windows.contains { $0.isPrivate && $0.sidebar.organization.tabs[id: id] != nil }
	}

	/// Match site (DEV-1101): the app changes windows' panes outside their own reducer, as a selection
	/// in another window does, so each window takes its panes' color again. Only a stale one is
	/// written, so no other window's chrome is touched.
	fileprivate mutating func refreshSiteChromeColors() {
		if main.siteChromeColorIsStale { main.refreshSiteChromeColor() }
		for window in windows where window.siteChromeColorIsStale {
			windows[id: window.id]?.refreshSiteChromeColor()
		}
	}

	fileprivate mutating func resolvePresentationConflict(source: UUID) {
		guard
			let current = source == main.id ? main : windows[id: source],
			let selected = current.sidebar.selectedTab,
			selected.id != current.viewer.item.tab?.id
		else { return }

		let owners: [MainFeature.State] = (windowIsOpen ? [main] : []) + Array(windows)
		let peekOwner = peeks.first { $0.tab.id == selected.id }
		let owner = owners.first { owner in
			owner.id != source
			&& owner.viewer.panes.contains { $0.item.tab?.id == selected.id }
		}
		guard peekOwner != nil || owner != nil else { return }

		var restored = current
		let spaceID = restored.sidebar.spaceID
		if let old = current.viewer.item.tab {
			restored.sidebar.select(old.id)
		} else if let index = restored.sidebar.organization.spaces.firstIndex(where: { $0.id == spaceID }) {
			restored.sidebar.organization.spaces[index].selectedTabID = nil
		}

		if source == main.id {
			main = restored
		} else {
			windows[id: source] = restored
		}

		if let peekOwner {
			focusedWindowID = peekOwner.source.windowID
			return
		}

		guard let owner else { return }

		if let pane = owner.viewer.panes.first(where: { $0.item.tab?.id == selected.id }) {
			if owner.id == main.id {
				main.viewer.activePaneID = pane.id
				main.sidebar.select(selected.id)
			} else {
				windows[id: owner.id]?.viewer.activePaneID = pane.id
				windows[id: owner.id]?.sidebar.select(selected.id)
			}
		}

		focusedWindowID = owner.id
	}
}

/// The Split View group menu's Mute: flips the tab's audio, unmuting a muted tab.
private func toggleMute(_ tabID: BrowserCore.Tab.ID) -> Effect<AppFeature.Action> {
	@Dependency(\.browserMedia)
	var media

	return .run { @MainActor send in
		let isMuted = media.position(tabID)?.isMuted ?? false
		try? media.setMuted(tabID, !isMuted)
		send(.event(.mediaMuteChanged(tabID, media.position(tabID)?.isMuted ?? isMuted)))
	}
}

extension AppFeature.State {
	/// Opens another ordinary browser window on `spaceID`, with no tab selected, in front.
	internal mutating func appendBrowserWindow(_ id: UUID, spaceID: Space.ID) {
		var organization = workspace
		for index in organization.spaces.indices {
			organization.spaces[index].selectedTabID = nil
		}
		var window = MainFeature.State(
			organization: organization,
			spaceID: spaceID,
			id: id
		)
		window.captureAvailable = captureAvailable
		window.downloadsAvailable = downloadsReady
		window.mediaAvailable = media.isAvailable
		window.commandBar.bangs = settings.bangs
		window.sidebarWidth = newWindowSidebarWidth
		window.canReopenClosedWindow = canReopenClosedWindow
		window.sidebar.windowUndo = windowUndo
		windows.append(window)
		focusedWindowID = id

		// Independent, it shows only the open tabs it keeps (DEV-822).
		applyOpenTabFilters()
	}
}
