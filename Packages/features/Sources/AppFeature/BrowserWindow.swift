import AppKit
import AppLinkClient
import AppUI
import BrowserAutomationClient
import BrowserCaptureClient
import BrowserCore
import BrowserEngineClient
import BrowserMediaClient
import BrowserPageInspectionClient
import BrowserPagePreviewClient
import BrowserPageWaitClient
import BrowserDownloadsClient
import BrowserSiteIconClient
import BrowserSurfaceClient
import BrowserHistoryClient
import HistoryDatabase
import PageTextIndexClient
import BrowserWorkspaceClient
import CoreServices.AE
import ChromiumBrowserEngine
import ChromiumEngine
import DownloadsFeature
import FairPlayBridge
import MainFeature
import MigrationAssistant
import MigrationAssistantFeature
import OnboardingFeature
import OSLog
import SettingsFeature
import SwiftUI
import TaskManagerFeature
import WebKitBrowserEngine
import WorkspaceSync
import _ComposableArchitecture

@MainActor
internal final class BrowserWindow: NSObject, NSWindowDelegate {
	internal let runtime: ChromiumRuntime
	internal let environment: [String: String]
	internal let profileDirectory: URL
	internal let engine: ChromiumBrowserEngine

	/// Chromium and WebKit pages behind one engine client (DEV-877).
	internal let pageRouter: PageEngineRouter
	private let webKitContentBlocking: WebKitContentBlockingSites

	/// Settings' Battery Saver and macOS Low Power Mode (DEV-915).
	private let batterySaver: BatterySaverController

	/// FairPlay in Chromium tabs (DEV-1144): Spotify's page stays in Chromium and plays through
	/// Arx's FairPlay helper. Nil when the `ARX_FAIRPLAY_IN_CHROMIUM` feature flag is off or the
	/// engine, the helper app or the script is missing; those sites then open in WebKit.
	private var fairPlay: FairPlayBridge?

	/// The bridged sites whose track failed this run: they open in WebKit pages until quit.
	private var fairPlayFallbacks: Set<String> = []
	internal let capabilities: BrowserCapabilities
	internal let automationHost: BrowserAutomationHost
	internal let workspace: BrowserWorkspaceClient

	/// iCloud sync of the SQLite workspace, made only with both the `ARX_SQLITE_WORKSPACE` and the
	/// `ARX_ICLOUD_SYNC` feature flags (DEV-977). Nothing reaches CloudKit until the person turns it on.
	private let workspaceSync: WorkspaceSync?
	internal let history: BrowserHistoryClient
	private let retirementStore: BrowserProfileRetirementStore?
	internal let profileRetirementConfiguration: ChromiumProfileRetirementConfiguration?
	internal let runtimeProfileDirectory: URL
	internal let downloads: BrowserDownloadsClient
	internal let siteIcons: BrowserSiteIconClient

	/// The front window's page offered to Handoff (DEV-922).
	private let handoff: HandoffActivity = .init()

	/// The `arx://` link confirmation on screen and its window (DEV-929).
	private var presentedArxLink: (id: UUID, alert: NSAlert, host: NSWindow)?
	private var arxLinkKeyObserver: (any NSObjectProtocol)?
	private var arxLinkArming: Int = 0
	private let pagePreviews: BrowserPagePreviewClient
	internal let downloadsFile: URL
	internal let store: StoreOf<AppFeature>
	internal var littleWindows: [UUID: LittleArxPanel] = [:]

	/// The profile picker at the pointer and the request it asks about (DEV-858).
	internal var profilePicker: (requestID: UUID, panel: RoutingProfilePickerPanel)?
	private var settingsFocusRequest: Int = 0
	internal var settingsWindow: NSWindow?
	private var agentSetupObservers: [any NSObjectProtocol] = []
	private var activationObserver: (any NSObjectProtocol)?
	private var mediaActivityObserver: (any NSObjectProtocol)?
	private var desktopSpaceObserver: (any NSObjectProtocol)?

	/// The Little Arx windows last reported on another macOS desktop Space (DEV-931).
	private var littleWindowsElsewhere: Set<UUID> = []
	private var windowsElsewhere: Set<UUID> = []

	/// What automatic Picture in Picture last heard about which windows are on the display
	/// (DEV-1246), and the AppKit notifications that can change it.
	private var windowsOnDisplay: Set<UUID>?
	private var windowsOnDisplayObservers: [any NSObjectProtocol] = []
	private var onboardingFocusRequest: Int = 0
	private var onboardingHandOffRequest: Int = 0

	/// The closed onboarding window, kept still while the main window is held for the
	/// provisional profile's checks, then grown into it (DEV-841).
	private var pendingHandOffWindow: NSWindow?
	private var onboardingWindow: NSWindow?
	private var mediaSourceFocusRequest: Int = 0
	private var downloadsWindow: NSWindow?
	private var downloadsFocusRequest: Int = 0
	private var taskManagerWindow: NSWindow?
	private var taskManagerFocusRequest: Int = 0
	private var lastFocusedWindowID: UUID?
	private var lastFocusWasLittle: Bool = false
	private var appActivationRequest: Int = 0
	private var appliedAppIcon: AppIconStyle?
	internal var additionalWindows: [UUID: NSWindow] = [:]
	internal var normalWindowFrames: [UUID: CGRect] = [:]
	internal var geometryReadyWindows: Set<UUID> = []
	internal var fullScreenTransitions: Set<UUID> = []
	internal var geometrySends: [UUID: Task<Void, Never>] = [:]
	internal var pendingFullScreenWindows: [NSWindow] = []
	internal var restoringFullScreenWindowID: UUID?

	/// Windows in or out of macOS full screen for a page in HTML full screen (DEV-949).
	internal let pageFullScreenWindows: PageFullScreenWindows = .init()

	/// Page PiP's floating window (DEV-950).
	private let pagePictureInPictureWindows: PagePictureInPictureWindows = .init()
	internal var window: NSWindow?
	private var observation: ObserveToken?
	private var titleObservation: ObserveToken?
	private var placementObservation: ObserveToken?

	/// DEV-1020: Settings' mode and the profiles' sites, and Arx's windows' appearance.
	private var darkPagesObservation: ObserveToken?
	private var appearanceObservation: NSKeyValueObservation?

	/// The extension tab placements last given to the engine, which hears only their changes.
	private var extensionTabPlacements: [BrowserCore.Tab.ID: ExtensionTabPlacements.Placement] = [:]
	private var linkContextMenu: LinkContextMenu?
	private var autofillDropdown: AutofillDropdown?
	private var linkStatus: LinkStatusPresenter?

	/// Turns the engine's hovered-link reports on with Settings' Show where links go (DEV-1118).
	private var linkStatusObservation: ObserveToken?
	private var incomingURLHandler: IncomingURLHandler?
	internal var isQuitting: Bool = false
	internal var reopenCount: Int = 0
	internal var smokePhase: Int = 0
	internal var smokeWindow: NSWindow?

	/// Names the last started smoke step, so a timeout identifies its fixture.
	internal var smokeStage: String = ""
	private var developerModeConfiguration: Bool?

	/// Whether the engine was told about the `ARX_PAGE_PROMPTS` feature flag (DEV-963).
	private var pagePromptsConfigured: Bool = false

	/// Whether the engine has the app's window for extensions' popups (DEV-1316).
	private var extensionPopupWindowsConfigured: Bool = false
	internal let headless: HeadlessRun?
	internal var failed: Bool = false
	#if DEBUG
	internal var routingSmoke: RoutingSmoke?
	internal var littleArxSpaceSmoke: LittleArxSpaceSmoke?
	internal var retirementSmoke: ProfileRetirementSmoke?
	internal var extensionSettingsSmokeFixture: ExtensionSettingsSmokeFixture?
	#endif

