import AppKit
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import OSLog
import WebKit

/// Shows each tab in Chromium or WebKit (DEV-877) behind the app's one engine client.
///
/// A tab opens in WebKit when its address is on Settings › Advanced › WebKit's list, and moves
/// there when it's typed or followed to a listed site, chosen in the site menu or accepted from
/// the fallback prompt. Moving closes the tab's Chromium page, so nothing reaches a document
/// the tab no longer shows; Back from WebKit's first entry opens the Chromium page's address
/// again. Every other client call goes to Chromium, which has no page for a WebKit tab.
///
/// A Chromium page that reaches a listed site some other way (a link within the site, a
/// redirect, a script, Back and Forward) moves to WebKit once it shows the site's address or
/// asks for protected media there (DEV-1000). A page the router itself showed in Chromium at a
/// listed site stays there until it leaves that site.
@MainActor
public final class PageEngineRouter {
	private let chromium: BrowserEngineClient
	private let chromiumSurface: BrowserSurfaceClient
	public let pages: WebKitPages

	/// The current list and switch from Settings.
	public var preferences: @MainActor () -> WebKitPagePreferences = { .init() }

	/// A site's cookies from Chromium's store for the profile, or from the tab's own Chromium
	/// page when it has one. Empty when they can't be read.
	public var siteCookies: @MainActor (Profile.ID, Tab.ID?, URL) async -> [HTTPCookie] = { _, _, _ in [] }

	/// How long a move waits for the cookies before loading without them.
	public var cookieTimeLimit: Duration = .seconds(2)

	/// A WebKit page asked for a new window. The app opens a tab, which `open` puts in WebKit.
	/// The flag is true when the page asked on its own, with no modifier key, middle button or
	/// popup size, so a Favorite's or pinned tab's link settings apply (DEV-1312).
	public var onNewTab: (@MainActor (Tab.ID, URL, Bool) -> Void)?

	private var engines: [Tab.ID: PageEngine] = [:]
	private var tabs: [Tab.ID: Tab] = [:]
	private var revisions: [Tab.ID: UInt64] = [:]

	/// Each tab's moves and navigations: a move that waited for cookies goes ahead only if
	/// nothing newer started meanwhile.
	private var generations: [Tab.ID: UInt64] = [:]

	/// Where Back from WebKit's first entry goes: the Chromium page the tab moved from.
	private var returnURLs: [Tab.ID: URL] = [:]

	/// The listed site each tab was shown in Chromium at, by Back or a move to Chromium: it
	/// stays in Chromium until it leaves that site (DEV-1000).
	private var keptInChromium: [Tab.ID: ChromiumKeeping] = [:]

	/// Tabs the router is moving to WebKit on its own, so later events don't start another move.
	private var followingListedSites: Set<Tab.ID> = []

	/// For a page the router moved on its own: the address before the listed site, where Back
	/// from WebKit's first entry lands (DEV-1000).
	private var previousURLs: [Tab.ID: URL] = [:]

	/// Chromium pages reopened at a listed site by Back that then step back to this address,
	/// once they report a committed one. Reopening at the listed address keeps the history.
	private var pendingStepsBack: [Tab.ID: URL] = [:]

	/// How many entries back those pages step, when not one; negative steps forward (DEV-1293).
	private var pendingStepCounts: [Tab.ID: Int] = [:]

	/// How many entries back from `returnURLs` the page Back reopens steps to `previousURLs`, when
	/// not one; negative steps forward (DEV-1293).
	private var returnSteps: [Tab.ID: Int] = [:]

	/// The WebKit page Back from its first entry left, ahead of the Chromium page it reopened:
	/// Forward from there shows it again (DEV-1293).
	private var webKitAhead: [Tab.ID: SharedHistory.WebKitNeighbor] = [:]

	/// The WebKit page the tab left for an address off the list, behind the Chromium page it
	/// opened: Back from there shows it again (DEV-1293).
	private var webKitBehind: [Tab.ID: SharedHistory.WebKitNeighbor] = [:]

	/// What each Chromium page's own swipe was last told about the WebKit pages beside it.
	private var sharedSwipes: [Tab.ID: (back: Bool, forward: Bool)] = [:]
	private var privateProfiles: Set<Profile.ID> = []

	/// Addresses a WebKit page asked to open in a new tab; the next tab opening one goes to WebKit.
	private var inheritedWebKitURLs: [URL] = []
	private var hosts: [Tab.ID: WeakView] = [:]
	private var observers: [Tab.ID: [UUID: AsyncStream<BrowserNavigation>.Continuation]] = [:]
	private var forwarders: [Tab.ID: Task<Void, Never>] = [:]
	private var changeObservers: [UUID: AsyncStream<PageEngineChange>.Continuation] = [:]
	private var mediaObservers: [UUID: AsyncStream<ProtectedMediaRequest>.Continuation] = [:]

	public init(
		chromium: BrowserEngineClient,
		chromiumSurface: BrowserSurfaceClient,
		pages: WebKitPages
	) {
		self.chromium = chromium
		self.chromiumSurface = chromiumSurface
		self.pages = pages
	}

	// MARK: - Clients

