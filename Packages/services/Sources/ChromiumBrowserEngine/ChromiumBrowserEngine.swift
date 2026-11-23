import AppKit
import BrowserCaptureClient
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import BrowserExtensionsClient
import BrowserMediaClient
import BrowserPageInspectionClient
import BrowserPageInteractionClient
import BrowserPageWaitClient
import BrowserSurfaceClient
import BrowserSiteIconClient
import ChromiumEngine

/// One registry per runtime. A tab keeps its page while its presentation changes.
@MainActor
public final class ChromiumBrowserEngine {
	internal let runtime: ChromiumRuntime
	internal let legacyProfileID: Profile.ID
	internal let enableContentHosting: Bool
	internal let enableExtensionViews: Bool
	public var onExtensionView: (@MainActor @Sendable (BrowserExtensionViewOffer) -> Bool)?

	/// Exact initial session ownership has already been released before this notification.
	public var onExtensionOptionsRevoked: (@MainActor @Sendable (BrowserExtensionViewOffer) -> Void)?

	/// The initial offer no longer carries rollback authority.
	public var onExtensionOptionsSettled: (@MainActor @Sendable (BrowserExtensionViewOffer) -> Void)?
	internal var initialExtensionOptions: [UInt64: BrowserExtensionViewOffer] = [:]
	public var onNewContents: (@MainActor @Sendable (BrowserNewContents) -> Bool)?

	/// True takes the Force Click: the link opens wherever the app sends it.
	public var onLinkForceClick: (@MainActor @Sendable (BrowserLinkForceClick) -> Bool)?

	/// ABI43. True takes a plain click on a link to another site: the tab stays where it
	/// was and the link opens wherever the app sends it.
	public var onCrossSiteLink: (@MainActor @Sendable (BrowserCrossSiteLink) -> Bool)?

	/// ABI50 (DEV-857). True takes a tab's link for another app: Chrome shows and launches
	/// nothing, and the app asks and handles it.
	public var onExternalLink: (@MainActor @Sendable (BrowserExternalLink) -> Bool)?

	/// ABI49 (DEV-855). The tab's page called `window.close()` and Blink allowed it (a
	/// window a script opened), after its before-unload. Nothing has closed: the app closes
	/// the tab's host without asking again, or ignores it.
	public var onPageCloseRequest: (@MainActor @Sendable (Tab.ID) -> Void)?

	/// DEV-907. A tab's page reports a different unread badge: from its title, or from the
	/// Badging API, which wins while set. Background pages report too.
	public var onUnreadBadge: (@MainActor @Sendable (Tab.ID, UnreadBadge) -> Void)?

	/// Each live tab's badges: the Badging API's while set, and its title's.
	internal var unreadBadges: [Tab.ID: (app: UnreadBadge?, title: UnreadBadge)] = [:]

	/// A tab's ordinary page finished loading at a different URL or title, whether a window shows
	/// it or not, so the app keeps the tab's own URL and title with its page: an agent's tab, a
	/// background tab, or a restored one moved along its history.
	public var onPageSettled: (@MainActor @Sendable (Tab.ID, BrowserNavigation) -> Void)?

	/// What each live tab's ordinary page last settled on, so a change is reported once.
	internal var settledPages: [Tab.ID: (url: URL?, title: String)] = [:]

	/// ABI54 (DEV-949). The tab's page entered (true) or left (false) HTML full screen.
	public var onPageFullScreen: (@MainActor @Sendable (Tab.ID, Bool) -> Void)?

	/// ABI60 (DEV-1111). The link under the pointer in the tab's page, or nil once the pointer
	/// leaves it, for the app's link status. Private tabs report too.
	public var onLinkHover: (@MainActor @Sendable (Tab.ID, BrowserHoveredLink?) -> Void)?

	/// ABI56 (DEV-963). With hosted page prompts on, the tab's site permission prompt for the app
	/// to draw became current (its token) or went away (0), also when the page closed.
	public var onPagePermissionPrompt: (@MainActor @Sendable (Tab.ID, UInt64) -> Void)?

	/// Tabs with a hosted prompt the app was told about, so removing the page withdraws it while
	/// the tab is still known: the runtime's own report then finds no tab.
	private var hostedPromptTabs: Set<Tab.ID> = []

	/// ABI55 (DEV-885). While a click on a notification from the tab's site ran, its page
	/// or service worker asked for the tab: show it and bring Arx forward.
	public var onPageActivationRequest: (@MainActor @Sendable (Tab.ID) -> Void)?

	/// ABI55 (DEV-885). A service worker opened a window from a click on its notification.
	/// The tab's page is already loading in its profile; true keeps it as a foreground tab.
	public var onNotificationWindow: (@MainActor @Sendable (Tab) -> Bool)?

	/// ABI55 (DEV-885). A click on a site's notification finished.
	public var onNotificationClick: (@MainActor @Sendable (BrowserNotificationClick) -> Void)?