	internal init(
		runtime: ChromiumRuntime,
		environment: [String: String],
		profileDirectory: URL,
		headless: HeadlessRun? = nil
	) throws {
		self.runtime = runtime
		self.environment = environment
		self.profileDirectory = profileDirectory
		self.headless = headless

		let workspaceFile = profileDirectory.appendingPathComponent("arx-workspace.json")

		// `ARX_SQLITE_WORKSPACE` moves the workspace into SQLite (DEV-560); off, the JSON file as before.
		// With `ARX_ICLOUD_SYNC` too, preference rows go through the preferences file's own connection,
		// the one the Preferences sync engine watches (DEV-977).
		let storage: BrowserWorkspaceClient.Storage = .init(environment: environment)
		let syncsWithICloud: Bool = storage == .sqlite && ICloudSyncFeatureFlag.isOn(environment: environment)
		let workspace = BrowserWorkspaceClient(
			file: workspaceFile,
			storage: storage,
			separatePreferencesConnection: syncsWithICloud
		)
		self.workspace = workspace

		// History moves into `arx-history.sqlite` with the workspace (DEV-984). A database that can't
		// open leaves this run on the JSON files, which it never changes.
		let historyFolder: URL = profileDirectory.appendingPathComponent("History")
		let historyDatabase: HistoryDatabase? = if storage == .sqlite {
			try? HistoryDatabase(directory: profileDirectory)
		} else {
			nil
		}

		// The history store asks which profiles are "this Mac only" at each write (DEV-981): the
		// document's, once it's made; until then, what the history file recorded last.
		let localProfiles: LockIsolated<(@Sendable () -> ProfileSync?)> = .init({ nil })
		let history: BrowserHistoryClient = historyDatabase.map {
			.database($0, legacyDirectory: historyFolder, localProfiles: { localProfiles.value() })
		} ?? .local(directory: historyFolder)
		self.history = history
		var recovery = try workspace.loadWithRecovery().applyingAutomationRecoveryPolicy()

		// A crashed headless run can leave its run-long grant behind; an attended
		// session revokes it. A headless run replaces its stale client itself.
		let loadedAutomation = recovery.preferences.automation
		if headless == nil {
			recovery.preferences.automation = AutomationState.attendedPreferences(loadedAutomation, now: Date())
		}
		let initialURL: String? = headless.map { $0.configuration.initialURL?.absoluteString ?? "about:blank" }
		?? environment["ARX_ENGINE_URL"]
		let startsProvisional: Bool = initialURL == nil
		&& OnboardingLaunchPolicy.presentsAutomatically(
			environment: environment,
			isHeadless: headless != nil
		)
		var organization: BrowserOrganization
		if let recovered = recovery.organization {
			organization = recovered
		} else if startsProvisional {
			// A first launch starts in a provisional Default profile that onboarding's
			// import may replace (DEV-841). The first save below records it.
			let provisional = ProvisionalProfile(
				profileID: .init(rawValue: UUID()),
				spaceID: .init(rawValue: UUID())
			)
			organization = provisional.organization
			recovery.preferences.onboarding.provisionalProfile = provisional

			// Onboarding may set Arx up from iCloud first (DEV-1215): until it decides, Default
			// stays on this Mac, so turning sync on there doesn't upload it.
			if syncsWithICloud, OnboardingICloudFeatureFlag.isOn(environment: environment) {
				organization.profiles[id: provisional.profileID]?.syncsWithICloud = false
				recovery.preferences.onboarding.heldForICloud = provisional.profileID
			}
		} else {
			organization = Self.initialOrganization(url: initialURL)
		}
		guard let legacyProfileID = organization.legacyProfileID
		else { throw BrowserLaunchError.invalidWorkspace }
		let revokedRunGrants = recovery.preferences.automation != loadedAutomation

		// A first launch gets Arx's default Proxy Links rules; an existing install, each once (DEV-1003).
		let offeredProxyLinkDefaults = recovery.preferences.offerDefaultProxyLinkRules()
		let requiresWorkspaceSave = !workspace.hasPersistedLegacyProfileIdentity
		|| recovery.usedBackup
		|| revokedRunGrants
		|| offeredProxyLinkDefaults

		if requiresWorkspaceSave {
			try workspace.save(
				organization,
				preferences: recovery.preferences,
				synchronizeSecurityChange: recovery.usedBackup
			)
		}
		let retirementStore: BrowserProfileRetirementStore?
		do {
			retirementStore = try BrowserProfileRetirementStore(
				root: profileDirectory,
				legacyProfileID: legacyProfileID
			)
		} catch {
			let permitsOrdinaryBrowsing = BrowserProfileRetirementStore
				.permitsOrdinaryBrowsingAfterInitializationFailure(root: profileDirectory)
			guard permitsOrdinaryBrowsing else { throw error }
			retirementStore = nil
		}
		let intents = try retirementStore?.load() ?? []
		let acknowledged = Set(intents.filter(\.acknowledged).map(\.profileID))
		do {
			organization = try organization.excludingRetiredProfiles(acknowledged)
		} catch {
			throw ProfileRetirementLaunchError()
		}
		self.retirementStore = retirementStore
		self.profileRetirementConfiguration = retirementStore.map {
			.init(installationID: $0.installationID, legacyProfileID: legacyProfileID.rawValue)
		}
		let runtimeProfileDirectory = retirementStore?.rootDirectory ?? profileDirectory
		self.runtimeProfileDirectory = runtimeProfileDirectory

		guard
			let profile = organization.profiles.first,
			let space = organization.spaces.first(where: { space in
				!intents.contains(where: { $0.profileID == space.profileID })
			})
		else {
			if !intents.isEmpty { throw ProfileRetirementLaunchError() }
			throw BrowserLaunchError.invalidWorkspace
		}

		// DEV-1234: an attended launch opens to the empty page with every folder collapsed, unless
		// Settings turned that off. Before the document and the first window exist, so nothing shows
		// the saved selection first. A run given a page to open (headless runs, smokes) keeps it.
		if initialURL == nil {
			LaunchEmptyPage.apply(
				to: &organization,
				preferences: &recovery.preferences,
				mainWindowID: MainFeature.State.mainWindowID,
				mainSpaceID: space.id
			)
		}

		let engine = ChromiumBrowserEngine(
			runtime: runtime,
			profileID: organization.legacyProfileID ?? profile.id,
			enableAuthorizedClosing: true,
			enableUnhandledEscape: true,
			// Unattended pages get Chromium's default denial instead of a consent UI nobody sees.
			enableContentHosting: headless == nil,
			enableExtensionViews: true
		)
		self.engine = engine
		for intent in intents { engine.client.blockProfileRetirement(intent.profileID) }

		// Each tab's back/forward history, apart from the workspace file (DEV-878). A headless
		// run's disposable profile is deleted at exit, so only a persistent one keeps it.
		if headless == nil || headless?.configuration.profile != nil {
			engine.keepNavigationHistory(
				in: profileDirectory.appendingPathComponent("Navigation", isDirectory: true),
				keeping: Set(organization.tabs.map(\.id) + organization.archive.map(\.tab.id))
			)
		}

		// Protected video and music play in WebKit pages (DEV-877). Unattended runs keep their
		// pages in Chromium: nobody watches them and nothing fetches block lists.
		let webKitPages = WebKitPages(
			contentRules: headless == nil
			? WebKitContentRules(directory: profileDirectory.appendingPathComponent("WebKit Content Rules", isDirectory: true))
			: nil
		)
		webKitPages.dialogButtons = .init(
			ok: String.localized(.appUI.common.ok),
			cancel: String.localized(.appUI.common.cancel)
		)
		let pageRouter = PageEngineRouter(chromium: engine.client, chromiumSurface: engine.surface, pages: webKitPages)
		self.pageRouter = pageRouter
		let webKitContentBlocking = WebKitContentBlockingSites(client: engine.client)
		self.webKitContentBlocking = webKitContentBlocking

		let capabilities = BrowserCapabilities(
			isRunning: { runtime.state == .running },
			capture: engine.capture,
			media: { try engine.media() },
			extensions: { engine.extensions(ordinaryProfileExists: $0) },
			inspection: engine.inspection,
			interaction: engine.interaction,
			pageWait: engine.pageWait
		)
		self.capabilities = capabilities

		let downloadsFile = profileDirectory.appendingPathComponent("arx-downloads.json")
		self.downloadsFile = downloadsFile
		let downloads = engine.downloads(metadataFile: downloadsFile, organization: organization)
		self.downloads = downloads
		let siteIcons = engine.siteIcons(
			organization: organization,
			storeDirectory: profileDirectory.appendingPathComponent("Site Icons", isDirectory: true)
		)
		self.siteIcons = siteIcons

		// Saved hover card pictures (DEV-730), kept only for pages a tab still points at.
		let pagePreviews = BrowserPagePreviewClient.live(
			directory: profileDirectory.appendingPathComponent("Page Previews", isDirectory: true)
		)
		self.pagePreviews = pagePreviews
		let pagePreviewKeys = Self.pagePreviewKeys(organization)
		let pagePreviewProfiles = Set(organization.profiles.map(\.id))
		Task.detached(priority: .utility) {
			await pagePreviews.retain(pagePreviewKeys, pagePreviewProfiles)
		}
		let automationDigest = AutomationSecurity.digest(Data(profileDirectory.path.utf8)).prefix(12)
		let automationHost = BrowserAutomationHost(
			directory: URL(fileURLWithPath: "/tmp/arx-mcp-\(getuid())-\(automationDigest)")
		)
		self.automationHost = automationHost
		let authorization = AutomationAuthorization()
		let captureAuthorization = CaptureAuthorizationContext()
		let quitAuthorization = QuitAuthorizationContext()
		let tabMoveAuthorization = TabMoveAuthorizationContext()
		let retirementAuthorization = ProfileRetirementAuthorizationContext()

		// The run's single in-memory workspace. Installed before any state exists, because
		// shared preference keys resolve it when they're created.
		let document = WorkspaceDocument(
			client: workspace,
			organization: organization,
			preferences: recovery.preferences
		)

		// The built-in assistant's per-profile connections: the reducer fills them, and the
		// assistant reads them through `AgentBrowserAccess` when a turn starts.
		self.batterySaver = BatterySaverController(runtime: runtime, document: document)
		let agentConnections = EmbeddedAgentConnections()

		// iCloud sync, on the store's connections, only while the workspace really is in SQLite: a store
		// that couldn't open left the run on the JSON file. A headless run never syncs.
		let workspaceSync: WorkspaceSync? = if syncsWithICloud, headless == nil, let store = workspace.workspaceDatabase,
			let preferencesDatabase = store.preferencesDatabase
		{
			try? WorkspaceSync.make(
				isFeatureFlagOn: true,
				organization: store.database,
				preferences: preferencesDatabase,
				history: historyDatabase?.database,
				archive: store.archiveDatabase,
				directory: profileDirectory,
				// A merged profile's history moves through the store that holds it (DEV-1216).
				moveHistory: { merged, kept in
					await history.moveProfile(Profile.ID(rawValue: merged), Profile.ID(rawValue: kept))
				}
			)
		} else {
			nil
		}
		self.workspaceSync = workspaceSync
		let workspaceSyncClient: WorkspaceSyncClient = workspaceSync.map(WorkspaceSyncClient.live) ?? .unavailable
		prepareDependencies {
			$0.workspaceSync = workspaceSyncClient
			$0.workspaceDocument = document
			$0.embeddedAgentConnections = agentConnections
			$0.agentBrowserAccess = .embedded(agentConnections)
		}
		var initialState: AppFeature.State = .init(
			main: .init(
				organization: organization,
				spaceID: space.id
			),
			automation: recovery.preferences.automation,
			retirementIntents: intents
		)

		// DEV-884: Settings offers content blocking only when this engine can apply it.
		initialState.settings.contentBlockingAvailable = runtime.supportsContentBlocking

		// DEV-1020: dark pages, behind their feature flag and on engines that have them.
		initialState.settings.darkPagesAvailable = DarkPagesFeatureFlag.isEnabled(environment: environment)
			&& runtime.supportsDarkPages

		// DEV-1111: Links › Link Status, with the feature flag on.
		initialState.settings.linkStatusAvailable = LinkStatusFeatureFlag.isOn(environment: environment)

		// DEV-1170: Match site's browser default and profile override, with the feature flag on.
		initialState.settings.matchSiteAvailable = MatchSiteBackground.isEnabled(environment: environment)

		// DEV-1174: General › Tabs' two rows, with the value every window takes.
		initialState.settings.newTabsAtTopAvailable = NewTabsAtTopFeatureFlag.atLaunch

		// DEV-757: the device capture popover, with the feature flag on.
		initialState.deviceCaptureEnabled = DeviceCaptureFeatureFlag.isOn(environment: ProcessInfo.processInfo.environment)

		// DEV-1019: Hide Element, with the feature flag on.
		initialState.hideElementEnabled = HideElementFeatureFlag.isOn(environment: ProcessInfo.processInfo.environment)

		// DEV-1201: Arx's own element picker for it, with its feature flag on.
		initialState.elementPickerEnabled = ElementPickerFeatureFlag.isOn(environment: ProcessInfo.processInfo.environment)

		// DEV-1208: whole-page frames and Capture Area's scrolling, with the feature flag on.
		initialState.captureBeyondViewportEnabled = CaptureBeyondViewportFeatureFlag.isOn(
			environment: ProcessInfo.processInfo.environment
		)

		// DEV-1215: onboarding's Sync with iCloud, and the wait for iCloud it may leave behind.
		initialState.onboardingICloudEnabled = syncsWithICloud && OnboardingICloudFeatureFlag.isOn(environment: environment)

		// DEV-1210: store updates turned down for asking more permissions wait for review.
		initialState.settings.extensions.updateReviewsEnabled = ExtensionUpdateReviewFeatureFlag.isOn(
			environment: ProcessInfo.processInfo.environment
		)

		// DEV-996: Translation Available, with the feature flag on.
		initialState.translationFeatureFlag = PageTranslationFeatureFlag.isEnabled()

		// DEV-822: each window keeps its own open tabs, on unless the feature flag turns it off.
		initialState.setIndependentWindows(IndependentWindowsFeatureFlag.isOn())
		document.update(organization: initialState.workspace)
		localProfiles.setValue { [document] in
			document.organization.map(ProfileSync.init)
		}
		self.store = Store(initialState: initialState) {
			AppFeature()

			WorkspacePersistence(workspace: workspace)

			Pullback(\.delegate.exportWorkspace) { state, organization in
				let preferences = state.persistedPreferences
				return .run { _ in
					await MainActor.run {
						let panel = NSSavePanel()
						panel.nameFieldStringValue = "Arx workspace.json"
						guard panel.runModal() == .OK, let url = panel.url else { return }
						do {
							try workspace.export(organization, preferences: preferences, to: url)
						} catch {
							let alert = NSAlert()
							alert.messageText = WorkspaceFailurePresentation.message(for: error)
							alert.runModal()
						}
					}
				}
			}

			Pullback(\.delegate.browserDataExported) { _, outcome in
				let (title, detail) = outcome.message
				return .run { _ in
					await MainActor.run {
						let alert = NSAlert()
						alert.messageText = title
						alert.informativeText = detail
						alert.runModal()
					}
				}
			}

			Pullback(\.delegate.commandFailed) { _, message in
				if headless != nil {
					// Messages may name user content; protocol output carries only the code.
					HeadlessOutput.emit("diagnostic", ["code": "commandFailed"])
					return .none
				}
				return .run { _ in
					await MainActor.run {
						let alert = NSAlert()
						alert.messageText = message
						alert.runModal()
					}
				}
			}
		} withDependencies: {
			$0.workspaceDocument = document
			$0.workspaceSync = workspaceSyncClient
			$0.browserHistory = history

			// History search's page text, beside each profile's history (DEV-1068).
			$0.pageTextIndex = .local(directory: profileDirectory.appendingPathComponent("History"))

			// Settings rows in every window's command bar (DEV-1015).
			$0.commandBarSettingsRows = .settingsIndex(initialState.settings.featureFlags)
			$0.pageCaptureAuthorization = .init(authorize: { captureAuthorization.check($0, $1) })
			$0.browserEngine = pageRouter.client
			$0.pageEngines = pageRouter.pageEngines

			// Device requests (DEV-905); a headless run never listens, so the engine cancels them.
			$0.deviceChoosers = engine.deviceChoosers

			// Cast pickers (DEV-927); a headless run never listens, and its engine has no Media Router.
			$0.cast = engine.cast

			// The CRLSet and other security components the engine keeps updating (DEV-874).
			$0.browserEngine.securityComponents = {
				BrowserSecurityComponent.installed(in: runtimeProfileDirectory)
			}

			// Passwords and sign-ins move straight into a profile when the engine has
			// ABI46 (DEV-830); on an older engine the step falls back to CSV. A headless run
			// never reads them: nobody could answer the Keychain or Touch ID prompt (DEV-896).
			$0.credentialMigration = headless == nil
			? .live(writer: .browserEngine(engine.client))
			: .unattended
			$0.profileRetirementPersistence = .init(
				record: { intent in
					guard let retirementStore
					else { throw ProfileRetirementFailure.unavailable }
					try retirementStore.record(intent)
				},
				acknowledge: { request in
					guard let retirementStore
					else { throw ProfileRetirementFailure.unavailable }
					try retirementStore.acknowledge(request)
				},
				authorize: { retirementAuthorization.check($0) }
			)
			$0.browserDownloads = downloads
			$0.browserSiteIcons = siteIcons
			$0.browserPagePreviews = pagePreviews
			$0.browserCapture = capabilities.capture
			$0.browserPageInspection = capabilities.inspection
			$0.pageCaptureInspection = capabilities.captureInspection
			$0.browserPageWait = capabilities.pageWait
			$0.browserPageInteraction = capabilities.interaction
			$0.browserMedia = capabilities.media
			$0.browserExtensions = capabilities.extensions
			$0.browserSurface = pageRouter.surface
			$0.quitAuthorization = .init(check: { quitAuthorization.check($0) })
			$0.tabMoveAuthorization = .init(check: { tabMoveAuthorization.check($0, $1) })
			$0.automationControl = .init(
				start: { try await automationHost.enable() },
				stop: { await automationHost.stop() },
				respond: { automationHost.respond($0, result: $1) },
				revoke: { automationHost.revoke($0) },
				authorize: { authorization.check($0) },
				beginForm: { authorization.check($0) && automationHost.beginForm($0) },
				beginScroll: { authorization.check($0) && automationHost.beginScroll($0) },
				beginClick: { authorization.check($0) && automationHost.beginClick($0) },
				waitForUser: { automationHost.waitForUser($0, $1) },
				replyToAgentSetup: { reply, agent in
					try AgentSetup.write(reply, for: agent, home: FileManager.default.homeDirectoryForCurrentUser)
				}
			)
		}

		super.init()
		self.capabilities.store = self.store

		// Settings › General: fetch icons for tabs that haven't loaded (DEV-796). Later changes
		// reach the engine through AppFeature.
		siteIcons.setFetchesUnloadedIcons(store.settings.general.fetchesUnloadedSiteIcons)

		// Settings › General › Autofill (DEV-875); later changes reach the engine through AppFeature.
		engine.client.configureAutofill(store.settings.general)

		// Settings › General › Content blocking (DEV-884), before any profile shows a page, so
		// uBlock Origin never starts in a profile only to be turned off. Later changes reach the
		// engine through AppFeature.
		runtime.setContentBlocking(
			enabled: store.settings.general.blocksContent,
			blockCookieBanners: store.settings.general.blocksCookieBanners
		)
		retirementAuthorization.check = { [weak store] in store?.state.authorizesRetirement($0) ?? false }

		automationHost.configure(
			preferences: { [weak store] in store?.state.automationHostPreferences ?? .init() },
			receive: { [weak store] in store?.send(.automation(.event(.host($0)))) },
			authorizeResponse: { [weak store] request, result in
				guard let store else { return .denied }
				let snapshots = AppFeature.State.automationSnapshots(
					of: store.state.automationSnapshotTabIDs(for: request, result: result),
					reading: engine.client.snapshot
				)
				return store.state.automationResponseValidation(
					request,
					result: result,
					snapshots: snapshots,
					inspectionDocumentIsCurrent: capabilities.inspection.documentIsCurrent,
					waitSourceIsCurrent: capabilities.pageWait.sourceIsCurrent
				)
			},
			focusedTab: { [weak store] client in
				guard let store else { return nil }
				let snapshotPairs = store.state.automationSnapshotTabIDs.compactMap { id in
					engine.client.snapshot(id).map { (id, $0) }
				}
				return store.state.automationFocusedTab(
					for: client,
					snapshots: Dictionary(uniqueKeysWithValues: snapshotPairs)
				)
			},
			changes: { [weak store] client in
				guard let store else { return nil }
				return store.state.automationChanges(
					for: client,
					snapshots: { id in engine.client.snapshot(id) },
					dialog: { id in engine.client.pageDialog(id)?.kind }
				)
			}
		)
		authorization.check = { [weak store] requestID in
			guard
				let store,
				!store.profileRetirement.isBusy,
				let pending = store.state.automation.pending[requestID]
			else { return false }

			let snapshots = AppFeature.State.automationSnapshots(
				of: store.state.automationSnapshotTabIDs(for: pending.request),
				reading: engine.client.snapshot
			)
			return store.state.automationCanExecute(requestID, snapshots: snapshots, now: Date())
		}

		captureAuthorization.check = { [weak store] id, request in
			store?.state.captureCanExecute(
				id,
				request: request,
				snapshot: engine.client.snapshot(request.tabID)
			) ?? false
		}

		quitAuthorization.check = { [weak store] ids in
			store?.state.canCommitQuit(approvedTabs: ids) ?? false
		}
		tabMoveAuthorization.check = { [weak store] id, sources in
			store?.state.canCommitTabMove(windowID: id, sourceIDs: sources) ?? false
		}

		self.incomingURLHandler = IncomingURLHandler { [weak self] url in
			guard let self else { return }
			#if DEBUG
			self.routingSmoke?.received(url)
			self.littleArxSpaceSmoke?.received(url)
			#endif
			// arx://open, arx://little and arx://space drive Arx from other apps (DEV-929), and
			// arx://settings/… opens Settings at its place (DEV-1193); Arx's other arx:// pages
			// never open from outside. A headless run takes none.
			let scheme = url.scheme?.lowercased()
			if scheme == "arx" {
				guard self.headless == nil else { return }
				if let command = ArxURLCommand(url) {
					self.store.send(.ui(.arxURLCommand(command)))
				} else {
					self.store.send(.browserLinks(.outsideLink(url)))
				}
				return
			}

			// arc:// links from other apps (DEV-1193).
			if scheme == "arc" {
				if self.headless == nil { self.store.send(.browserLinks(.outsideLink(url))) }
				return
			}
			self.store.send(.ui(.routeURLs([url])))
		}

		// The Shortcuts app's actions and AppleScript reach this store (DEV-929, DEV-909); a
		// headless run refuses them.
		if headless == nil {
			AppIntentsBridge.connect(store)
			AppleScriptBridge.connect(store, engine: engine.client) { [engine] id in
				engine.client.snapshot(id)?.navigation.url
			}
		}

		engine.onExtensionOptionsRevoked = { [weak store] offer in
			store?.send(.event(.extensionOptionsRevoked(offer)))
		}
		engine.onExtensionOptionsSettled = { [weak store] offer in
			store?.send(.event(.extensionOptionsSettled(offer)))
		}
		engine.onExtensionView = { [weak store] offer in
			guard let store else { return false }

			store.send(.event(.extensionViewCreated(offer)))

			// The page is taken once a Little Arx shows it (DEV-1185).
			return store.littleWindows.contains { $0.tab == offer.tab }
		}

		engine.onLinkForceClick = { [weak store, engine] click in
			guard let store else { return false }
			return store.state.takeLinkForceClick(click, engine: engine.client) { store.send($0) }
		}

		// The page menu's choices run as the same commands as the menu bar's, for that tab, and
		// it offers only what those commands allow there now (DEV-795).
		engine.onPageMenuChoice = { [weak store] tabID, item in
			store?.send(.ui(.pageMenu(tabID, Self.command(for: item))))
		}
		engine.pageMenuItems = { [weak store] tabID in
			guard let store else { return [] }
			let commands = store.state.pageMenuCommands(showing: tabID)
			return Set(ChromiumPageMenuItem.allCases.filter { commands.contains(Self.command(for: $0)) })
		}

		// Context menus on text fields, selections, images and media (DEV-814): the engine
		// carries out most items; these go to the host showing the tab, re-resolved on choice.
		engine.onContextMenuChoice = { [weak store] tabID, choice in
			guard let action = Self.action(for: choice) else { return }
			store?.send(.ui(.pageContextMenu(tabID, action)))
		}
		engine.contextMenuItems = { [weak store] tabID in
			guard
				let store,
				let host = store.state.pageContextHost(showing: tabID)
			else { return [] }

			return Self.contextMenuItems(host.actions)
		}

		// WebKit pages (DEV-877): the site list, a site's Chromium cookies, Chromium's protected
		// media requests and WebKit's popups.
		let showsWebKitPages = headless == nil
		pageRouter.preferences = { [weak self, document] in
			guard showsWebKitPages else { return .init(isEnabled: false) }

			// FairPlay sites stay in Chromium while the bridge plays them and Settings prefers
			// FairPlay in the tab (DEV-1144).
			let pages = document.preferences.webKitPages
			return pages.keepingInChromium(pages.bridgedOrigins(self?.fairPlayOrigins ?? []))
		}
		pageRouter.siteCookies = { [engine] profile, tab, url in
			await engine.siteCookies(profile: profile, tab: tab, url: url)
		}
		pageRouter.onNewTab = { [weak store] source, url, isPageRequest in
			store?.send(.webKitPages(.openNewTab(source: source, url, isPageRequest: isPageRequest)))
		}

		// A WebKit page's right click shows Arx's page menu (DEV-1199): the page menu's commands
		// the host showing the tab allows now, carried out as the Chromium page menu's are.
		webKitPages.pageMenu = .init(
			commands: { [weak store] tabID in
				guard let store else { return [] }
				return store.state.pageMenuCommands(showing: tabID)
			},
			title: { $0.title },
			exitFullScreenTitle: String.localized(.appUI.contextMenu.exitFullScreen),
			choose: { [weak store] tabID, command in
				store?.send(.ui(.pageMenu(tabID, command)))
			}
		)
		if showsWebKitPages { startFairPlay(document: document) }

		// The Widevine answer is the engine's, read at launch from Arx's defaults (DEV-1144).
		Self.storeWidevineAnswer(document.preferences.webKitPages.answersWidevine)
		_ = document.observe(origin: nil) { old, new in
			let isOn = new.preferences.webKitPages.answersWidevine
			guard old.preferences.webKitPages.answersWidevine != isOn else { return }
			Self.storeWidevineAnswer(isOn)
		}

		// A headless run never offers WebKit: nobody could answer the prompt.
		if showsWebKitPages {
			engine.onProtectedMedia = { [weak pageRouter] request in
				pageRouter?.protectedMediaRequested(request)
			}
		}

		// DEV-1293: a swipe on a Chromium page toward the tab's WebKit page.
		engine.onSharedHistorySwipe = { [weak pageRouter] id, forward in
			pageRouter?.sharedHistorySwiped(id, forward: forward)
		}
		webKitPages.contentRules?.settings = { [document] in
			.init(
				isEnabled: document.preferences.blocksContent,
				blocksCookieBanners: document.preferences.blocksCookieBanners
			)
		}
		webKitPages.contentRules?.blocksContent = { [weak webKitContentBlocking] profile, url in
			webKitContentBlocking?.blocksContent(profile, url) ?? true
		}
		webKitContentBlocking.onChange = { [weak webKitPages] in webKitPages?.contentRules?.reapply() }

		// Content blocking's switches reach open WebKit pages at once, as they reach uBlock. The
		// observation lasts as long as the run.
		_ = document.observe(origin: nil) { [weak webKitPages] old, new in
			let changed = old.preferences.blocksContent != new.preferences.blocksContent
			|| old.preferences.blocksCookieBanners != new.preferences.blocksCookieBanners
			guard changed else { return }
			Task { @MainActor [weak webKitPages] in webKitPages?.contentRules?.reapply() }
		}

		// A headless run applies Battery Saver too, and says nothing.
		if showsWebKitPages {
			batterySaver.onActiveChange = { [weak store] isActive in
				store?.send(.batterySaver(.changed(isActive: isActive)))
			}
		}
		webKitContentBlocking.start()

		engine.onCrossSiteLink = { [weak store, weak pageRouter, engine] link in

			// A followed link to a listed site moves the page to WebKit.
			if let pageRouter, showsWebKitPages, pageRouter.preferences().opensInWebKit(link.url) {
				Task { await pageRouter.move(link.sourceTabID, to: .webKit, url: link.url) }
				return true
			}
			guard
				let store,
				let action = store.state.crossSiteLinkAction(for: link, engine: engine.client)
			else { return false }

			store.send(action)
			return true
		}

		// A page's link for another app (DEV-857): Arx's prompt replaces Chrome's dialog, with a
		// handler in Air Traffic Control or, when none matches, with the app macOS assigns to the
		// scheme (DEV-1259). Only a link no app on this Mac opens stays with Chrome, which then
		// neither asks nor opens anything.
		engine.onExternalLink = { [weak store, weak self] link in

			// The member number's sign-in window (DEV-1323): Arx's server's redirect to the sign-in
			// scheme is Apple's answer, taken here with no prompt. Nothing else from that window
			// opens another app, and no other window can deliver the scheme.
			if let decision = store?.state.memberSignInLink(link) {
				if case let .answer(url) = decision { store?.send(.memberSignIn(.answered(url))) }
				return true
			}

			// A page's arx:// link asks first (DEV-929). Arx takes every one, so Chrome never
			// hands it to macOS, which would open it as if another app had; headless drops them.
			if link.link.lowercased().hasPrefix("arx:") {
				if self?.headless == nil { store?.send(.event(.arxLinkFromPage(link))) }
				return true
			}

			// A page's arc:// or chrome:// link (DEV-1193). Chromium doesn't know arc://, so it
			// arrives here like any app's link. Blink refuses chrome://, and engines with the
			// DEV-1193 hook offer it here too. Arx opens its place for either, hands it to Arc,
			// or puts a chrome:// link to App Links' built-in handler for Chrome's pages.
			if
				FeatureFlag.browserLinks.isOn(),
				link.hasUserGesture,
				let scheme = URL(string: link.link)?.scheme?.lowercased(),
				BrowserSchemeLink.Browser(rawValue: scheme) != nil
			{
				if self?.headless == nil { store?.send(.browserLinks(.pageLink(link))) }
				return true
			}

			@Dependency(\.appLinks)
			var appLinks

			guard
				let store,
				let presentation = store.state.appLinkPresentation(
					for: link,
					hasSystemApp: URL(string: link.link).flatMap(appLinks.appPath) != nil
				)
			else { return false }

			store.send(.presentAppLink(presentation))
			return true
		}

		engine.onPageCloseRequest = { [weak store] tabID in
			store?.send(.event(.pageCloseRequested(tabID)))
		}

		engine.onUnreadBadge = { [weak store] tabID, badge in
			store?.send(.event(.unreadBadgeChanged(tabID, badge)))
		}
		engine.onPageSettled = { [weak store] tabID, navigation in
			store?.send(.event(.pageSettled(tabID, navigation)))
		}
		engine.onPageFullScreen = { [weak store] tabID, isFullScreen in
			store?.send(.event(.pageFullScreenChanged(tabID, isFullScreen)))
		}
		engine.onPagePermissionPrompt = { [weak store] tabID, token in
			store?.send(.event(.pagePermissionPromptChanged(tabID, token)))
		}

		// Web notifications (DEV-885): a click shows the site's tab, the one its service worker
		// opened, or the site's newest tab in that profile.
		engine.onPageActivationRequest = { [weak store] tabID in
			store?.send(.event(.pageActivationRequested(tabID)))
		}
		engine.onNotificationWindow = { [weak store] tab in
			guard let store else { return false }

			store.send(.event(.notificationWindowOpened(tab)))
			return store.workspace.tabs.contains(tab)
		}
		engine.onNotificationClick = { [weak store] click in
			store?.send(.event(.notificationClicked(click)))
		}

		engine.onNewContents = { [weak store, engine] offer in
			guard let store else { return false }

			// Declining means Chromium's page is never loaded, so the link opens once.
			if let action = store.state.linkClickAction(
				for: offer,
				modifiers: NSEvent.modifierFlags,
				pointer: NSApp.currentEvent.linkActivationPointer,
				engine: engine.client
			) {
				#if DEBUG
				SmokeDiagnostics.noteNewContentsRoute(.app, engine: engine)
				#endif
				store.send(action)
				return false
			}

			#if DEBUG
			SmokeDiagnostics.noteNewContentsRoute(.chromium, engine: engine)
			#endif
			let held = NSEvent.modifierFlags.intersection([.shift, .option, .command, .control])
			store.send(.event(.browserNewContents(
				offer,
				shiftHeld: held.contains(.shift),
				modified: !held.isEmpty,
				origin: NSApp.currentEvent.linkActivationPointer
			)))
			if offer.isPrivate {
				return store.windows.contains { host in
					host.isPrivate && host.sidebar.organization.tabs.contains(offer.tab)
				}
			}

			// A Little Arx's new tab or popup goes into a new Little Arx (DEV-855), and a Favorite's
			// new tab may go to Peek (DEV-1312).
			return store.workspace.tabs.contains(offer.tab)
			|| store.littleWindows.contains { $0.tab == offer.tab }
			|| store.peeks.contains { $0.isTemporary && $0.tab == offer.tab }
		}

		if recovery.usedBackup {
			let message = [
				String.localized(.appUI.persistence.recovered),
				String.localized(.appUI.persistence.recoveredGrants),
			].joined(separator: " ")
			self.store.send(.event(.saveFailed(message)))
		}

		// Last, once the store listens for its changes. Reads no account and makes no engine unless
		// the person turned sync on before.
		if let workspaceSync {
			Task { await workspaceSync.launch() }
		}
	}

