import AppKit
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import Foundation
import Testing
import WebKit

@testable import WebKitBrowserEngine

@Suite(.serialized)
@MainActor
internal struct PageEngineRouterTests {
	private let profile: Profile.ID = .init(rawValue: UUID())

	private func tab(_ address: String) -> Tab {
		.init(
			id: .init(rawValue: UUID()),
			profileID: profile,
			restoration: .init(title: "", url: URL(string: address)!)
		)
	}

	@Test
	internal func listedSitesOpenInWebKitAndOthersInChromium() async throws {
		let fixture = RouterFixture()
		let netflix = tab("https://www.netflix.com/browse")
		let news = tab("https://news.example/")

		try await fixture.client.open(netflix)
		try await fixture.client.open(news)

		#expect(fixture.router.engine(netflix.id) == .webKit)
		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.opened == [news.id])
		let snapshot = try #require(fixture.client.snapshot(netflix.id))
		#expect(snapshot.navigation.engine == .webKit)
		#expect(snapshot.documentRevision == nil)
		#expect(snapshot.nativeProfileID == profile)
		// A tab that never had a Chromium page reads cookies from the profile's store.
		#expect(fixture.cookieReads.map(\.tab) == [nil])
		try await fixture.waitFor { !fixture.changes.isEmpty }
		#expect(fixture.changes == [.init(tabID: netflix.id, engine: .webKit)])
		#expect(fixture.client.unloadTab(netflix.id, .inactive) == .kept)
		#expect(fixture.client.documentType(netflix.id) == .web)
	}

	@Test
	internal func webKitPagesOffKeepsEveryTabInChromium() async throws {
		let fixture = RouterFixture()
		fixture.preferences.isEnabled = false
		let netflix = tab("https://www.netflix.com")

		try await fixture.client.open(netflix)

		#expect(fixture.router.engine(netflix.id) == .chromium)
		#expect(fixture.chromium.opened == [netflix.id])
		#expect(await !fixture.router.move(netflix.id, to: .webKit, url: nil))
	}

	@Test
	internal func typedListedAddressMovesTheChromiumPageAndBackReturns() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)

		try await fixture.client.command(news.id, .navigate(URL(string: "https://open.spotify.com/album/1")!))

		#expect(fixture.router.engine(news.id) == .webKit)
		#expect(fixture.chromium.permitsClosingAsked == [news.id])
		#expect(fixture.cookieReads.map(\.tab) == [news.id])
		#expect(fixture.chromium.commands.isEmpty)
		#expect(fixture.client.snapshot(news.id)?.navigation.canGoBack == true)

		try await fixture.client.command(news.id, .back)
		try await fixture.waitFor { fixture.router.engine(news.id) == .chromium }

		#expect(fixture.router.pages.page(news.id) == nil)
		try await fixture.waitFor { fixture.changes.count == 2 }
		#expect(fixture.changes.map(\.engine) == [.webKit, .chromium])
		// The Chromium page closed when the tab moved, and Back opens its address again.
		#expect(fixture.chromium.closed == [news.id])
		try await fixture.waitFor { fixture.chromium.opened.count == 2 }
		#expect(fixture.chromium.openedURLs.last == URL(string: "https://news.example/"))
	}

	@Test
	internal func refusedUnloadKeepsThePageWhereItIs() async throws {
		let fixture = RouterFixture()
		fixture.chromium.permitsClosing = false
		let form = tab("https://form.example/")
		try await fixture.client.open(form)

		try await fixture.client.command(form.id, .navigate(URL(string: "https://www.netflix.com")!))

		#expect(fixture.router.engine(form.id) == .chromium)
		#expect(fixture.chromium.commands.isEmpty)
		#expect(fixture.cookieReads.isEmpty)
	}

	@Test
	internal func typedUnlistedAddressInWebKitGoesBackToChromium() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		#expect(await fixture.router.move(news.id, to: .webKit, url: URL(string: "https://www.netflix.com")!))

		let other = URL(string: "https://other.example/")!
		try await fixture.client.command(news.id, .navigate(other))

		#expect(fixture.router.engine(news.id) == .chromium)
		try await fixture.waitFor { fixture.chromium.openedURLs.last == other }
	}

	@Test
	internal func slowCookiesDontHoldTheMove() async throws {
		let fixture = RouterFixture()
		fixture.router.cookieTimeLimit = .milliseconds(20)
		fixture.router.siteCookies = { _, _, _ in
			try? await Task.sleep(for: .seconds(30))
			return []
		}
		let netflix = tab("https://www.netflix.com")
		let clock = ContinuousClock()
		let start = clock.now

		try await fixture.client.open(netflix)

		#expect(fixture.router.engine(netflix.id) == .webKit)
		#expect(clock.now - start < .seconds(5))
	}

	@Test
	internal func closingEndsBothPagesAndTheEvents() async throws {
		let fixture = RouterFixture()
		let netflix = tab("https://www.netflix.com")
		let events = fixture.client.events(netflix.id)
		try await fixture.client.open(netflix)

		fixture.client.close(netflix.id)

		#expect(fixture.chromium.closed == [netflix.id])
		#expect(fixture.router.pages.page(netflix.id) == nil)
		#expect(fixture.router.engine(netflix.id) == .chromium)
		var received: [BrowserNavigation] = []
		for await navigation in events { received.append(navigation) }
		#expect(received.allSatisfy { $0.engine == .webKit })
	}

	/// DEV-1312: only a window the page asked for on its own follows a Favorite's link settings.
	@Test
	internal func aNewWindowIsThePagesRequestWithoutModifiersMiddleButtonOrSize() {
		#expect(WebKitPage.isPageRequest(modifiers: [], buttonNumber: 0, isSized: false))
		#expect(WebKitPage.isPageRequest(modifiers: [.capsLock, .function], buttonNumber: 0, isSized: false))
		for modifier in [NSEvent.ModifierFlags.command, .shift, .option, .control] {
			#expect(!WebKitPage.isPageRequest(modifiers: modifier, buttonNumber: 0, isSized: false))
		}
		#expect(!WebKitPage.isPageRequest(modifiers: [], buttonNumber: 2, isSized: false))
		#expect(!WebKitPage.isPageRequest(modifiers: [], buttonNumber: 0, isSized: true))
		// A script's window goes on to `createWebViewWith`, which sees its size; a link's or a
		// form's opens from the navigation policy.
		#expect(WebKitPage.isScriptWindow(.other))
		#expect(!WebKitPage.isScriptWindow(.linkActivated))
		#expect(!WebKitPage.isScriptWindow(.formSubmitted))
	}

	@Test
	internal func popupsFromWebKitOpenInWebKitOnce() async throws {
		let fixture = RouterFixture()
		let netflix = tab("https://www.netflix.com")
		try await fixture.client.open(netflix)
		var opened: [URL] = []
		fixture.router.onNewTab = { _, url, _ in opened.append(url) }
		let help = URL(string: "https://help.example/article")!

		fixture.router.pages.page(netflix.id)?.onNewTab?(help, true)
		let popup = tab(help.absoluteString)
		try await fixture.client.open(popup)
		let again = tab(help.absoluteString)
		try await fixture.client.open(again)

		#expect(opened == [help])
		#expect(fixture.router.engine(popup.id) == .webKit)
		#expect(fixture.router.engine(again.id) == .chromium)
	}

	@Test
	internal func surfaceSwapsTheViewInTheHost() async throws {
		let fixture = RouterFixture()
		let netflix = tab("https://www.netflix.com")
		try await fixture.client.open(netflix)
		let host = NSView(frame: .init(x: 0, y: 0, width: 400, height: 300))

		fixture.router.surface.attach(netflix.id, host)

		let view = try #require(fixture.router.pages.page(netflix.id)?.webView)
		#expect(view.superview === host)
		#expect(view.frame == host.bounds)
		#expect(fixture.chromium.detachedHosts.count == 1)

		fixture.router.surface.detach(host)
		#expect(view.superview == nil)
	}

	@Test
	internal func aWebKitPageShownInOneWindowStaysThereWhenAnotherAttachesIt() async throws {
		let fixture = RouterFixture()
		let netflix = tab("https://www.netflix.com")
		try await fixture.client.open(netflix)
		let first = Self.windowHost()
		let second = Self.windowHost()

		fixture.router.surface.attach(netflix.id, first.host)
		fixture.router.surface.attach(netflix.id, second.host)

		let view = try #require(fixture.router.pages.page(netflix.id)?.webView)
		#expect(view.superview === first.host)
		#expect(second.host.subviews.isEmpty)

		// Once the first window lets go, the second shows it.
		fixture.router.surface.detach(first.host)
		fixture.router.surface.attach(netflix.id, second.host)
		#expect(view.superview === second.host)
	}

	private static func windowHost() -> (window: NSWindow, host: NSView) {
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 400, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: true
		)
		window.isReleasedWhenClosed = false
		let host = NSView(frame: .init(x: 0, y: 0, width: 400, height: 300))
		window.contentView?.addSubview(host)
		return (window, host)
	}

	@Test
	internal func aMoveThatWaitedForCookiesGivesWayToANewerNavigation() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		fixture.router.siteCookies = { _, _, _ in
			try? await Task.sleep(for: .milliseconds(200))
			return []
		}

		async let moved = fixture.router.move(news.id, to: .webKit, url: URL(string: "https://www.netflix.com")!)
		try await Task.sleep(for: .milliseconds(50))
		try await fixture.client.command(news.id, .navigate(URL(string: "https://elsewhere.example")!))

		#expect(await !moved)
		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.closed.isEmpty)
	}

	@Test
	internal func authorizedClosesNeedTheCurrentRevision() async throws {
		let fixture = RouterFixture()
		let netflix = tab("https://www.netflix.com")
		try await fixture.client.open(netflix)
		let close = try #require(fixture.client.closeAuthorized)
		let revision = try #require(fixture.client.snapshot(netflix.id)?.revision)

		await #expect(throws: AutomationFailure.staleTarget) {
			try await close(netflix.id, revision &+ 1, { true }, {})
		}
		var closed = false
		#expect(try await close(netflix.id, revision, { true }, { closed = true }))
		#expect(closed)
	}

	@Test
	internal func clearingDataTypesFollowTheKinds() async throws {
		let cookies = WebKitPages.dataTypes([.cookies])
		let cache = WebKitPages.dataTypes([.cache])
		#expect(cookies.contains(WKWebsiteDataTypeCookies))
		#expect(!cookies.contains(WKWebsiteDataTypeDiskCache))
		#expect(cache == [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache])
		#expect(WebKitPages.dataTypes([.history, .downloads]).isEmpty)
	}

	@Test
	internal func aPinnedTabLeavingWebKitOpensTheTypedAddress() async throws {
		let fixture = RouterFixture()
		var pinned = tab("https://www.netflix.com/browse")
		pinned.savedDestination = .init(title: "Netflix", url: URL(string: "https://www.netflix.com/browse")!)
		try await fixture.client.open(pinned)
		let other = URL(string: "https://other.example/")!

		try await fixture.client.command(pinned.id, .navigate(other))

		try await fixture.waitFor { fixture.chromium.openedURLs.last == other }
		#expect(fixture.router.engine(pinned.id) == .chromium)
	}

	@Test
	internal func authorizedHistoryCommandsReachWebKitPages() async throws {
		let fixture = RouterFixture()
		let netflix = tab("https://www.netflix.com")
		try await fixture.client.open(netflix)
		let revision = try #require(fixture.client.snapshot(netflix.id)?.revision)

		try await fixture.client.commandAuthorized(netflix.id, revision, .reload, { true })
		await #expect(throws: AutomationFailure.staleTarget) {
			try await fixture.client.commandAuthorized(netflix.id, revision &+ 99, .reload, { true })
		}
		await #expect(throws: AutomationFailure.denied) {
			try await fixture.client.commandAuthorized(netflix.id, revision, .reload, { false })
		}
		await #expect(throws: BrowserEngineClient.Failure.self) {
			try await fixture.client.commandAuthorized(netflix.id, revision, .openDeveloperTools, { true })
		}
	}

	// MARK: - History across engines (DEV-1293)

	@Test
	internal func forwardFromTheChromiumPageBackReopenedShowsTheWebKitPageAgain() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		let netflix = URL(string: "https://www.netflix.com/title/1")!
		try await fixture.client.open(news)
		fixture.chromium.show(news.id, news.reopeningURL)

		// The site menu's Open in WebKit, or the fallback prompt.
		#expect(await fixture.router.move(news.id, to: .webKit, url: netflix))
		// The WebKit page's history list ends at the Chromium page it came from.
		let webKit = try #require(fixture.client.snapshot(news.id)?.navigation)
		#expect(webKit.history.first?.id == SharedHistory.behindID)
		#expect(webKit.history.first?.url == news.reopeningURL)

		try await fixture.client.command(news.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }
		fixture.chromium.show(news.id, news.reopeningURL)

		// Forward is enabled on the Chromium page, and the history list has the WebKit page.
		try await fixture.waitFor { fixture.client.snapshot(news.id)?.navigation.canGoForward == true }
		let chromium = try #require(fixture.client.snapshot(news.id)?.navigation)
		#expect(chromium.history.last?.id == SharedHistory.aheadID)
		#expect(chromium.history.last?.url == netflix)

		try await fixture.client.command(news.id, .forward)
		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		#expect(fixture.chromium.commands.isEmpty)
		#expect(fixture.router.pages.page(news.id)?.returnsToChromium == true)
	}

	@Test
	internal func forwardWorksWhenTheReopenedPageLostItsHistory() async throws {
		let fixture = RouterFixture()
		let home = tab("https://www.spotify.com/")
		let homeURL = URL(string: "https://www.spotify.com/")!
		let player = URL(string: "https://open.spotify.com/track/1")!
		try await fixture.client.open(home)
		fixture.chromium.show(home.id, player, back: [homeURL])
		try await fixture.waitFor { fixture.router.engine(home.id) == .webKit }

		try await fixture.client.command(home.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }

		// A private window keeps no saved history: a fresh page at the player opens the page
		// before, and Chromium has nothing ahead of it.
		fixture.chromium.show(home.id, player)
		try await fixture.waitFor { fixture.chromium.commands == [.navigate(homeURL)] }
		fixture.chromium.show(home.id, homeURL, back: [player], entryID: 1)

		try await fixture.waitFor { fixture.client.snapshot(home.id)?.navigation.canGoForward == true }
		try await fixture.client.command(home.id, .forward)
		try await fixture.waitFor { fixture.router.engine(home.id) == .webKit }
		#expect(fixture.chromium.commands == [.navigate(homeURL)])
	}

	@Test
	internal func forwardFromThePageBeforeAFollowedSiteShowsTheWebKitPageWithoutLoadingItInChromium() async throws {
		let fixture = RouterFixture()
		let home = tab("https://www.spotify.com/")
		let homeURL = URL(string: "https://www.spotify.com/")!
		let player = URL(string: "https://open.spotify.com/track/1")!
		try await fixture.client.open(home)
		fixture.chromium.show(home.id, player, back: [homeURL])
		try await fixture.waitFor { fixture.router.engine(home.id) == .webKit }

		try await fixture.client.command(home.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }
		fixture.chromium.show(home.id, player, back: [homeURL])
		try await fixture.waitFor { fixture.chromium.commands == [.back] }

		// Chromium's own history still has the player ahead.
		fixture.chromium.show(home.id, homeURL, entryID: -1, forward: [player])

		try await fixture.waitFor {
			fixture.client.snapshot(home.id)?.navigation.history.last?.id == SharedHistory.aheadID
		}
		try await fixture.client.command(home.id, .forward)
		try await fixture.waitFor { fixture.router.engine(home.id) == .webKit }
		#expect(fixture.chromium.commands == [.back])
		// Back from the WebKit page returns to the page before the player, not to the player.
		try await fixture.client.command(home.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 3 }
		#expect(fixture.chromium.openedURLs.last == homeURL)
	}

	@Test
	internal func chromiumReachingTheFollowedSitesEntryAgainShowsTheWebKitPage() async throws {
		let fixture = RouterFixture()
		let home = tab("https://www.spotify.com/")
		let homeURL = URL(string: "https://www.spotify.com/")!
		let player = URL(string: "https://open.spotify.com/track/1")!
		try await fixture.client.open(home)
		fixture.chromium.show(home.id, player, back: [homeURL])
		try await fixture.waitFor { fixture.router.engine(home.id) == .webKit }
		try await fixture.client.command(home.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }
		fixture.chromium.show(home.id, player, back: [homeURL])
		try await fixture.waitFor { fixture.chromium.commands == [.back] }
		fixture.chromium.show(home.id, homeURL, entryID: -1, forward: [player])
		try await fixture.waitFor { fixture.client.snapshot(home.id)?.navigation.canGoForward == true }

		// Chromium's own swipe goes forward to the player's entry.
		fixture.chromium.traverse(home.id, to: player, back: [homeURL])

		try await fixture.waitFor { fixture.router.engine(home.id) == .webKit }
		#expect(fixture.router.pages.page(home.id)?.returnsToChromium == true)
	}

	@Test
	internal func backFromTheChromiumPageATypedAddressOpenedShowsTheWebKitPageAgain() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		let netflix = URL(string: "https://www.netflix.com/title/1")!
		let other = URL(string: "https://other.example/")!
		try await fixture.client.open(news)
		#expect(await fixture.router.move(news.id, to: .webKit, url: netflix))

		try await fixture.client.command(news.id, .navigate(other))
		try await fixture.waitFor { fixture.chromium.openedURLs.last == other }
		fixture.chromium.show(news.id, other)

		// Back is enabled on the Chromium page, and the history list has the WebKit page.
		try await fixture.waitFor { fixture.client.snapshot(news.id)?.navigation.canGoBack == true }
		let chromium = try #require(fixture.client.snapshot(news.id)?.navigation)
		#expect(chromium.history.first?.id == SharedHistory.behindID)
		#expect(chromium.history.first?.url == netflix)

		try await fixture.client.command(news.id, .back)
		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		#expect(fixture.chromium.commands.isEmpty)

		// Forward from the WebKit page returns to the Chromium page, by the list and the swipe too.
		let webKit = try #require(fixture.client.snapshot(news.id)?.navigation)
		#expect(webKit.canGoForward)
		#expect(webKit.history.last?.id == SharedHistory.aheadID)
		#expect(webKit.history.last?.url == other)
		let page = try #require(fixture.router.pages.page(news.id))
		#expect(page.swipeEntries(.forward).last?.navigation == .forwardToChromium)

		try await fixture.client.command(news.id, .forward)
		try await fixture.waitFor { fixture.router.engine(news.id) == .chromium }
		try await fixture.waitFor { fixture.chromium.openedURLs.last == other }
		fixture.chromium.show(news.id, other)
		try await fixture.waitFor { fixture.client.snapshot(news.id)?.navigation.canGoBack == true }
	}

	@Test
	internal func aJumpToWebKitFromALaterChromiumEntryComesForwardToTheEntryBesideIt() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		let netflix = URL(string: "https://www.netflix.com/title/1")!
		let first = URL(string: "https://other.example/")!
		let second = URL(string: "https://other.example/story")!
		try await fixture.client.open(news)
		#expect(await fixture.router.move(news.id, to: .webKit, url: netflix))
		try await fixture.client.command(news.id, .navigate(first))
		try await fixture.waitFor { fixture.chromium.openedURLs.last == first }
		fixture.chromium.show(news.id, first)

		// The router has seen the first page: the page's own swipe heard of the WebKit page behind.
		try await fixture.waitFor { fixture.chromium.sharedHistory[news.id]?.back == true }
		fixture.chromium.show(news.id, second, back: [first], entryID: 1)
		try await fixture.waitFor { fixture.chromium.sharedHistory[news.id]?.back == false }

		// The history list jumps from the second Chromium page straight to the WebKit page.
		try await fixture.client.command(news.id, .historyEntry(SharedHistory.behindID))
		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		let webKit = try #require(fixture.client.snapshot(news.id)?.navigation)
		#expect(webKit.history.last?.url == first)

		// Forward reopens the Chromium page where it was and steps back to the first page.
		try await fixture.client.command(news.id, .forward)
		try await fixture.waitFor { fixture.chromium.openedURLs.last == second }
		fixture.chromium.show(news.id, second, back: [first], entryID: 1)
		try await fixture.waitFor { fixture.chromium.commands == [.back] }
		fixture.chromium.show(news.id, first, forward: [second])
		try await fixture.waitFor { fixture.client.snapshot(news.id)?.navigation.history.first?.id == SharedHistory.behindID }
	}

	@Test
	internal func aJumpToWebKitFromAnEarlierChromiumEntryComesBackToTheEntryBesideIt() async throws {
		let fixture = RouterFixture()
		let first = URL(string: "https://news.example/")!
		let second = URL(string: "https://news.example/story")!
		let news = tab(second.absoluteString)
		let netflix = URL(string: "https://www.netflix.com/title/1")!
		try await fixture.client.open(news)
		fixture.chromium.show(news.id, second, back: [first])
		#expect(await fixture.router.move(news.id, to: .webKit, url: netflix))
		try await fixture.client.command(news.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }
		fixture.chromium.show(news.id, second, back: [first])
		try await fixture.waitFor { fixture.chromium.sharedHistory[news.id]?.forward == true }

		// Back within Chromium, then the history list jumps forward past the second page to WebKit.
		fixture.chromium.show(news.id, first, entryID: -1, forward: [second])
		try await fixture.waitFor { fixture.chromium.sharedHistory[news.id]?.forward == false }

		try await fixture.client.command(news.id, .historyEntry(SharedHistory.aheadID))
		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		#expect(fixture.client.snapshot(news.id)?.navigation.history.first?.url == second)

		// Back reopens the Chromium page where it was and steps forward to the second page.
		try await fixture.client.command(news.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.last == first }
		fixture.chromium.show(news.id, first, entryID: -1, forward: [second])
		try await fixture.waitFor { fixture.chromium.commands == [.historyEntry(0)] }
	}

	@Test
	internal func theHistoryListAndAuthorizedCommandsCrossToWebKit() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		let netflix = URL(string: "https://www.netflix.com/title/1")!
		try await fixture.client.open(news)
		fixture.chromium.show(news.id, news.reopeningURL)
		#expect(await fixture.router.move(news.id, to: .webKit, url: netflix))
		try await fixture.client.command(news.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }
		fixture.chromium.show(news.id, news.reopeningURL)
		try await fixture.waitFor { fixture.client.snapshot(news.id)?.navigation.canGoForward == true }
		let revision = try #require(fixture.client.snapshot(news.id)?.revision)

		await #expect(throws: AutomationFailure.staleTarget) {
			try await fixture.client.commandAuthorized(news.id, revision &+ 1, .historyEntry(SharedHistory.aheadID), { true })
		}
		try await fixture.client.commandAuthorized(news.id, revision, .historyEntry(SharedHistory.aheadID), { true })

		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		#expect(fixture.chromium.commands.isEmpty)
	}

	@Test
	internal func aGrantWithdrawnWhileTheCrossingWaitsKeepsTheChromiumPage() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		let netflix = URL(string: "https://www.netflix.com/title/1")!
		try await fixture.client.open(news)
		fixture.chromium.show(news.id, news.reopeningURL)
		#expect(await fixture.router.move(news.id, to: .webKit, url: netflix))
		try await fixture.client.command(news.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }
		fixture.chromium.show(news.id, news.reopeningURL)
		try await fixture.waitFor { fixture.client.snapshot(news.id)?.navigation.canGoForward == true }
		let revision = try #require(fixture.client.snapshot(news.id)?.revision)

		// The page takes a moment to say it may close, and the grant ends meanwhile.
		fixture.chromium.closingAnswerDelay = .milliseconds(100)
		var allowed = true
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(30))
			allowed = false
		}

		await #expect(throws: AutomationFailure.denied) {
			try await fixture.client.commandAuthorized(news.id, revision, .forward, { allowed })
		}
		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.closed == [news.id])
	}

	@Test
	internal func chromiumsOwnSwipeHearsOfTheWebKitPageAndCrossesToIt() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		let netflix = URL(string: "https://www.netflix.com/title/1")!
		try await fixture.client.open(news)
		fixture.chromium.show(news.id, news.reopeningURL)
		#expect(await fixture.router.move(news.id, to: .webKit, url: netflix))
		try await fixture.client.command(news.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }
		fixture.chromium.show(news.id, news.reopeningURL)

		// The engine's swipe on the Chromium page offers Forward, which its history lacks.
		try await fixture.waitFor { fixture.chromium.sharedHistory[news.id].map { !$0.back && $0.forward } == true }

		// A swipe back has nowhere to go across engines.
		fixture.router.sharedHistorySwiped(news.id, forward: false)
		try await Task.sleep(for: .milliseconds(50))
		#expect(fixture.router.engine(news.id) == .chromium)

		fixture.router.sharedHistorySwiped(news.id, forward: true)
		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		#expect(fixture.chromium.commands.isEmpty)
	}

	@Test
	internal func aNewPageFromTheChromiumPageDropsTheWebKitPageAhead() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		let netflix = URL(string: "https://www.netflix.com/title/1")!
		try await fixture.client.open(news)
		fixture.chromium.show(news.id, news.reopeningURL)
		#expect(await fixture.router.move(news.id, to: .webKit, url: netflix))
		try await fixture.client.command(news.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }
		fixture.chromium.show(news.id, news.reopeningURL)
		try await fixture.waitFor { fixture.client.snapshot(news.id)?.navigation.canGoForward == true }

		// A link from the reopened page replaces what was ahead of it.
		fixture.chromium.show(news.id, URL(string: "https://news.example/story")!, back: [news.reopeningURL], entryID: 1)

		try await fixture.waitFor { fixture.client.snapshot(news.id)?.navigation.canGoForward == false }
		try await fixture.client.command(news.id, .forward)
		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.commands == [.forward])
	}

	// MARK: - Listed sites reached in Chromium (DEV-1000)

	@Test
	internal func aChromiumPageReachingAListedSiteMovesAndBackReturnsToThePageBefore() async throws {
		let fixture = RouterFixture()
		let home = tab("https://www.spotify.com/")
		try await fixture.client.open(home)
		let player = URL(string: "https://open.spotify.com/track/1")!

		// A link within spotify.com, which isn't a cross-site click, commits the player.
		fixture.chromium.show(home.id, player, back: [URL(string: "https://www.spotify.com/")!])

		try await fixture.waitFor { fixture.router.engine(home.id) == .webKit }
		#expect(fixture.chromium.permitsClosingAsked == [home.id])
		#expect(fixture.cookieReads.map(\.tab) == [home.id])
		#expect(fixture.cookieReads.map(\.url) == [player])
		#expect(fixture.chromium.closed == [home.id])

		// Back reopens Chromium at the player, where its saved history ends, and steps back
		// once the page reports it, so the history before and after stays.
		try await fixture.client.command(home.id, .back)
		try await fixture.waitFor { fixture.router.engine(home.id) == .chromium }
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }
		#expect(fixture.chromium.openedURLs.last == player)
		fixture.chromium.show(home.id, player, back: [URL(string: "https://www.spotify.com/")!])
		try await fixture.waitFor { fixture.chromium.commands == [.back] }
		try await Task.sleep(for: .milliseconds(50))
		#expect(fixture.router.engine(home.id) == .chromium)
		#expect(fixture.chromium.permitsClosingAsked == [home.id])
	}

	@Test
	internal func backWithoutSavedHistoryOpensThePageBefore() async throws {
		let fixture = RouterFixture()
		let home = tab("https://www.spotify.com/")
		try await fixture.client.open(home)
		let player = URL(string: "https://open.spotify.com/track/1")!
		fixture.chromium.show(home.id, player, back: [URL(string: "https://www.spotify.com/")!])
		try await fixture.waitFor { fixture.router.engine(home.id) == .webKit }

		try await fixture.client.command(home.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }

		// A fresh page at the player: nothing to go back to, so it opens the page before.
		fixture.chromium.show(home.id, player)

		try await fixture.waitFor { fixture.chromium.commands == [.navigate(URL(string: "https://www.spotify.com/")!)] }
	}

	@Test
	internal func aListedSiteThatAsksForProtectedMediaMovesWithoutAPrompt() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let forwarded = fixture.forwardedRequests()
		let video = tab("https://video.example/")
		try await fixture.client.open(video)

		// The Chromium page reached the player without an event the router followed.
		let player = URL(string: "https://open.spotify.com/album/1")!
		fixture.chromium.commit(news.id, player)
		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: player))
		fixture.router.protectedMediaRequested(.init(tabID: video.id, profileID: profile, url: video.reopeningURL))

		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		try await fixture.waitFor { !forwarded.urls.isEmpty }
		#expect(forwarded.urls == [video.reopeningURL])
		#expect(fixture.router.engine(video.id) == .chromium)
		// No page before the player in this tab: Back from WebKit has nowhere to go.
		#expect(fixture.client.snapshot(news.id)?.navigation.canGoBack == false)
	}

	@Test
	internal func aPageShownInChromiumAtAListedSiteStaysUntilItLeaves() async throws {
		let fixture = RouterFixture()

		// A site the person listed: its protected media may play in Chromium some other way.
		fixture.preferences.sites.append("video.example")
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let forwarded = fixture.forwardedRequests()
		let player = URL(string: "https://video.example/watch/1")!
		#expect(await fixture.router.move(news.id, to: .webKit, url: player))
		#expect(await fixture.router.move(news.id, to: .chromium, url: player))
		try await fixture.waitFor { fixture.chromium.openedURLs.last == player }
		let asked = fixture.chromium.permitsClosingAsked.count

		fixture.chromium.show(news.id, player)
		fixture.chromium.show(news.id, URL(string: "https://video.example/watch/2")!)
		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: player))

		// Its failed video goes to the app, which asks (DEV-1188).
		try await fixture.waitFor { forwarded.urls == [player] }
		try await Task.sleep(for: .milliseconds(100))
		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.permitsClosingAsked.count == asked)

		// Leaving the site ends it; coming back follows the list again.
		fixture.chromium.show(news.id, URL(string: "https://elsewhere.example/")!)
		fixture.chromium.show(news.id, player)
		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
	}

	/// DEV-1188: a move back to Chromium opens a new page, which shows Chromium's initial
	/// about:blank before the site's entry, as the overnight webkit-fallback smoke saw: the page
	/// address with no history, about:blank as entry 798, then the site as entry 800. That isn't
	/// leaving the site: the page stays kept, and its failed video goes to the app. Once it has
	/// shown the site, about:blank is leaving it.
	@Test(arguments: [true, false])
	internal func aReopenedPagesInitialBlankEntryDoesntEndTheKeeping(blankIsLoading: Bool) async throws {
		let fixture = RouterFixture()

		// A site the person added, as the smoke's loopback one is.
		fixture.preferences.sites.append("video.example")
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let forwarded = fixture.forwardedRequests()
		let player = URL(string: "https://video.example/watch/1")!
		let blank = URL(string: "about:blank")!
		#expect(await fixture.router.move(news.id, to: .webKit, url: player))
		#expect(await fixture.router.move(news.id, to: .chromium, url: player))
		try await fixture.waitFor { fixture.chromium.openedURLs.last == player }

		fixture.chromium.opening(news.id, player)
		if blankIsLoading {
			fixture.chromium.traverse(news.id, to: blank, back: [], entryID: 798)
		} else {
			fixture.chromium.show(news.id, blank, entryID: 798)
		}
		fixture.chromium.show(news.id, player, entryID: 800)
		try await Task.sleep(for: .milliseconds(100))
		#expect(fixture.router.engine(news.id) == .chromium)

		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: player))
		try await fixture.waitFor { forwarded.urls == [player] }
		try await Task.sleep(for: .milliseconds(100))
		#expect(fixture.router.engine(news.id) == .chromium)

		// Shown at the site, the page leaves it for about:blank like any other page.
		fixture.chromium.show(news.id, blank, back: [player], entryID: 801)
		fixture.chromium.show(news.id, player, back: [player, blank], entryID: 802)
		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
	}

	/// DEV-1188: Open in WebKit lists the site, then moves the page, and the router, seeing the
	/// page at a site it now lists, follows it too. Both ask the page to close while it answers;
	/// they hear one answer, and the newer move goes ahead. Before, Chromium refused the second
	/// question, the follow kept the page in Chromium as one that refused to leave, and the
	/// person's move lost to the follow's: the overnight webkit-fallback smoke's intermittent
	/// "The page did not move to WebKit".
	@Test
	internal func openInWebKitAndTheRoutersFollowMoveThePage() async throws {
		let fixture = RouterFixture()
		fixture.chromium.closingAnswerDelay = .milliseconds(100)
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let player = URL(string: "https://video.example/watch/1")!
		fixture.chromium.show(news.id, player, back: [news.reopeningURL])
		try await Task.sleep(for: .milliseconds(50))
		#expect(fixture.router.engine(news.id) == .chromium)

		fixture.preferences.sites.append("video.example")
		async let moved = fixture.router.move(news.id, to: .webKit, url: player)

		// The page reports again, its title for one, while the move asks it to close.
		try await Task.sleep(for: .milliseconds(20))
		fixture.chromium.show(news.id, player, back: [news.reopeningURL])
		_ = await moved

		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		try await Task.sleep(for: .milliseconds(200))
		#expect(fixture.router.engine(news.id) == .webKit)
		#expect(fixture.cookieReads.map(\.url) == [player])
	}

	/// DEV-1188: Netflix's video plays only in WebKit, but a page the person kept in Chromium at
	/// the listed site doesn't move silently when it fails: the app asks, as for any streaming site.
	@Test
	internal func aKeptPageWhoseVideoPlaysOnlyInWebKitIsPassedOnWhenItFails() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let forwarded = fixture.forwardedRequests()
		let title = URL(string: "https://www.netflix.com/title/1")!
		#expect(await fixture.router.move(news.id, to: .webKit, url: title))
		#expect(await fixture.router.move(news.id, to: .chromium, url: title))
		try await fixture.waitFor { fixture.chromium.openedURLs.last == title }

		// Kept: the listed site's own pages don't move it back.
		fixture.chromium.show(news.id, title)
		try await Task.sleep(for: .milliseconds(50))
		#expect(fixture.router.engine(news.id) == .chromium)

		let asked = fixture.chromium.permitsClosingAsked.count
		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: title))
		try await fixture.waitFor { forwarded.urls == [title] }
		try await Task.sleep(for: .milliseconds(50))
		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.permitsClosingAsked.count == asked)
	}

	/// DEV-1188: a person who took Netflix off the list chose Chromium for it, so a failure doesn't
	/// move the page on its own: it goes to the app, which asks.
	@Test
	internal func anUnlistedSiteWhoseVideoPlaysOnlyInWebKitIsPassedOnWhenItFails() async throws {
		let fixture = RouterFixture()
		fixture.preferences.sites.removeAll { $0 == "netflix.com" }
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let forwarded = fixture.forwardedRequests()
		let title = URL(string: "https://www.netflix.com/title/1")!
		fixture.chromium.show(news.id, title, back: [news.reopeningURL])
		try await Task.sleep(for: .milliseconds(50))
		#expect(fixture.router.engine(news.id) == .chromium)

		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: title))
		try await fixture.waitFor { forwarded.urls == [title] }
		try await Task.sleep(for: .milliseconds(50))
		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(!fixture.preferences.sites.contains("netflix.com"))
	}

	/// DEV-1188: a site the FairPlay helper keeps in Chromium plays there; its failures are the
	/// helper's to handle, and a site the person added is the app's to offer WebKit for.
	@Test
	internal func aSiteThatCanPlayInChromiumIsPassedOnWhenItFails() async throws {
		let fixture = RouterFixture()
		fixture.preferences = fixture.preferences.keepingInChromium(["https://open.spotify.com"])
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let forwarded = fixture.forwardedRequests()
		let player = URL(string: "https://open.spotify.com/album/1")!
		let other = URL(string: "https://video.example/watch/1")!

		fixture.chromium.show(news.id, player)
		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: player))
		try await fixture.waitFor { forwarded.urls == [player] }
		fixture.chromium.show(news.id, other)
		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: other))
		try await fixture.waitFor { forwarded.urls == [player, other] }
		#expect(fixture.router.engine(news.id) == .chromium)
	}

	/// DEV-1188: with WebKit pages off, Netflix stays in Chromium and the app explains why.
	@Test
	internal func withWebKitPagesOffAVideoOnlyInWebKitStaysAndIsReported() async throws {
		let fixture = RouterFixture()
		fixture.preferences.isEnabled = false
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let forwarded = fixture.forwardedRequests()
		let title = URL(string: "https://www.netflix.com/title/1")!

		fixture.chromium.show(news.id, title)
		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: title))
		try await fixture.waitFor { forwarded.urls == [title] }
		#expect(fixture.router.engine(news.id) == .chromium)
	}

	@Test
	internal func aPageThatRefusesToLeaveIsAskedOncePerSite() async throws {
		let fixture = RouterFixture()
		fixture.chromium.permitsClosing = false
		let form = tab("https://form.example/")
		try await fixture.client.open(form)
		let player = URL(string: "https://open.spotify.com/")!

		fixture.chromium.show(form.id, player)
		try await fixture.waitFor { fixture.chromium.permitsClosingAsked.count == 1 }
		try await Task.sleep(for: .milliseconds(50))
		fixture.chromium.show(form.id, player.appending(path: "search"))
		try await Task.sleep(for: .milliseconds(100))

		#expect(fixture.router.engine(form.id) == .chromium)
		#expect(fixture.chromium.permitsClosingAsked == [form.id])
	}

	@Test
	internal func aPendingAddressDoesntMoveThePageUntilItCommits() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let player = URL(string: "https://open.spotify.com/")!

		fixture.chromium.start(news.id, player, from: news.reopeningURL)
		try await Task.sleep(for: .milliseconds(100))
		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.permitsClosingAsked.isEmpty)

		fixture.chromium.show(news.id, player, back: [news.reopeningURL])
		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		#expect(fixture.client.snapshot(news.id)?.navigation.canGoBack == true)
	}

	@Test
	internal func aHistoryTraversalMovesOnlyOnceTheListedPageHasLoaded() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let player = URL(string: "https://open.spotify.com/")!

		// Forward toward the player: its entry is current before it commits.
		fixture.chromium.traverse(news.id, to: player, back: [news.reopeningURL])
		try await Task.sleep(for: .milliseconds(100))
		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.permitsClosingAsked.isEmpty)

		fixture.chromium.show(news.id, player, back: [news.reopeningURL])
		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
	}

	@Test
	internal func leavingTheKeptSiteForALocalFileEndsTheKeeping() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let player = URL(string: "https://open.spotify.com/album/1")!
		#expect(await fixture.router.move(news.id, to: .webKit, url: player))
		#expect(await fixture.router.move(news.id, to: .chromium, url: player))
		try await fixture.waitFor { fixture.chromium.openedURLs.last == player }

		fixture.chromium.show(news.id, URL(filePath: "/tmp/notes.html"))
		fixture.chromium.show(news.id, player)

		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
	}

	@Test
	internal func aKeptSiteWithATrailingDotStaysInChromium() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let player = URL(string: "https://open.spotify.com./album/1")!
		#expect(await fixture.router.move(news.id, to: .webKit, url: player))
		#expect(await fixture.router.move(news.id, to: .chromium, url: player))
		try await fixture.waitFor { fixture.chromium.openedURLs.last == player }

		fixture.chromium.show(news.id, player)
		try await Task.sleep(for: .milliseconds(100))

		#expect(fixture.router.engine(news.id) == .chromium)
	}

	@Test
	internal func leavingTheKeptSiteCountsWhileThePageStillLoads() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let player = URL(string: "https://open.spotify.com/album/1")!
		#expect(await fixture.router.move(news.id, to: .webKit, url: player))
		#expect(await fixture.router.move(news.id, to: .chromium, url: player))
		try await fixture.waitFor { fixture.chromium.openedURLs.last == player }

		// An off-site page commits and redirects back before it finishes loading.
		fixture.chromium.traverse(news.id, to: URL(string: "https://redirect.example/")!, back: [])
		fixture.chromium.show(news.id, player)

		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
	}

	/// DEV-1063: Back toward another site, stopped before it commits, leaves the page at the
	/// entry it kept in Chromium, and it stays there.
	@Test
	internal func aBackOffTheKeptSiteStoppedBeforeItCommitsKeepsThePage() async throws {
		let kept = try await keptPlayer()
		let news = URL(string: "https://news.example/")!

		kept.fixture.chromium.traverse(kept.tab.id, to: news, back: [], entryID: -1)
		kept.fixture.chromium.show(kept.tab.id, kept.player, back: [news])
		try await Task.sleep(for: .milliseconds(100))

		#expect(kept.fixture.router.engine(kept.tab.id) == .chromium)
	}

	/// DEV-1063: Back to another site that commits ends the keeping, so Forward to the listed
	/// site moves the page.
	@Test
	internal func aBackOffTheKeptSiteThatCommitsEndsTheKeeping() async throws {
		let kept = try await keptPlayer()
		let news = URL(string: "https://news.example/")!

		kept.fixture.chromium.traverse(kept.tab.id, to: news, back: [], entryID: -1)
		kept.fixture.chromium.show(kept.tab.id, news, entryID: -1)
		kept.fixture.chromium.show(kept.tab.id, kept.player, back: [news])

		try await kept.fixture.waitFor { kept.fixture.router.engine(kept.tab.id) == .webKit }
	}

	/// DEV-1063: a page that left the kept site while loading and comes back to it at another
	/// entry, as a redirect back does, has left it. Both come before the router hears either, and
	/// the events keep only the newest, as the engine's do: the entry changes show the departure.
	@Test
	internal func comingBackToTheKeptSiteAtAnotherEntryEndsTheKeeping() async throws {
		let kept = try await keptPlayer()
		let redirect = URL(string: "https://redirect.example/")!

		kept.fixture.chromium.traverse(kept.tab.id, to: redirect, back: [], entryID: 1)
		kept.fixture.chromium.show(kept.tab.id, kept.player, entryID: 2)

		try await kept.fixture.waitFor { kept.fixture.router.engine(kept.tab.id) == .webKit }
	}

	/// A tab at a listed site that was moved back to Chromium on purpose, and so kept there, its
	/// page at the player's entry 0 with news.example before it (DEV-1000).
	private func keptPlayer() async throws -> KeptPage {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let player = URL(string: "https://open.spotify.com/album/1")!
		#expect(await fixture.router.move(news.id, to: .webKit, url: player))
		#expect(await fixture.router.move(news.id, to: .chromium, url: player))
		try await fixture.waitFor { fixture.chromium.openedURLs.last == player }

		fixture.chromium.show(news.id, player, back: [URL(string: "https://news.example/")!])
		try await Task.sleep(for: .milliseconds(50))
		#expect(fixture.router.engine(news.id) == .chromium)
		return .init(fixture: fixture, tab: news, player: player)
	}

	@Test
	internal func aFailedReopeningStillStepsBack() async throws {
		let fixture = RouterFixture()
		let home = tab("https://www.spotify.com/")
		try await fixture.client.open(home)
		let player = URL(string: "https://open.spotify.com/track/1")!
		fixture.chromium.show(home.id, player, back: [URL(string: "https://www.spotify.com/")!])
		try await fixture.waitFor { fixture.router.engine(home.id) == .webKit }

		try await fixture.client.command(home.id, .back)
		try await fixture.waitFor { fixture.chromium.openedURLs.count == 2 }
		fixture.chromium.fail(home.id, player)

		try await fixture.waitFor { fixture.chromium.commands == [.navigate(URL(string: "https://www.spotify.com/")!)] }
	}

	@Test
	internal func aRequestForAPageThatMovedOnDoesNothing() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let player = URL(string: "https://open.spotify.com/")!
		fixture.chromium.commit(news.id, player)

		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: player))

		// The page leaves before the move starts.
		fixture.chromium.commit(news.id, URL(string: "https://elsewhere.example/")!)
		try await Task.sleep(for: .milliseconds(100))

		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.permitsClosingAsked.isEmpty)
		#expect(fixture.chromium.closed.isEmpty)
	}

	@Test
	internal func aFollowedMoveLoadsTheAddressThePageShowsWhenItStarts() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let first = URL(string: "https://open.spotify.com/track/A")!
		let second = URL(string: "https://open.spotify.com/track/B")!

		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: first))

		// The player moves on to another track before the move starts.
		fixture.chromium.commit(news.id, second)

		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		#expect(fixture.cookieReads.map(\.url) == [second])
	}

	@Test
	internal func aPageThatReachedAnotherListedSiteFirstMovesThere() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let player = URL(string: "https://open.spotify.com/")!
		let netflix = URL(string: "https://www.netflix.com/browse")!

		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: player))
		fixture.chromium.commit(news.id, netflix)

		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		#expect(fixture.cookieReads.map(\.url) == [netflix])
	}

	@Test
	internal func aMoveThatLostToAPendingNavigationDoesntFollowIt() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let player = URL(string: "https://open.spotify.com/")!
		let netflix = URL(string: "https://www.netflix.com/browse")!
		fixture.router.siteCookies = { [weak fixture] _, _, _ in

			// Another navigation starts while the cookies are read, and hasn't committed.
			fixture?.chromium.start(news.id, netflix, from: player)
			return []
		}

		fixture.chromium.show(news.id, player)
		try await fixture.waitFor { fixture.chromium.permitsClosingAsked.count == 1 }
		try await Task.sleep(for: .milliseconds(100))

		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.permitsClosingAsked == [news.id])
		#expect(fixture.chromium.closed.isEmpty)
	}

	@Test
	internal func aPlayerThatChangesItsAddressWhileCookiesAreReadStillMoves() async throws {
		let fixture = RouterFixture()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let player = URL(string: "https://open.spotify.com/")!
		let home = URL(string: "https://open.spotify.com/intl-de")!
		fixture.router.siteCookies = { [weak fixture] _, _, _ in

			// The player rewrites its address before the first move goes ahead.
			if fixture?.chromium.navigations[news.id]?.url == player {
				fixture?.chromium.commit(news.id, home)
			}
			return []
		}

		fixture.chromium.show(news.id, player)

		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		#expect(fixture.chromium.permitsClosingAsked == [news.id, news.id])
	}

	@Test
	internal func withWebKitPagesOffAListedSiteStaysInChromiumAndIsReported() async throws {
		let fixture = RouterFixture()
		fixture.preferences.isEnabled = false
		let news = tab("https://news.example/")
		try await fixture.client.open(news)
		let forwarded = fixture.forwardedRequests()
		let player = URL(string: "https://open.spotify.com/")!

		fixture.chromium.show(news.id, player)
		fixture.router.protectedMediaRequested(.init(tabID: news.id, profileID: profile, url: player))

		try await fixture.waitFor { forwarded.urls == [player] }
		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.permitsClosingAsked.isEmpty)
	}

	// MARK: - Netflix opens in WebKit (DEV-1188)

	/// The preferences as the app gives them to the router: Settings' list, with the FairPlay
	/// helper's sites kept in Chromium (`ARX_FAIRPLAY_IN_CHROMIUM` on, FairPlay in the tab).
	private static func appPreferences(_ pages: WebKitPagePreferences = .init()) -> WebKitPagePreferences {
		pages.keepingInChromium(pages.bridgedOrigins(FairPlayInChromium.origins))
	}

	/// Netflix's pages: every one it shows is on `www.netflix.com` or `help.netflix.com`.
	nonisolated private static let netflixPages: [String] = [
		"https://netflix.com/",
		"https://www.netflix.com/",
		"https://www.netflix.com/pl-en/",
		"https://www.netflix.com/login",
		"https://www.netflix.com/browse",
		"https://www.netflix.com/title/80057281",
		"https://www.netflix.com/watch/80057281",
		"https://www.netflix.com/YourAccount",
		"https://help.netflix.com/en",
	]

	/// How a tab starts at a page. Typing in a new tab, a bookmark or saved tab, a restored tab,
	/// Peek and Little Arx all open the tab through the client, at its `reopeningURL`.
	nonisolated internal enum NewPage: CaseIterable, Sendable {
		case typedInANewTab
		case bookmark
		case restoredTab
	}

	@Test(arguments: NewPage.allCases, netflixPages)
	internal func netflixOpensInWebKitWithoutAPrompt(_ newPage: NewPage, _ address: String) async throws {
		let fixture = RouterFixture()
		fixture.preferences = Self.appPreferences()
		let forwarded = fixture.forwardedRequests()
		let url = URL(string: address)!
		var netflix: Tab
		switch newPage {
		case .typedInANewTab:
			netflix = tab(address)
		case .bookmark:
			netflix = tab("about:blank")
			netflix.savedDestination = .init(title: "Netflix", url: url)
		case .restoredTab:
			netflix = tab(address)
			netflix.restoration.title = "Netflix"
		}

		try await fixture.client.open(netflix)

		#expect(fixture.router.engine(netflix.id) == .webKit)
		#expect(fixture.client.snapshot(netflix.id)?.navigation.engine == .webKit)
		// Chromium never showed it, and nothing asked the app.
		#expect(fixture.chromium.opened.isEmpty)
		#expect(forwarded.urls.isEmpty)
	}

	/// An address typed in a Chromium tab moves it before Chromium loads it.
	@Test(arguments: netflixPages)
	internal func netflixTypedInAChromiumTabMovesBeforeChromiumLoadsIt(_ address: String) async throws {
		let fixture = RouterFixture()
		fixture.preferences = Self.appPreferences()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)

		try await fixture.client.command(news.id, .navigate(URL(string: address)!))

		#expect(fixture.router.engine(news.id) == .webKit)
		#expect(fixture.chromium.commands.isEmpty)
	}

	/// A link from another site, a redirect from one of Netflix's other domains (netflix.net, the
	/// country ones and http all land on https://www.netflix.com) or a script: the Chromium page
	/// moves as soon as it shows Netflix.
	@Test(arguments: [
		"https://www.netflix.com/title/80057281",
		"https://www.netflix.com/pl-en/",
		"https://help.netflix.com/en",
	])
	internal func aChromiumPageReachingNetflixMovesToWebKit(_ address: String) async throws {
		let fixture = RouterFixture()
		fixture.preferences = Self.appPreferences()
		let forwarded = fixture.forwardedRequests()
		let news = tab("https://news.example/")
		try await fixture.client.open(news)

		fixture.chromium.show(news.id, URL(string: address)!, back: [news.reopeningURL])

		try await fixture.waitFor { fixture.router.engine(news.id) == .webKit }
		#expect(forwarded.urls.isEmpty)
		// Back crosses to the page the link was on.
		#expect(fixture.client.snapshot(news.id)?.navigation.canGoBack == true)
	}

	/// Netflix's other domains and its http address aren't Netflix's pages: they redirect, and
	/// the page moves once it lands on www.netflix.com.
	@Test(arguments: ["https://netflix.net/", "https://www.netflix.ca/", "http://netflix.com/"])
	internal func netflixsOtherAddressesWaitForTheRedirect(_ address: String) async throws {
		let fixture = RouterFixture()
		fixture.preferences = Self.appPreferences()
		let alias = tab(address)
		try await fixture.client.open(alias)
		#expect(fixture.router.engine(alias.id) == .chromium)

		fixture.chromium.show(alias.id, URL(string: "https://www.netflix.com/pl-en/")!)

		try await fixture.waitFor { fixture.router.engine(alias.id) == .webKit }
	}

	/// Netflix stays a WebKit site whichever way protected media plays on the FairPlay helper's
	/// sites, and with the helper off: the helper keeps only Spotify's player in Chromium.
	@Test(arguments: [ProtectedMediaPlayback.fairPlayInTab, .webKitPage], [true, false])
	internal func netflixOpensInWebKitWhateverTheFairPlayHelperDoes(_ playback: ProtectedMediaPlayback, _ helperIsOn: Bool) async throws {
		let fixture = RouterFixture()
		var pages = WebKitPagePreferences()
		pages.protectedMedia = playback
		fixture.preferences = helperIsOn ? Self.appPreferences(pages) : pages
		let netflix = tab("https://www.netflix.com/browse")
		let spotify = tab("https://open.spotify.com/track/1")

		try await fixture.client.open(netflix)
		try await fixture.client.open(spotify)

		#expect(fixture.router.engine(netflix.id) == .webKit)
		let spotifyStays = helperIsOn && playback == .fairPlayInTab
		#expect(fixture.router.engine(spotify.id) == (spotifyStays ? .chromium : .webKit))
	}

	/// The person's way back: Netflix taken off the list, in the site menu or Settings, opens in
	/// Chromium from every entry point, and stays there across a save.
	@Test
	internal func netflixTakenOffTheListStaysInChromium() async throws {
		let fixture = RouterFixture()
		var pages = WebKitPagePreferences()
		let didRemove = pages.remove(URL(string: "https://www.netflix.com/browse")!)
		#expect(didRemove)
		pages = try JSONDecoder().decode(WebKitPagePreferences.self, from: JSONEncoder().encode(pages))
		fixture.preferences = Self.appPreferences(pages)
		let netflix = tab("https://www.netflix.com/browse")
		let news = tab("https://news.example/")

		try await fixture.client.open(netflix)
		try await fixture.client.open(news)
		try await fixture.client.command(news.id, .navigate(URL(string: "https://www.netflix.com/title/1")!))
		fixture.chromium.show(news.id, URL(string: "https://www.netflix.com/title/1")!, back: [news.reopeningURL])
		try await Task.sleep(for: .milliseconds(100))

		#expect(fixture.router.engine(netflix.id) == .chromium)
		#expect(fixture.router.engine(news.id) == .chromium)
		#expect(fixture.chromium.permitsClosingAsked.isEmpty)
	}

	@Test
	internal func storeIdentifiersAreStableAndPerProfile() async throws {
		let first = WebKitPages.dataStoreIdentifier(for: profile)
		#expect(first == WebKitPages.dataStoreIdentifier(for: profile))
		#expect(first != WebKitPages.dataStoreIdentifier(for: .init(rawValue: UUID())))
		#expect(first != profile.rawValue)
	}

	@Test
	internal func downloadsGetAFreeName() async throws {
		let folder = URL(filePath: "/tmp/downloads")
		let taken: Set<String> = ["/tmp/downloads/song.mp3", "/tmp/downloads/song 2.mp3"]
		let destination = WebKitDownloads.freeDestination(for: "song.mp3", in: folder) { taken.contains($0.path) }
		#expect(destination.lastPathComponent == "song 3.mp3")
		#expect(WebKitDownloads.freeDestination(for: "a/b:c", in: folder) { _ in false }.lastPathComponent == "a-b-c")
	}
}