	/// DEV-877. A tab's page asked for protected media key systems, which Chromium can't play
	/// in Arx; the app may offer WebKit for its site.
	public var onProtectedMedia: (@MainActor @Sendable (ProtectedMediaRequest) -> Void)?

	/// DEV-1293. A swipe on a tab's page was released toward its page in the other engine
	/// (`setSharedHistory`): true for forward.
	public var onSharedHistorySwipe: (@MainActor @Sendable (Tab.ID, _ forward: Bool) -> Void)?

	/// DEV-1144. A tab's audio was muted or unmuted through the engine, so audio Arx plays for it
	/// outside Chromium (FairPlay) follows.
	public var onAudioMutedChange: (@MainActor @Sendable (Tab.ID, Bool) -> Void)?

	/// DEV-1144. A tab's Chromium page went: it closed, or moved to another engine.
	public var onPageRemoved: (@MainActor @Sendable (Tab.ID) -> Void)?

	/// DEV-1144. A tab's volume changed through the engine, for its audio outside Chromium.
	public var onAudioVolumeChange: (@MainActor @Sendable (Tab.ID, Double) -> Void)?

	/// DEV-1144. Whether a tab plays sound outside Chromium (FairPlay), which Chromium can't see:
	/// such a tab is never unloaded, as Chromium keeps an audible page.
	public var playsOutsideChromium: (@MainActor @Sendable (Tab.ID) -> Bool)?

	/// DEV-1147. Tracks tabs play outside Chromium (FairPlay), shown among Chromium's media sources
	/// so the tab's speaker and the Media page see them.
	public var outsideMedia: [Tab.ID: OutsideChromiumMedia] = [:] {
		didSet { mediaService?.setOutside(outsideMedia) }
	}

	/// DEV-1147. Hands a control for a tab's outside track to its page's own player; false when the
	/// tab has none.
	public var performOutsideMedia: (@MainActor @Sendable (Tab.ID, BrowserMediaSource.Action) -> Bool)?
	internal let enableAuthorizedClosing: Bool
	internal var sessionRevisions: [Tab.ID: UInt64] = [:]
#if DEBUG
	internal var newContentsRequests: Int = 0

	/// The last request for new contents from a page and what became of it (DEV-1191).
	public internal(set) var lastNewContents: NewContentsRecord?
#endif
	internal var mediaService: ChromiumMediaAdapter?
	internal var siteIconService: ChromiumSiteIconService?
	internal var downloadsService: ChromiumDownloads?
	internal var downloadSourceTabs: [UInt64: Tab.ID] = [:]

	/// Pages this engine opened fresh: they start at the `about:blank` that `makePage` creates
	/// them with, which commits before the tab's own address loads (DEV-1116).
	internal var blankStartPages: Set<UInt64> = []

	/// The newest transfer each tab's navigation became while it had no page (DEV-1116).
	internal var pageDownloads: [Tab.ID: (download: BrowserNavigation.Download, startedAt: Date)] = [:]
	internal var pageProfiles: [Tab.ID: Profile.ID] = [:]
	internal var pendingPrivateProfileReleases: Set<Profile.ID> = []
	internal var openGenerations: [Tab.ID: Int] = [:]
	internal var pendingOpens: [Tab.ID: Task<Void, Error>] = [:]
	internal var retiringProfiles: Set<Profile.ID> = []
	internal var retirementOperations: Set<Profile.ID> = []
	internal var retirementRequests: [Profile.ID: UUID] = [:]
	internal var retirementIntents: Set<Profile.ID> = []

	/// DEV-880. When the last idle-release sweep saw each loaded profile in use.
	internal var profilesLastSeenInUse: [Profile.ID: ContinuousClock.Instant] = [:]

	/// DEV-880. Profiles whose site icons were answered from storage while they weren't loaded.
	internal var deferredSiteIconProfiles: Set<Profile.ID> = []
	internal var siteIconRefreshes: [UUID: AsyncStream<ChromiumSiteIconInvalidation>.Continuation] = [:]

	/// DEV-1020: what pages darken, as the app last set it.
	internal var darkPages: DarkPagesConfiguration = .off
	internal var pages: [Tab.ID: ChromiumPage] = [:] {
		didSet {
			scheduleExtensionTabPlacements()
			for id in dockedDeveloperTools.keys where pages[id] == nil { dockedDeveloperTools[id] = nil }
		}
	}

	/// Each page's tab by the page's engine identifier, so a native callback finds its tab without
	/// scanning `pages` (DEV-945). `setPage(_:for:)` and `removePage(_:)` keep it in step.
	private var tabIDsByPage: [UInt64: Tab.ID] = [:]

	/// DEV-927: the app's Cast picker events, so a tab whose page goes hears its picker close.
	internal var castPickerContinuation: AsyncStream<BrowserCastPickerEvent>.Continuation?

	/// ABI42: each page's docked DevTools view, kept in the page's host behind it (DEV-733).
	internal var dockedDeveloperTools: [Tab.ID: NSView] = [:]

