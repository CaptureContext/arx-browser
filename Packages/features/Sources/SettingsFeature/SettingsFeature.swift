import AppUI
import AppUpdaterClient
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import DefaultBrowserClient
import DiagnosticsClient
import ExtensionsFeature
import WorkspaceSync
import Foundation
import _ComposableArchitecture

@Reducer
public struct SettingsFeature {
	@ObservableState
	public struct State: Equatable {
		public var extensions: ExtensionsFeature.State
		public var extensionProfiles: [Profile]
		public var historyStatus: [Profile.ID: HistoryStatus]
		public var pendingHistoryClearID: Profile.ID?
		public var historyRemovalError: String?
		public var routing: RoutingEditor

		/// Air Traffic Control's New Route, not saved yet: it's saved once its pattern names a
		/// host. The list's row and the bar's "+" share it.
		public var routingDraft: RoutingRule?

		/// Air Traffic Control › App Links (DEV-857).
		public var appLinks: AppLinkEditor

		/// Settings › Links' rule form, while its sheet is open.
		public var proxyLinkEditor: ProxyLinksEditor?

		/// Settings › Advanced's Add Site or Edit Site form, while its sheet is open (DEV-1001).
		public var siteDraft: SettingsSiteDraft?
		public var category: SettingsCategory
		public var panel: SettingsPanel?
		public var selectedProfileID: Profile.ID?
		public var selectedCommand: BrowserCommand?
		public var recordingCommand: BrowserCommand?

		/// The shortcut being recorded goes beside the command's others (DEV-920).
		public var recordingAddsShortcut: Bool

		/// The conflict on screen came from Reset to Default: Replace restores every default.
		public var shortcutConflictResets: Bool
		public var shortcutConflict: ShortcutBinding?
		public var shortcutError: String?

		/// Why the alias just typed for a command wasn't saved.
		public var aliasError: AliasError?

		/// A page inside the pane, such as Assistant › AI Commands, open in its place.
		public var page: SettingsPage?

		/// The row a search result scrolled to, highlighted for a moment.
		public var highlightedAnchor: SettingsAnchor?
		public var globalShortcutMessage: String?
		public var shortcutQuery: String
		public var error: String?
		public var draft: SearchShortcut
		public var editingKeyword: String?

		/// The search shortcut editor is open: for `editingKeyword`, or for a new shortcut.
		public var isEditingShortcut: Bool

		/// Helium's bundled !bang list; empty until the app has read it.
		public var bangs: BangCatalog
		public var bangQuery: String
		public var organizationEditor: OrganizationEditor
		public var organizationEditorIsPresented: Bool
		public var isManagingOrganization: Bool
		public var organizationError: String?
		public var retirementAvailable: Bool

		/// The engine can turn content blocking on and off (DEV-884). Without it the Content
		/// blocking section isn't shown.
		public var contentBlockingAvailable: Bool

		/// DEV-1020: the `ARX_DARK_PAGES` feature flag is on and the engine can darken pages.
		public var darkPagesAvailable: Bool

		/// The `ARX_LINK_STATUS` feature flag is on (DEV-1111). Without it Links › Link Status
		/// isn't shown.
		public var linkStatusAvailable: Bool

		/// The `ARX_MATCH_SITE_BACKGROUND` feature flag is on (DEV-1101). Without it Appearance shows
		/// no Match site, here or in a profile's settings (DEV-1170).
		public var matchSiteAvailable: Bool

		/// The `ARX_NEW_TABS_AT_TOP` feature flag is on (DEV-1174): General › Tabs shows New tabs
		/// open and Tabs from links open instead of the one New tabs open.
		public var newTabsAtTopAvailable: Bool
		public var profileRetirements: [ProfileRetirementStatusRow]

		/// Whether Arx is the default browser; `nil` until the row first checks.
		public var defaultBrowser: DefaultBrowserClient.Status?

		/// Whether macOS's default-browser confirmation may be showing.
		public var isRequestingDefaultBrowser: Bool

		/// The result of the last Make Default, so a declined prompt can be explained.
		public var defaultBrowserOutcome: DefaultBrowserClient.Outcome?

		/// Sparkle's state for the Updates section and Check for Updates…; `nil` until the app starts the updater.
		public var updates: AppUpdaterClient.Status?

		/// Settings › Developer's security components; `nil` until the section first reads them.
		public var securityComponents: [BrowserSecurityComponent]?

		/// What's New after an update (DEV-888): set at the first launch of a newer build until
		/// the sheet is closed.
		public var whatsNew: AppUpdaterClient.WhatsNew?

		/// Settings › Privacy: Share crash reports and the reports kept (DEV-887); `nil` until read.
		public var diagnostics: DiagnosticsClient.Status?

		/// One profile's saved passwords, while its sheet is open.
		public var savedPasswords: SavedPasswordsFeature.State?

		/// One profile's addresses and payment cards (DEV-893).
		public var autofillData: AutofillDataFeature.State?

		/// One profile's site permissions and zoom, while its sheet is open.
		public var siteSettings: SiteSettingsFeature.State?

		/// One profile's Clear Browsing Data, while its sheet is open.
		public var clearBrowsingData: ClearBrowsingDataFeature.State?

		/// Settings › Arx › iCloud Sync, shown only with the `ARX_ICLOUD_SYNC` feature flag (DEV-560).
		public var iCloudSync: ICloudSyncSettingsFeature.State

		/// Each listed profile's downloads folder, once its page has read it.
		public var downloadSettings: [Profile.ID: DownloadSettings]