	public var client: BrowserEngineClient {
		var client = chromium
		client.snapshot = { [self] id in snapshot(id) }
		client.open = { [self] tab in try await open(tab) }
		client.openAuthorized = { [self] tab, authorize in
			guard authorize() else { throw AutomationFailure.denied }
			try await open(tab, authorize: authorize)
		}
		client.command = { [self] id, command in try await self.command(id, command) }
		client.commandAuthorized = { [self] id, revision, command, authorize in
			guard engine(id) == .webKit else {
				// Back or Forward to the WebKit page beside this one (DEV-1293), for the session
				// the caller saw.
				if crossesToWebKit(id, command) {
					guard authorize() else { throw AutomationFailure.denied }
					guard chromium.snapshot(id)?.revision == revision else { throw AutomationFailure.staleTarget }

					// Still allowed, for the page the caller saw, once the move has waited.
					let stillAuthorized: @MainActor @Sendable () -> Bool = { [weak self] in
						authorize() && self?.chromium.snapshot(id)?.revision == revision
					}
					guard await crossToWebKit(id, command, authorize: stillAuthorized) else {
						try Task.checkCancellation()
						throw AutomationFailure.denied
					}
					return
				}
				if Self.navigates(command) { advance(id) }
				return try await chromium.commandAuthorized(id, revision, command, authorize)
			}

			// A WebKit page takes the history menu's and the toolbar's navigation, for the
			// session the caller saw; nothing that reads or acts inside the page.
			guard Self.navigates(command) || command == .stop
			else { throw BrowserEngineClient.Failure.unavailable }
			guard authorize() else { throw AutomationFailure.denied }
			guard revisions[id, default: 0] == revision else { throw AutomationFailure.staleTarget }
			try await self.command(id, command)
		}
		if let chromiumClose = chromium.closeAuthorized {
			client.closeAuthorized = { [self] id, revision, authorize, didClose in
				guard engine(id) == .webKit else {
					// The router forgets the tab with Chromium's disposal, before the caller hears of it.
					return try await chromiumClose(id, revision, authorize) { [self] in
						forget(id)
						didClose()
					}
				}
				guard authorize() else { throw AutomationFailure.denied }

				// The session the caller saw: a WebKit page that navigated since is another target.
				guard let revision, revisions[id, default: 0] == revision
				else { throw AutomationFailure.staleTarget }
				close(id)
				didClose()
				return true
			}
		}

		// WebKit has no public way to run a page's before-unload, so a WebKit page always closes.
		client.permitsClosing = { [self] id in
			engine(id) == .webKit ? true : await chromium.permitsClosing(id)
		}
		client.close = { [self] id in close(id) }
		client.events = { [self] id in events(id) }
		client.preparePrivateProfile = { [self] profile, opener in
			privateProfiles.insert(profile)
			try chromium.preparePrivateProfile(profile, opener)
		}
		client.releasePrivateProfile = { [self] profile in
			chromium.releasePrivateProfile(profile)
			privateProfiles.remove(profile)
			pages.releasePrivateProfile(profile)
		}
		client.unloadTab = { [self] id, reason in
			guard engine(id) == .webKit else { return chromium.unloadTab(id, reason) }

			// WebKit can't unload a page in place. With no window showing it, it stops playing
			// (DEV-1104).
			if
				reason == .windowClosed || reason == .windowClosedAnswered,
				let page = pages.page(id),
				page.webView.window == nil
			{
				page.webView.pauseAllMediaPlayback(completionHandler: nil)
			}
			return .kept
		}

		// WebKit pages never unload, so a closing window has nothing to ask them (DEV-1107).
		client.tabHoldsUnsavedInput = { [self] id in
			engine(id) != .webKit && chromium.tabHoldsUnsavedInput(id)
		}

		// WebKit's own picture in picture isn't the engine's; its paused media ends it (DEV-1128).
		client.endPictureInPicture = { [self] id in
			guard engine(id) != .webKit else { return }
			chromium.endPictureInPicture(id)
		}
		client.pageZoom = { [self] id in
			engine(id) == .webKit ? pages.page(id)?.zoom : chromium.pageZoom(id)
		}
		client.setPageZoom = { [self] id, factor in
			guard engine(id) == .webKit else { return chromium.setPageZoom(id, factor) }
			guard let page = pages.page(id) else { return nil }
			page.webView.pageZoom = CGFloat(factor == 0 ? 1 : factor)
			return page.zoom
		}
		client.documentType = { [self] id in
			engine(id) == .webKit ? .web : chromium.documentType(id)
		}
		client.pageDialog = { [self] id in
			engine(id) == .webKit ? nil : chromium.pageDialog(id)
		}

		// Site permission prompts the app draws (DEV-963) come only from Chromium pages.
		client.pagePermissionPrompt = { [self] id, token in
			engine(id) == .webKit ? nil : chromium.pagePermissionPrompt(id, token)
		}
		client.answerPagePermissionPrompt = { [self] id, token, decision, accuracy in
			engine(id) == .webKit ? .stale : chromium.answerPagePermissionPrompt(id, token, decision, accuracy)
		}
		client.focusedLink = { [self] id in
			engine(id) == .webKit ? nil : await chromium.focusedLink(id)
		}

		// WebKit pages have no all-frames check; the app keeps its own script for them (DEV-1084).
		client.formEdits = { [self] id in
			engine(id) == .webKit ? nil : await chromium.formEdits(id)
		}

		// A WebKit page's data goes with the profile's and the site's (DEV-877).
		client.clearBrowsingData = { [self] profile, kinds, since throws(ProfileDataFailure) in
			let remaining = try await chromium.clearBrowsingData(profile, kinds, since)
			await pages.clearData(of: profile, isPrivate: privateProfiles.contains(profile), kinds: kinds, since: since)
			return remaining
		}
		client.clearSiteData = { [self] profile, url, kinds throws(ProfileDataFailure) in
			let remaining = try await chromium.clearSiteData(profile, url, kinds)
			let site = (try? await chromium.siteDataScope(profile, url)) ?? url.host() ?? ""
			await pages.clearData(of: profile, isPrivate: privateProfiles.contains(profile), kinds: kinds, site: site)
			return remaining
		}
		client.retireProfile = { [self] request, authorize in
			let snapshot = try await chromium.retireProfile(request, authorize)
			await pages.removeData(of: request.profileID)
			return snapshot
		}
		return client
	}

	public var surface: BrowserSurfaceClient {
		.init(
			attach: { [self] id, host in attach(id, to: host) },
			detach: { [self] host in detach(host) },
			stage: { [self] id, stage in

				// A WebKit page draws as soon as it's shown; only Chromium pages are staged.
				chromiumSurface.stage(id.flatMap { engine($0) == .chromium ? $0 : nil }, stage)
			},
			release: { [self] id in
				if let view = pages.page(id)?.webView, view.superview === hosts[id]?.view {
					view.removeFromSuperview()
				}
				hosts[id] = nil
				chromiumSurface.release(id)
			},
			focus: { [self] id in
				guard engine(id) == .webKit else { return chromiumSurface.focus(id) }
				guard let view = pages.page(id)?.webView else { return }
				view.window?.makeFirstResponder(view)
			},
			bindUnhandledEscape: { [chromiumSurface] id, host, handler in
				chromiumSurface.bindUnhandledEscape(id, host, handler)
			}
		)
	}

	public var pageEngines: PageEngineClient {
		.init(
			engine: { [self] id in engine(id) },
			move: { [self] id, engine, url in await move(id, to: engine, url: url) },
			protectedMediaRequests: { [self] in protectedMediaRequests() },
			changes: { [self] in changes() },
			// DEV-1199: Print and Save As are WebKit's own on a WebKit page.
			printWebKitPage: { [self] id, title in
				guard engine(id) == .webKit, let page = pages.page(id)
				else { throw BrowserEngineClient.Failure.unavailable }

				try await page.print(title: title)
			},
			saveWebKitPage: { [self] id, address, destination, format in
				guard engine(id) == .webKit, let page = pages.page(id)
				else { throw BrowserEngineClient.Failure.unavailable }

				try await page.save(address, to: destination, as: format)
			}
		)
	}

	public func engine(_ id: Tab.ID) -> PageEngine {
		engines[id] ?? .chromium
	}