	/// ABI22: the app's latest placements, resent when sessions gain or lose pages.
	private var extensionTabPlacements: [Tab.ID: ChromiumExtensionTabPlacement] = [:]
	private var lastExtensionTabPlacements: [UInt64: ChromiumExtensionTabPlacement] = [:]
	private var extensionTabPlacementsScheduled: Bool = false
	internal var hosts: [Tab.ID: WeakHost] = [:]

	/// A page kept in the window behind the shown one, so it is already drawing when it's shown.
	private var staged: (id: Tab.ID, stage: WeakHost)?
	internal let escapeHosts: BrowserUnhandledEscapeHosts = .init()
	internal var observers: [Tab.ID: [UUID: AsyncStream<BrowserNavigation>.Continuation]] = [:]

	/// `entryChanges` subscribers, and the current history entry each tab last showed them.
	internal var entryObservers: [Tab.ID: [UUID: AsyncStream<BrowserNavigation>.Continuation]] = [:]
	internal var shownEntries: [Tab.ID: (entry: BrowserNavigation.Entry, isLoading: Bool)] = [:]

	/// DEV-1016: renderer ends across pages, for shared causes and pages that keep crashing.
	internal var rendererEnds: RendererEndHistory = .init()

	/// Renderers the engine ended whose end the page hasn't reported yet, by tab, so the next
	/// command waits for it rather than reaching the dying renderer (DEV-1009, DEV-1016).
	internal var endingRenderers: [Tab.ID: EndingRenderer] = [:]

	/// Commands that leave the document, counted by tab, so one that waited on an ended
	/// renderer doesn't run after a newer one.
	internal var documentCommands: [Tab.ID: UInt64] = [:]

	internal struct EndingRenderer {
		internal var id: UUID = .init()
		internal var end: UInt32
		internal var wasUnresponsive: Bool
	}

	/// DEV-878: where ordinary tabs keep their back/forward history; nil keeps none.
	internal var navigationStore: TabNavigationStore?

	/// Open tabs whose profile's history was cleared: they keep none until they close.
	internal var forgottenNavigation: Set<Tab.ID> = []

	/// Each tab's next save, 2.5 s after its page last changed.
	internal var navigationSaves: [Tab.ID: Task<Void, Never>] = [:]