	internal func open() {
		// No Dock icon, menu bar or activation for an unattended run.
		if headless != nil { NSApplication.shared.setActivationPolicy(.accessory) }
		#if DEBUG
		if environment["ARX_SITE_ICONS_RESTART"] != nil {
			startSiteIconRestartSmoke()
			return
		}
		if let phase = environment["ARX_DOWNLOAD_RESUME_SMOKE"] {
			startDownloadResumeSmoke(phase)
			return
		}
		#endif

		// The chosen app icon, not a cached engine-host icon (DEV-839).
		applyAppIcon()

		capabilities.activate()
		let linkContextMenu = LinkContextMenu(
			store: store,
			client: engine.client,
			view: { [weak engine] in engine?.linkContextView($0) }
		)
		self.linkContextMenu = linkContextMenu
		linkContextMenu.start()

		// Unattended runs have nobody to choose a suggestion.
		if headless == nil {
			let autofillDropdown = AutofillDropdown(
				store: store,
				client: engine.client,
				view: { [weak engine] in engine?.autofillView($0) }
			)
			self.autofillDropdown = autofillDropdown
			autofillDropdown.start()
		}

		// Where a hovered link goes (DEV-1111), behind its feature flag; headless runs show nothing.
		if headless == nil, store.settings.linkStatusAvailable {
			let linkStatus = LinkStatusPresenter(
				store: store,
				view: { [weak engine] in engine?.linkStatusView($0) },
				opensInWebKit: { [weak store] url in
					store?.settings.webKitPages.opensInWebKit(url) ?? false
				}
			)
			self.linkStatus = linkStatus
			engine.onLinkHover = { [weak linkStatus] tabID, link in
				linkStatus?.receive(tabID, link)
			}

			// Each report runs a script in the page's frames, so pages report only while the
			// status shows.
			linkStatusObservation = observe { [weak self, weak store] in
				guard let self, let store else { return }
				self.engine.setLinkHoverReports(store.settings.linkClicks.showsLinkStatus)

				// A link remembered from before is stale: the engine reported nothing while off.
				self.linkStatus?.stop()
			}
		}
		BrowserCommands.install(
			store: store,
			siteIcons: siteIcons,
			pageURL: { ($0 as? ChromiumPage)?.navigation.url }
		) { [weak runtime] view in
			runtime?.page(containing: view)
		}

		// An engine that reports every key Arx can bind lets shortcuts without ⌘ reach a page first
		// (DEV-1332); an older one keeps them Arx's.
		store.send(.settings(.event(.followsAllShortcutKeys(runtime.followsAllShortcutKeys))))

		// ABI62 (DEV-1264, DEV-1073): whether a page used a key Arx let through to it.
		runtime.onCommandKey = { _, key, consumed in
			BrowserCommands.receivePageKey(
				.init(keyCode: key.keyCode, modifierFlags: key.modifierFlags, timestamp: key.timestamp),
				consumed: consumed
			)
		}

		// Handoff from another device opens in the current space; headless runs take none (DEV-922).
		if headless == nil, let delegate = NSApplication.shared.delegate {
			HandoffContinuation.install(on: delegate) { [weak store] url in
				store?.send(.ui(.routeURLs([url], override: .init(scope: .currentSpace, mode: .mainBrowser))))
			}
		}
		store.send(.observeWorkspaceDocument)
		store.send(.recordInstallDate)
		store.send(.memberSignIn(.observe))
		store.send(.configureCapture)
		store.send(.profileRetirement(.refresh))
		store.send(.configureMedia)
		store.send(.automation(.ui(.observePasswordSaves)))
		store.send(.observeWebstoreInstalls)
		store.send(.webKitPages(.observe))
		batterySaver.start()

		// Nobody answers a device chooser in a headless run: the engine cancels them at once.
		if headless == nil { store.send(.deviceChoosers(.observe)) }

		// Nobody picks a Cast device in a headless run: a site's Cast button fails at once.
		if headless == nil { store.send(.cast(.observe(menuTitle: BrowserCommand.castTab.title))) }
		store.send(.settings(.configureExtensions(Array(store.workspace.profiles))))

		// Chromium's AppController would restore a Chrome window against Arx's menu.
		// Own only the Dock reopen event; retain Chromium's application delegate.
		NSAppleEventManager.shared().setEventHandler(
			self,
			andSelector: #selector(handleReopen(_:withReplyEvent:)),
			forEventClass: AEEventClass(kCoreEventClass),
			andEventID: AEEventID(kAEReopenApplication)
		)
		NSAppleEventManager.shared().setEventHandler(
			self,
			andSelector: #selector(handleQuit(_:withReplyEvent:)),
			forEventClass: AEEventClass(kCoreEventClass),
			andEventID: AEEventID(kAEQuitApplication)
		)
		incomingURLHandler?.install()

		// DEV-987: whatever AppKit hands Chromium's delegate to open reaches Arx's routing,
		// never a Chromium browser window.
		if let delegate = NSApplication.shared.delegate {
			IncomingURLHandler.routeDelegateOpenURLs(on: delegate)
		}

		// Before the first render, so a first launch's main window never flashes behind
		// onboarding (DEV-838).
		let presentsOnboarding: Bool = OnboardingLaunchPolicy.presentsAutomatically(
			environment: environment,
			isHeadless: headless != nil
		)
		if presentsOnboarding { store.send(.presentOnboardingIfNeeded) }
		observation = observe { [weak self] in self?.render() }

		// Titles follow navigation and placements follow tab order; observing them separately
		// keeps page loads from re-running every window's lifecycle rendering.
		titleObservation = observe { [weak self] in
			self?.updateWindowTitles()
			self?.updateHandoff()
			self?.presentArxLinkConfirmation()
		}
		placementObservation = observe { [weak self] in self?.updateExtensionTabPlacements() }
		darkPagesObservation = observe { [weak self] in self?.applyDarkPages() }

		// With the theme following the system, the system's appearance decides too.
		appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
			MainActor.assumeIsolated { self?.applyDarkPages() }
		}
		store.send(.event(.downloadsReady))