	/// Chromium reported a page whose protected media failed. A listed site's page the router
	/// missed moves to WebKit, as it would have when it loaded (DEV-1000). Any other goes to the
	/// app, which offers WebKit with a prompt: a streaming site's video falls back to WebKit, never
	/// silently, so a page kept in Chromium at a listed site, such as Netflix after Back, is asked
	/// too (DEV-1188). A likely bot check never gets here: the engine answers it as Chrome does
	/// and reports nothing (DEV-1205).
	public func protectedMediaRequested(_ request: ProtectedMediaRequest) {
		let tab = String(request.tabID.rawValue.uuidString.prefix(8))
		guard engine(request.tabID) == .chromium else {
			log.info("Tab \(tab, privacy: .public): protected media failed in a page WebKit shows already")
			return
		}
		if followListedSite(request.tabID, at: request.url) {
			log.notice("Tab \(tab, privacy: .public): protected media failed in Chromium at a listed site it shows; moving the page to WebKit")
			return
		}
		log.notice("Tab \(tab, privacy: .public): protected media failed in Chromium on a page that isn't moved; asking the app")
		for observer in mediaObservers.values { observer.yield(request) }
	}

	// MARK: - Sessions

	private func open(
		_ tab: Tab,
		authorize: @escaping @MainActor @Sendable () -> Bool = { true }
	) async throws {
		tabs[tab.id] = tab
		switch engines[tab.id] {
		case .webKit:
			if pages.page(tab.id) != nil { return }
			engines[tab.id] = nil
			try await open(tab, authorize: authorize)

		case .chromium:
			try await chromium.openAuthorized(tab, authorize)

		case nil:
			let url = tab.reopeningURL
			let inherited = inheritedWebKitURLs.firstIndex(of: url)
			if let inherited { inheritedWebKitURLs.remove(at: inherited) }
			let opensInWebKit = preferences().opensInWebKit(url)
			|| (inherited != nil && preferences().isEnabled && url.hasWebScheme)
			guard opensInWebKit else {
				engines[tab.id] = .chromium
				ensureForwarder(tab.id)
				try await chromium.openAuthorized(tab, authorize)
				return
			}
			guard authorize() else { throw AutomationFailure.denied }
			let generation = advance(tab.id)
			guard await showWebKit(tab, url: url, from: nil, returnURL: nil, generation: generation, authorize: authorize)
			else {
				try Task.checkCancellation()
				throw AutomationFailure.denied
			}
		}
	}

	/// Whether a command changes the tab's document.
	private static func navigates(_ command: BrowserEngineClient.Command) -> Bool {
		switch command {
		case .navigate, .back, .forward, .historyEntry, .reload, .clearCacheAndReload, .reloadBypassingCache: true
		default: false
		}
	}

	/// Starts a newer operation on the tab; older ones waiting for cookies give up.
	@discardableResult
	private func advance(_ id: Tab.ID) -> UInt64 {
		// Something newer drives the page: a step back that hasn't happened yet is dropped.
		pendingStepsBack[id] = nil
		pendingStepCounts[id] = nil
		generations[id, default: 0] &+= 1
		return generations[id, default: 0]
	}

	private func command(
		_ id: Tab.ID,
		_ command: BrowserEngineClient.Command
	) async throws {
		guard engine(id) == .webKit, let page = pages.page(id) else {
			// A typed address on the list moves the page; when the page refuses to leave
			// (unsaved input), it stays where it is, as a refused navigation would.
			if case let .navigate(url) = command, tabs[id] != nil, preferences().opensInWebKit(url) {
				await move(id, to: .webKit, url: url)
				return
			}
			if crossesToWebKit(id, command) {
				await crossToWebKit(id, command)
				return
			}

			// A navigation of its own supersedes a move still waiting for cookies.
			if Self.navigates(command) { advance(id) }
			return try await chromium.command(id, command)
		}

		advance(id)
		switch command {
		case let .navigate(url):
			// A typed address picks its engine by the list, as a new tab would.
			if url.hasWebScheme, !preferences().opensInWebKit(url) {
				_ = await move(id, to: .chromium, url: url)
			} else {
				page.load(url)
			}

		case .back: page.goBack()

		case .forward: page.goForward()

		case .reload: page.reload(bypassingCache: false)

		case .clearCacheAndReload, .reloadBypassingCache: page.reload(bypassingCache: true)

		case .stop: page.stop()

		case let .historyEntry(entry): page.goToEntry(entry)

		case let .find(text, forward, _): await page.find(text, forward: forward)

		case .stopFind: page.stopFind()

		case let .zoom(step): page.zoom(step)

		case .exitFullScreen: page.exitFullScreen()

		case .openDeveloperTools, .toggleDeveloperTools, .showDeveloperToolsPanel, .inspectElementMode:
			throw BrowserEngineClient.Failure.unavailable
		}
	}

	private func close(_ id: Tab.ID) {
		chromium.close(id)
		forget(id)
	}

	/// Drops the tab's WebKit page and everything the router knew of it; Chromium's side is
	/// the caller's.
	private func forget(_ id: Tab.ID) {
		let wasWebKit = engine(id) == .webKit
		pages.close(id)
		engines[id] = nil
		tabs[id] = nil
		revisions[id] = nil
		returnURLs[id] = nil
		previousURLs[id] = nil
		returnSteps[id] = nil
		pendingStepsBack[id] = nil
		pendingStepCounts[id] = nil
		webKitAhead[id] = nil
		webKitBehind[id] = nil
		sharedSwipes[id] = nil
		keptInChromium[id] = nil
		followingListedSites.remove(id)
		advance(id)
		hosts[id] = nil
		forwarders.removeValue(forKey: id)?.cancel()
		for observer in observers.removeValue(forKey: id)?.values ?? [:].values {
			observer.finish()
		}
		if wasWebKit { announce(id, .chromium) }
	}

	private func snapshot(_ id: Tab.ID) -> BrowserSessionSnapshot? {
		guard engine(id) == .webKit else {
			guard var snapshot = chromium.snapshot(id) else { return nil }
			snapshot.navigation = joined(snapshot.navigation, for: id)
			return snapshot
		}
		guard let page = pages.page(id) else { return nil }

		// No document revision: agents' document-bound reads and actions refuse WebKit pages.
		return .init(
			navigation: page.navigation,
			revision: revisions[id, default: 0],
			documentRevision: nil,
			isVisibleForCapture: false,
			nativePageID: nil,
			nativeProfileID: page.profileID
		)
	}

	// MARK: - Moving between engines

	/// Moves the tab's page to `engine`, loading `url` (its current address when nil).
	@discardableResult
	public func move(
		_ id: Tab.ID,
		to engine: PageEngine,
		url: URL?
	) async -> Bool {
		await move(id, to: engine, url: url, followsSite: false)
	}