	public init(
		runtime: ChromiumRuntime,
		profileID: Profile.ID,
		enableAuthorizedClosing: Bool = false,
		enableUnhandledEscape: Bool = false,
		enableContentHosting: Bool = false,
		enableExtensionViews: Bool = false
	) {
		self.runtime = runtime
		self.legacyProfileID = profileID
		self.enableAuthorizedClosing = enableAuthorizedClosing
		self.enableContentHosting = enableContentHosting
		self.enableExtensionViews = enableExtensionViews
		if enableUnhandledEscape {
			runtime.onUnhandledEscape = { [weak self] page, generation in
				self?.unhandledEscape(page, generation: generation) ?? false
			}
		}
		runtime.onPageBadge = { [weak self] page, badge in
			guard
				let self,
				let id = self.pages.first(where: { $0.value === page })?.key
			else { return }

			// A clear is an update too: the page's title shows again.
			self.unreadBadgeChanged(id, app: .some(badge.map(UnreadBadge.init(appBadge:))))
		}
		runtime.observePageBadges()
		runtime.onDeveloperToolsLayout = { [weak self] page in
			guard
				let self,
				let id = self.tabID(of: page)
			else { return }
			self.placeDeveloperTools(id)
		}
		runtime.onPageMenuChoice = { [weak self] page, item in
			guard
				let self,
				let id = self.tabID(of: page)
			else { return }
			self.onPageMenuChoice?(id, item)
		}
		runtime.onPageMenuItems = { [weak self] page in
			guard
				let self,
				let id = self.tabID(of: page)
			else { return [] }
			return self.pageMenuItems?(id) ?? []
		}
		runtime.onContextMenuChoice = { [weak self] page, choice in
			guard
				let self,
				let id = self.tabID(of: page)
			else { return }
			self.onContextMenuChoice?(id, choice)
		}
		runtime.onContextMenuItems = { [weak self] page in
			guard
				let self,
				let id = self.tabID(of: page)
			else { return [] }
			return self.contextMenuItems?(id) ?? []
		}
		runtime.onLinkForceClick = { [weak self] page, generation, url in
			self?.linkForceClick(page, generation: generation, url: url) ?? false
		}
		runtime.onCrossSiteLink = { [weak self] page, generation, url in
			self?.crossSiteLink(page, generation: generation, url: url) ?? false
		}
		runtime.onExternalLink = { [weak self] page, link in
			self?.externalLink(page, link: link) ?? false
		}
		runtime.onOrdinaryProfilePrepared = { [weak self] profile in
			self?.refreshDeferredSiteIcons(profile)
		}
		runtime.observeProtectedMedia { [weak self] page, url, reason in
			guard
				let self,
				let id = self.tabID(of: page),
				let profileID = self.pageProfiles[id]
			else { return }

			let reason: ProtectedMediaRequest.Reason = switch reason {
			case .playbackFailed: .playbackFailed
			case .keysWithoutMedia: .keysWithoutMedia
			}
			self.onProtectedMedia?(.init(tabID: id, profileID: profileID, url: url, reason: reason))
		}
		runtime.observeSharedHistorySwipes { [weak self] page, forward in
			guard let self, let id = self.tabID(of: page) else { return }
			self.onSharedHistorySwipe?(id, forward)
		}
		runtime.onPageCloseRequest = { [weak self] page in
			guard
				let self,
				let id = self.tabID(of: page)
			else { return }
			self.onPageCloseRequest?(id)
		}
		runtime.onPageFullScreen = { [weak self] page, isFullScreen in
			guard
				let self,
				let id = self.tabID(of: page)
			else { return }
			self.onPageFullScreen?(id, isFullScreen)
		}
		runtime.onLinkHover = { [weak self] page, link in
			guard
				let self,
				let id = self.tabID(of: page)
			else { return }
			let hovered = link.flatMap { link in
				self.pageProfiles[id].map { profileID in
					BrowserHoveredLink(
						tabID: id,
						profileID: profileID,
						isPrivate: page.isPrivate,
						url: link.url,
						isCrossSite: link.isCrossSite,
						target: Self.hoveredLinkTarget(link.target)
					)
				}
			}
			self.onLinkHover?(id, hovered)
		}
		runtime.onPagePermissionPrompt = { [weak self] page, token in
			guard
				let self,
				let id = self.tabID(of: page)
			else { return }
			if token == 0 {
				self.hostedPromptTabs.remove(id)
			} else {
				self.hostedPromptTabs.insert(id)
			}
			self.onPagePermissionPrompt?(id, token)
		}
		runtime.onPageActivationRequest = { [weak self] page in
			guard
				let self,
				let id = self.tabID(of: page)
			else { return }
			self.onPageActivationRequest?(id)
		}
		runtime.onNotificationWindow = { [weak self] child, profile in
			guard let self else { return false }
			let profileID = Profile.ID.chromium(profile, legacy: self.legacyProfileID)
			return self.adoptNotificationWindow(child, profileID: profileID)
		}
		runtime.onNotificationClick = { [weak self] click in
			guard let self else { return }
			let profileID = Profile.ID.chromium(UUID(uuidString: click.profileKey), legacy: self.legacyProfileID)
			guard
				!self.retiringProfiles.contains(profileID),
				!self.retirementIntents.contains(profileID)
			else { return }

			self.onNotificationClick?(.init(
				profileID: profileID,
				origin: click.origin,
				isPersistent: click.isPersistent,
				isHandled: click.isHandled,
				pageIsGone: click.pageIsGone
			))
		}
		if enableContentHosting {
			runtime.onNewContents = { [weak self] source, generation, child, url, intent in
				self?.adoptContents(
					child,
					from: source,
					generation: generation,
					url: url,
					intent: intent
				) ?? false
			}
		}
	}

	// MARK: - Developer tools

	/// Developer mode is app-wide; the native side only offers Inspect Element while enabled.
	public func configureDeveloperTools(
		windowTitle: String,
		inspectTitle: String,
		isEnabled: Bool
	) {
		runtime.configureDeveloperTools(
			windowTitle: windowTitle,
			inspectTitle: inspectTitle,
			inspectsContext: isEnabled
		)
	}

	public var supportsDeveloperTools: Bool { runtime.supportsDeveloperTools }

	// MARK: - Page menu

	/// ABI45 (DEV-795): an item chosen in a tab's page menu, for the app to carry out.
	public var onPageMenuChoice: (@MainActor (Tab.ID, ChromiumPageMenuItem) -> Void)?

	/// ABI45 (DEV-795): which page menu items the tab's host can carry out now.
	public var pageMenuItems: (@MainActor (Tab.ID) -> Set<ChromiumPageMenuItem>)?

	/// Turns the engine's page menu on with localized titles.
	public func configurePageMenu(titles: [ChromiumPageMenuItem: String]) {
		runtime.configurePageMenu(titles: titles)
	}

	public var supportsPageMenu: Bool { runtime.supportsPageMenu }

	// MARK: - Context menus

	/// ABI48 (DEV-814): an app item chosen in a tab's context menu (a text field, a
	/// selection, an image or media), for the app to carry out.
	public var onContextMenuChoice: (@MainActor (Tab.ID, ChromiumContextMenuChoice) -> Void)?

	/// ABI48 (DEV-814): which app items of the context menus the tab's host can carry out
	/// now. Read synchronously as a menu opens: never close a page here.
	public var contextMenuItems: (@MainActor (Tab.ID) -> Set<ChromiumContextMenuItem>)?

	/// Turns the engine's context menus on with localized titles.
	public func configureContextMenus(titles: [ChromiumContextMenuItem: String]) {
		runtime.configureContextMenus(titles: titles)
	}

	public var supportsContextMenus: Bool { runtime.supportsContextMenus }