/// A tab kept in Chromium at a listed site, from `PageEngineRouterTests.keptPlayer()`.
@MainActor
private struct KeptPage {
	internal let fixture: RouterFixture
	internal let tab: Tab
	internal let player: URL
}

@MainActor
private final class RouterFixture {
	internal let chromium: FakeChromium = .init()
	internal let router: PageEngineRouter
	internal var preferences: WebKitPagePreferences = .init()
	internal var cookieReads: [(profile: Profile.ID, tab: Tab.ID?, url: URL)] = []
	internal var changes: [PageEngineChange] = []
	private var changeTask: Task<Void, Never>?

	deinit { changeTask?.cancel() }

	internal init() {
		router = .init(chromium: chromium.client, chromiumSurface: chromium.surface, pages: .init(stores: .inMemory))
		router.preferences = { [weak self] in self?.preferences ?? .init() }
		router.siteCookies = { [weak self] profile, tab, url in
			self?.cookieReads.append((profile, tab, url))
			return []
		}
		let stream = router.pageEngines.changes()
		changeTask = Task { [weak self] in
			for await change in stream { self?.changes.append(change) }
		}
	}

	internal var client: BrowserEngineClient { router.client }

	/// Records the protected media requests the router passes on to the app.
	internal func forwardedRequests() -> RequestRecorder {
		let recorder = RequestRecorder()
		let requests = router.pageEngines.protectedMediaRequests()
		recorder.task = Task { [weak recorder] in
			for await request in requests { recorder?.urls.append(request.url) }
		}
		return recorder
	}