		// Only the profiles windows show load now; the rest when first needed (DEV-880).
		store.send(.startProfileRelease(.configured(environment: environment)))

		// Unattended runs have no pointer or person to ask; Ask uses Incoming Links there.
		if headless == nil { store.send(.profilePicker(.event(.hostAvailable))) }
		store.send(.event(.routingReady))
		store.send(.loadBangs)
		store.send(.chat(.launched))
		if store.automationPreferences.isEnabled {
			store.send(.automation(.ui(.enabled(true))))
		}
		if headless == nil, environment["ARX_ENGINE_PROFILE"] == nil { observeAgentSetup() }
		store.send(.main(.ui(.task)))
		store.send(.startTabArchiving)

		// Unattended runs are short and their agents' pages must stay as they left them.
		if headless == nil { store.send(.startTabUnloading) }

		// Unattended runs are short: their agents' tabs stay for whoever reads their results.
		if headless == nil { store.send(.startAgentTabs) }

		// Sparkle only runs in a configured, signed release build; elsewhere this reports why not.
		if headless == nil { store.send(.settings(.ui(.startUpdates))) }

		// Keeps crash reports of earlier runs; sends them only if the person shares them (DEV-887).
		if headless == nil, environment["ARX_ENGINE_PROFILE"] == nil { store.send(.settings(.ui(.startDiagnostics))) }
		if presentsOnboarding { observeActivation() }
		observeMediaActivity()