		/// Why a profile's downloads folder couldn't be read or changed.
		public var downloadSettingsNotice: [Profile.ID: ProfileDataFailure]

		/// Profiles with a downloads-folder change in flight; another waits for it.
		public var downloadSettingsChanging: Set<Profile.ID>

		/// Whether the share sheet for the identity card is showing.
		public var isSharingIdentityCard: Bool

		/// The identity card's member number (DEV-701).
		public var memberNumber: MemberNumberFeature.State

		/// The pages kept for Back and Forward when this run started, which the engine uses
		/// until the next launch (DEV-943).
		public let backForwardCachePagesAtLaunch: Int

		/// The app-wide chrome tint and grain that profiles and spaces build on.
		@Shared
		public var chromeAppearance: ChromeAppearance

		/// The user's search shortcuts. Validated before every write.
		@Shared
		public var searchShortcuts: [SearchShortcut]

		/// Air Traffic Control. Validated before every write.
		@Shared
		public var routingPreferences: RoutingPreferences

		/// Proxy Link rules. Validated before every write.
		@Shared
		public var proxyLinkRules: [ProxyLinkRule]

		/// The default Proxy Link rules the person deleted (DEV-1113).
		@Shared
		public var removedProxyLinkDefaults: [UUID]

		/// Keyboard shortcut overrides. Validated before every write.
		@Shared
		public var keyboardShortcuts: [ShortcutBinding]

		/// Words that find commands in the command bar. Validated before every write.
		@Shared
		public var commandAliases: [CommandAlias]

		/// Conflict resolution per command (DEV-1332), where it differs from the default.
		@Shared
		public var shortcutConflictChoices: [ShortcutConflictOverride]

		/// Whether the engine reports every key combination Arx can bind (DEV-1332). Until it does, a
		/// shortcut without ⌘ can't reach a page first, and its picker stays at Arx.
		public var followsAllShortcutKeys: Bool = false

		/// Link click gestures and the Little Arx launcher.
		@Shared
		public var linkClicks: LinkClickPreferences

		/// Quit warnings, developer mode and the identity card style.
		@Shared
		public var general: GeneralPreferences

		/// Automatic Picture in Picture.
		@Shared
		public var automaticPictureInPicture: AutomaticPiPPreferences

		/// Opt-in experiments. There are none now.
		@Shared
		public var experiments: ExperimentalPreferences

		/// Settings › Advanced › WebKit: the sites that open in WebKit pages (DEV-877).
		@Shared
		public var webKitPages: WebKitPagePreferences

		/// Settings › General › Battery Saver (DEV-915).
		@Shared
		public var batterySaver: BatterySaverMode

		/// The sites' and tabs' own unread badges choices (DEV-1258): the site menu and the tab's
		/// menu set them, and General › Tabs lists the sites.
		@Shared
		public var unreadBadgeOverrides: UnreadBadgeOverrides

		/// Each profile's Never and Always translate choices, from the site menu (DEV-904), and
		/// Settings › General › Translation (DEV-996).
		@Shared
		public var translation: TranslationPreferences

		/// Pages each tab keeps for Back and Forward from the next launch (DEV-943).
		@Shared
		public var backForwardCachePages: Int

		/// When this Arx was first installed on this Mac: the identity card's Member since
		/// (DEV-1323). AppFeature records it at launch; Settings only reads it.
		@SharedReader
		public var installDate: Date?

		/// The one date the identity card's Member since shows (DEV-1323): the account's day from
		/// Arx's server once this Mac has a member number, else this Mac's install date.
		public var cardMemberSince: Date? {
			InstallDate.shown(member: memberNumber.number, installedAt: installDate)
		}

		/// Settings › Advanced › Feature Flags (DEV-1115): each flag's value and what set it, read
		/// when the page opens.
		public var featureFlagStates: [FeatureFlag: FeatureFlagState] = [:]

		/// The flags as Arx launched with them, read when this state is made at launch, so the page
		/// knows which changes wait for a relaunch.
		public var launchFeatureFlags: [FeatureFlag: Bool] = Dictionary(
			uniqueKeysWithValues: FeatureFlag.allCases.map { ($0, $0.isOn()) }
		)