	/// `followsSite`: the Chromium page itself reached the listed site at `url`, so Back from
	/// WebKit's first entry returns to the page before it rather than to that address.
	private func move(
		_ id: Tab.ID,
		to engine: PageEngine,
		url: URL?,
		followsSite: Bool
	) async -> Bool {
		guard let tab = tabs[id] else { return false }
		switch (self.engine(id), engine) {
		case (.chromium, .webKit):
			guard preferences().isEnabled else { return false }
			let current = chromium.snapshot(id)?.navigation
			let target = url ?? current?.url ?? tab.reopeningURL
			guard target.hasWebScheme else { return false }

			// A page that reached the listed site itself goes Back to the page before it, by
			// reopening its history at the listed address and stepping back; with none, Back
			// from WebKit has nowhere to go.
			let previous = followsSite ? current?.entries(in: .back).first?.url : nil
			let back = followsSite && previous == nil ? nil : current?.url
			let generation = advance(id)

			// The page's before-unload asks about unsaved input; a refusal keeps it here.
			guard
				await chromium.permitsClosing(id),
				generations[id] == generation
			else { return false }
			return await showWebKit(
				tab,
				url: target,
				from: current?.url,
				returnURL: back,
				previousURL: previous,
				generation: generation
			)

		case (.webKit, .chromium):
			let target = url ?? pages.page(id)?.navigation.url ?? tab.reopeningURL
			let session = pages.page(id).map { webKitSession(of: $0, for: id) }
			advance(id)
			showChromium(id, url: target)

			// Back from the Chromium page shows the WebKit page again (DEV-1293).
			if let session { webKitBehind[id] = .init(session: session, side: .behind) }
			return true

		default:
			if let url { try? await command(id, .navigate(url)) }
			return url != nil
		}
	}

	/// Shows `url` in a WebKit page for the tab, once the site's cookies are copied. False when
	/// a newer operation, closing the tab or the authorization stopped it first.
	///
	/// `from` is the address of the Chromium page the tab moves from, nil for a new tab;
	/// `returnURL` is where Back from WebKit's first entry reopens Chromium, nil for nowhere,
	/// and `previousURL` the address it then steps back to, if any. `restoring` is the history a
	/// WebKit page the tab left had, shown at the entry `offset` from the one it showed, and
	/// `forward` the Chromium page Forward from its last entry returns to (DEV-1293).
	@discardableResult
	private func showWebKit(
		_ tab: Tab,
		url: URL,
		from: URL?,
		returnURL: URL?,
		previousURL: URL? = nil,
		returnStepCount: Int = 1,
		restoring: (session: SharedHistory.WebKitSession, offset: Int)? = nil,
		forward: SharedHistory.ChromiumPage? = nil,
		generation: UInt64,
		authorize: @escaping @MainActor @Sendable () -> Bool = { true }
	) async -> Bool {
		let isPrivate = privateProfiles.contains(tab.profileID)
		let cookies = await withCookieTimeLimit {
			await self.siteCookies(tab.profileID, from == nil ? nil : tab.id, url)
		}
		guard isCurrent(tab.id, generation, authorize, from) else { return false }
		await pages.importCookies(cookies, profileID: tab.profileID, isPrivate: isPrivate)
		guard isCurrent(tab.id, generation, authorize, from) else { return false }

		// Nothing reaches a Chromium document the tab no longer shows, an adopted one included;
		// Back opens the address it moved from.
		if chromium.snapshot(tab.id) != nil { chromium.close(tab.id) }

		// That page's events end; reopening one subscribes afresh.
		forwarders.removeValue(forKey: tab.id)?.cancel()
		returnURLs[tab.id] = returnURL
		previousURLs[tab.id] = previousURL
		returnSteps[tab.id] = returnStepCount == 1 ? nil : returnStepCount
		keptInChromium[tab.id] = nil

		// The Chromium page's neighbors go with it.
		webKitAhead[tab.id] = nil
		webKitBehind[tab.id] = nil
		let page = pages.make(tab, isPrivate: isPrivate, returnsToChromium: returnURL != nil)
		page.onNavigation = { [weak self] navigation in self?.publish(navigation, for: tab.id) }

		// A color-only change (DEV-1101) reaches observers without moving the session's revision.
		page.onColors = { [weak self] navigation in self?.yield(navigation, for: tab.id) }
		page.onNewTab = { [weak self] url, isPageRequest in
			guard let self else { return }
			self.inheritedWebKitURLs.append(url)
			self.onNewTab?(tab.id, url, isPageRequest)
		}
		page.onReturnToChromium = { [weak self] in self?.returnToChromium(tab.id) }
		page.onForwardToChromium = { [weak self] in self?.forwardToChromium(tab.id) }

		// Back from WebKit lands on the page before the listed site when there is one.
		page.chromiumReturnTitle = (previousURL ?? returnURL).flatMap { $0.host() ?? $0.absoluteString } ?? ""
		page.chromiumReturnURL = previousURL ?? returnURL

		// Arx's swipe asks the router where Back and Forward go, and goes there as ⌘[ and ⌘] do,
		// so a swipe back from the first WebKit entry reopens the Chromium page (DEV-1203).
		if let swipe = page.historySwipe {
			swipe.availability = { [weak self] in
				let navigation = self?.snapshot(tab.id)?.navigation
				return (navigation?.canGoBack ?? false, navigation?.canGoForward ?? false)
			}
			swipe.perform = { [weak self] navigation in self?.swipe(tab.id, to: navigation) }
		}
		engines[tab.id] = .webKit
		mount(tab.id)
		pages.contentRules?.apply(
			to: page.webView.configuration.userContentController,
			profile: tab.profileID,
			for: url
		)
		if let restoring {
			page.restore(restoring.session.state, url: url)

			// The Chromium page ahead comes after the last entry before it when the tab left, counted
			// from the one the page shows again until the step to the chosen entry commits.
			page.chromiumForwardEdgeOffset = restoring.session.state == nil
			? 0 : restoring.session.boundary - restoring.session.current
			page.chromiumForward = forward
			if restoring.session.state != nil, restoring.offset != 0 { page.goToEntry(restoring.offset) }
		} else {
			page.load(url)
			page.chromiumForward = forward
		}
		page.publish()
		announce(tab.id, .webKit)
		return true
	}

	/// Whether a move that waited may go ahead: nothing newer started, the tab is open, the
	/// caller still may, and a Chromium page it moves from still shows the same address (the
	/// page itself may have navigated meanwhile).
	private func isCurrent(
		_ id: Tab.ID,
		_ generation: UInt64,
		_ authorize: @MainActor @Sendable () -> Bool,
		_ from: URL?
	) -> Bool {
		guard !Task.isCancelled, tabs[id] != nil, generations[id] == generation, authorize()
		else { return false }

		guard let from else { return true }
		return chromium.snapshot(id)?.navigation.url == from
	}

	/// Back from the first entry of a WebKit page that came from Chromium: reopens that page,
	/// with the WebKit page ahead of it (DEV-1293).
	private func returnToChromium(_ id: Tab.ID) {
		guard engine(id) == .webKit, let back = returnURLs[id] else { return }
		let previous = previousURLs[id]
		let steps = returnSteps[id] ?? 1
		let session = pages.page(id).map { webKitSession(of: $0, for: id) }
		advance(id)
		showChromium(id, url: back, steppingBackTo: previous, steps: steps)
		if let session { webKitAhead[id] = .init(session: session, side: .ahead) }
	}

