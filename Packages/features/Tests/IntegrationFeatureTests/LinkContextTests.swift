import AppKit
import BrowserCore
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct LinkContextTests {
	@Test(arguments: LinkCopyMode.allCases)
	internal func menuSelectionCopiesOnlyTheExplicitLinkWithoutChangingThePinOrSelection(mode: LinkCopyMode) async throws {
		var fixture = LinkMenuFixture()
		fixture.state.main.viewer.item.tab?.savedDestination = .init(title: "Saved", url: URL(string: "https://saved.example/")!)
		fixture.state.main.viewer.item.navigation = .init(url: URL(string: "https://current.example/")!, title: "Current")
		var copied: [String] = []
		let store = Store(initialState: fixture.state) { AppFeature() } withDependencies: {
			$0.linkSharing.copy = {
				copied.append($0)
				return true
			}
		}
		let presenter = LinkContextMenu(
			store: store,
			client: .init(status: { .ready }, linkContextIsCurrent: { _ in true }),
			view: { _ in nil }
		)
		let placement = try #require(store.state.linkContextPlacement(fixture.context))
		let action = try #require(presenter.action(fixture.context, placement: placement, mode: mode))
		await store.send(action).finish()
		let rules = fixture.state.settings.proxyLinkRules
		expectNoDifference(copied, [LinkTransformer.copy([fixture.context.item], mode: mode, rules: rules).text])
		expectNoDifference(store.state.main, fixture.state.main)
		expectNoDifference(store.state.workspace, fixture.state.workspace)
	}

	@Test
	internal func explicitShareUsesTheClickedLinkAndOriginalWindow() async throws {
		let fixture = LinkMenuFixture()
		var shared: [URL] = []
		var source: UUID?
		let store = Store(initialState: fixture.state) { AppFeature() } withDependencies: {
			$0.linkSharing.share = { urls, window in
				shared = urls
				source = window
				return .cancelled
			}
		}
		let presenter = LinkContextMenu(
			store: store,
			client: .init(status: { .ready }, linkContextIsCurrent: { _ in true }),
			view: { _ in nil }
		)
		let placement = try #require(store.state.linkContextPlacement(fixture.context))
		let action = try #require(presenter.action(fixture.context, placement: placement, mode: nil))
		await store.send(action).finish()

		// Through X's rule, the one that matches the link (DEV-1262).
		expectNoDifference(shared, [URL(string: "https://fxtwitter.com/linked-post?a=1&a=2#fragment")!])
		expectNoDifference(source, fixture.state.main.id)
		expectNoDifference(store.state.main, fixture.state.main)
		expectNoDifference(store.state.workspace, fixture.state.workspace)
	}

	@Test(arguments: ["native", "generation", "closed", "profile", "removed", "quit", "transfer", "closing-tab"])
	internal func staleMenuCannotCopyAnotherTabOrRetainAClosedSource(change: String) async throws {
		let fixture = LinkMenuFixture()
		let placement = try #require(fixture.state.linkContextPlacement(fixture.context))
		var state = fixture.state
		switch change {
		case "generation":
			state.main.viewer.item.generation += 1

		case "closed":
			state.windowIsOpen = false

		case "profile":
			state.main.viewer.item.tab = .init(
			id: fixture.context.tabID,
			profileID: .init(rawValue: UUID()),
			restoration: .init(title: "Other profile", url: fixture.context.item.url)
		)

		case "removed":
			state.main.sidebar.organization.tabs.removeAll { $0.id == fixture.context.tabID }

		case "quit":
			state.shouldQuit = true

		case "transfer":
			state.main.transferInProgress = true

		case "closing-tab":
			state.main.pendingTabCloses.insert(fixture.context.tabID)

		default:
			break
		}
		let store = Store(initialState: state) { AppFeature() }
		let presenter = LinkContextMenu(
			store: store,
			client: .init(status: { .ready }, linkContextIsCurrent: { _ in change != "native" }),
			view: { _ in nil }
		)
		#expect(presenter.action(fixture.context, placement: placement, mode: .proxy) == nil)
	}

	@Test
	internal func openItemsUseTheMenusLinkSourceAndSpace() throws {
		let fixture = LinkMenuFixture()
		let store = Store(initialState: fixture.state) { AppFeature() }
		let presenter = LinkContextMenu(
			store: store,
			client: .init(status: { .ready }, linkContextIsCurrent: { _ in true }),
			view: { _ in nil }
		)
		let placement = try #require(store.state.linkContextPlacement(fixture.context))
		let origin = CGPoint(x: 12, y: 34)

		let peek = try #require(presenter.openAction(fixture.context, placement: placement, route: .peek, origin: origin))
		guard case let .ui(.peekURLFromSource(url, source, from)) = peek else {
			Issue.record("Expected Peek, got \(peek)")
			return
		}
		expectNoDifference(url, fixture.context.item.url)
		expectNoDifference(source.windowID, fixture.state.main.id)
		expectNoDifference(source.tabID, fixture.context.tabID)
		expectNoDifference(source.profileID, fixture.context.profileID)
		expectNoDifference(source.spaceID, fixture.state.main.sidebar.spaceID)
		expectNoDifference(from, origin)

		let little = try #require(presenter.openAction(fixture.context, placement: placement, route: .littleArx, origin: origin))
		guard case let .ui(.openLittleArx(space, littleURL)) = little else {
			Issue.record("Expected Little Arx, got \(little)")
			return
		}
		expectNoDifference(space, fixture.state.main.sidebar.spaceID)
		expectNoDifference(littleURL, fixture.context.item.url)
	}

	@Test(arguments: ["native", "generation", "closed", "profile", "removed", "quit", "transfer", "closing-tab"])
	internal func staleMenuCannotOpenTheLinkFromAnotherSource(change: String) throws {
		let fixture = LinkMenuFixture()
		let placement = try #require(fixture.state.linkContextPlacement(fixture.context))
		var state = fixture.state
		switch change {
		case "generation": state.main.viewer.item.generation += 1
		case "closed": state.windowIsOpen = false
		case "profile":
			state.main.viewer.item.tab = .init(
				id: fixture.context.tabID,
				profileID: .init(rawValue: UUID()),
				restoration: .init(title: "Other profile", url: fixture.context.item.url)
			)
		case "removed": state.main.sidebar.organization.tabs.removeAll { $0.id == fixture.context.tabID }
		case "quit": state.shouldQuit = true
		case "transfer": state.main.transferInProgress = true
		case "closing-tab": state.main.pendingTabCloses.insert(fixture.context.tabID)
		default: break
		}
		let store = Store(initialState: state) { AppFeature() }
		let presenter = LinkContextMenu(
			store: store,
			client: .init(status: { .ready }, linkContextIsCurrent: { _ in change != "native" }),
			view: { _ in nil }
		)
		for route in LinkOpenRoute.allCases {
			#expect(presenter.openAction(fixture.context, placement: placement, route: route, origin: nil) == nil)
		}
	}

	@Test
	internal func privateLinksAndOtherSchemesOfferNeitherOpenItem() throws {
		var fixture = LinkMenuFixture()
		var host = MainFeature.State(
			organization: fixture.state.workspace,
			spaceID: fixture.state.main.sidebar.spaceID,
			isPrivate: true,
			id: UUID(20)
		)
		host.viewer.item = fixture.state.main.viewer.item
		fixture.state.windows.append(host)
		let privateContext = fixture.context(isPrivate: true)
		let privatePlacement = try #require(fixture.state.linkContextPlacement(privateContext))

		let store = Store(initialState: fixture.state) { AppFeature() }
		let presenter = LinkContextMenu(
			store: store,
			client: .init(status: { .ready }, linkContextIsCurrent: { _ in true }),
			view: { _ in nil }
		)
		for route in LinkOpenRoute.allCases {
			#expect(presenter.openAction(privateContext, placement: privatePlacement, route: route, origin: nil) == nil)
		}

		let placement = try #require(store.state.linkContextPlacement(fixture.context))
		for url in ["ftp://x.com/file", "mailto:someone@x.com"] {
			for route in LinkOpenRoute.allCases {
				#expect(store.state.linkOpenAction(URL(string: url)!, route: route, placement: placement, origin: nil) == nil)
			}
		}
	}

	/// A tab's menu and the page's, on the address bar, offer the proxy link items only when a
	/// proxy link rule matches the tab's site, or one of the selected tabs' (DEV-1262).
	@Test
	internal func tabAndPageMenusOfferProxyItemsOnlyWhereARuleMatches() async throws {
		let fixture = LinkMenuFixture()
		let store = Store(initialState: fixture.state) { AppFeature() }
		let actions = browserLinkActions(store: store, windowID: store.state.main.id)
		let tabs = store.state.workspace.tabs.map(\.id.rawValue)

		// The fixture's tabs show capturecontext.dev, which no rule matches.
		#expect(!actions.proxies(nil))
		#expect(!actions.proxies([tabs[0]]))
		#expect(!actions.proxies(tabs))

		var state = fixture.state
		state.main.viewer.item = .init(
			tab: state.workspace.tabs[0],
			navigation: .init(url: URL(string: "https://x.com/user/status/1")!, title: "Post")
		)
		let matching = Store(initialState: state) { AppFeature() }
		let matchingActions = browserLinkActions(store: matching, windowID: matching.state.main.id)
		#expect(matchingActions.proxies(nil))
		#expect(matchingActions.proxies([tabs[0]]))
		#expect(!matchingActions.proxies([tabs[1]]))
		#expect(matchingActions.proxies(tabs))
	}

	/// DEV-853: every link gets the menu, as in Chromium; each item decides whether it applies.
	/// The proxy items need a proxy link rule that matches the link's site (DEV-1262).
	@Test(arguments: [
		("https://x.com/post", true, true, true, true),
		("https://example.com/post", true, true, true, false),
		("http://localhost:3000/app", true, true, false, false),
		("https://x.com:8443/post", true, true, false, false),
		("https://user:secret@x.com/post", true, false, false, true),
		("mailto:hello@capturecontext.dev", false, false, false, false),
		("tel:+15555550100", false, false, false, false),
		("javascript:void(0)", false, false, false, false),
	])
	internal func everyLinkGetsTheMenuAndEachItemDecides(
		url: String,
		opens: Bool,
		peeks: Bool,
		cleans: Bool,
		proxies: Bool
	) throws {
		let fixture = LinkMenuFixture()
		let context = fixture.context(isPrivate: false, url: url)
		try context.validate()
		let store = Store(initialState: fixture.state) { AppFeature() }
		let presenter = LinkContextMenu(
			store: store,
			client: .init(status: { .ready }, linkContextIsCurrent: { _ in true }),
			view: { _ in nil }
		)
		let placement = try #require(store.state.linkContextPlacement(context))
		for route in LinkOpenRoute.allCases {
			// Open in Main Window is Little Arx's alone (DEV-855); this link is in the main window.
			let expected = switch route {
			case .peek: peeks
			case .mainWindow: false
			default: opens
			}
			expectNoDifference(
				presenter.openAction(context, placement: placement, route: route, origin: nil) != nil,
				expected,
				"\(route)"
			)
		}
		let expected: [LinkCopyMode: Bool] = [
			.original: true,
			.clean: cleans,
			.markdownOriginal: opens,
			.proxy: proxies,
			.markdownProxy: proxies,
		]
		for mode in LinkCopyMode.allCases {
			expectNoDifference(presenter.action(context, placement: placement, mode: mode) != nil, expected[mode], "\(mode)")
		}
		expectNoDifference(presenter.action(context, placement: placement, mode: nil) != nil, proxies)
		if !opens || url.contains("@x.com") {
			#expect(presenter.downloadAction(context, placement: placement) == nil)
		}
	}

	@Test(arguments: [
		("mailto:hello@capturecontext.dev?subject=Hi", LinkCopyMode.original, "hello@capturecontext.dev"),
		("https://user:secret@x.com/post", .original, "https://user:secret@x.com/post"),
		("https://user:secret@x.com/post", .proxy, "https://fxtwitter.com/post"),
		("https://user:secret@x.com/post", .markdownProxy, "[Actual \\[link\\]](<https://fxtwitter.com/post>)"),
		("http://localhost:3000/app", .original, "http://localhost:3000/app"),
	])
	internal func copyItemsCopyWhatChromiumDoesAndProxyLinksDropCredentials(
		url: String,
		mode: LinkCopyMode,
		expected: String
	) async throws {
		let fixture = LinkMenuFixture()
		let context = fixture.context(isPrivate: false, url: url)
		var copied: [String] = []
		let store = Store(initialState: fixture.state) { AppFeature() } withDependencies: {
			$0.linkSharing.copy = {
				copied.append($0)
				return true
			}
		}
		let presenter = LinkContextMenu(
			store: store,
			client: .init(status: { .ready }, linkContextIsCurrent: { _ in true }),
			view: { _ in nil }
		)
		let placement = try #require(store.state.linkContextPlacement(context))
		let action = try #require(presenter.action(context, placement: placement, mode: mode))
		await store.send(action).finish()
		expectNoDifference(copied, [expected])
	}

	@Test
	internal func shareProxyLinkNeverCarriesCredentials() async throws {
		let fixture = LinkMenuFixture()
		let context = fixture.context(isPrivate: false, url: "https://user:secret@x.com/post")
		var shared: [URL] = []
		let store = Store(initialState: fixture.state) { AppFeature() } withDependencies: {
			$0.linkSharing.share = { urls, _ in
				shared = urls
				return .cancelled
			}
		}
		let presenter = LinkContextMenu(
			store: store,
			client: .init(status: { .ready }, linkContextIsCurrent: { _ in true }),
			view: { _ in nil }
		)
		let placement = try #require(store.state.linkContextPlacement(context))
		let action = try #require(presenter.action(context, placement: placement, mode: nil))
		await store.send(action).finish()
		expectNoDifference(shared, [URL(string: "https://fxtwitter.com/post")!])
	}

	@Test
	internal func linksInsidePeekDoNotOpenAnotherPeek() throws {
		let fixture = LinkMenuFixture()
		let placement = try #require(fixture.state.linkContextPlacement(fixture.context))
		let inside = LinkContextPlacement(
			windowID: placement.windowID,
			paneID: placement.paneID,
			peekID: UUID(77),
			generation: placement.generation
		)
		let state = fixture.state
		#expect(state.linkOpenAction(fixture.context.item.url, route: .peek, placement: inside, origin: nil) == nil)
		#expect(state.linkOpenAction(fixture.context.item.url, route: .peek, placement: placement, origin: nil) != nil)
	}

	@Test
	internal func littleProfileTransitionRejectsThePreviouslyPresentedLink() throws {
		var fixture = LinkMenuFixture()
		let context = fixture.context
		let tab = fixture.state.workspace.tabs[0]
		var little = LittleArxFeature.State(
			id: UUID(30),
			spaceID: fixture.state.main.sidebar.spaceID,
			tab: tab
		)
		little.viewer.tab = tab
		fixture.state.main.viewer.item.tab = nil
		fixture.state.littleWindows.append(little)

		let placement = try #require(fixture.state.linkContextPlacement(context))
		expectNoDifference(placement.windowID, little.id)
		fixture.state.littleWindows[id: little.id]?.isSwitchingProfile = true
		#expect(fixture.state.linkContextPlacement(context) == nil)
	}

	@Test
	internal func focusedOtherWindowDoesNotReplaceTheSourceTarget() async throws {
		var fixture = LinkMenuFixture()
		let original = try #require(fixture.state.linkContextPlacement(fixture.context))
		fixture.state.focusedWindowID = UUID(999)
		expectNoDifference(fixture.state.linkContextPlacement(fixture.context), original)
	}

	@Test
	internal func privateWindowMatchesOnlyItsOwnNativeProfileAndDropsLateFeedbackAfterClose() async throws {
		var fixture = LinkMenuFixture()
		var host = MainFeature.State(
			organization: fixture.state.workspace,
			spaceID: fixture.state.main.sidebar.spaceID,
			isPrivate: true,
			id: UUID(20)
		)
		host.viewer.item = fixture.state.main.viewer.item
		fixture.state.windows.append(host)
		fixture.state.main.viewer.item.tab = nil
		let context = fixture.context(isPrivate: true)
		expectNoDifference(fixture.state.linkContextPlacement(context)?.windowID, host.id)
		#expect(fixture.state.linkContextPlacement(fixture.context) == nil)
		fixture.state.windows.removeAll()
		let store = Store(initialState: fixture.state) { AppFeature() }
		await store.send(.event(.linkActionFinished(0, .init(
			windowID: host.id,
			result: LinkTransformer.copy([context.item], mode: .original),
			status: .copied
		)))).finish()
		#expect(store.linkActionFeedback == nil)
	}
}

@MainActor
private struct LinkMenuFixture {
	fileprivate var state: AppFeature.State

	fileprivate init() {
		let organization = IntegrationFeatureTests().fixture()
		self.state = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		self.state.main.viewer.item = .init(tab: organization.tabs[0], generation: 4)

		// The rules Arx starts with: X's matches the fixture's x.com links (DEV-1262).
		self.state.settings.$proxyLinkRules.withLock { $0 = ProxyLinkRule.defaults }
	}

	fileprivate var context: BrowserLinkContext { context(isPrivate: false) }

	fileprivate func context(
		isPrivate: Bool,
		url: String = "https://x.com/linked-post?a=1&a=2#fragment"
	) -> BrowserLinkContext {
		.init(
			token: 1,
			tabID: state.workspace.tabs[0].id,
			profileID: state.workspace.tabs[0].profileID,
			sessionRevision: 3,
			documentRevision: 7,
			isPrivate: isPrivate,
			item: .init(title: "Actual [link]", url: URL(string: url)!),
			x: 4,
			y: 5
		)
	}
}