		public init(
			category: SettingsCategory = .general,
			panel: SettingsPanel? = nil,
			selectedProfileID: Profile.ID? = nil,
			shortcutQuery: String = "",
			error: String? = nil,
			draft: SearchShortcut = .init(
				name: "",
				keyword: "",
				template: "https://capturecontext.dev/search?q={query}"
			),
			editingKeyword: String? = nil,
			bangs: BangCatalog = .empty,
			bangQuery: String = ""
		) {
			self.extensions = .init()
			self.extensionProfiles = []
			self.historyStatus = [:]
			self.pendingHistoryClearID = nil
			self.historyRemovalError = nil
			self.routing = .init()
			self.routingDraft = nil
			self.appLinks = .init()
			self.proxyLinkEditor = nil
			self.siteDraft = nil
			self.category = category
			self.panel = panel
			self.selectedProfileID = selectedProfileID
			self.globalShortcutMessage = nil
			self.shortcutQuery = shortcutQuery
			self.selectedCommand = .newTab
			self.recordingCommand = nil
			self.recordingAddsShortcut = false
			self.shortcutConflictResets = false
			self.shortcutConflict = nil
			self.shortcutError = nil
			self.aliasError = nil
			self.page = nil
			self.highlightedAnchor = nil
			self.error = error
			self.draft = draft
			self.editingKeyword = editingKeyword
			self.isEditingShortcut = editingKeyword != nil
			self.bangs = bangs
			self.bangQuery = bangQuery
			self.organizationEditor = .init()
			self.organizationEditorIsPresented = false
			self.isManagingOrganization = false
			self.organizationError = nil
			self.retirementAvailable = false
			self.contentBlockingAvailable = false
			self.darkPagesAvailable = false
			self.linkStatusAvailable = false
			self.matchSiteAvailable = false
			self.newTabsAtTopAvailable = false
			self.profileRetirements = []
			self.defaultBrowser = nil
			self.isRequestingDefaultBrowser = false
			self.defaultBrowserOutcome = nil
			self.updates = nil
			self.securityComponents = nil
			self.whatsNew = nil
			self.diagnostics = nil
			self.savedPasswords = nil
			self.autofillData = nil
			self.siteSettings = nil
			self.clearBrowsingData = nil

			@Dependency(\.workspaceSync)
			var workspaceSync

			self.iCloudSync = .init(isAvailable: workspaceSync.isAvailable())
			self.downloadSettings = [:]
			self.downloadSettingsNotice = [:]
			self.downloadSettingsChanging = []
			self.isSharingIdentityCard = false
			self.memberNumber = .init()
			self._chromeAppearance = Shared(.chromeAppearance)
			self._searchShortcuts = Shared(.searchShortcuts)
			self._routingPreferences = Shared(.routing)
			self._proxyLinkRules = Shared(.proxyLinkRules)
			self._removedProxyLinkDefaults = Shared(.removedProxyLinkDefaults)
			self._keyboardShortcuts = Shared(.keyboardShortcuts)
			self._commandAliases = Shared(.commandAliases)
			self._shortcutConflictChoices = Shared(.shortcutConflictChoices)
			self._linkClicks = Shared(.linkClicks)
			self._general = Shared(.general)
			self._automaticPictureInPicture = Shared(.automaticPictureInPicture)
			self._experiments = Shared(.experiments)
			self._webKitPages = Shared(.webKitPages)
			self._batterySaver = Shared(.batterySaver)
			self._unreadBadgeOverrides = Shared(.unreadBadgeOverrides)
			self._translation = Shared(.translation)
			self._installDate = SharedReader(.installDate)
			let backForwardCachePages = Shared(.backForwardCachePages)
			self._backForwardCachePages = backForwardCachePages
			self.backForwardCachePagesAtLaunch = backForwardCachePages.wrappedValue
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case extensions(ExtensionsFeature.Action)
		case savedPasswords(SavedPasswordsFeature.Action)
		case autofillData(AutofillDataFeature.Action)
		case siteSettings(SiteSettingsFeature.Action)
		case clearBrowsingData(ClearBrowsingDataFeature.Action)
		case iCloudSync(ICloudSyncSettingsFeature.Action)
		case memberNumber(MemberNumberFeature.Action)
		case configureExtensions([Profile])
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case requestClearHistory(Profile.ID)
			case cancelClearHistory
			case confirmClearHistory
			case retryHistory(Profile.ID)
			case routing(RoutingEditor.Action)
			case appLinks(AppLinkEditor.Action)
			case proxyLinks(ProxyLinksEditor.Action)

			/// The site lists' Add Site and Edit Site form (DEV-1001).
			case siteDraft(SettingsSiteDraft.Action)
			case categorySelected(SettingsCategory)

			/// A result of the sidebar's search: its pane, then its row, page or sheet.
			case searchResultChosen(SettingsDestination)
			case panelPresented(SettingsPanel?)
			case profileSelected(Profile.ID)
			case shortcutQueryChanged(String)
			case selectKeyboardCommand(BrowserCommand)
			case recordKeyboardShortcut(BrowserCommand?)

			/// Add Shortcut: records another shortcut for the command (DEV-920).
			case addKeyboardShortcut(BrowserCommand)
			case assignKeyboardShortcut(BrowserCommand, BrowserCore.KeyboardShortcut?)
			case replaceKeyboardShortcut
			case cancelKeyboardConflict
			case resetKeyboardShortcut(BrowserCommand)
			case resetKeyboardShortcuts

			/// The alias field of a command was committed; empty removes the alias.
			case commandAliasChanged(BrowserCommand, String)

			/// A command's Conflict resolution picker (DEV-1332): who gets its keys when the page
			/// would handle them too.
			case shortcutConflictResolutionChanged(BrowserCommand, ShortcutConflictResolution)

			/// Opens Assistant › AI Commands, or goes back to Assistant.
			/// Opens a page inside the pane, or goes back with nil.
			case pagePresented(SettingsPage?)
			case globalLittleArxEnabled(Bool)
			case shiftClickLinkAction(ShiftClickLinkAction)
			case littleArxLinkBinding(LittleArxLinkBinding)
			case forceClickLinkAction(ForceClickLinkAction)
			case crossSiteLinkFromFavorites(CrossSiteLinkAction)
			case crossSiteLinkFromPinnedTabs(CrossSiteLinkAction)
			case showsLinkStatus(Bool)
			case warnsBeforeQuitting(Bool)

			/// Settings › General › Handoff (DEV-922).
			case handoffEnabled(Bool)

			/// Settings › Developer › JavaScript from AppleScript (DEV-909).
			case appleScriptJavaScriptEnabled(Bool)

			/// Settings › General › Notifications open closed sites (DEV-885).
			case notificationsOpenClosedSites(Bool)
			case restoresWindowsAtStartup(Bool)
			case hapticsEnabled(Bool)
			case soundsEnabled(Bool)
			case hoverPreviewsEnabled(Bool)

			/// Folders, mail and recent pages in hover previews (DEV-802).
			case hoverPreviewSources(HoverPreviewSources)

			/// Delete in an empty command bar or address field closes it (DEV-750).
			case closesCommandBarOnEmptyDelete(Bool)
			case fetchesUnloadedSiteIcons(Bool)

			/// How long a hidden tab keeps its page loaded (DEV-873).
			case tabUnloadDelay(TabUnloadDelay)

			/// How long a tab stays hidden before low memory may unload it (DEV-873).
			case tabUnloadPressureGrace(TabUnloadPressureGrace)

			/// Pinned tabs and Favorites never unload (DEV-932).
			case keepsPinnedTabsLoaded(Bool)

			/// Pages each tab keeps for Back and Forward, from the next launch (DEV-943).
			case backForwardCachePages(Int)

			/// Filling a saved password asks for Touch ID or the login password first (DEV-875).
			case asksBeforeFillingPasswords(Bool)

			/// Addresses and payment cards fill in ordinary profiles (DEV-893).
			case fillsAddresses(Bool)
			case fillsPaymentCards(Bool)

			/// Arx's content blocking, and its cookie notice lists (DEV-884).
			case blocksContent(Bool)
			case blocksCookieBanners(Bool)

			/// Opens uBlock Origin's dashboard in a tab (DEV-884).
			case openContentBlockingDashboard

			/// Settings › Advanced › WebKit (DEV-877): the switch, and adding, editing and removing
			/// a listed site, or bringing back the built-in ones.
			case webKitPagesEnabled(Bool)
			case addWebKitSite(String)
			case editWebKitSite(String, String)
			case removeWebKitSite(String)
			case restoreWebKitSites

			/// Settings › Advanced › Feature Flags (DEV-1115): reads every flag, saves one, and
			/// relaunches Arx for the changes that wait for it.
			case featureFlagsAppeared
			case featureFlagChanged(FeatureFlag, Bool)
			case relaunchForFeatureFlags

			/// Protected media (DEV-1144): FairPlay in the tab or a WebKit page, and the Widevine answer.
			case protectedMediaPlayback(ProtectedMediaPlayback)
			case widevineAnswer(Bool)

			/// Settings › General › Battery Saver (DEV-915).
			case batterySaverMode(BatterySaverMode)

			/// Settings › General › Translation (DEV-996).
			case translationProvider(TranslationProvider)
			case translationQuality(TranslationQuality)

			/// Nil translates into the person's first preferred language.
			case translationTarget(String?)

			/// Moves the Settings identity card to its next style and remembers it.
			case cycleIdentityCardStyle

			/// Opens the share sheet with the identity card as an image.
			case shareIdentityCard

			/// The identity card's share sheet closed.
			case identityCardShareFinished

			/// Light, dark, or the system's appearance for every Arx window.
			case appTheme(AppTheme)

			/// DEV-1020.
			case darkPages(DarkPagesMode)
			case appIcon(AppIconStyle)
			case automaticPictureInPicture(Bool)
			case closesPictureInPictureOnReturn(Bool)
			case littleArxLauncherPosition(LittleArxLauncherPosition)

			/// Settings › Links › Air Traffic Control › Runway appearance.
			case runwayAppearance(RunwayAppearance)

			/// Settings › Links › Little Arx › Archive Little Arx windows (DEV-1138).
			case littleArxArchiveInterval(LittleArxArchiveInterval?)
			case developerModeEnabled(Bool)
			case developerHeaderEnabled(Bool)
			case localTabHighlightEnabled(Bool)

			/// Settings › Appearance › Sidebar (DEV-913).
			case sidebarPosition(SidebarPosition)

			/// Settings › General › Tabs (DEV-913).
			case newTabPlacement(NewTabPlacement)

			/// Settings › General › Tabs › New tabs open while `ARX_NEW_TABS_AT_TOP` is on (DEV-1174).
			case openedTabPlacement(NewTabPlacement)

			/// Settings › General › Tabs: a tab a link opens comes forward (DEV-952).
			case switchesToLinkTabs(Bool)

			/// Settings › General › Tabs: a launch opens to the empty page with every folder collapsed
			/// (DEV-1234).
			case opensEmptyPageAtLaunch(Bool)

			/// Settings › General › Tabs › Show unread badges: the browser default (DEV-907, DEV-1258).
			case showsUnreadBadges(Bool)

			/// Settings › General › Tabs: a site's tabs follow the profile and the browser default
			/// again (DEV-1258).
			case resetUnreadBadgeSite(String)
			case grainEnabled(Bool)
			case grainIntensity(Double)
			case grainSize(Double)

			/// The app-wide tint and film grain, committed once an edit ends.
			case chromeAppearance(ChromeAppearance)
			case resetAppearance

			/// Opens the editor for a new search shortcut.
			case addShortcut
			case editShortcut(String)
			case cancelShortcutEdit
			case draftChanged(SearchShortcut)
			case saveShortcut
			case deleteShortcut(String)
			case toggleShortcut(String)
			case bangQueryChanged(String)
			case editOrganization(OrganizationEditor)
			case organizationEditorChanged(OrganizationEditor)
			case dismissOrganizationEditor
			case organizationEditorPresented(Bool)
			case submitOrganizationEditor
			case retryProfileRetirement(Profile.ID)
			case changeOrganization(OrganizationChange)

			/// Keep on a profile or space marked for deletion, with everything in it (DEV-1336): clears the
			/// mark on every Mac and cancels the removal.
			case keepMarked(Set<UUID>)

			/// The Default Browser row appeared; reads the current default.
			case checkDefaultBrowser
			case makeDefaultBrowser

			/// Starts the updater once at launch and follows its state.
			case startUpdates

			/// Check Now in Settings, or Check for Updates… in the Arx menu.
			case checkForUpdates
			case automaticallyChecksForUpdates(Bool)
			case automaticallyDownloadsUpdates(Bool)

			/// Quit and Install, while a downloaded update waits for Arx to quit.
			case installUpdate

			/// Settings › Developer's Security data section appeared; reads the versions in use.
			case loadSecurityComponents

			/// Stable or Beta, in Settings › General › Updates (DEV-888).
			case updateChannel(AppUpdaterClient.Channel)

			/// What's New's Continue, or the sheet closing by itself.
			case dismissWhatsNew

			/// What's New's link to the full release notes.
			case openReleaseNotes

			/// At launch: keeps new crash reports on this Mac (DEV-887).
			case startDiagnostics

			/// Settings › Privacy appeared.
			case loadDiagnostics
			case removeCrashReports

			/// Settings › Privacy › Report a Problem….
			case reportProblem

			/// Opens a listed profile's saved passwords.
			case showSavedPasswords(Profile.ID)
			case savedPasswordsPresented(Bool)

			/// A profile's addresses and payment cards (DEV-893).
			case showAutofill(Profile.ID)
			case autofillPresented(Bool)

			/// Opens a listed profile's site permissions and zoom.
			case showSiteSettings(Profile.ID)
			case siteSettingsPresented(Bool)

			/// Opens a listed profile's Clear Browsing Data.
			case showClearBrowsingData(Profile.ID)

			/// Forgets a profile's never-translate sites and always-translate languages (DEV-871).
			case resetTranslationChoices(Profile.ID)
			case clearBrowsingDataPresented(Bool)

			/// Reads a listed profile's downloads folder.
			case loadDownloadSettings(Profile.ID)
			case chooseDownloadFolder(Profile.ID, URL)
			case asksWhereToSave(Profile.ID, Bool)

			/// Goes back to the folder a new profile starts with.
			case resetDownloadFolder(Profile.ID)
		}