	public func developerToolsFrontendLoaded(_ id: Tab.ID) -> Bool {
		guard let page = pages[id] else { return false }
		return runtime.developerToolsFrontendLoaded(for: page)
	}

	public func developerToolsAreOpen(_ id: Tab.ID) -> Bool {
		guard let page = pages[id] else { return false }
		return runtime.developerToolsAreOpen(for: page)
	}

	internal func waitSubscription(_ id: Tab.ID) -> ChromiumWaitAdapter.Subscription {
		let token = UUID()
		let (stream, continuation) = AsyncStream<BrowserNavigation>.makeStream(
			bufferingPolicy: .bufferingNewest(1)
		)
		observers[id, default: [:]][token] = continuation
		if let page = pages[id] {
			continuation.yield(snapshot(page.navigation, tab: id))
		}

		return .init(
			events: stream,
			cancel: { [weak self] in
				self?.observers[id]?.removeValue(forKey: token)?.finish()
			}
		)
	}

	/// The size of the page's view where its host's layout put it, in points, or nil while it has
	/// no host. The page full-screen smoke compares it with the page's own size when a wait times
	/// out, to tell a layout that never gave the page its area from a page that never took it
	/// (DEV-1183).
	public func pageViewSize(_ id: Tab.ID) -> CGSize? {
		guard let view = pages[id]?.view, view.superview != nil else { return nil }
		return view.bounds.size
	}

	public func isAttached(_ id: Tab.ID) -> Bool {
		guard let view = pages[id]?.view, !isStaged(id) else { return false }
		return view.window != nil && view.bounds.width > 0 && view.bounds.height > 0
	}

	internal func isVisibleForCapture(_ id: Tab.ID) -> Bool {
		guard
			!isStaged(id),
			let view = pages[id]?.view,
			let window = view.window,
			window.isVisible,
			!window.isMiniaturized,
			!view.isHiddenOrHasHiddenAncestor,
			view.visibleRect.width > 0,
			view.visibleRect.height > 0
		else { return false }

		return true
	}

	// MARK: - Extension tab placements

	/// ABI22. Changes to sessions' places in Arx windows for the extensions tabs and
	/// windows APIs: a placement for each session that arrived or moved, nil for each
	/// that left every window. A session without a page takes its place once it has
	/// one. Chromium hears again only when what it was last sent changes (DEV-945).
	public func updateExtensionTabPlacements(
		_ changes: [Tab.ID: ChromiumExtensionTabPlacement?]
	) {
		guard !changes.isEmpty else { return }

		for (id, placement) in changes {
			extensionTabPlacements[id] = placement
		}
		sendExtensionTabPlacements()
	}

	private func scheduleExtensionTabPlacements() {
		guard !extensionTabPlacementsScheduled, !extensionTabPlacements.isEmpty else { return }

		extensionTabPlacementsScheduled = true
		Task { @MainActor [weak self] in
			self?.extensionTabPlacementsScheduled = false
			self?.sendExtensionTabPlacements()
		}
	}

	private func sendExtensionTabPlacements() {
		guard runtime.state == .running, runtime.supportsExtensionWindows else { return }

		var values: [(page: ChromiumPage, placement: ChromiumExtensionTabPlacement)] = []
		var sent: [UInt64: ChromiumExtensionTabPlacement] = [:]
		for (id, placement) in extensionTabPlacements {
			guard let page = pages[id] else { continue }

			values.append((page: page, placement: placement))
			sent[page.identifier] = placement
		}

		// Compared unordered, so an unchanged set costs no sort.
		guard sent != lastExtensionTabPlacements else { return }

		lastExtensionTabPlacements = sent

		// Chromium's call replaces every placement and orders windows by first appearance.
		runtime.setExtensionTabPlacements(values.sorted {
			($0.placement.windowNumber, $0.placement.index, $0.page.identifier)
			< ($1.placement.windowNumber, $1.placement.index, $1.page.identifier)
		})
	}

	// MARK: - Page registry

	/// The tab showing `page`, for this target's other files too (DEV-1144).
	internal func tabID(of page: ChromiumPage) -> Tab.ID? {
		guard let id = tabIDsByPage[page.identifier], pages[id] === page
		else { return nil }

		return id
	}

	internal func tabID(ofPage identifier: UInt64) -> Tab.ID? {
		tabIDsByPage[identifier]
	}

	/// The tab's Chromium page, for this target's other files (DEV-877).
	internal func chromiumPage(_ id: Tab.ID) -> ChromiumPage? {
		pages[id]
	}

	/// Every tab with a page, for this target's other files (DEV-1020).
	internal var openPageIDs: [Tab.ID] {
		Array(pages.keys)
	}

	/// The tab showing a Chromium page, for this target's other files (DEV-905, DEV-927).
	internal func tabID(ofChromiumPage page: ChromiumPage) -> Tab.ID? {
		tabID(of: page)
	}

	internal func setPage(
		_ page: ChromiumPage,
		for id: Tab.ID
	) {
		if let previous = pages[id], tabIDsByPage[previous.identifier] == id {
			tabIDsByPage[previous.identifier] = nil
		}
		if let previous = pages[id], previous !== page { blankStartPages.remove(previous.identifier) }
		pages[id] = page
		tabIDsByPage[page.identifier] = id
		applyDarkPages(to: id)
	}