	/// Forward from the last entry of a WebKit page that Back from Chromium showed: reopens the
	/// Chromium page, with the WebKit page behind it (DEV-1293).
	private func forwardToChromium(_ id: Tab.ID) {
		guard engine(id) == .webKit, let page = pages.page(id), let forward = page.chromiumForward else { return }
		var session = webKitSession(of: page, for: id)

		// The page lists its own entries up to the Chromium page; from an earlier one the jump
		// keeps those between.
		session.boundary = max(session.current, session.entries.count - 1)
		advance(id)
		showChromium(
			id,
			url: forward.reopenURL,
			steppingBackTo: forward.stepsBack > 0 ? forward.url : nil,
			steps: forward.stepsBack
		)
		webKitBehind[id] = .init(session: session, side: .behind)
	}

	/// What a WebKit page the tab leaves has, so Back or Forward can show it again.
	private func webKitSession(
		of page: WebKitPage,
		for id: Tab.ID
	) -> SharedHistory.WebKitSession {
		// Its own entries; the Chromium pages beside them are the router's. A page that hasn't
		// committed one yet is its address.
		var entries = page.navigation.history.filter {
			SharedHistory.aheadIndex($0.id) == nil && SharedHistory.behindIndex($0.id) == nil
		}
		if entries.isEmpty, let url = page.navigation.url {
			entries = [.init(id: 0, url: url, title: page.navigation.title, isCurrent: true)]
		}
		return .init(
			state: page.webView.interactionState,
			entries: entries,
			current: entries.firstIndex(where: \.isCurrent) ?? 0,
			returnURL: returnURLs[id],
			previousURL: previousURLs[id],
			returnSteps: returnSteps[id] ?? 1
		)
	}

	// MARK: - Shared history (DEV-1293)

	/// The Chromium page's navigation with the WebKit pages beside it.
	private func joined(
		_ navigation: BrowserNavigation,
		for id: Tab.ID
	) -> BrowserNavigation {
		guard webKitAhead[id] != nil || webKitBehind[id] != nil else { return navigation }
		return SharedHistory.joined(navigation, behind: webKitBehind[id], ahead: webKitAhead[id])
	}

	/// Whether `command` on the tab's Chromium page goes to the WebKit page beside it: Back or
	/// Forward from the entry it sits next to, or its entry in the history list.
	private func crossesToWebKit(
		_ id: Tab.ID,
		_ command: BrowserEngineClient.Command
	) -> Bool {
		guard engine(id) == .chromium, let navigation = chromium.snapshot(id)?.navigation else { return false }
		switch command {
		case .back:
			return webKitBehind[id].map { $0.isAtAnchor(navigation) } ?? false
		case .forward:
			return webKitAhead[id].map { $0.isAtAnchor(navigation) } ?? false
		case let .historyEntry(entry):
			if let index = SharedHistory.aheadIndex(entry) {
				return webKitAhead[id].map { $0.holds(in: navigation.history) && $0.entries.indices.contains(index) } ?? false
			}
			if let index = SharedHistory.behindIndex(entry) {
				return webKitBehind[id].map { $0.holds(in: navigation.history) && $0.entries.indices.contains(index) } ?? false
			}
			return false
		default:
			return false
		}
	}

	/// Shows the WebKit page beside the Chromium one again, at the entry `command` names. False
	/// when a newer operation, the page or the authorization stopped it.
	@discardableResult
	private func crossToWebKit(
		_ id: Tab.ID,
		_ command: BrowserEngineClient.Command,
		authorize: @escaping @MainActor @Sendable () -> Bool = { true }
	) async -> Bool {
		let (neighbor, index): (SharedHistory.WebKitNeighbor?, Int) = switch command {
		case .back: (webKitBehind[id], 0)
		case .forward: (webKitAhead[id], 0)
		case let .historyEntry(entry):
			if let index = SharedHistory.aheadIndex(entry) {
				(webKitAhead[id], index)
			} else {
				(webKitBehind[id], SharedHistory.behindIndex(entry) ?? 0)
			}
		default: (nil, 0)
		}
		guard let neighbor, let tab = tabs[id], neighbor.entries.indices.contains(index) else { return false }
		return await showWebKit(id, beside: neighbor, at: index, tab: tab, authorize: authorize)
	}

	/// Moves the tab from its Chromium page to the WebKit page beside it, at its entry `index`
	/// entries away. Back from the WebKit page's first entry returns to the Chromium page; one
	/// behind it keeps its own way back, and Forward from its last entry returns here.
	@discardableResult
	private func showWebKit(
		_ id: Tab.ID,
		beside neighbor: SharedHistory.WebKitNeighbor,
		at index: Int,
		tab: Tab,
		authorize: @escaping @MainActor @Sendable () -> Bool = { true }
	) async -> Bool {
		let current = chromium.snapshot(id)?.navigation
		let target = neighbor.entries[index].url
		let generation = advance(id)
		guard
			await chromium.permitsClosing(id),
			generations[id] == generation,
			authorize()
		else { return false }

		let here = current.flatMap(Self.committedAddress(of:)) ?? current?.url
		let anchor = neighbor.anchor.flatMap { anchor in current?.history.first { $0.id == anchor.entryID } }

		// Forward from the WebKit page returns to the Chromium entry beside it, reopening the page
		// where it is now, with its history, and stepping back to that entry.
		let history = current?.history ?? []

		// Negative when the page shows an entry before the anchor.
		let offsetFromAnchor = anchor.flatMap { anchor in
			history.firstIndex(where: \.isCurrent).flatMap { now in
				history.firstIndex(where: { $0.id == anchor.id }).map { now - $0 }
			}
		} ?? 0
		let stepsBack = max(offsetFromAnchor, 0)
		let forward: SharedHistory.ChromiumPage? = switch neighbor.side {
		case .ahead: nil
		case .behind: here.map { here in
			.init(
				url: stepsBack > 0 ? anchor?.url ?? here : here,
				title: stepsBack > 0 ? anchor?.title ?? "" : current?.title ?? "",
				reopenURL: here,
				stepsBack: stepsBack
			)
		}
		}

		// From the entry that stands for the WebKit page, Back returns to the anchor before it, as
		// it did when the page first reached the listed site.
		let atPlaceholder = neighbor.anchor?.neighbors.first != nil
			&& current?.history.first(where: \.isCurrent)?.id == neighbor.anchor?.neighbors.first

		// From an entry before the anchor, Back reopens the page there, with its history, and steps
		// forward to the anchor, so the entries between stay.
		let (returnURL, previousURL, returnStepCount): (URL?, URL?, Int) = switch neighbor.side {
		case .ahead where offsetFromAnchor < 0: (here, anchor?.url, offsetFromAnchor)
		case .ahead: (here, atPlaceholder ? anchor?.url : nil, 1)
		case .behind: (neighbor.session.returnURL, neighbor.session.previousURL, neighbor.session.returnSteps)
		}
		return await showWebKit(
			tab,
			url: target,
			from: current?.url,
			returnURL: returnURL,
			previousURL: previousURL,
			returnStepCount: returnStepCount,
			restoring: (neighbor.session, neighbor.offset(to: index)),
			forward: forward,
			generation: generation,
			authorize: authorize
		)
	}