		@CasePathable
		public enum Event: Sendable {
			/// The engine reports every key combination Arx can bind, not only ⌘ ones (DEV-1332).
			case followsAllShortcutKeys(Bool)
			case organizationChanged
			case organizationChangeFailed(String)

			/// The app became active again; the default may have changed in System Settings.
			case applicationBecameActive
			case defaultBrowserChecked(DefaultBrowserClient.Status)
			case defaultBrowserRequestFinished(DefaultBrowserClient.Outcome)
			case updatesChanged(AppUpdaterClient.Status)

			/// The first launch after an update; What's New opens.
			case whatsNewReady(AppUpdaterClient.WhatsNew)
			case diagnosticsChanged(DiagnosticsClient.Status)

			/// The quit `quitToInstallUpdate` started was cancelled; the update waits for the next one.
			case updateQuitCancelled
			case securityComponentsLoaded([BrowserSecurityComponent])
			case downloadSettingsLoaded(Profile.ID, Result<DownloadSettings, ProfileDataFailure>)
			case downloadSettingsChangeFinished(Profile.ID)

			/// A search result's highlight has been shown long enough.
			case highlightEnded(SettingsAnchor)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case retireProfile(Profile.ID)
			case clearHistory(Profile.ID)

			/// Removes history entries last visited at or after a moment (DEV-647).
			case clearHistorySince(Profile.ID, Date)