	@discardableResult
	internal func removePage(_ id: Tab.ID) -> ChromiumPage? {
		guard let page = pages.removeValue(forKey: id)
		else { return nil }

		if tabIDsByPage[page.identifier] == id {
			tabIDsByPage[page.identifier] = nil
		}
		blankStartPages.remove(page.identifier)
		pageDownloads[id] = nil

		// The page's Cast picker went with it; the engine may not say so for a page it's dropping.
		castPickerContinuation?.yield(.init(tabID: id, picker: nil))

		// So does its hosted permission prompt (DEV-963).
		if hostedPromptTabs.remove(id) != nil { onPagePermissionPrompt?(id, 0) }
		onPageRemoved?(id)
		return page
	}

	// MARK: - Session lifecycle

	public func closeAll() {
		for id in Set(pages.keys).union(pendingOpens.keys) {
			close(id)
		}
		navigationStore?.flush()
	}

	// MARK: - Unread badges (DEV-907)

	/// A page's title changed. A new document's dropping the last one's Badging API badge
	/// comes from the engine, which alone sees which navigations commit a new document.
	internal func pageSettled(
		_ id: Tab.ID,
		_ navigation: ChromiumPage.Navigation
	) {
		guard !navigation.isLoading, navigation.errorCode == nil else { return }

		let settled = (url: navigation.url, title: navigation.title)
		if let last = settledPages[id], last == settled { return }
		settledPages[id] = settled
		onPageSettled?(id, snapshot(navigation, tab: id))
	}

	internal func unreadBadgeNavigated(
		_ id: Tab.ID,
		_ navigation: ChromiumPage.Navigation
	) {
		unreadBadgeChanged(id, title: UnreadBadge(title: navigation.title))
	}

	private func unreadBadgeChanged(
		_ id: Tab.ID,
		app: UnreadBadge?? = nil,
		title: UnreadBadge? = nil
	) {
		let previous = unreadBadges[id]
		var current = previous ?? (app: nil, title: .none)
		if case let .some(app) = app { current.app = app }
		if let title { current.title = title }
		unreadBadges[id] = current

		let shown = current.app ?? current.title
		guard previous.map({ $0.app ?? $0.title }) != shown else { return }

		onUnreadBadge?(id, shown)
	}

	// MARK: - Hosting

	internal func attach(
		_ id: Tab.ID,
		to host: NSView
	) {
		let existing = hosts[id]?.view
		let belongsToAnotherWindow = existing !== host
		&& existing?.window != nil
		&& existing?.window !== host.window
		if belongsToAnotherWindow {
			existing?.window?.makeKeyAndOrderFront(nil)
			return
		}
		for other in Array(hosts.keys) where other != id && hosts[other]?.view === host {
			unmount(other)
			hosts[other] = nil
		}

		// SwiftUI may replace a host within one window before dismantling its old
		// view. Remap first so that old-host teardown cannot detach the replacement.
		hosts[id] = WeakHost(host)
		if staged?.id == id { staged = nil }
		if let page = pages[id] { mount(page, in: host) }
	}

	internal func detach(_ host: NSView) {
		for id in Array(hosts.keys) where hosts[id]?.view === host {
			unmount(id)
			hosts[id] = nil
		}
	}

	/// Moves a page into its host without taking it out of the window on the way.
	///
	/// A page that leaves its window is hidden: Chromium gives up its compositor and shows
	/// nothing when it comes back until it has drawn again, which reads as a blank flash.
	/// So a page that is in a window waits for a windowless host to join one, and is then
	/// moved straight across, which AppKit does without a detour through no window.
	internal func mount(
		_ page: ChromiumPage,
		in host: NSView
	) {
		guard page.view.superview !== host else { return }
		if page.view.window != nil, host.window == nil { return }
		page.view.frame = host.bounds
		page.view.autoresizingMask = [.width, .height]
		host.addSubview(page.view)
		if let id = tabID(of: page) { placeDeveloperTools(id) }
	}

	/// Takes a page, and its docked DevTools, out of their host.
	internal func unmount(_ id: Tab.ID) {
		pages[id]?.view.removeFromSuperview()
		if let docked = dockedDeveloperTools[id], docked.superview != nil { docked.removeFromSuperview() }
	}