		// Headless runs have no Little Arx and nobody switching Spaces.
		if headless == nil { observeDesktopSpaces() }
		if environment["ARX_ENGINE_SMOKE_TITLE"] != nil { checkSmokeReadiness(remaining: 300) }
		startHeadlessRun()
		if headless == nil, BenchmarkDriver.isRequested(environment: environment) {
			BenchmarkDriver.start { [weak self] in self?.window }
		}
		#if DEBUG
		startDeveloperToolsSmoke()
		startLocalFailureSmoke()
		startProfileReleaseSmoke()
		startTabUnloadSmoke()
		startSignInSmoke()
		startRoutingSmoke()
		startLittleArxSpaceSmoke()
		startNotificationSmoke()
		startHandCheckSmoke()
		startRetirementSmoke()
		startExtensionSettingsSmoke()
		startPagePopupDemo()
		#endif
	}

	internal func stopCapabilities() {
		linkContextMenu?.stop()
		linkContextMenu = nil
		autofillDropdown?.stop()
		autofillDropdown = nil
		linkStatusObservation = nil
		engine.setLinkHoverReports(false)
		engine.onLinkHover = nil
		linkStatus?.finish()
		linkStatus = nil
		capabilities.stop()
		incomingURLHandler?.stop()
		batterySaver.stop()
	}

	// MARK: - Apple events

	@objc
	private func handleReopen(
		_ event: NSAppleEventDescriptor,
		withReplyEvent reply: NSAppleEventDescriptor
	) {
		guard !store.shouldQuit else { return }
		reopenCount += 1

		// Launch onboarding holds the main window back: bring onboarding forward instead (DEV-838).
		if store.mainWindowWaitsForOnboarding, let onboardingWindow {
			onboardingWindow.makeKeyAndOrderFront(nil)
			NSApplication.shared.activate(ignoringOtherApps: true)
			return
		}
		if !store.windowIsOpen { store.send(.ui(.openWindow)) }

		// Store observation is scheduled; materialize a closed window before focusing it.
		render()
		if window?.isMiniaturized == true { window?.deminiaturize(nil) }
		window?.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate(ignoringOtherApps: true)
	}

	@objc
	private func handleQuit(
		_ event: NSAppleEventDescriptor,
		withReplyEvent reply: NSAppleEventDescriptor
	) {
		store.send(.ui(.quit))
	}

	// MARK: - Rendering

	/// Settings › Appearance & Sound's theme, for every Arx window.
	/// Settings › Appearance's app icon, in the Dock while Arx runs (DEV-839). Arx Dev keeps its
	/// own icon, so it's never mistaken for the installed Arx (DEV-1013).
	private func applyAppIcon() {
		let icon = store.settings.general.appIcon
		guard
			headless == nil,
			!ArxEdition.current.isDevelopment,
			appliedAppIcon != icon,
			let image = icon.image
		else { return }

		appliedAppIcon = icon
		NSApplication.shared.applicationIconImage = image
		NSApplication.shared.dockTile.display()
	}

	/// DEV-1020: what the engine darkens. The engine ignores a configuration it already has.
	private func applyDarkPages() {
		guard store.settings.darkPagesAvailable else { return }

		// Only what decides it is read, so the observation follows only those.
		let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		engine.client.setDarkPages(
			.init(
				mode: store.settings.general.darkPages,
				appearanceIsDark: isDark,
				profiles: store.workspace.profiles
			)
		)
	}

	private func applyAppTheme() {
		let appearance: NSAppearance? = switch store.settings.general.appTheme {
		case .system: nil
		case .light: NSAppearance(named: .aqua)
		case .dark: NSAppearance(named: .darkAqua)
		}
		guard NSApp.appearance?.name != appearance?.name else { return }
		NSApp.appearance = appearance
	}

	internal func render() {
		if store.shouldQuit {
			guard !isQuitting else { return }
			isQuitting = true
			capabilities.stop()
			let chatProfiles = store.workspace.profiles.map(\.id)

			Task { [self] in
				await history.flush()

				// Ephemeral chats end with the browser, including what their provider kept.
				await AgentChatLifecycle.sweep(chatProfiles)
				await automationHost.stop()
				engine.closeAll()
				runtime.requestQuit()
			}
			return
		}

		if store.windowIsOpen, window == nil { createWindow() }
		if headless != nil { fitHeadlessViewport() }
		if !store.windowIsOpen, let closed = window {
			forgetWindowGeometry(store.main.id, window: closed)
			window = nil
			closed.delegate = nil
			closed.contentView = nil
			closed.close()
		}

		let windowNumbers = nativeWindowNumbers
		applyAppTheme()
		applyAppIcon()
		configureDeveloperTools()
		configurePagePrompts()
		configureExtensionPopupWindows()
		renderLittleArxWindows()
		renderExtensionPopups()
		renderSettingsWindow()
		renderOnboardingWindow()
		renderDownloadsWindow()
		renderTaskManagerWindow()
		renderAdditionalWindows()

		// A headless run has no screen to fill and shows no floating windows.
		if headless == nil {
			renderPageFullScreen()
			renderPagePictureInPicture()
		}
		focusRequestedWindow()

		// After focus, so the next link's picker keeps the keyboard when the link before it
		// opens a Little Arx in the same update.
		renderProfilePicker()

		// A window created or closed here needs its title and placement now; their own
		// observations only re-run when the values they read change.
		if nativeWindowNumbers != windowNumbers {
			updateWindowTitles()
			updateExtensionTabPlacements()
		}
	}

	private var nativeWindowNumbers: Set<Int> {
		var numbers: Set<Int> = Set(additionalWindows.values.map(\.windowNumber))
		numbers.formUnion(littleWindows.values.map(\.windowNumber))
		if let window { numbers.insert(window.windowNumber) }
		return numbers
	}

	/// Arx windows and their visible spaces as extension windows (ABI22).
	private func updateExtensionTabPlacements() {
		func placementWindow(
			_ host: MainFeature.State,
			number: Int?
		) -> ExtensionTabPlacements.Window? {
			guard let number else { return nil }

			return .init(
				number: number,
				spaceID: host.sidebar.spaceID,
				isPrivate: host.isPrivate,
				openTabFilter: host.sidebar.openTabFilter,
				shown: host.viewer.panes.compactMap(\.item.tab?.id),
				active: host.viewer.item.tab?.id
			)
		}

		var windows = [placementWindow(store.main, number: window?.windowNumber)]
		windows += store.windows.map { placementWindow($0, number: additionalWindows[$0.id]?.windowNumber) }
		windows += store.littleWindows.map { little in
			littleWindows[little.id].map { panel in
				.init(
					number: panel.windowNumber,
					spaceID: nil,
					shown: little.isCommandOnly ? [] : [little.tab.id],
					active: little.isCommandOnly ? nil : little.tab.id
				)
			}
		}
		let placements = ExtensionTabPlacements.plan(windows.compactMap(\.self), organization: store.workspace)
		let changes = ExtensionTabPlacements.changes(from: extensionTabPlacements, to: placements)
		guard !changes.isEmpty else { return }

		extensionTabPlacements = placements
		engine.updateExtensionTabPlacements(changes.mapValues { placement in
			placement.map {
				ChromiumExtensionTabPlacement(
					windowNumber: $0.windowNumber,
					index: $0.index,
					isActive: $0.isActive,
					isHighlighted: $0.isHighlighted
				)
			}
		})
	}

	/// Native Inspect Element follows the app-wide preference; open inspectors stay
	/// attached to their pages when it is turned off and close with them.
	private func configureDeveloperTools() {
		let isEnabled = store.settings.general.developerModeEnabled

		// WebKit pages' Inspect Element is Safari's Web Inspector (DEV-1199).
		pageRouter.pages.isInspectable = isEnabled
		guard developerModeConfiguration != isEnabled, runtime.state == .running else { return }
		developerModeConfiguration = isEnabled
		engine.configureDeveloperTools(
			windowTitle: String.localized(.appUI.developer.windowTitle),
			inspectTitle: String.localized(.appUI.developer.inspectElement),
			isEnabled: isEnabled
		)
		engine.configurePageMenu(titles: [
			.back: BrowserCommand.goBack.title,
			.forward: BrowserCommand.goForward.title,
			.reload: BrowserCommand.reload.title,
			.saveAs: BrowserCommand.savePageAs.title,
			.print: BrowserCommand.printPage.title,
			.viewSource: BrowserCommand.viewSource.title,
			.share: BrowserCommand.sharePage.title,
		])
		engine.configureContextMenus(titles: Self.contextMenuTitles)
	}

	/// With the `ARX_PAGE_PROMPTS` feature flag on, the engine hands ordinary site permission
	/// prompts to the app (DEV-963), once it runs. A headless run has no window for them and keeps
	/// the engine's own handling, as does the flag off.
	private func configurePagePrompts() {
		guard !pagePromptsConfigured, runtime.state == .running else { return }

		pagePromptsConfigured = true
		guard headless == nil, PagePrompts.isEnabled(environment: environment) else { return }

		_ = engine.client.setPagePromptsHosted(true)
	}

	/// Extensions' action popups open in Arx's own small window, as Settings' sheets look (DEV-1316).
	/// A headless run has no screen for them and keeps the engine's window.
	private func configureExtensionPopupWindows() {
		guard !extensionPopupWindowsConfigured, headless == nil else { return }

		extensionPopupWindowsConfigured = true
		_ = engine.client.setExtensionPopupWindows(ExtensionPopupPanel.windows)
	}

	/// An extension's popup floats above the window it was opened from, but steps aside while
	/// that window shows its command bar, so it never covers it (DEV-1316).
	private func renderExtensionPopups() {
		var covered: Set<Int> = []
		if let window, store.main.commandBar.isPresented { covered.insert(window.windowNumber) }
		for host in store.windows where host.commandBar.isPresented {
			if let window = additionalWindows[host.id] { covered.insert(window.windowNumber) }
		}
		for little in store.littleWindows where little.commandBar.isPresented {
			if let window = littleWindows[little.id] { covered.insert(window.windowNumber) }
		}
		for case let popup as ExtensionPopupPanel in NSApplication.shared.windows {
			let aside = popup.parent.map { covered.contains($0.windowNumber) } ?? false
			if popup.stepsAside != aside { popup.stepsAside = aside }
		}
	}

	// MARK: - Auxiliary windows

	private func renderDownloadsWindow() {
		if store.downloads.isPresented, downloadsWindow == nil {
			let window = NSWindow(
				contentRect: .init(x: 0, y: 0, width: 720, height: 500),
				styleMask: [.titled, .closable, .resizable],
				backing: .buffered,
				defer: false
			)
			downloadsWindow = window
			window.identifier = .init("downloads")
			window.title = String.localized(.appUI.downloads.title)
			window.delegate = self
			window.isReleasedWhenClosed = false
			let downloadsStore = store.scope(state: \.downloads, action: \.downloads)
			window.contentView = NSHostingView(rootView: DownloadsView(store: downloadsStore))
			window.center()
			window.makeKeyAndOrderFront(nil)
		}
		if store.downloads.isPresented, downloadsFocusRequest != store.downloadsFocusRequest {
			downloadsFocusRequest = store.downloadsFocusRequest
			downloadsWindow?.makeKeyAndOrderFront(nil)
		}
		if !store.downloads.isPresented, let closed = downloadsWindow {
			downloadsWindow = nil
			closed.delegate = nil
			closed.contentView = nil
			closed.close()
		}
	}

	/// Window ▸ Task Manager (DEV-898).
	private func renderTaskManagerWindow() {
		let taskManager = store.taskManager
		if taskManager.isPresented, taskManagerWindow == nil {
			let window = NSWindow(
				contentRect: .init(x: 0, y: 0, width: 640, height: 420),
				styleMask: [.titled, .closable, .resizable, .miniaturizable],
				backing: .buffered,
				defer: false
			)
			taskManagerWindow = window
			window.identifier = .init("task-manager")
			window.title = String.localized(.appUI.taskManager.title)
			window.delegate = self
			window.isReleasedWhenClosed = false
			let appStore = store
			window.contentView = NSHostingView(rootView: TaskManagerView(
				store: store.scope(state: \.taskManager, action: \.taskManager),
				title: { appStore.state.taskManagerTitle(for: $0) }
			))
			window.center()
			window.makeKeyAndOrderFront(nil)
			taskManagerFocusRequest = taskManager.focusRequest
		}
		if taskManager.isPresented, taskManagerFocusRequest != taskManager.focusRequest {
			taskManagerFocusRequest = taskManager.focusRequest
			taskManagerWindow?.makeKeyAndOrderFront(nil)
		}
		if !taskManager.isPresented, let closed = taskManagerWindow {
			taskManagerWindow = nil
			closed.delegate = nil
			closed.contentView = nil
			closed.close()
		}
	}

	private func renderSettingsWindow() {
		if store.settingsIsOpen, settingsWindow == nil {
			let window = NSWindow(
				contentRect: .init(
					x: 0,
					y: 0,
					width: SettingsWindowSize.width,
					height: SettingsWindowSize.height
				),
				styleMask: [.titled, .closable, .fullSizeContentView],
				backing: .buffered,
				defer: false
			)
			settingsWindow = window
			window.identifier = .init("settings")
			window.title = store.settings.category.title
			window.titleVisibility = .hidden
			window.titlebarAppearsTransparent = true
			window.delegate = self
			window.isReleasedWhenClosed = false
			window.contentView = NSHostingView(rootView: AppSettingsView(store: store))
			window.center()
			window.makeKeyAndOrderFront(nil)
		}

		if let settingsWindow {
			settingsWindow.title = store.settings.category.title
		}

		if store.settingsIsOpen, settingsFocusRequest != store.settingsFocusRequest {
			settingsFocusRequest = store.settingsFocusRequest
			settingsWindow?.makeKeyAndOrderFront(nil)
		}

		if !store.settingsIsOpen, let settings = settingsWindow {
			settingsWindow = nil
			settings.delegate = nil
			settings.close()
		}
	}

	/// Re-reads state mirrored from the system, such as the default browser, when Arx comes back
	/// to the front. Automated runs never install it, so they never reach those clients.
	private func observeActivation() {
		activationObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				_ = self?.store.send(.event(.applicationBecameActive))
			}
		}
	}

	/// Tells AppFeature which Little Arx windows are on another macOS desktop Space whenever
	/// the active one changes, so it never brings one of them forward on its own (DEV-931).
	private func observeDesktopSpaces() {
		desktopSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.activeSpaceDidChangeNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.reportLittleWindowsElsewhere()
				self?.reportWindowsOnDisplay()
			}
		}

		// Any of these can take a window off the display or put it back: a window ordered in or
		// out, minimised or restored, Arx hidden or shown, or going in or out of full screen,
		// which decides whether its OS workspace counts (DEV-1322).
		let changes: [(NotificationCenter, Notification.Name)] = [
			(.default, NSWindow.didChangeOcclusionStateNotification),
			(.default, NSWindow.didMiniaturizeNotification),
			(.default, NSWindow.didDeminiaturizeNotification),
			(.default, NSWindow.didEnterFullScreenNotification),
			(.default, NSWindow.didExitFullScreenNotification),
			(.default, NSApplication.didHideNotification),
			(.default, NSApplication.didUnhideNotification),
		]
		windowsOnDisplayObservers = changes.map { center, name in
			center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.reportWindowsOnDisplay() }
			}
		}
		reportWindowsOnDisplay()
	}

	/// Tells AppFeature which browser and Little Arx windows are on the display, so automatic
	/// Picture in Picture floats a video only when its window is minimised, hidden or, full
	/// screen, its OS workspace leaves the display, never because Arx merely lost focus or
	/// another app covers it (DEV-1246, DEV-1322).
	private func reportWindowsOnDisplay() {
		let ordinary = [(store.main.id, window)] + additionalWindows.map { ($0.key, Optional($0.value)) }
		let little = littleWindows.map { ($0.key, Optional<NSWindow>($0.value)) }
		let onDisplay = Set((ordinary + little).compactMap { id, window in
			window.map(Self.isOnDisplay) == true ? id : nil
		})
		guard onDisplay != windowsOnDisplay else { return }

		windowsOnDisplay = onDisplay
		store.send(.event(.windowsOnDisplayChanged(onDisplay)))
	}

	/// Visible, not minimised, and Arx isn't hidden; a full-screen window only on its own OS
	/// workspace (DEV-1322).
	internal static func isOnDisplay(_ window: NSWindow) -> Bool {
		WindowDisplay(
			isShown: !NSApp.isHidden && window.isVisible && !window.isMiniaturized,
			isFullScreen: window.styleMask.contains(.fullScreen),
			isOnActiveSpace: window.isOnActiveSpace
		).isOnDisplay
	}

	private func reportLittleWindowsElsewhere() {
		let elsewhere = Set(littleWindows.compactMap { id, panel in
			panel.isVisible && !panel.isOnActiveSpace ? id : nil
		})

		// The window a popup came from, too (DEV-1186): closing the popup never brings it over.
		let ordinary = [(store.main.id, window)] + additionalWindows.map { ($0.key, Optional($0.value)) }
		let windows = Set(ordinary.compactMap { id, window in
			window.map { $0.isVisible && !$0.isOnActiveSpace } == true ? id : nil
		})
		guard elsewhere != littleWindowsElsewhere || windows != windowsElsewhere else { return }

		littleWindowsElsewhere = elsewhere
		windowsElsewhere = windows
		store.send(.event(.desktopSpaceChanged(littleWindowsElsewhere: elsewhere, windowsElsewhere: windows)))
	}

	/// Automatic Picture in Picture follows Arx leaving the front (DEV-848). Coming back is
	/// reported when a browser window becomes key instead, in `windowDidBecomeKey`.
	private func observeMediaActivity() {
		mediaActivityObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didResignActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				_ = self?.store.send(.event(.browserActivityChanged(isActive: false)))
			}
		}
	}

	/// `arx setup` can't reach the socket before a client exists, so it asks over a same-user notification.
	/// That only starts a question for a person, and the answer goes in a file only this user can read.
	private func observeAgentSetup() {
		let center = DistributedNotificationCenter.default()
		agentSetupObservers = [
			center.addObserver(
				forName: AgentSetup.requestNotification,
				object: nil,
				queue: .main
			) { [weak self] notification in
				guard let request = AgentSetup.Request(userInfo: notification.userInfo) else { return }
				MainActor.assumeIsolated {
					NSApplication.shared.activate()
					self?.store.send(.automation(.event(.agentSetupRequested(request))))
				}
			},
			center.addObserver(
				forName: AgentSetup.revokeNotification,
				object: nil,
				queue: .main
			) { [weak self] notification in
				let clientID = notification.userInfo?["clientID"] as? String
				guard let id = clientID.flatMap(UUID.init(uuidString:)) else { return }
				MainActor.assumeIsolated {
					_ = self?.store.send(.automation(.ui(.revokeClient(id))))
				}
			},
		]
	}

	private func renderOnboardingWindow() {
		if let onboarding = store.scope(state: \.onboarding, action: \.onboarding), onboardingWindow == nil {
			let window = NSWindow(
				contentRect: .init(origin: .zero, size: OnboardingView.size),
				styleMask: [.titled, .closable, .fullSizeContentView],
				backing: .buffered,
				defer: false
			)
			onboardingWindow = window
			window.identifier = .init("onboarding")
			window.title = String.localized(.appUI.onboarding.title)
			window.titleVisibility = .hidden
			window.titlebarAppearsTransparent = true
			window.isMovableByWindowBackground = true
			window.delegate = self
			window.isReleasedWhenClosed = false
			window.contentView = NSHostingView(rootView: OnboardingView(store: onboarding))
			window.center()

			// The content springs in itself; the window only fades so the two don't fight.
			window.alphaValue = 0
			window.makeKeyAndOrderFront(nil)
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.25
				window.animator().alphaValue = 1
			}
		}

		if store.onboarding != nil, onboardingFocusRequest != store.onboardingFocusRequest {
			onboardingFocusRequest = store.onboardingFocusRequest
			onboardingWindow?.makeKeyAndOrderFront(nil)

			// A link or command from elsewhere brings onboarding forward over other apps (DEV-838).
			NSApplication.shared.activate(ignoringOtherApps: true)
		}

		if store.onboarding == nil, let closed = onboardingWindow {
			onboardingWindow = nil
			closed.delegate = nil
			if onboardingHandOffRequest != store.onboardingHandOffRequest {
				onboardingHandOffRequest = store.onboardingHandOffRequest
				if store.mainWindowWaitsForOnboarding {
					closed.ignoresMouseEvents = true
					pendingHandOffWindow = closed
				} else {
					handOffFromOnboarding(closed)
				}
			} else {
				closed.contentView = nil
				closed.close()
			}
		}
		onboardingHandOffRequest = store.onboardingHandOffRequest

		if !store.mainWindowWaitsForOnboarding, let pending = pendingHandOffWindow {
			pendingHandOffWindow = nil
			handOffFromOnboarding(pending)
		}
	}

	/// Grows the onboarding window into the main window while it fades, then brings
	/// the main window forward. Under Reduce Motion it only crossfades.
	private func handOffFromOnboarding(_ closing: NSWindow) {
		guard let main = window else {
			closing.contentView = nil
			closing.close()
			return
		}

		let reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
		main.makeKeyAndOrderFront(nil)
		closing.orderFront(nil)
		NSAnimationContext.runAnimationGroup { context in
			context.duration = reduceMotion ? 0.2 : 0.35
			context.timingFunction = .init(name: .easeInEaseOut)
			closing.animator().alphaValue = 0
			if !reduceMotion {
				closing.animator().setFrame(main.frame, display: true)
			}
		} completionHandler: {
			MainActor.assumeIsolated {
				closing.contentView = nil
				closing.close()
			}
		}
	}

	/// Puts the window a page fills in or out of full screen (DEV-949).
	internal func renderPageFullScreen() {
		guard headless == nil else { return }

		// The window keeps these to look again at a toggle AppKit dropped (DEV-1183), so they
		// don't keep this alive.
		pageFullScreenWindows.update(
			target: store.pageFullScreen?.windowID,
			browserWindow: { [weak self] id in
				guard let self else { return nil }
				return id == self.store.main.id ? self.window : self.additionalWindows[id]
			},
			littleWindows: littleWindows,
			isTransitioning: { [weak self] id in
				guard let self else { return false }
				return self.fullScreenTransitions.contains(id) || self.restoringFullScreenWindowID == id
			}
		)
	}

	/// What every window's page area, Page PiP and page full screen attach their tab's page
	/// with: the router's, which shows the tab's Chromium page or its WebKit page (DEV-877).
	/// Chromium's own surface knows nothing of WebKit pages, which then never reach a window.
	internal var pageSurface: BrowserSurfaceClient { pageRouter.surface }

	/// Page PiP's floating window, opened and closed with the store's Page PiP (DEV-950).
	private func renderPagePictureInPicture() {
		pagePictureInPictureWindows.update(store: store, surface: pageSurface) { [self] id in
			id == store.main.id ? window : additionalWindows[id] ?? littleWindows[id]
		}
	}

	private func renderAdditionalWindows() {
		for id in Array(additionalWindows.keys) where store.windows[id: id] == nil {
			let window = additionalWindows.removeValue(forKey: id)
			if let window { forgetWindowGeometry(id, window: window) }
			window?.delegate = nil
			window?.contentView = nil
			window?.close()
		}

		for child in store.scope(state: \.windows, action: \.windows) {
			guard additionalWindows[child.id] == nil else { continue }

			geometryReadyWindows.remove(child.id)
			let window = makeWindow()
			window.identifier = LinkSharingClient.windowIdentifier(for: child.id)
			additionalWindows[child.id] = window
			window.contentView = BrowserHostingView(
				rootView: AppAdditionalMainView(
					store: store,
					child: child,
					surface: pageSurface,
					engine: pageRouter.client,
					siteIcons: viewSiteIcons,
					previewClients: previewClients
				),
				minimumSize: BrowserWindowSize.mainMinimum
			)
			placeBrowserWindow(window, id: child.id)
			window.makeKeyAndOrderFront(nil)
		}
	}

	private func renderLittleArxWindows() {
		let rendered = Set(littleWindows.keys)
		defer {
			// Out of rendering: the report is an action, and rendering follows the store.
			if headless == nil, Set(littleWindows.keys) != rendered {
				Task { @MainActor [weak self] in
					self?.reportLittleWindowsElsewhere()
					self?.reportWindowsOnDisplay()
				}
			}
		}
		for id in Array(littleWindows.keys) where store.littleWindows[id: id] == nil {
			let window = littleWindows.removeValue(forKey: id)

			// A closing popup hands the keyboard to its opener first, so AppKit doesn't pick
			// another window (DEV-855): a Little Arx, or the window a popup came from (DEV-1186).
			if
				window?.isKeyWindow == true,
				let focused = store.focusedWindowID,
				let next = littleWindows[focused]
					?? (focused == store.main.id ? self.window : additionalWindows[focused])
			{
				next.makeKeyAndOrderFront(nil)
			}
			window?.delegate = nil
			window?.contentView = nil
			window?.close()
		}

		for child in store.scope(state: \.littleWindows, action: \.littleWindows) {
			guard littleWindows[child.id] == nil else { continue }

			let panel = LittleArxPanel(
				commandOnly: child.isCommandOnly,
				launcherPosition: store.settings.linkClicks.littleArxLauncherPosition,
				origin: child.origin
			)
			panel.identifier = LinkSharingClient.windowIdentifier(for: child.id)
			littleWindows[child.id] = panel
			panel.delegate = self
			panel.contentView = BrowserHostingView(
				rootView: AppLittleArxView(
					app: store,
					child: child,
					surface: pageSurface,
					siteIcons: viewSiteIcons,
					onCommandHeightChange: { [weak panel] height in panel?.fitCommandBar(height: height) }
				),
				minimumSize: panel.minimumBrowserContentSize
			)

			// A background tab from another Little Arx (⌘-click) opens behind the focused one,
			// without the keyboard, so it never covers the page being read. A new panel joins the
			// active macOS desktop Space, where the link was clicked, and takes the keyboard
			// without activating Arx, which would switch to its main window's Space (DEV-931).
			if store.focusedWindowID == child.id {
				panel.orderFrontRegardless()
				panel.makeKey()
			} else if let focused = store.focusedWindowID.flatMap({ littleWindows[$0] }) {
				panel.order(.below, relativeTo: focused.windowNumber)
			} else {
				panel.orderFront(nil)
			}
		}

		for child in store.littleWindows {
			let title = child.viewer.navigation.title
			littleWindows[child.id]?.updatePresentation(commandOnly: child.isCommandOnly)
			littleWindows[child.id]?.updatePictureInPicture(
				child.isPictureInPicture,
				siteKey: (child.viewer.navigation.url ?? child.tab.restoration.url).host()
			)
			littleWindows[child.id]?.title = title.isEmpty ? "Little Arx" : title
		}
	}

	/// Shows the profile picker at the pointer for the link it asks about, and closes it once
	/// the link is decided. A new link gets a new panel where the pointer is then.
	private func renderProfilePicker() {
		let picker = store.routingInbox.picker
		if let current = profilePicker, current.requestID != picker?.requestID {
			profilePicker = nil
			current.panel.onBecomeKey = nil
			current.panel.onResignKey = nil
			current.panel.onCancel = nil
			current.panel.onOpenNumber = nil
			current.panel.contentView = nil
			current.panel.close()
		}
		guard let picker, profilePicker == nil else { return }

		// Sized for every option, so the Runway's look and its list set the panel's size.
		let content = NSHostingView(rootView: RoutingProfilePickerView(store: store, picker: picker))
		let panel = RoutingProfilePickerPanel(size: content.fittingSize)
		panel.identifier = .init("routing-profile-picker")
		panel.contentView = content
		let requestID = picker.requestID
		panel.onBecomeKey = { [weak self] in self?.store.send(.ui(.windowBecameKey)) }
		panel.onCancel = { [weak self] in self?.store.send(.profilePicker(.ui(.cancel))) }
		panel.onOpenNumber = { [weak self] in self?.store.send(.profilePicker(.ui(.openNumber($0)))) }
		panel.onResignKey = { [weak self] in
			self?.store.send(.profilePicker(.ui(.lostFocus(requestID))))
		}
		profilePicker = (requestID, panel)

		// Key without activating Arx, as Little Arx opens over another app, on the active macOS
		// desktop Space, so the picker and the Little Arx it opens stay on one (DEV-931).
		panel.orderFrontRegardless()
		panel.makeKey()
	}

	// MARK: - Focus and titles

	private func focusRequestedWindow() {
		let mediaReturn = mediaSourceFocusRequest != store.mediaSourceFocusRequest

		// An activation request raises Arx even when the focused window stays the same, such as
		// the main window after Report a Problem showed its file in Finder.
		guard
			let focused = store.focusedWindowID,
			lastFocusedWindowID != focused || mediaReturn || appActivationRequest != store.appActivationRequest
		else { return }

		mediaSourceFocusRequest = store.mediaSourceFocusRequest
		let wasLittle = lastFocusWasLittle
		let activationRequested = appActivationRequest != store.appActivationRequest
		appActivationRequest = store.appActivationRequest
		lastFocusedWindowID = focused
		lastFocusWasLittle = littleWindows[focused] != nil
		let target = focused == store.main.id
		? window
		: additionalWindows[focused] ?? littleWindows[focused]

		// Dismissing Little Arx over another app returns there, without raising Arx.
		if wasLittle, !activationRequested, !mediaReturn, !NSApp.isActive { return }

		if mediaReturn, target?.isMiniaturized == true { target?.deminiaturize(nil) }
		target?.makeKeyAndOrderFront(nil)
		if mediaReturn || activationRequested {
			NSApplication.shared.activate(ignoringOtherApps: true)
		}
	}

	/// Asks on the page's window before an `arx://` link it opened drives Arx (DEV-929).
	private func presentArxLinkConfirmation() {
		guard store.arxLinkConfirmation?.id != presentedArxLink?.id else { return }

		// A newer link from the page replaced the one on screen: its sheet goes.
		if let presented = presentedArxLink {
			presentedArxLink = nil
			presented.host.endSheet(presented.alert.window)
		}
		guard let confirmation = store.arxLinkConfirmation else { return }

		let host = confirmation.windowID == store.main.id
		? window
		: additionalWindows[confirmation.windowID] ?? littleWindows[confirmation.windowID]
		guard let host, host.isVisible else {
			store.send(.ui(.cancelArxLink(confirmation.id)))
			return
		}

		let alert = NSAlert()
		alert.messageText = String.localized(.appUI.arxLink.title)
		let requestedBy: String = confirmation.source.isEmpty
		? String.localized(.appUI.arxLink.requestedByUnknown)
		: String.localized(.appUI.arxLink.requestedBy(confirmation.source))
		alert.informativeText = Self.describe(confirmation.command) + "\n\n" + requestedBy
		let open = alert.addButton(withTitle: String.localized(.appUI.arxLink.open))
		let cancel = alert.addButton(withTitle: String.localized(.appUI.common.cancel))

		// Return and Escape cancel, and Open waits a moment, so keys meant for the page
		// can't approve it.
		open.keyEquivalent = ""
		cancel.keyEquivalent = "\r"
		open.isEnabled = false

		// Armed only once the sheet is on screen and key, again each time Arx comes back
		// (a queued sheet or an inactive app doesn't count down).
		arxLinkKeyObserver.map(NotificationCenter.default.removeObserver)
		arxLinkKeyObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didBecomeKeyNotification,
			object: alert.window,
			queue: .main
		) { [weak self, weak open] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				open?.isEnabled = false
				self.arxLinkArming &+= 1
				let generation = self.arxLinkArming
				DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750)) { [weak self, weak open] in
					guard
						let self,
						generation == self.arxLinkArming,
						open?.window?.isKeyWindow == true
					else { return }
					open?.isEnabled = true
				}
			}
		}
		let id = confirmation.id
		presentedArxLink = (id, alert, host)
		alert.beginSheetModal(for: host) { [weak self] response in
			guard let self else { return }
			if self.presentedArxLink?.id == id {
				self.presentedArxLink = nil
				self.arxLinkKeyObserver.map(NotificationCenter.default.removeObserver)
				self.arxLinkKeyObserver = nil
			}
			self.store.send(response == .alertFirstButtonReturn ? .ui(.confirmArxLink(id)) : .ui(.cancelArxLink(id)))
		}
	}

	/// What the link does, as one whole sentence per case, so no language joins fragments
	/// (DEV-1291).
	internal static func describe(_ command: ArxURLCommand) -> String {
		switch command {
		case let .open(url, space?, _):
			String.localized(.appUI.arxLink.openPageInSpace(url.absoluteString, space))

		case let .open(url, nil, profile?):
			String.localized(.appUI.arxLink.openPageInProfile(url.absoluteString, profile))

		case let .open(url, nil, nil):
			String.localized(.appUI.arxLink.openPage(url.absoluteString))

		case let .littleArx(url?, space?):
			String.localized(.appUI.arxLink.openPageInLittleArxInSpace(url.absoluteString, space))

		case let .littleArx(url?, nil):
			String.localized(.appUI.arxLink.openPageInLittleArx(url.absoluteString))

		case let .littleArx(nil, space?):
			String.localized(.appUI.arxLink.openLittleArxInSpace(space))

		case .littleArx(nil, nil):
			String.localized(.appUI.arxLink.openLittleArx)

		case let .switchSpace(name):
			String.localized(.appUI.arxLink.switchSpace(name))
		}
	}

	/// Offers the front ordinary window's page to Handoff while Settings allow it. Headless
	/// runs and private windows offer nothing (DEV-922).
	private func updateHandoff() {
		guard headless == nil, store.settings.general.handoffEnabled else {
			handoff.invalidate()
			return
		}

		let id = store.focusedWindowID ?? store.main.id
		let navigation: BrowserNavigation?
		if id == store.main.id {
			navigation = store.windowIsOpen ? store.main.viewer.item.navigation : nil
		} else if let window = store.windows[id: id] {
			navigation = window.isPrivate ? nil : window.viewer.item.navigation
		} else {
			navigation = store.littleWindows[id: id]?.viewer.navigation
		}
		handoff.update(url: navigation?.url, title: navigation?.title ?? "")
	}

	private func updateWindowTitles() {
		for child in store.windows {
			let navigation = child.viewer.item.navigation
			additionalWindows[child.id]?.title = navigation.title.isEmpty ? "Arx" : navigation.title
			additionalWindows[child.id]?.subtitle = child.isPrivate
			? String.localized(.appUI.menu.privateTitle)
			: store.persistenceError ?? ""
		}

		let navigation = store.main.viewer.item.navigation
		window?.title = navigation.title.isEmpty ? "Arx" : navigation.title
		window?.subtitle = store.persistenceError ?? ""
	}

	// MARK: - Window factory

	private func makeWindow() -> NSWindow {
		let window = NSWindow(
			contentRect: .init(
				x: 0,
				y: 0,
				width: 1120,
				height: 850
			),
			styleMask: [
				.titled,
				.closable,
				.miniaturizable,
				.resizable,
				.fullSizeContentView
			],
			backing: .buffered,
			defer: false
		)
		window.delegate = self
		window.isReleasedWhenClosed = false
		window.contentMinSize = BrowserWindowSize.mainMinimum
		window.titleVisibility = .hidden
		window.titlebarAppearsTransparent = true
		if TranslucentChrome.isEnabledForThisLaunch {
			// The chrome lets the desktop through (DEV-1286): its own blur and tint cover the
			// window, and the page card is solid. The frame keeps its corners and shadow.
			window.isOpaque = false
			window.backgroundColor = .clear
		} else {
			window.backgroundColor = .windowBackgroundColor
		}
		return window
	}

	/// The site icons windows draw. Nobody sees a headless run's windows, so none of their
	/// missing icons is fetched from its site; a page's own icon still reaches them.
	internal var viewSiteIcons: BrowserSiteIconClient {
		headless == nil ? siteIcons : siteIcons.neverFetching
	}

	/// Hover previews read sessions and take pictures through this window's own clients,
	/// because views run outside the store's dependency scope.
	internal var previewClients: SidebarPreviewClients {
		let client = engine.client
		let media = capabilities.media
		return .init(
			// A page Arx unloaded to free memory (DEV-873) has no document to picture or read,
			// so previews treat it as a tab that isn't loaded and use its saved picture.
			snapshot: { id in client.snapshot(id).flatMap { $0.navigation.isUnloaded ? nil : $0 } },
			capture: capabilities.capture,
			readScript: { id, script in

				// Arx's own fixed read for a favorite's hover card, not an agent's script (DEV-802).
				guard
					client.developerTierIsAvailable(),
					case let .value(text)? = try? await client.evaluateScript(id, script, 262_144, 5_000, { true })
				else { return nil }
				return text
			},
			pagePreviews: pagePreviews,
			siteCookies: previewSiteCookies,
			// Full previews (DEV-730): a page of its own, outside every window and the store,
			// so nothing records its visit or shows it.
			openPage: { try await client.open($0) },
			mutePage: { id in try? media.setMuted(id, true) },
			closePage: { client.close($0) },
			mediaPosition: { media.position($0) }
		)
	}

	/// Site details ask with the profile's cookies for the page's own host (DEV-1142).
	/// A profile no space has shown yet is loaded first, without a page, or it has no cookies.
	private var previewSiteCookies: (@MainActor @Sendable (Profile.ID, URL) async -> [HTTPCookie])? {
		guard SitePreviewImagesFeatureFlag.isOn() else { return nil }

		return { [engine] profile, url in
			do {
				try await engine.client.prepareProfile(profile)
			} catch {
				return []
			}
			return await engine.siteCookies(profile: profile, tab: nil, url: url)
		}
	}

	/// The pages whose saved pictures stay: every tab's last address and saved destination,
	/// archived tabs included.
	private static func pagePreviewKeys(_ organization: BrowserOrganization) -> Set<BrowserPagePreviewKey> {
		let tabs = Array(organization.tabs) + organization.archive.map(\.tab)
		return Set(tabs.flatMap { tab in
			[tab.restoration.url, tab.savedDestination?.url]
				.compactMap(\.self)
				.map { BrowserPagePreviewKey(profileID: tab.profileID, pageURL: $0) }
		})
	}

	// MARK: - Main window

	private func createWindow() {
		geometryReadyWindows.remove(store.main.id)
		let window = makeWindow()
		if headless != nil { return createHeadlessWindow(window) }
		window.identifier = LinkSharingClient.windowIdentifier(for: store.main.id)
		self.window = window
		window.contentView = BrowserHostingView(
			rootView: AppMainView(
				store: store,
				surface: pageSurface,
				engine: pageRouter.client,
				siteIcons: viewSiteIcons,
				previewClients: previewClients
			),
			minimumSize: BrowserWindowSize.mainMinimum
		)
		placeBrowserWindow(window, id: store.main.id)
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate(ignoringOtherApps: true)
		LaunchSignposts.windowShown()
	}

	// MARK: - NSWindowDelegate

	internal func windowDidBecomeKey(_ notification: Notification) {
		guard let focused = notification.object as? NSWindow else { return }

		// Utility activation does not change the last focused browser window, but
		// must still supersede a deferred request to bring a page to the front.
		store.send(.ui(.windowBecameKey))
		var isBrowserWindow = true
		if focused === window {
			store.send(.ui(.focusWindow(store.main.id)))
		} else if let id = littleWindows.first(where: { $0.value === focused })?.key {
			store.send(.ui(.focusWindow(id)))
		} else if let id = additionalWindows.first(where: { $0.value === focused })?.key {
			store.send(.ui(.focusWindow(id)))
		} else {
			isBrowserWindow = false
		}
		if isBrowserWindow, NSApp.isActive {
			store.send(.event(.browserActivityChanged(isActive: true)))
		}
	}

	internal func windowDidResignKey(_ notification: Notification) {
		guard
			let panel = notification.object as? LittleArxPanel,
			let id = littleWindows.first(where: { $0.value === panel })?.key
		else { return }

		store.send(.littleWindows(.element(id: id, action: .ui(.lostFocus))))
	}

	internal func windowShouldClose(_ sender: NSWindow) -> Bool {
		if sender === onboardingWindow {
			// AppFeature refuses while an import is committing and removes the window otherwise.
			store.send(.ui(.closeOnboarding))
			return false
		}

		// An ordinary window releasing pages with unsaved input asks them first, then closes through
		// the store, which closes a Peek it hosts before it (DEV-1107). Others close as before.
		if sender === window, asksBeforeClosing(store.main.id) {
			store.send(.ui(.requestCloseWindow(store.main.id)))
			return false
		}
		if sender === window, store.peeks.contains(where: { $0.source.windowID == store.main.id }) {
			store.send(.ui(.closeWindow))
			return false
		}
		if let id = additionalWindows.first(where: { $0.value === sender })?.key {
			if store.windows[id: id]?.isPrivate == false, asksBeforeClosing(id) {
				store.send(.ui(.requestCloseWindow(id)))
				return false
			}
			if store.peeks.contains(where: { $0.source.windowID == id }) {
				store.send(.ui(.closeAdditionalWindow(id)))
				return false
			}
			if store.windows[id: id]?.isPrivate == true {
				store.send(.ui(.requestClosePrivateWindow(id)))
				return false
			}
		}

		guard let id = littleWindows.first(where: { $0.value === sender })?.key
		else { return true }

		store.send(.littleWindows(.element(id: id, action: .ui(.close))))
		return false
	}

	/// Whether closing this ordinary window would release a page holding unsaved input, which it
	/// asks first (DEV-1107). The store asks the engine again before the question; a window
	/// already asking says yes, so a second close waits for its answer.
	private func asksBeforeClosing(_ id: UUID) -> Bool {
		if store.windowCloseRequests[id] != nil { return true }
		let engine = pageRouter.client
		return store.state.tabsReleasedByClosing(id).contains { engine.tabHoldsUnsavedInput($0) }
	}

	internal func windowWillClose(_ notification: Notification) {
		if let closed = notification.object as? NSWindow, let id = browserWindowID(closed) {
			forgetWindowGeometry(id, window: closed)
		}
		if let closed = notification.object as? NSWindow, closed === downloadsWindow {
			downloadsWindow = nil
			store.send(.downloads(.ui(.dismissed)))
			return
		}
		if let closed = notification.object as? NSWindow, closed === taskManagerWindow {
			taskManagerWindow = nil
			store.send(.taskManager(.ui(.dismissed)))
			return
		}
		if let closed = notification.object as? NSWindow, closed === settingsWindow {
			settingsWindow = nil
			store.send(.ui(.closeSettings))
			return
		}
		if let closed = notification.object as? NSWindow, closed === onboardingWindow {
			onboardingWindow = nil
			closed.contentView = nil
			store.send(.ui(.closeOnboarding))
			return
		}
		if
			let closed = notification.object as? NSWindow,
			let id = additionalWindows.first(where: { $0.value === closed })?.key
		{
			closed.contentView = nil
			additionalWindows[id] = nil
			store.send(.ui(.closeAdditionalWindow(id)))
			return
		}
		guard
			let closed = notification.object as? NSWindow,
			closed === window
		else { return }

		// A closed NSWindow can outlive its presentation; release its native host now.
		window?.contentView = nil
		window = nil
		store.send(.ui(.closeWindow))
	}

	// MARK: - Initial workspace

	/// The first workspace of automated and headless runs, which never show onboarding:
	/// a Default profile and space with one tab their checks can drive.
	private static func initialOrganization(url raw: String?) -> BrowserOrganization {
		let profileID = Profile.ID(rawValue: UUID())
		let spaceID = Space.ID(rawValue: UUID())
		let tabID = BrowserCore.Tab.ID(rawValue: UUID())
		let url = raw.flatMap(URL.init(string:)) ?? URL(string: "https://capturecontext.dev")!
		return .init(
			profiles: [.init(
				id: profileID,
				name: ProvisionalProfile.name
			)],
			spaces: [.init(
				id: spaceID,
				profileID: profileID,
				name: ProvisionalProfile.name,
				unpinnedTabs: [tabID],
				selectedTabID: tabID
			)],
			tabs: [.init(
				id: tabID,
				profileID: profileID,
				restoration: .init(
					title: url.host() ?? "Arx",
					url: url
				)
			)]
		)
	}
}