	/// Notes where the WebKit pages beside the Chromium page sit, once it shows that entry, and
	/// forgets one the page navigated away from. True when the page reached the entry that stands
	/// for the WebKit page ahead, which then shows instead.
	private func followSharedHistory(
		_ navigation: BrowserNavigation,
		for id: Tab.ID
	) -> Bool {
		for side in [SharedHistory.Side.ahead, .behind] {
			guard var neighbor = side == .ahead ? webKitAhead[id] : webKitBehind[id] else { continue }
			if neighbor.anchor == nil {
				guard let anchor = neighbor.anchored(at: navigation) else { continue }
				neighbor.anchor = anchor
			} else if !neighbor.holds(in: navigation.history) {
				if side == .ahead { webKitAhead[id] = nil } else { webKitBehind[id] = nil }
				continue
			}
			if side == .ahead { webKitAhead[id] = neighbor } else { webKitBehind[id] = neighbor }
		}

		// A Chromium page that reached the listed site itself keeps that entry after Back from
		// WebKit; reaching it again, by its own Forward, swipe or history list, shows the WebKit
		// page as it was rather than loading the site in Chromium.
		guard
			let ahead = webKitAhead[id],
			let anchor = ahead.anchor,
			let placeholder = anchor.neighbors.first,
			let entry = Self.currentEntry(of: navigation),
			entry.id == placeholder,
			let tab = tabs[id]
		else { return false }

		Task { [weak self] in await self?.showWebKit(id, beside: ahead, at: 0, tab: tab) }
		return true
	}

	/// Tells the Chromium page's own swipe whether Back or Forward reaches a WebKit page.
	private func updateSharedSwipe(
		_ navigation: BrowserNavigation,
		for id: Tab.ID
	) {
		let back = webKitBehind[id].map { $0.isAtAnchor(navigation) } ?? false
		let forward = webKitAhead[id].map { $0.isAtAnchor(navigation) } ?? false
		guard sharedSwipes[id].map({ $0.back != back || $0.forward != forward }) ?? (back || forward) else { return }
		sharedSwipes[id] = (back, forward)
		chromium.setSharedHistory(id, back, forward)
	}

	/// A swipe on the tab's Chromium page was released toward the WebKit page beside it.
	public func sharedHistorySwiped(
		_ id: Tab.ID,
		forward: Bool
	) {
		let command: BrowserEngineClient.Command = forward ? .forward : .back
		guard crossesToWebKit(id, command) else { return }
		Task { [weak self] in await self?.crossToWebKit(id, command) }
	}

	/// Where a released swipe on a WebKit page goes, by the commands ⌘[, ⌘] and the history
	/// menu send.
	internal func swipe(
		_ id: Tab.ID,
		to navigation: WebKitHistorySwipe.Navigation
	) {
		switch navigation {
		case .returnToChromium:
			returnToChromium(id)

		case .forwardToChromium:
			forwardToChromium(id)

		case .back, .forward, .entry:
			let command: BrowserEngineClient.Command = switch navigation {
			case .back: .back
			case .forward: .forward
			case let .entry(offset): .historyEntry(offset)
			case .returnToChromium: .back
			case .forwardToChromium: .forward
			}
			Task { [weak self] in try? await self?.command(id, command) }
		}
	}

	/// Opens the tab's Chromium page again at `url`, with its saved history when that ends there,
	/// then steps back to `previous` when there is one.
	private func showChromium(
		_ id: Tab.ID,
		url: URL,
		steppingBackTo previous: URL? = nil,
		steps: Int = 1
	) {
		guard var tab = tabs[id] else { return }
		engines[id] = .chromium
		returnURLs[id] = nil
		previousURLs[id] = nil
		returnSteps[id] = nil

		// The caller says which WebKit page, if any, sits beside the reopened one; the page it
		// opens hears of them with its first navigation.
		webKitAhead[id] = nil
		webKitBehind[id] = nil
		sharedSwipes[id] = nil
		pendingStepsBack[id] = previous
		pendingStepCounts[id] = previous == nil || steps == 1 || steps == 0 ? nil : steps

		// Shown here on purpose: a listed address stays in Chromium until the page leaves its site.
		keptInChromium[id] = keeping(id, at: url)
		if let view = pages.page(id)?.webView { view.removeFromSuperview() }
		pages.close(id)
		ensureForwarder(id)
		if let host = hosts[id]?.view { chromiumSurface.attach(id, host) }
		tab.restoration.url = url
		tabs[id] = tab

		// The page opens at `url`, not at a pinned tab's saved address.
		var opening = tab
		opening.savedDestination = nil
		let generation = generations[id, default: 0]
		Task { [weak self, chromium] in

			// A tab that closed or moved on before this ran opens nothing.
			guard let self, self.tabs[id] != nil, self.generations[id] == generation else { return }

			// The page reports its own failure through its events.
			try? await chromium.open(opening)
		}
		announce(id, .chromium)
	}

	private func withCookieTimeLimit(
		_ read: @escaping @MainActor @Sendable () async -> [HTTPCookie]
	) async -> [HTTPCookie] {
		let limit = cookieTimeLimit
		return await withCheckedContinuation { continuation in
			let reply = CookieReply(continuation)
			Task { @MainActor in reply.resume(with: await read()) }
			Task { @MainActor in
				try? await Task.sleep(for: limit)
				reply.resume(with: [])
			}
		}
	}

	/// Moves a Chromium page that shows `url` to WebKit when `url` is a listed site's, unless
	/// the router kept the page in Chromium at that site. True when it starts the move or one
	/// is already under way.
	@discardableResult
	private func followListedSite(
		_ id: Tab.ID,
		at url: URL
	) -> Bool {
		guard engine(id) == .chromium, tabs[id] != nil else { return false }
		if followingListedSites.contains(id) { return preferences().opensInWebKit(url) }
		guard follows(id, to: url) else { return false }

		followingListedSites.insert(id)
		let generation = generations[id, default: 0]
		Task { [weak self] in
			guard let self else { return }

			// Something newer (a typed address, a move) took over, and its own events decide.
			// Otherwise the page moves at the address it has committed by now, which a
			// single-page app or a later navigation may have changed, if that's still listed.
			// Still loading, it's the address that started this, which had committed.
			let shown = self.chromium.snapshot(id)?.navigation
			let committed = shown.flatMap(Self.committedAddress(of:)) ?? (shown?.url == url ? url : nil)
			guard
				self.generations[id, default: 0] == generation,
				let target = committed,
				self.follows(id, to: target)
			else {
				self.followingListedSites.remove(id)
				return
			}

			let moved = await self.move(id, to: .webKit, url: target, followsSite: true)
			self.followingListedSites.remove(id)
			guard !moved, self.engine(id) == .chromium, self.tabs[id] != nil else { return }

			// The page committed another address while the cookies were read: follow that.
			// Still at the target, it refused to leave (unsaved input) or the person took over,
			// and it isn't asked again on this site.
			if let latest = self.committedAddress(in: id), latest != target {
				self.followListedSite(id, at: latest)
			} else if self.chromium.snapshot(id)?.navigation.url == target {
				self.keptInChromium[id] = self.keeping(id, at: target)
			}
		}
		return true
	}