	internal func waitFor(_ condition: @MainActor () -> Bool) async throws {
		for _ in 0 ..< 200 where !condition() {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(condition())
	}
}

@MainActor
private final class RequestRecorder {
	internal var urls: [URL] = []
	internal var task: Task<Void, Never>?

	deinit { task?.cancel() }
}

@MainActor
private final class FakeChromium {
	internal var opened: [Tab.ID] = []
	internal var openedURLs: [URL] = []
	internal var commands: [BrowserEngineClient.Command] = []
	internal var closed: [Tab.ID] = []
	internal var permitsClosingAsked: [Tab.ID] = []
	internal var permitsClosing: Bool = true

	/// How long a page takes to answer beforeunload. A question asked while it answers hears
	/// the same answer, as `ChromiumRuntime.permitsClosing` gives it (DEV-1188).
	internal var closingAnswerDelay: Duration?
	private var closingAnswers: [Tab.ID: Task<Bool, Never>] = [:]
	internal var detachedHosts: [NSView] = []

	/// What the router last told each page's own swipe about the WebKit pages beside it.
	internal var sharedHistory: [Tab.ID: (back: Bool, forward: Bool)] = [:]

	/// What each page shows when a test set it; otherwise the last opened address.
	internal var navigations: [Tab.ID: BrowserNavigation] = [:]
	private var sessions: Set<Tab.ID> = []

