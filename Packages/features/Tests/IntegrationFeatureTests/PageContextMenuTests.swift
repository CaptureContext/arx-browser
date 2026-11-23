@testable import AppFeature
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import CustomDump
import Foundation
@testable import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-814, DEV-815 and DEV-818: the context menus' app items, the link menu's window and
/// download items, and Share… for a page.
@Suite(.dependencies)
@MainActor
internal struct PageContextMenuTests {
	private let page = URL(string: "https://capturecontext.dev/arx")!

	private func state(showing tab: Int = 0) -> (AppFeature.State, BrowserCore.Tab) {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let shown = organization.tabs[tab]
		state.main.sidebar.organization.spaces[0].selectedTabID = shown.id
		state.main.viewer.item.tab = shown
		state.main.viewer.item.navigation = .init(url: page)
		state.main.viewer.item.navigation.title = "Arx"
		return (state, shown)
	}

	@Test
	internal func shareIsAPageCommandForWebPages() throws {
		let web = BrowserCommandContext(host: .main, hasTab: true, canSavePage: true)
		let other = BrowserCommandContext(host: .main, hasTab: true, canSavePage: false)
		let privateWeb = BrowserCommandContext(host: .main, hasTab: true, isPrivate: true, canSavePage: true)
		#expect(BrowserCommand.sharePage.isEnabled(in: web))
		#expect(BrowserCommand.sharePage.isEnabled(in: privateWeb))
		#expect(!BrowserCommand.sharePage.isEnabled(in: other))
		#expect(!BrowserCommand.sharePage.isEnabled(in: .init(host: .main)))

		let (state, tab) = state()
		#expect(state.pageMenuCommands(showing: tab.id).contains(.sharePage))
	}

	@Test
	internal func shareSendsThePagesAddressWithItsTitle() async throws {
		let (state, _) = state()
		let shared = LockIsolated<[ShareContent]>([])
		let windows = LockIsolated<[UUID?]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.shareContent = { content, windowID in
				shared.withValue { $0.append(content) }
				windows.withValue { $0.append(windowID) }
				return .shared
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.command(.sharePage, .window(state.main.id))))
		await store.receive(\.event.linkActionFinished)
		await store.finish()