	/// Whether the tab's Chromium page at `url` goes to WebKit: a listed site's address, and not
	/// the site the router kept it at. An address off that site ends the keeping.
	private func follows(
		_ id: Tab.ID,
		to url: URL
	) -> Bool {
		guard !isKept(id, at: url) else { return false }
		return preferences().opensInWebKit(url)
	}

	/// Whether the tab is kept in Chromium at `url`'s site. An address off that site ends the
	/// keeping.
	@discardableResult
	private func isKept(
		_ id: Tab.ID,
		at url: URL
	) -> Bool {
		guard let kept = keptInChromium[id] else { return false }

		let host = WebKitPagePreferences.host(of: url) ?? ""
		if WebKitPagePreferences.covers(kept.site, host: host) || kept.isOpening(url) { return true }

		keptInChromium[id] = nil
		return false
	}

	/// Follows the history entry a kept tab's page shows, while it still loads too. An entry off
	/// the kept site ends the keeping once the page is there: when it has loaded, or when the page
	/// comes back to the site at another entry. Back at the entry it left, as a Back or Forward
	/// stopped before it committed leaves it, the page stays kept (DEV-1063).
	///
	/// The engine reports no commit while a page loads, so a Back that committed another site and
	/// a Forward to this entry before that site finished loading look the same, and keep it too.
	///
	/// A page the router opened to show the site, as a move back to Chromium does, starts at
	/// Chromium's initial `about:blank`: that isn't leaving (DEV-1188).
	private func noteKeptEntry(
		_ id: Tab.ID,
		_ entry: BrowserNavigation.Entry,
		isLoading: Bool
	) {
		guard var keeping = keptInChromium[id], !keeping.isOpening(entry.url) else { return }

		let host = WebKitPagePreferences.host(of: entry.url) ?? ""
		if WebKitPagePreferences.covers(keeping.site, host: host) {
			guard !keeping.isLeaving || keeping.entryID == entry.id else {
				endKeeping(id)
				return
			}
			keeping.entryID = entry.id
			keeping.isLeaving = false

		} else if isLoading {
			keeping.isLeaving = true

		} else {
			endKeeping(id)
			return
		}
		keptInChromium[id] = keeping
	}

	/// Ends keeping the tab in Chromium. The page may already have loaded a listed address its
	/// events showed while it was still kept: it follows that now.
	private func endKeeping(_ id: Tab.ID) {
		keptInChromium[id] = nil
		if let url = committedAddress(in: id) { followListedSite(id, at: url) }
	}

	/// Keeping the tab in Chromium at `url`'s listed site, from the history entry its page shows.
	private func keeping(
		_ id: Tab.ID,
		at url: URL
	) -> ChromiumKeeping? {
		guard let site = preferences().listedSite(for: url) else { return nil }

		var keeping = ChromiumKeeping(site: site)
		keeping.entryID = chromium.snapshot(id).flatMap { Self.currentEntry(of: $0.navigation)?.id }
		return keeping
	}

	/// Back from a followed page's WebKit entry: the Chromium page, reopened at the listed site
	/// with its history, goes back one entry, or to `previous` when its history didn't come back.
	private func stepBack(
		_ id: Tab.ID,
		to previous: URL,
		canGoBack: Bool,
		entry: Int? = nil
	) {
		let generation = generations[id, default: 0]
		Task { [weak self, chromium] in
			guard
				let self,
				self.engine(id) == .chromium,
				self.generations[id] == generation
			else { return }

			let command: BrowserEngineClient.Command = if let entry {
				.historyEntry(entry)
			} else {
				canGoBack ? .back : .navigate(previous)
			}
			try? await chromium.command(id, command)
		}
	}

	/// The tab's Chromium page's committed address.
	private func committedAddress(in id: Tab.ID) -> URL? {
		chromium.snapshot(id).flatMap { Self.committedAddress(of: $0.navigation) }
	}

	/// The navigation's address when its current history entry has it. A navigation the
	/// browser started reports its pending address before it's an entry; a history traversal
	/// (Back, Forward) marks its entry current before it commits.
	nonisolated private static func currentEntryAddress(of navigation: BrowserNavigation) -> URL? {
		currentEntry(of: navigation)?.url
	}

	/// The navigation's current history entry when it has the navigation's address, as
	/// `currentEntryAddress(of:)` takes it.
	nonisolated private static func currentEntry(of navigation: BrowserNavigation) -> BrowserNavigation.Entry? {
		guard
			navigation.errorCode == nil,
			let url = navigation.url,
			let entry = navigation.history.first(where: \.isCurrent),
			entry.url == url
		else { return nil }

		return entry
	}

	/// The navigation's address once the page is there: its current entry's, after loading
	/// stopped, which rules out a history traversal still on its way.
	nonisolated private static func committedAddress(of navigation: BrowserNavigation) -> URL? {
		navigation.isLoading ? nil : currentEntryAddress(of: navigation)
	}

	// MARK: - Presentation

	/// Every window's page area attaches through here, Chromium pages too. As Chromium's surface
	/// does, a page another window shows stays there, and that window comes forward.
	private func attach(
		_ id: Tab.ID,
		to host: NSView
	) {
		if
			let existing = hosts[id]?.view,
			existing !== host,
			let window = existing.window,
			window !== host.window
		{
			window.makeKeyAndOrderFront(nil)
			return
		}
		for (other, weak) in hosts where other != id && weak.view === host {
			hosts[other] = nil
			if let view = pages.page(other)?.webView, view.superview === host { view.removeFromSuperview() }
		}
		hosts[id] = WeakView(host)
		mount(id)
	}

	private func mount(_ id: Tab.ID) {
		guard let host = hosts[id]?.view else { return }
		guard engine(id) == .webKit, let view = pages.page(id)?.webView else {
			chromiumSurface.attach(id, host)
			return
		}

		// Chromium's pages leave this host; the WebKit page fills it.
		chromiumSurface.detach(host)
		guard view.superview !== host else { return }
		view.frame = host.bounds
		view.autoresizingMask = [.width, .height]
		host.addSubview(view)
	}

	private func detach(_ host: NSView) {
		for (id, weak) in hosts where weak.view === host {
			hosts[id] = nil
			if let view = pages.page(id)?.webView, view.superview === host { view.removeFromSuperview() }
		}
		chromiumSurface.detach(host)
	}