	/// `events` subscribers, which keep only the newest navigation, as the engine's do.
	private var observers: [Tab.ID: [AsyncStream<BrowserNavigation>.Continuation]] = [:]

	/// `entryChanges` subscribers, and the current entry each page last showed them.
	private var entryObservers: [Tab.ID: [AsyncStream<BrowserNavigation>.Continuation]] = [:]
	private var shownEntries: [Tab.ID: (entry: BrowserNavigation.Entry, isLoading: Bool)] = [:]

	/// The page commits `url`, with `back` before it in its history, and reports it. The entries
	/// in `back` are numbered up to `entryID`, `url`'s.
	internal func show(
		_ id: Tab.ID,
		_ url: URL,
		back: [URL] = [],
		entryID: Int = 0,
		forward: [URL] = []
	) {
		var history = back.enumerated().map { offset, url in
			BrowserNavigation.Entry(id: entryID + offset - back.count, url: url, title: "", isCurrent: false)
		}
		history.append(.init(id: entryID, url: url, title: "", isCurrent: true))
		history += forward.enumerated().map { offset, url in
			BrowserNavigation.Entry(id: entryID + offset + 1, url: url, title: "", isCurrent: false)
		}
		let navigation = BrowserNavigation(
			url: url,
			canGoBack: !back.isEmpty,
			canGoForward: !forward.isEmpty,
			history: history
		)
		navigations[id] = navigation
		report(navigation, for: id)
	}