	/// ABI42: puts the page's docked DevTools behind the page in the page's host, filling
	/// it, and the page at the bounds DevTools gives it, as Chrome does (DEV-733). Undocked
	/// or closed DevTools leaves the page filling its host. Called whenever the page moves
	/// to a host and whenever the engine reports a change.
	private func placeDeveloperTools(_ id: Tab.ID) {
		guard let page = pages[id] else { return }
		let layout = runtime.developerToolsLayout(for: page)
		let docked = layout?.view

		// A closed frontend has already left its host; its view is only dropped here.
		if let previous = dockedDeveloperTools[id], previous !== docked, previous.superview != nil {
			previous.removeFromSuperview()
		}
		dockedDeveloperTools[id] = docked
		page.view.autoresizingMask = [.width, .height]
		guard let host = page.view.superview else {
			docked?.removeFromSuperview()
			return
		}
		guard let layout, let docked else {
			page.view.frame = host.bounds
			return
		}
		if docked.superview !== host { host.addSubview(docked, positioned: .below, relativeTo: page.view) }
		docked.frame = host.bounds
		docked.autoresizingMask = [.width, .height]
		page.view.frame = layout.pageFrame(in: host.bounds, isFlipped: host.isFlipped)

		// Lets an activation that waited for the view to join a window focus DevTools.
		if docked.window != nil { _ = runtime.developerToolsLayout(for: page) }
	}

	private func isStaged(_ id: Tab.ID) -> Bool {
		guard let staged, staged.id == id, let page = pages[id] else { return false }
		return page.view.superview === staged.stage.view
	}

	/// Keeps a loaded page that's about to be shown, such as a pressed sidebar tab or the space a
	/// swipe is revealing, drawing in the window under the shown one, so showing it needs no new
	/// frame. Chromium treats a staged page as shown, so a mere hover never stages (DEV-941).
	///
	/// A page that's shown, playing media or in Picture in Picture is left where it is. A page
	/// that's no longer wanted leaves a moment later, so a host taking it in the same update
	/// gets it first. An unloaded page (DEV-873) isn't staged: drawing would load it again
	/// before anyone chose it.
	internal func stage(
		_ id: Tab.ID?,
		in stage: NSView
	) {
		if let previous = staged, previous.id != id || previous.stage.view !== stage {
			staged = nil
			Task { @MainActor [weak self] in
				try? await Task.sleep(for: .milliseconds(300))
				guard let self, self.staged?.id != previous.id else { return }
				guard let view = self.pages[previous.id]?.view, view.superview === previous.stage.view
				else { return }
				self.unmount(previous.id)
			}
		}
		guard
			let id,
			staged == nil,
			let page = pages[id],
			stage.window != nil,
			page.view.window == nil || page.view.superview === stage,
			mediaService?.isActive(tabID: id) != true,
			!runtime.isUnloaded(page)
		else { return }

		staged = (id, WeakHost(stage))
		guard page.view.superview !== stage else { return }
		page.view.frame = stage.bounds
		page.view.autoresizingMask = [.width, .height]
		stage.addSubview(page.view)
		placeDeveloperTools(id)
	}

	/// The page's navigation for the app: why its renderer last ended and whether it keeps
	/// ending, from every page's ends (DEV-1016), and the transfer that navigation became while
	/// the tab has no page of its own (DEV-1116). A committed page forgets the transfer; a
	/// navigation that is only pending, or was stopped, doesn't.
	internal func snapshot(
		_ value: ChromiumPage.Navigation,
		tab: Tab.ID
	) -> BrowserNavigation {
		var navigation = Self.snapshot(value)
		navigation.download = pageDownload(value, tab: tab)
		navigation.hasNoPage = runtime.supportsDocumentTypes && pages[tab].map { hasNoPage($0, value) } == true
		guard let end = value.rendererEnd else { return navigation }
		let now = ProcessInfo.processInfo.systemUptime
		let source = pages[tab]?.identifier ?? 0
		let changed = rendererEnds.record(
			tab: tab,
			page: source,
			number: end.number,
			at: now,
			counts: !end.endedByEngine
		)
		if !changed.isEmpty { republish(changed) }
		navigation.rendererEnd = .init(
			cause: Self.cause(end),
			number: end.number,
			exitCode: end.exitCode,
			isShared: rendererEnds.isShared(tab: tab, page: source, number: end.number),
			isRepeated: rendererEnds.isRepeated(tab: tab, at: now)
		)
		return navigation
	}

	/// Ends the page's renderer and notes it, so the next command waits for the end.
	@discardableResult
	internal func endRenderer(
		_ id: Tab.ID,
		_ page: ChromiumPage
	) -> Bool {
		let ending = EndingRenderer(
			end: page.navigation.rendererEnd?.number ?? 0,
			wasUnresponsive: page.navigation.unresponsive != 0
		)
		guard runtime.endRenderer(page) else { return false }
		endingRenderers[id] = ending
		return true
	}