			/// A profile's cookies or cache were cleared (DEV-1142).
			case clearedSiteData(Profile.ID)
			case retryHistory(Profile.ID)
			case changeOrganization(OrganizationChange)

			/// Opens Local assistants (MCP), which AppFeature presents.
			case openAutomation

			/// Opens uBlock Origin's dashboard in a tab of the front window (DEV-884).
			case openContentBlockingDashboard

			/// A downloaded update asked to relaunch; AppFeature quits as usual and Sparkle
			/// installs the update once Arx has exited.
			case quitToInstallUpdate

			/// Feature Flags' Relaunch (DEV-1115): AppFeature quits as usual and, once the quit
			/// goes ahead, Arx opens again.
			case quitToRelaunch

			/// Opens the full release notes in a new tab.
			case openReleaseNotes(URL)

			/// Opens Report a Problem, which AppFeature presents.
			case reportProblem
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.continuousClock)
	private var clock

	private struct HighlightID: Hashable, Sendable {}

	/// How long a search result's row stays highlighted.
	internal static let highlightDuration: Duration = .seconds(1.6)

	public init() {}

	public var body: some ReducerOf<Self> {
		Scope(state: \.extensions, action: \.extensions) {
			ExtensionsFeature()
		}

		Scope(state: \.iCloudSync, action: \.iCloudSync) {
			ICloudSyncSettingsFeature()
		}

		Scope(state: \.memberNumber, action: \.memberNumber) {
			MemberNumberFeature()
		}

		Pullback(\.configureExtensions) { state, profiles in
			state.extensionProfiles = profiles
			let selected = profiles.first { $0.id == state.selectedProfileID } ?? profiles.first

			return ExtensionsFeature()
				._reduce(into: &state.extensions, action: .configure(selected))
				.map(Action.extensions)
		}

		SettingsHistory()
		SettingsOrganization()
		SettingsProxyLinks()
		SettingsSiteLists()
		SettingsRouting()
		SettingsAppLinks()
		SettingsDefaultBrowser()
		SettingsUpdates()
		SettingsSecurityData()
		SettingsPrivacy()
		SettingsSavedPasswords()
			.ifLet(\.savedPasswords, action: \.savedPasswords) { SavedPasswordsFeature() }
			.ifLet(\.autofillData, action: \.autofillData) { AutofillDataFeature() }
		SettingsSiteSettings()
			.ifLet(\.siteSettings, action: \.siteSettings) { SiteSettingsFeature() }
		SettingsWebKitPages()
		SettingsFeatureFlagsPage()
		SettingsBatterySaver()
		SettingsTranslation()
		SettingsProfileData()
			.ifLet(\.clearBrowsingData, action: \.clearBrowsingData) { ClearBrowsingDataFeature() }

		KeyboardShortcutSettings()

		// These are shared keys: AppFeature saves their edits.
		Pullback(\.ui.shiftClickLinkAction) { state, action in
			state.$linkClicks.withLock { $0.shiftClickLinkAction = action }
			return .none
		}

		Pullback(\.ui.littleArxArchiveInterval) { state, interval in
			state.$linkClicks.withLock { $0.littleArxArchiveInterval = interval }
			return .none
		}

		Pullback(\.ui.littleArxLauncherPosition) { state, position in
			state.$linkClicks.withLock { $0.littleArxLauncherPosition = position }
			return .none
		}

		Pullback(\.ui.runwayAppearance) { state, appearance in
			state.$linkClicks.withLock { $0.runwayAppearance = appearance }
			return .none
		}

		Pullback(\.ui.littleArxLinkBinding) { state, binding in
			state.$linkClicks.withLock { $0.littleArxLinkBinding = binding }
			return .none
		}

		Pullback(\.ui.forceClickLinkAction) { state, action in
			state.$linkClicks.withLock { $0.forceClickLinkAction = action }
			return .none
		}

		Pullback(\.ui.crossSiteLinkFromFavorites) { state, action in
			state.$linkClicks.withLock { $0.crossSiteLinkFromFavorites = action }
			return .none
		}

		Pullback(\.ui.crossSiteLinkFromPinnedTabs) { state, action in
			state.$linkClicks.withLock { $0.crossSiteLinkFromPinnedTabs = action }
			return .none
		}

		Pullback(\.ui.showsLinkStatus) { state, isEnabled in
			state.$linkClicks.withLock { $0.showsLinkStatus = isEnabled }
			return .none
		}

		Pullback(\.ui.appleScriptJavaScriptEnabled) { state, isEnabled in
			guard !isEnabled || state.general.developerModeEnabled else { return .none }
			state.$general.withLock { $0.appleScriptJavaScriptEnabled = isEnabled }
			return .none
		}

		Pullback(\.ui.notificationsOpenClosedSites) { state, isEnabled in
			state.$general.withLock { $0.notificationsOpenClosedSites = isEnabled }
			return .none
		}

		Pullback(\.ui.handoffEnabled) { state, isEnabled in
			state.$general.withLock { $0.handoffEnabled = isEnabled }
			return .none
		}

		Pullback(\.ui.warnsBeforeQuitting) { state, warns in
			state.$general.withLock { $0.warnsBeforeQuitting = warns }
			return .none
		}

		Pullback(\.ui.restoresWindowsAtStartup) { state, restores in
			state.$general.withLock { $0.restoresWindowsAtStartup = restores }
			return .none
		}

		Pullback(\.ui.hapticsEnabled) { state, isEnabled in
			state.$general.withLock { $0.hapticsEnabled = isEnabled }
			return .none
		}

		Pullback(\.ui.soundsEnabled) { state, isEnabled in
			state.$general.withLock { $0.soundsEnabled = isEnabled }
			return .none
		}

		Pullback(\.ui.hoverPreviewsEnabled) { state, isEnabled in
			state.$general.withLock { $0.hoverPreviewsEnabled = isEnabled }
			return .none
		}

		Pullback(\.ui.hoverPreviewSources) { state, sources in
			state.$general.withLock { $0.hoverPreviewSources = sources }
			return .none
		}

		Pullback(\.ui.fetchesUnloadedSiteIcons) { state, isEnabled in
			state.$general.withLock { $0.fetchesUnloadedSiteIcons = isEnabled }
			return .none
		}

		Pullback(\.ui.tabUnloadDelay) { state, delay in
			state.$general.withLock { $0.tabUnloadDelay = delay }
			return .none
		}

		Pullback(\.ui.tabUnloadPressureGrace) { state, grace in
			state.$general.withLock { $0.tabUnloadPressureGrace = grace }
			return .none
		}

		Pullback(\.ui.keepsPinnedTabsLoaded) { state, isOn in
			state.$general.withLock { $0.keepsPinnedTabsLoaded = isOn }
			return .none
		}

		Pullback(\.ui.backForwardCachePages) { state, count in
			guard BackForwardCachePages.counts.contains(count) else { return .none }
			state.$backForwardCachePages.withLock { $0 = count }
			return .none
		}

		Pullback(\.ui.asksBeforeFillingPasswords) { state, isEnabled in
			state.$general.withLock { $0.asksBeforeFillingPasswords = isEnabled }
			return .none
		}

		Pullback(\.ui.fillsAddresses) { state, isEnabled in
			state.$general.withLock { $0.fillsAddresses = isEnabled }
			return .none
		}

		Pullback(\.ui.fillsPaymentCards) { state, isEnabled in
			state.$general.withLock { $0.fillsPaymentCards = isEnabled }
			return .none
		}

		Pullback(\.ui.blocksContent) { state, isEnabled in
			guard state.contentBlockingAvailable else { return .none }

			state.$general.withLock { $0.blocksContent = isEnabled }
			return .none
		}

		Pullback(\.ui.blocksCookieBanners) { state, isEnabled in
			guard state.contentBlockingAvailable else { return .none }

			state.$general.withLock { $0.blocksCookieBanners = isEnabled }
			return .none
		}

		Pullback(\.ui.openContentBlockingDashboard) { state in
			guard state.contentBlockingAvailable, state.general.blocksContent else { return .none }

			return .send(.delegate(.openContentBlockingDashboard))
		}

		Pullback(\.ui.closesCommandBarOnEmptyDelete) { state, isEnabled in
			state.$general.withLock { $0.closesCommandBarOnEmptyDelete = isEnabled }
			return .none
		}

		Pullback(\.ui.cycleIdentityCardStyle) { state in
			state.$general.withLock { $0.identityCardStyle = $0.identityCardStyle.next }
			return .none
		}

		Pullback(\.ui.shareIdentityCard) { state in
			state.isSharingIdentityCard = true
			return .none
		}

		Pullback(\.ui.identityCardShareFinished) { state in
			state.isSharingIdentityCard = false
			return .none
		}

		Pullback(\.ui.darkPages) { state, mode in
			guard state.darkPagesAvailable else { return .none }

			state.$general.withLock { $0.darkPages = mode }
			return .none
		}

		Pullback(\.ui.appTheme) { state, theme in
			state.$general.withLock { $0.appTheme = theme }
			return .none
		}

		Pullback(\.ui.appIcon) { state, icon in
			state.$general.withLock { $0.appIcon = icon }
			return .none
		}

		Pullback(\.ui.automaticPictureInPicture) { state, enabled in
			state.$automaticPictureInPicture.withLock { $0.isEnabled = enabled }
			return .none
		}

		Pullback(\.ui.closesPictureInPictureOnReturn) { state, closes in
			state.$automaticPictureInPicture.withLock { $0.closesOnReturn = closes }
			return .none
		}

		Pullback(\.ui.globalLittleArxEnabled) { state, enabled in
			state.$linkClicks.withLock { $0.globalLittleArxEnabled = enabled }
			return .none
		}

		Pullback(\.ui.localTabHighlightEnabled) { state, enabled in
			state.$general.withLock { $0.localTabHighlightEnabled = enabled }
			return .none
		}

		Pullback(\.ui.sidebarPosition) { state, position in
			state.$general.withLock { $0.sidebarPosition = position }
			return .none
		}

		Pullback(\.ui.showsUnreadBadges) { state, isOn in
			state.$general.withLock { $0.showsUnreadBadges = isOn }
			return .none
		}

		Pullback(\.ui.resetUnreadBadgeSite) { state, host in
			state.$unreadBadgeOverrides.withLock { $0.sites[host] = nil }
			return .none
		}

		Pullback(\.ui.newTabPlacement) { state, placement in
			state.$general.withLock { $0.newTabPlacement = placement }
			return .none
		}

		Pullback(\.ui.openedTabPlacement) { state, placement in
			state.$general.withLock { $0.openedTabPlacement = placement }
			return .none
		}

		Pullback(\.ui.switchesToLinkTabs) { state, isEnabled in
			state.$general.withLock { $0.switchesToLinkTabs = isEnabled }
			return .none
		}

		Pullback(\.ui.opensEmptyPageAtLaunch) { state, isEnabled in
			state.$general.withLock { $0.opensEmptyPageAtLaunch = isEnabled }
			return .none
		}

		Pullback(\.ui.developerHeaderEnabled) { state, enabled in
			state.$general.withLock { $0.developerHeaderEnabled = enabled }
			return .none
		}

		Pullback(\.ui.developerModeEnabled) { state, enabled in
			state.$general.withLock { $0.developerModeEnabled = enabled }
			return .none
		}

		Pullback(\.ui.categorySelected) { state, category in
			state.category = category
			state.panel = nil
			state.page = nil
			state.highlightedAnchor = nil
			return .cancel(id: HighlightID())
		}

		Pullback(\.ui.searchResultChosen) { state, destination in
			state.category = destination.category
			state.panel = nil

			// A page this build doesn't list opens its pane instead (DEV-871).
			if case let .page(page) = destination, SettingsPage.available.contains(page) {
				state.page = page
			} else {
				state.page = nil
			}
			state.highlightedAnchor = destination.anchor
			var effects: [Effect<Action>] = []
			switch destination {
			case let .panel(panel, _):
				state.panel = panel

			case .automation:
				effects.append(.send(.delegate(.openAutomation)))

			case .extensions:
				let profileID = state.selectedProfileID
				?? state.extensions.profile?.id
				?? state.extensionProfiles.first?.id
				guard let profileID else { break }

				state.page = .profile
				effects.append(.concatenate(
					.send(.ui(.profileSelected(profileID))),
					.send(.extensions(.ui(.present)))
				))

			case .pane, .row, .page:
				break
			}
			if let anchor = destination.anchor {
				let timer: Effect<Action> = .run { [clock] send in
					try await clock.sleep(for: Self.highlightDuration)
					await send(.event(.highlightEnded(anchor)))
				}
				.cancellable(id: HighlightID())

				// Cancelled in reducer order: `cancelInFlight` cancels only when the task registers,
				// off the main actor, so an older timer could cancel this one and keep the newer
				// highlight. One that registers late ends only its own anchor's highlight.
				effects.append(.concatenate(.cancel(id: HighlightID()), timer))
			} else {
				effects.append(.cancel(id: HighlightID()))
			}
			return .merge(effects)
		}

		Pullback(\.event.highlightEnded) { state, anchor in
			if state.highlightedAnchor == anchor { state.highlightedAnchor = nil }
			return .none
		}

		Pullback(\.ui.pagePresented) { state, page in

			// A page this build doesn't list stays closed (DEV-871).
			guard let page, SettingsPage.available.contains(page) else {
				state.page = nil
				return .none
			}

			state.page = page
			return .none
		}

		Pullback(\.ui.panelPresented) { state, panel in
			state.panel = panel
			return .none
		}

		Pullback(\.ui.profileSelected) { state, id in
			state.selectedProfileID = id
			let profile = state.extensionProfiles.first { $0.id == id }

			return ExtensionsFeature()
				._reduce(into: &state.extensions, action: .configure(profile))
				.map(Action.extensions)
		}

		Pullback(\.ui.shortcutQueryChanged) { state, query in
			state.shortcutQuery = query
			return .none
		}

		// The app-wide appearance is a shared key: AppFeature saves its edits.
		Pullback(\.ui.grainEnabled) { state, value in
			state.$chromeAppearance.withLock { $0.grain.isEnabled = value }
			return .none
		}

		Pullback(\.ui.grainIntensity) { state, value in
			guard value.isFinite else { return .none }
			state.$chromeAppearance.withLock { $0.grain.intensity = min(max(value, 0), 1) }
			return .none
		}

		Pullback(\.ui.grainSize) { state, value in
			guard value.isFinite else { return .none }
			state.$chromeAppearance.withLock { $0.grain.size = min(max(value, 1), 3) }
			return .none
		}

		Pullback(\.ui.chromeAppearance) { state, chosen in

			// Clamps and rejects values that aren't numbers, as an override would be.
			var appearance = AppearanceOverride(chosen).applied(to: state.chromeAppearance)

			// Automatic is no accent at all at this level, so the current one isn't kept for it (DEV-1117).
			appearance.accent = chosen.accent?.normalized

			// Nor is one color the current gradient kept: the theme panel's last dot removed is none
			// (DEV-1286).
			appearance.gradient = chosen.gradient?.normalized.flatMap { $0.stops.isEmpty ? nil : $0 }
			guard appearance != state.chromeAppearance else { return .none }

			state.$chromeAppearance.withLock { $0 = appearance }
			return .none
		}

		Pullback(\.ui.resetAppearance) { state in
			state.$chromeAppearance.withLock { $0 = BrowserPreferences().chromeAppearance }
			return .none
		}

		// Search shortcuts are a shared key: AppFeature saves their edits.
		Pullback(\.ui.addShortcut) { state in
			state.draft = .newSearchShortcut
			state.editingKeyword = nil
			state.isEditingShortcut = true
			state.error = nil
			return .none
		}

		Pullback(\.ui.editShortcut) { state, keyword in
			guard let shortcut = state.searchShortcuts.first(where: { $0.id == keyword })
			else { return .none }

			state.draft = shortcut
			state.editingKeyword = keyword
			state.isEditingShortcut = true
			state.error = nil
			return .none
		}

		Pullback(\.ui.cancelShortcutEdit) { state in
			state.draft = .newSearchShortcut
			state.editingKeyword = nil
			state.isEditingShortcut = false
			state.error = nil
			return .none
		}

		Pullback(\.ui.draftChanged) { state, draft in
			state.draft = draft
			state.error = nil
			return .none
		}

		Pullback(\.ui.saveShortcut) { state in
			var shortcuts = state.searchShortcuts
			shortcuts.removeAll { $0.id == state.editingKeyword }
			shortcuts.append(state.draft)
			do {
				try BrowserPreferences(searchShortcuts: shortcuts).validate()
			} catch {
				state.error = String.localized(.appUI.search.invalidShortcut)
				return .none
			}
			state.$searchShortcuts.withLock { $0 = shortcuts }
			state.editingKeyword = nil
			state.isEditingShortcut = false
			state.draft = .newSearchShortcut
			state.error = nil
			return .none
		}

		Pullback(\.ui.deleteShortcut) { state, keyword in
			state.$searchShortcuts.withLock { $0.removeAll { $0.id == keyword } }
			if state.editingKeyword == keyword {
				state.editingKeyword = nil
				state.isEditingShortcut = false
				state.draft = .newSearchShortcut
				state.error = nil
			}
			return .none
		}

		Pullback(\.ui.toggleShortcut) { state, keyword in
			guard let index = state.searchShortcuts.firstIndex(where: { $0.id == keyword })
			else { return .none }

			state.$searchShortcuts.withLock { $0[index].isEnabled.toggle() }
			return .none
		}

		Pullback(\.ui.bangQueryChanged) { state, query in
			state.bangQuery = query
			return .none
		}
	}
}

extension SettingsFeature.State {
	/// Bundled bangs listed in Settings: the most popular first, or those matching `bangQuery`.
	public var bundledBangResults: [BangCatalog.Bang] {
		bangs.search(bangQuery, limit: Self.bundledBangLimit)
	}

	private static let bundledBangLimit: Int = 50
}

extension SettingsFeature.State {
	public struct AliasError: Equatable, Sendable {
		public let command: BrowserCommand
		public let message: String

		public init(
			command: BrowserCommand,
			message: String
		) {
			self.command = command
			self.message = message
		}
	}
}

extension SearchShortcut {
	/// The search shortcut editor's starting point for a new shortcut.
	internal static var newSearchShortcut: Self {
		.init(
			name: "",
			keyword: "",
			template: "https://capturecontext.dev/search?q={query}"
		)
	}
}