	/// The page commits `url` without reporting it, as a page that changes its address between
	/// the events the router hears.
	internal func commit(
		_ id: Tab.ID,
		_ url: URL
	) {
		navigations[id] = .init(url: url, history: [.init(id: 0, url: url, title: "", isCurrent: true)])
	}

	/// A new page opening at `url`, before it has any history entry.
	internal func opening(
		_ id: Tab.ID,
		_ url: URL
	) {
		let navigation = BrowserNavigation(url: url, isLoading: true, history: [])
		navigations[id] = navigation
		report(navigation, for: id)
	}

	/// The page failed to load `url`, with no history.
	internal func fail(
		_ id: Tab.ID,
		_ url: URL
	) {
		let navigation = BrowserNavigation(url: url, errorCode: -106)
		navigations[id] = navigation
		report(navigation, for: id)
	}

	/// A history traversal toward `url`, reported before it commits: its entry is already the
	/// current one, and the page is loading. The entries are numbered as `show` numbers them.
	internal func traverse(
		_ id: Tab.ID,
		to url: URL,
		back: [URL],
		entryID: Int = 0
	) {
		var history = back.enumerated().map { offset, url in
			BrowserNavigation.Entry(id: entryID + offset - back.count, url: url, title: "", isCurrent: false)
		}
		history.append(.init(id: entryID, url: url, title: "", isCurrent: true))
		let navigation = BrowserNavigation(url: url, isLoading: true, canGoBack: true, history: history)
		navigations[id] = navigation
		report(navigation, for: id)
	}