		expectNoDifference(shared.value, [.page(page, title: "Arx")])
		expectNoDifference(windows.value, [state.main.id])
		expectNoDifference(store.state.linkActionFeedback?.status, .share(.shared))
	}

	@Test
	internal func aWindowPaneOffersEveryItemAndPiPForAListedVideo() throws {
		var (state, tab) = state()
		let host = try #require(state.pageContextHost(showing: tab.id))
		expectNoDifference(host.actions, [.search, .shareText, .openInNewTab])

		state.media = .init(profileID: tab.profileID, isAvailable: true, snapshot: .init(revision: 1, sources: [
			.init(
				id: .init(tabID: tab.id, profileID: tab.profileID, generation: 1), revision: 1, title: "Clip",
				site: nil, hasVideo: true, playback: .playing, actions: [.enterPictureInPicture]
			),
		]))
		let listed = try #require(state.pageContextHost(showing: tab.id))
		expectNoDifference(listed.actions, Set(PageContextAction.Kind.allCases))
		expectNoDifference(host.windowID, state.main.id)
		expectNoDifference(host.profileID, tab.profileID)

		// A tab no host shows offers nothing.
		#expect(state.pageContextHost(showing: .init(rawValue: UUID(99))) == nil)
	}

	@Test
	internal func searchOpensTheProfilesSearchInANewTab() async throws {
		var (state, tab) = state()
		state.main.sidebar.organization.profiles[id: tab.profileID]?.searchEngine = .duckDuckGo
		state.workspace.profiles[id: tab.profileID]?.searchEngine = .duckDuckGo
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.pageContextMenu(tab.id, .search("  arx browser\n"))))
		await store.skipReceivedActions()
		await store.finish()

		let selected = try #require(store.state.main.sidebar.selectedTab)
		expectNoDifference(selected.restoration.url, SearchEngine.duckDuckGo.url(for: "arx browser"))
	}

	@Test
	internal func openInNewTabTakesOnlyWebAddresses() async throws {
		let (state, tab) = state()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let tabs = store.state.main.sidebar.organization.tabs.count

		await store.send(.ui(.pageContextMenu(tab.id, .openInNewTab(URL(string: "file:///etc/hosts")!))))
		#expect(store.state.main.sidebar.organization.tabs.count == tabs)

		let image = URL(string: "https://capturecontext.dev/image.png")!
		await store.send(.ui(.pageContextMenu(tab.id, .openInNewTab(image))))
		await store.skipReceivedActions()
		await store.finish()
		expectNoDifference(store.state.main.sidebar.selectedTab?.restoration.url, image)
	}

	@Test
	internal func linkDownloadsStartInTheirOrdinaryProfile() async throws {
		var (state, tab) = state()
		state.downloadsReady = true
		let started = LockIsolated<[(Profile.ID, URL)]>([])
		let image = URL(string: "https://capturecontext.dev/image.png")!
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserDownloads.start = { profile, url in
				started.withValue { $0.append((profile, url)) }
				return .init(profileID: profile, guid: "guid")
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.downloadURL(image, tab.profileID))
		await store.finish()

		#expect(started.value.count == 1)
		#expect(started.value.first?.0 == tab.profileID && started.value.first?.1 == image)
	}

	@Test
	internal func aFailedDownloadSaysSo() async throws {
		var (state, _) = state()
		state.downloadsReady = true
		let profile = state.workspace.profiles[0].id
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserDownloads.start = { _, _ in throw BrowserDownloadsClient.Failure.couldNotStart }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.downloadURL(URL(string: "https://capturecontext.dev/file.zip")!, profile))
		await store.receive(\.delegate.commandFailed)
		await store.finish()
	}

	/// DEV-851: Download Linked File starts in the engine at once, while the link menu is
	/// current, so it carries the link's page as its referrer; the app then waits for the item.
	@Test
	internal func aLinkMenuDownloadStartsInTheEngineAtOnce() async throws {
		var (state, tab) = state()
		state.downloadsReady = true
		let context = Self.linkContext(tab)
		let started = LockIsolated<[BrowserLinkContext]>([])
		let waited = LockIsolated<[UInt64]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.startLinkContextDownload = { context in
				started.withValue { $0.append(context) }
				return 7
			}
			$0.browserEngine.linkContextDownload = { context, request in
				waited.withValue { $0.append(request) }
				return .init(profileID: context.profileID, guid: "guid")
			}
			$0.browserDownloads.start = { _, _ in
				Issue.record("The engine started it")
				throw BrowserDownloadsClient.Failure.unavailable
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.downloadLink(context))

		// Started while the action ran, before any effect: the menu ends right after.
		expectNoDifference(started.value, [context])
		await store.finish()

		expectNoDifference(waited.value, [7])
	}

	/// An engine that can't download from the link's frame starts a plain download, as before.
	@Test
	internal func aLinkMenuDownloadFallsBackToAPlainDownload() async throws {
		var (state, tab) = state()
		state.downloadsReady = true
		let context = Self.linkContext(tab)
		let started = LockIsolated<[(Profile.ID, URL)]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserDownloads.start = { profile, url in
				started.withValue { $0.append((profile, url)) }
				return .init(profileID: profile, guid: "guid")
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.downloadLink(context))
		await store.finish()

		#expect(started.value.count == 1)
		#expect(started.value.first?.0 == tab.profileID && started.value.first?.1 == context.item.url)
	}

	@Test
	internal func aFailedLinkMenuDownloadSaysSo() async throws {
		var (state, tab) = state()
		state.downloadsReady = true
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.startLinkContextDownload = { _ in 7 }
			$0.browserEngine.linkContextDownload = { _, _ in throw BrowserDownloadsClient.Failure.couldNotStart }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.downloadLink(Self.linkContext(tab)))
		await store.receive(\.delegate.commandFailed)
		await store.finish()
	}

	private static func linkContext(_ tab: BrowserCore.Tab) -> BrowserLinkContext {
		.init(
			token: 3,
			tabID: tab.id,
			profileID: tab.profileID,
			sessionRevision: 1,
			documentRevision: 1,
			isPrivate: false,
			item: .init(title: "File", url: URL(string: "https://capturecontext.dev/file.zip")!),
			x: 10,
			y: 10
		)
	}

	@Test
	internal func aSharedSelectionGoesToTheShareSheetOfItsWindow() async throws {
		let (state, tab) = state()
		let shared = LockIsolated<[ShareContent]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.shareContent = { content, windowID in
				#expect(windowID == state.main.id)
				shared.withValue { $0.append(content) }
				return .failed("No sharing services")
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.pageContextMenu(tab.id, .shareText("Selected words"))))
		await store.receive(\.delegate.commandFailed)
		await store.finish()
		expectNoDifference(shared.value, [.text("Selected words")])
	}

	@Test
	internal func theLinkMenuOpensANewWindowOnTheSourcesSpace() async throws {
		let (state, tab) = state()
		let placement = LinkContextPlacement(
			windowID: state.main.id, paneID: state.main.viewer.activePaneID, generation: 0
		)
		let link = URL(string: "https://capturecontext.dev/link")!
		let action = try #require(state.linkOpenAction(link, route: .newWindow, placement: placement, origin: nil))
		guard case let .openInNewWindow(url, spaceID) = action else {
			Issue.record("Expected a new window, got \(action)")
			return
		}
		expectNoDifference(url, link)
		expectNoDifference(spaceID, state.main.sidebar.spaceID)
		#expect(state.linkOpenAction(URL(string: "mailto:a@b.c")!, route: .newWindow, placement: placement, origin: nil).map { _ in true } == nil)

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(action)
		await store.skipReceivedActions()
		await store.finish()

		let window = try #require(store.state.windows.last)
		#expect(!window.isPrivate && store.state.focusedWindowID == window.id)
		expectNoDifference(window.sidebar.spaceID, state.main.sidebar.spaceID)
		expectNoDifference(window.sidebar.selectedTab?.restoration.url, link)
		expectNoDifference(window.sidebar.selectedTab?.profileID, tab.profileID)
	}

	@Test
	internal func theLinkMenuOpensAPrivateWindowWithTheLinkOnceItIsReady() async throws {
		let (state, _) = state()
		let link = URL(string: "https://capturecontext.dev/link")!
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.preparePrivateProfile = { _, _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.openInPrivateWindow(link, opener: nil))
		#expect(store.state.privateWindowURLs.values.contains(link))
		await store.receive(\.event.privateWindowReady)
		await store.skipReceivedActions()
		await store.finish()

		let window = try #require(store.state.windows.last)
		#expect(window.isPrivate)
		expectNoDifference(window.sidebar.selectedTab?.restoration.url, link)
		#expect(store.state.privateWindowURLs.isEmpty)
		// Nothing from the private window reaches the durable workspace.
		#expect(!store.state.workspace.tabs.contains { $0.restoration.url == link })
	}

	@Test
	internal func aFailedPrivateWindowKeepsTheOthersLinks() async throws {
		var (state, _) = state()
		let first = URL(string: "https://capturecontext.dev/first")!
		let second = URL(string: "https://capturecontext.dev/second")!
		state.privateWindowURLs = [UUID(1): first, UUID(2): second]

		// DEV-889: the failed window's opener reservation goes; one still preparing stays.
		let opener = state.workspace.profiles[0].id
		let failed = Profile.ID(rawValue: UUID(3))
		let preparing = Profile.ID(rawValue: UUID(4))
		state.privateProfileOpeners = [failed: opener, preparing: opener]
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.privateWindowFailed(UUID(1), failed, "No profile")))
		await store.receive(\.delegate.commandFailed)
		await store.finish()
		expectNoDifference(store.state.privateWindowURLs, [UUID(2): second])
		expectNoDifference(store.state.privateProfileOpeners, [preparing: opener])
	}

	@Test
	internal func aPrivateWindowFromALinkFollowsTheSourcesProfile() async throws {
		var (state, tab) = state()
		state.focusedWindowID = nil  // Nothing focused: only the link names the profile.
		let placement = LinkContextPlacement(
			windowID: state.main.id, paneID: state.main.viewer.activePaneID, generation: 0
		)
		let link = URL(string: "https://capturecontext.dev/link")!
		let action = try #require(state.linkOpenAction(link, route: .privateWindow, placement: placement, origin: nil))
		guard case let .openInPrivateWindow(url, opener) = action else {
			Issue.record("Expected a private window, got \(action)")
			return
		}
		expectNoDifference(url, link)
		expectNoDifference(opener, tab.profileID)

		let openers = LockIsolated<[Profile.ID?]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.preparePrivateProfile = { _, opener in openers.withValue { $0.append(opener) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(action)
		await store.receive(\.event.privateWindowReady)
		await store.skipReceivedActions()
		await store.finish()
		expectNoDifference(openers.value, [tab.profileID])
	}

	@Test
	internal func pictureInPictureAsksMediaForArxPiP() async throws {
		var (state, tab) = state()
		let source = BrowserMediaSource(
			id: .init(tabID: tab.id, profileID: tab.profileID, generation: 1), revision: 1, title: "Clip",
			site: nil, hasVideo: true, playback: .playing, actions: [.enterPictureInPicture]
		)
		state.media = .init(profileID: tab.profileID, isAvailable: true, snapshot: .init(revision: 1, sources: [source]))
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.pageContextMenu(tab.id, .pictureInPicture)))

		// MediaFeature takes it from here, as for Media's own PiP button.
		await store.receive(\.media.ui.perform)
		await store.finish()
	}
}