	// MARK: - Observation

	private func events(_ id: Tab.ID) -> AsyncStream<BrowserNavigation> {
		let token = UUID()
		let (stream, continuation) = AsyncStream<BrowserNavigation>.makeStream(bufferingPolicy: .bufferingNewest(1))
		observers[id, default: [:]][token] = continuation
		if engine(id) == .webKit, let page = pages.page(id) {
			continuation.yield(page.navigation)
		} else if let snapshot = chromium.snapshot(id) {
			continuation.yield(joined(snapshot.navigation, for: id))
		}
		ensureForwarder(id)
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in self?.observers[id]?[token] = nil }
		}
		return stream
	}

	/// Passes the Chromium page's events on while the tab shows it, and follows its history
	/// entries, none missed, while it's kept at a site.
	private func ensureForwarder(_ id: Tab.ID) {
		guard forwarders[id] == nil else { return }
		let events = chromium.events(id)
		let entries = chromium.entryChanges(id)
		let forwarding = Task { [weak self] in
			for await navigation in events {
				guard let self, !Task.isCancelled else { return }
				self.forward(navigation, for: id)
			}
		}

		// The events keep only the newest: a page that leaves the kept site and comes straight
		// back may show only its return there (DEV-1063).
		let following = Task { [weak self] in
			for await navigation in entries {
				guard let self, !Task.isCancelled else { return }
				self.followEntry(navigation, for: id)
			}
		}
		let task = Task {
			await withTaskCancellationHandler {
				await forwarding.value
				await following.value
			} onCancel: {
				forwarding.cancel()
				following.cancel()
			}
		}
		forwarders[id] = task
		Task { [weak self] in
			await task.value

			// Only this subscription's own entry; a newer one stays.
			if self?.forwarders[id] == task { self?.forwarders[id] = nil }
		}
	}

	private func forward(
		_ navigation: BrowserNavigation,
		for id: Tab.ID
	) {
		guard engine(id) == .chromium else { return }

		// A page Back reopened at the listed site steps back as soon as it shows its entry there
		// (its history has come back by then, or never will), or fails to.
		if let previous = pendingStepsBack[id] {
			yield(joined(navigation, for: id), for: id)
			let reopened = Self.currentEntryAddress(of: navigation)?.hasWebScheme == true
			guard reopened || navigation.errorCode != nil else { return }

			pendingStepsBack[id] = nil
			let steps = pendingStepCounts.removeValue(forKey: id) ?? 1

			// The entry it steps back from isn't where the WebKit page sits beside it.
			let from = Self.currentEntry(of: navigation)?.id
			webKitAhead[id]?.steppedFrom = from
			webKitBehind[id]?.steppedFrom = from
			let target = navigation.history.firstIndex(where: \.isCurrent).flatMap { current in
				navigation.history.indices.contains(current - steps) ? navigation.history[current - steps].id : nil
			}

			// More than one step, or a step forward, goes to that entry, or opens `previous` when the
			// history didn't come back.
			stepBack(id, to: previous, canGoBack: steps == 1 && navigation.canGoBack, entry: steps != 1 ? target : nil)
			return
		}
		if followSharedHistory(navigation, for: id) { return }
		updateSharedSwipe(navigation, for: id)
		yield(joined(navigation, for: id), for: id)

		// A loaded address off the kept site, a local file's too, ends the keeping; only a loaded
		// address moves the page.
		if let url = Self.committedAddress(of: navigation) { followListedSite(id, at: url) }
	}

	/// A change of the Chromium page's current history entry, for keeping it at a site.
	private func followEntry(
		_ navigation: BrowserNavigation,
		for id: Tab.ID
	) {
		guard
			engine(id) == .chromium,
			pendingStepsBack[id] == nil,
			let entry = Self.currentEntry(of: navigation)
		else { return }

		noteKeptEntry(id, entry, isLoading: navigation.isLoading)
	}

	private func publish(
		_ navigation: BrowserNavigation,
		for id: Tab.ID
	) {
		revisions[id, default: 0] &+= 1
		yield(navigation, for: id)
	}

	private func yield(
		_ navigation: BrowserNavigation,
		for id: Tab.ID
	) {
		for observer in observers[id, default: [:]].values { observer.yield(navigation) }
	}

	private func announce(
		_ id: Tab.ID,
		_ engine: PageEngine
	) {
		for observer in changeObservers.values { observer.yield(.init(tabID: id, engine: engine)) }
	}

	private func changes() -> AsyncStream<PageEngineChange> {
		let token = UUID()
		let (stream, continuation) = AsyncStream<PageEngineChange>.makeStream()
		changeObservers[token] = continuation
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in self?.changeObservers[token] = nil }
		}
		return stream
	}

	private func protectedMediaRequests() -> AsyncStream<ProtectedMediaRequest> {
		let token = UUID()
		let (stream, continuation) = AsyncStream<ProtectedMediaRequest>.makeStream()
		mediaObservers[token] = continuation
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in self?.mediaObservers[token] = nil }
		}
		return stream
	}
}

/// A listed site a tab is kept in Chromium at (DEV-1000), and where its page is in its history.
private struct ChromiumKeeping {
	/// The listed site, as the list names it.
	internal var site: String

	/// The history entry the page last showed at the site.
	internal var entryID: Int?

	/// The page showed an entry off the site while loading: a Back or Forward on its way, or a
	/// page that committed and still loads. Which of them shows when it loads or comes back.
	internal var isLeaving: Bool

	internal init(site: String) {
		self.site = site
		self.entryID = nil
		self.isLeaving = false
	}

	/// Whether `url` is the empty document a page the router opened shows before its first entry
	/// at the site: Chromium's initial `about:blank`. A move back to Chromium opens a new page, and
	/// that entry, loading or loaded, isn't the page leaving the site, so it ends no keeping
	/// (DEV-1188). Once the page has shown an entry at the site, an `about:` page is leaving it.
	internal func isOpening(_ url: URL) -> Bool {
		entryID == nil && url.scheme?.lowercased() == "about"
	}
}

/// Resumes a cookie read once: with the cookies, or with none when the time limit wins.
@MainActor
private final class CookieReply {
	private var continuation: CheckedContinuation<[HTTPCookie], Never>?

	internal init(_ continuation: CheckedContinuation<[HTTPCookie], Never>) {
		self.continuation = continuation
	}

	internal func resume(with cookies: [HTTPCookie]) {
		continuation?.resume(returning: cookies)
		continuation = nil
	}
}

private struct WeakView {
	internal weak var view: NSView?

	internal init(_ view: NSView) {
		self.view = view
	}
}

/// DEV-1188: where a Chromium page's failed protected media went, in the FairPlay log category
/// (`log stream --predicate 'subsystem == "dev.capturecontext.arx" AND category == "FairPlay"'`).
/// Never a page's address.
private let log: Logger = .init(subsystem: "dev.capturecontext.arx", category: "FairPlay")