	/// A navigation the browser started for `url`, reported before it commits: the address is
	/// `url`, while the current history entry is still `from`.
	internal func start(
		_ id: Tab.ID,
		_ url: URL,
		from: URL
	) {
		let navigation = BrowserNavigation(
			url: url,
			isLoading: true,
			history: [.init(id: 0, url: from, title: "", isCurrent: true)]
		)
		navigations[id] = navigation
		report(navigation, for: id)
	}

	internal var client: BrowserEngineClient {
		var client = BrowserEngineClient(
			status: { .ready },
			snapshot: { [weak self] id in
				guard let self, self.sessions.contains(id) else { return nil }
				return .init(navigation: self.navigations[id] ?? .init(url: self.openedURLs.last), revision: 1)
			},
			openAuthorized: { [weak self] tab, _ in
				self?.opened.append(tab.id)
				self?.openedURLs.append(tab.reopeningURL)
				self?.sessions.insert(tab.id)
			},
			closeAuthorized: { _, _, _, didClose in
				didClose()
				return true
			},
			open: { [weak self] tab in
				self?.opened.append(tab.id)
				self?.openedURLs.append(tab.reopeningURL)
				self?.sessions.insert(tab.id)
			},
			command: { [weak self] _, command in self?.commands.append(command) },
			permitsClosing: { [weak self] id in
				guard let self else { return true }
				self.permitsClosingAsked.append(id)
				guard let delay = self.closingAnswerDelay else { return self.permitsClosing }
				if let answer = self.closingAnswers[id] { return await answer.value }
				let answer = Task { [weak self] in
					try? await Task.sleep(for: delay)
					self?.closingAnswers[id] = nil
					return self?.permitsClosing ?? true
				}
				self.closingAnswers[id] = answer
				return await answer.value
			},
			close: { [weak self] id in
				self?.closed.append(id)
				self?.sessions.remove(id)
				self?.navigations[id] = nil
				self?.observers.removeValue(forKey: id)?.forEach { $0.finish() }
				self?.entryObservers.removeValue(forKey: id)?.forEach { $0.finish() }
				self?.shownEntries[id] = nil
			},
			events: { [weak self] id in
				let (stream, continuation) = AsyncStream<BrowserNavigation>.makeStream(bufferingPolicy: .bufferingNewest(1))
				self?.observers[id, default: []].append(continuation)
				return stream
			}
		)
		client.setSharedHistory = { [weak self] id, back, forward in
			self?.sharedHistory[id] = (back, forward)
		}
		client.entryChanges = { [weak self] id in
			let (stream, continuation) = AsyncStream<BrowserNavigation>.makeStream()
			self?.entryObservers[id, default: []].append(continuation)
			if let navigation = self?.navigations[id] { continuation.yield(navigation) }
			return stream
		}
		return client
	}

	/// Reports the page's navigation to its events, and to its entry changes when its current
	/// history entry changed or started or finished loading, as the engine does.
	private func report(
		_ navigation: BrowserNavigation,
		for id: Tab.ID
	) {
		for observer in observers[id, default: []] { observer.yield(navigation) }
		guard
			let entry = navigation.history.first(where: \.isCurrent),
			shownEntries[id].map({
				$0.entry.id == entry.id && $0.entry.url == entry.url && $0.isLoading == navigation.isLoading
			}) != true
		else { return }

		shownEntries[id] = (entry, navigation.isLoading)
		for observer in entryObservers[id, default: []] { observer.yield(navigation) }
	}

	internal var surface: BrowserSurfaceClient {
		.init(
			attach: { _, _ in },
			detach: { [weak self] host in self?.detachedHosts.append(host) }
		)
	}
}