	/// Waits, at most two seconds, until the page reports the renderer the engine ended gone:
	/// a new end, or, for a hung out-of-process frame's renderer, the hang over. Chromium's
	/// Shutdown only signals the process, and a navigation sent before its end is cancelled.
	/// A cancelled caller stops waiting, and its command doesn't run. The marker stays until
	/// the end is seen or the wait runs out, so every command meanwhile waits for it too.
	internal func settleEndedRenderer(
		_ id: Tab.ID,
		_ page: ChromiumPage
	) async throws {
		guard let ending = endingRenderers[id] else { return }
		let deadline = ContinuousClock.now + .seconds(2)
		while ContinuousClock.now < deadline, pages[id] === page {
			let navigation = page.navigation
			if (navigation.rendererEnd?.number ?? 0) != ending.end
				|| (ending.wasUnresponsive && navigation.unresponsive == 0) {
				break
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		if endingRenderers[id]?.id == ending.id { endingRenderers[id] = nil }
	}

	/// Tells the pages whose earlier end another page's end just made shared, after this read
	/// returns (DEV-1016).
	private func republish(_ tabs: Set<Tab.ID>) {
		Task { @MainActor [weak self] in
			guard let self else { return }
			for id in tabs {
				guard let page = self.pages[id] else { continue }
				let navigation = self.snapshot(page.navigation, tab: id)
				for observer in self.observers[id, default: [:]].values { observer.yield(navigation) }
			}
		}
	}

	/// A page's colors changed alone (DEV-1101): its observers hear the new snapshot, and its session
	/// revision, saved navigation and settling stay as they were, so menus and references stay current.
	/// The snapshot is the tab's own, so a tab showing its transfer keeps showing it (DEV-1116).
	internal func observeColors(
		of page: ChromiumPage,
		tab id: Tab.ID
	) {
		page.onColors = { [weak self, weak page] navigation in
			guard let self, let page, self.pages[id] === page else { return }

			let snapshot = self.snapshot(navigation, tab: id)
			for observer in self.observers[id, default: [:]].values {
				observer.yield(snapshot)
			}
		}
	}

	private static func cause(_ end: ChromiumPage.RendererEnd) -> BrowserNavigation.RendererEnd.Cause {
		if end.endedByEngine { return .endedByArx }
		return switch end.status {
		case .crashed, .abnormal: .crashed
		case .outOfMemory: .outOfMemory
		case .killed: .killed
		case .launchFailed: .launchFailed
		case .normal, .other: .other
		}
	}

	internal static func snapshot(_ value: ChromiumPage.Navigation) -> BrowserNavigation {
		.init(
			url: value.url,
			title: value.title,
			isLoading: value.isLoading,
			errorCode: value.errorCode,
			authenticationCancelled: value.authenticationCancellations > 0,
			cancelledSignInPrompts: signInPrompts(value.userActionRequests),
			findResult: value.findResult.map { .init(matches: $0.matches, active: $0.active) },
			canGoBack: value.canGoBack,
			canGoForward: value.canGoForward,
			history: value.history.map {
				.init(
					id: $0.id,
					url: $0.url,
					title: $0.title,
					isCurrent: $0.isCurrent
				)
			},
			isUnloaded: value.isUnloaded,
			unresponsive: value.unresponsive,
			document: value.document,
			colors: .init(themeARGB: value.colors.theme, backgroundARGB: value.colors.background)
		)
	}

	/// DEV-873. Unloads a tab's page that no window, Peek or Little Arx shows, as the engine's
	/// rules allow.
	internal func unloadTab(
		_ id: Tab.ID,
		reason: TabUnloadReason
	) -> TabUnloadOutcome {
		// A page still opening can't unload yet; a window-close release asks again (DEV-1104).
		guard pendingOpens[id] == nil else { return .busy }
		guard let page = pages[id] else { return .unavailable }

		// A mounted page is drawing, or about to be (the staged one); the engine checks the
		// native visibility too.
		guard page.view.window == nil else { return .kept }

		// Its music plays through Arx's FairPlay helper (DEV-1144), as audible as a Chromium page.
		guard playsOutsideChromium?(id) != true else { return .kept }

		let native: ChromiumPageUnloadReason = switch reason {
		case .inactive: .inactive
		case .memoryPressure: .memoryPressure
		case .windowClosed: .windowClosed
		case .windowClosedAnswered: .windowClosedAnswered
		}
		return switch runtime.unload(page, reason: native) {
		case .unloaded: .unloaded
		case .alreadyUnloaded: .alreadyUnloaded
		case .refused: .kept
		case .busy: .busy
		case .unavailable: .unavailable
		}
	}

	/// DEV-1107. Whether the tab's page holds unsaved input that closing the window holding it
	/// would keep loaded, so the window asks the page before it goes. False for a page still
	/// opening, and with an engine that can't unload an answered page.
	internal func tabHoldsUnsavedInput(_ id: Tab.ID) -> Bool {
		guard
			pendingOpens[id] == nil,
			runtime.supportsAnsweredUnloads,
			let page = pages[id],
			let blockers = runtime.unloadBlockers(page, reason: .windowClosed)
		else { return false }

		return blockers.contains(.unsavedInput)
	}
}

extension ChromiumBrowserEngine {
	private static func signInPrompts(
		_ requests: ChromiumPage.UserActionRequests
	) -> BrowserNavigation.SignInPrompts {
		var prompts: BrowserNavigation.SignInPrompts = []
		if requests.contains(.webAuthentication) { prompts.insert(.webAuthentication) }
		if requests.contains(.federatedSignIn) { prompts.insert(.federatedSignIn) }
		return prompts
	}
}