// MARK: - FairPlay in Chromium tabs (DEV-1144)

extension BrowserWindow {
	/// The FairPlay sites that stay in Chromium now: none without the bridge, and none whose
	/// track failed this run.
	fileprivate var fairPlayOrigins: [String] {
		guard fairPlay != nil else { return [] }
		return FairPlayInChromium.origins.filter { !fairPlayFallbacks.contains($0) }
	}

	/// Settings' Widevine answer, where the engine reads it at its next launch.
	fileprivate nonisolated static func storeWidevineAnswer(_ isOn: Bool) {
		UserDefaults.standard.set(WidevineAnswer.defaultsValue(isOn), forKey: WidevineAnswer.featureFlag)
	}

	/// Starts the bridge when the feature flag is on and the engine, the helper app and the script
	/// are all there. A track that fails moves its tab to WebKit, and its site opens in WebKit for
	/// the rest of the run.
	fileprivate func startFairPlay(document: WorkspaceDocument) {
		let log = FairPlayBridge.diagnosticsLog
		guard FairPlayInChromium.isOn(environment: environment) else {
			log.notice("FairPlay in Chromium tabs is off: its feature flag is off")
			return
		}
		guard engine.supportsPageMedia else {
			log.error("FairPlay in Chromium tabs is off: the engine has no page media bridge")
			return
		}
		guard FairPlayHelperConnection.isAvailable else {
			log.error("FairPlay in Chromium tabs is off: no helper app at \(FairPlayHelperConnection.helperExecutable.path, privacy: .public)")
			return
		}
		guard let script = FairPlayBridgeScript.source else {
			log.error("FairPlay in Chromium tabs is off: the bridge script is missing")
			return
		}

		let bridge = FairPlayBridge(helper: .live()) { [weak engine] tab, document, text in
			engine?.sendPageMedia(text, to: document, in: tab) ?? false
		}
		bridge.onFailure = { [weak self, document] tab, _ in
			guard
				let self,
				let url = self.engine.client.snapshot(tab)?.navigation.url,
				let origin = FairPlayInChromium.origin(of: url)
			else {
				log.notice("A FairPlay track failed in a tab that no longer shows a FairPlay site; nothing moves")
				return
			}

			self.fairPlayFallbacks.insert(origin)
			self.publishFairPlayOrigins()
			guard document.preferences.webKitPages.isEnabled else {
				log.notice("A FairPlay track failed; WebKit pages are off, so the tab stays")
				return
			}
			log.notice("A FairPlay track failed; its tab moves to a WebKit page")
			Task { [weak pageRouter = self.pageRouter] in
				await pageRouter?.move(tab, to: .webKit, url: url)
			}
		}
		engine.onAudioMutedChange = { [weak bridge] tab, isMuted in
			bridge?.setMuted(isMuted, tab: tab)
		}
		engine.onPageRemoved = { [weak bridge] tab in
			bridge?.pageGone(tab)
		}
		engine.onAudioVolumeChange = { [weak bridge] tab, volume in
			bridge?.setVolume(volume, tab: tab)
		}
		engine.playsOutsideChromium = { [weak bridge] tab in
			bridge?.isPlaying(tab) ?? false
		}

		// Chromium hears a silent page while the helper holds its track, yet its script must keep
		// answering: the page holds a freeze lease meanwhile (DEV-1151). Engines without it don't.
		bridge.onHolderChange = { [weak engine] tab, document, holds in
			engine?.setPageMediaKeepsRunning(holds, document: document, in: tab)
		}

		// Chromium's media session hears nothing of the helper's track: the engine shows it among
		// its media sources, on the tab's speaker and the Media page, and their play and pause
		// reach the page's own player (DEV-1147).
		bridge.onTrackChange = { [weak self] track in
			self?.showFairPlayTrack(track)
		}
		engine.performOutsideMedia = { [weak bridge] tab, action in
			bridge?.control(action, tab: tab) ?? false
		}
		let started = engine.setPageMediaBridge(origins: FairPlayInChromium.origins, script: script) { [weak bridge] message in
			bridge?.receive(.init(tabID: message.tabID, document: message.document, text: message.text, isPrivate: message.isPrivate))
		}
		guard started else {
			log.error("FairPlay in Chromium tabs is off: the engine refused the page media bridge")
			return
		}
		log.notice("FairPlay in Chromium tabs is on")
		fairPlay = bridge
		publishFairPlayOrigins()
	}

	private func showFairPlayTrack(_ track: FairPlayBridge.Track?) {
		guard let track else {
			engine.outsideMedia = [:]
			return
		}

		engine.outsideMedia = [
			track.tabID: .init(
				track: UInt64(max(track.number, 0)),
				title: track.metadata.title,
				artist: track.metadata.artist,
				site: engine.client.snapshot(track.tabID)?.navigation.url.flatMap(MediaSite.init(url:)),
				playback: track.isPlaying ? .playing : .paused,
				actions: [.play, .pause, .nextTrack, .previousTrack]
			),
		]
	}

	/// Tells every window's site menu which FairPlay sites stay in Chromium, as the router has
	/// them (DEV-1151).
	private func publishFairPlayOrigins() {
		store.send(.webKitPages(.fairPlayOriginsChanged(Set(fairPlayOrigins))))
	}
}
