import AppUI
import BrowserCore
import BrowserEngineClient
import Clocks
import CustomDump
import Foundation
import MainFeature
import PageReaderClient
import Testing
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

/// DEV-1028: reading mode lays the page's article over the page and closes back to it untouched.
@Suite(.dependencies)
@MainActor
internal struct ReadingModeTests {
	private static let story: URL = URL(string: "https://news.example/2026/11/story")!
	private static let article: ReaderArticle = .init(url: story, title: "Story", html: "<p>Words.</p>")

	private func loaded(_ url: URL = Self.story) -> BrowserNavigation {
		Self.loaded(url)
	}

	private static func loaded(_ url: URL = Self.story) -> BrowserNavigation {
		.init(url: url, title: "Story", isLoading: false)
	}

	/// A loaded page is checked for an article once, after a pause, and the address offers
	/// reading mode when it has one. Its own later updates don't check it again.
	@Test
	internal func aLoadedPageIsCheckedOnceForAnArticle() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let clock = TestClock<Duration>()
		let checks = LockIsolated(0)
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 1)) {
			ViewerItemFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.pageReader.isEnabled = { true }
			$0.pageReader.isReadable = { _ in checks.withValue { $0 += 1 }; return true }
		}
		store.exhaustivity = .off

		// Still loading: not yet.
		await store.send(.event(.navigation(tab.id, 1, .init(url: Self.story, isLoading: true))))
		await store.send(.event(.navigation(tab.id, 1, loaded())))
		await clock.advance(by: ViewerItemFeature.readabilityDelay)
		await store.receive(\.event.readabilityChecked) { $0.isReadable = true }

		var retitled = loaded()
		retitled.title = "Story, updated"
		await store.send(.event(.navigation(tab.id, 1, retitled)))
		await clock.advance(by: ViewerItemFeature.readabilityDelay)
		await store.finish()
		#expect(checks.value == 1)
	}

	/// Reading mode shows the article over the page, and closing it leaves the page as it was:
	/// no command reaches the page, so nothing reloads or scrolls.
	@Test
	internal func readingModeOpensOverThePageAndClosesWithoutTouchingIt() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.pageReader.isEnabled = { true }
			$0.pageReader.article = { _ in Self.article }
			$0.browserEngine.command = { _, command in commands.withValue { $0.append(command) } }
		}

		await store.send(.ui(.readerToggled)) {
			$0.reader = .reading
			$0.urlBarPageButton = .readingMode(isReading: true)
		}
		await store.receive(\.event.articleRead) {
			$0.reader = .article(Self.article)
			$0.isReadable = true
		}
		await store.send(.ui(.readerToggled))
		await store.receive(\.ui.readerClosed) {
			$0.reader = nil
			$0.urlBarPageButton = .readingMode(isReading: false)
		}
		#expect(commands.value.isEmpty)
	}

	/// A page without an article says so; going to another page closes reading mode, and moving
	/// within the page doesn't.
	@Test
	internal func anotherPageClosesReadingModeAndAFragmentDoesNot() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.reader = .article(Self.article)
		initial.urlBarPageButton = .readingMode(isReading: true)
		initial.isReadable = true
		initial.readabilityChecked = Self.story.absoluteString
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.pageReader.isEnabled = { false }
		}

		let section = URL(string: "https://news.example/2026/11/story#comments")!
		await store.send(.event(.navigation(tab.id, 1, loaded(section)))) {
			$0.navigation = self.loaded(section)
		}
		await store.receive(\.delegate.navigation)

		let next = URL(string: "https://news.example/2026/11/next")!
		await store.send(.event(.navigation(tab.id, 1, .init(url: next, isLoading: true)))) {
			$0.navigation = .init(url: next, isLoading: true)
			$0.reader = nil
			$0.isReadable = false
			$0.readabilityChecked = nil

			// DEV-1254: the button's room is held until the next page settles.
			$0.urlBarPageButton = .reserved
		}
		await store.receive(\.delegate.navigation)
	}

	/// Reload brings a new document to the same address: the article read from the old one goes,
	/// and the new one is checked again. A frame in the page loading keeps reading mode open.
	@Test
	internal func reloadClosesReadingModeAndAFrameLoadingDoesNot() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.reader = .article(Self.article)
		initial.urlBarPageButton = .readingMode(isReading: true)
		initial.isReadable = true
		initial.readabilityChecked = Self.story.absoluteString
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.pageReader.isEnabled = { false }
			$0.browserEngine.command = { _, _ in }
		}

		// An ad's frame loading: the engine reports the page loading at the same address.
		await store.send(.event(.navigation(tab.id, 1, .init(url: Self.story, isLoading: true)))) {
			$0.navigation = .init(url: Self.story, isLoading: true)
		}
		await store.receive(\.delegate.navigation)

		await store.send(.ui(.command(.reload))) {
			$0.reader = nil
			$0.isReadable = false
			$0.readabilityChecked = nil
			$0.urlBarPageButton = .reserved
		}
		await store.finish()
	}

	/// DEV-1065: a new document at the same address, from a reload Arx didn't send (the page's
	/// own location.reload() or AppleScript), closes reading mode and checks the page again. A
	/// fragment or a frame loading in the same document keeps it, and so does the first report
	/// after the same tab is shown again.
	@Test
	internal func aNewDocumentAtTheSameAddressClosesReadingMode() async throws {
		var tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		tab.restoration.url = Self.story
		let clock = TestClock<Duration>()
		let checks = LockIsolated(0)
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.navigation.document = 3
		initial.document = 3
		initial.reader = .article(Self.article)
		initial.urlBarPageButton = .readingMode(isReading: true)
		initial.isReadable = true
		initial.readabilityChecked = Self.story.absoluteString
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.pageReader.isEnabled = { true }
			$0.pageReader.isReadable = { _ in checks.withValue { $0 += 1 }; return false }
			$0.pageReader.article = { _ in Self.article }
		}
		store.exhaustivity = .off

		// A frame loading, then a fragment, in the same document.
		var frame = Self.loaded(Self.story)
		frame.isLoading = true
		frame.document = 3
		await store.send(.event(.navigation(tab.id, 1, frame)))
		var fragment = Self.loaded(URL(string: "https://news.example/2026/11/story#comments")!)
		fragment.document = 3
		await store.send(.event(.navigation(tab.id, 1, fragment)))
		#expect(store.state.reader == .article(Self.article))

		// The page reloads itself.
		var reloaded = Self.loaded(Self.story)
		reloaded.document = 4
		await store.send(.event(.navigation(tab.id, 1, reloaded))) {
			$0.reader = nil
			$0.isReadable = false
			$0.document = 4
		}
		await clock.advance(by: ViewerItemFeature.readabilityDelay)
		await store.receive(\.event.readabilityChecked)
		#expect(checks.value == 1)
		#expect(store.state.readabilityChecked == Self.story.absoluteString)

		// Reading again, then shown again: the navigation starts over without a document, and
		// the first report of the same one keeps reading mode open.
		await store.send(.ui(.readerToggled))
		await store.receive(\.event.articleRead)
		#expect(store.state.reader == .article(Self.article))
		await store.send(.show(tab))
		var same = Self.loaded(Self.story)
		same.document = 4
		await store.send(.event(.navigation(tab.id, store.state.generation, same)))
		#expect(store.state.reader == .article(Self.article))
		await store.skipInFlightEffects(strict: false)
	}

	/// An article check that finishes after a new document came answers for the old one.
	@Test
	internal func aCheckOfTheOldDocumentIsIgnored() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.document = 4
		let store = TestStore(initialState: initial) { ViewerItemFeature() }

		await store.send(.event(.readabilityChecked(tab.id, Self.story, document: 3, true)))
		#expect(!store.state.isReadable)
	}

	@Test
	internal func aPageWithoutAnArticleSaysSo() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.pageReader.isEnabled = { true }
			$0.pageReader.article = { _ in nil }
		}

		await store.send(.ui(.readerToggled)) {
			$0.reader = .reading
			$0.urlBarPageButton = .readingMode(isReading: true)
		}
		await store.receive(\.event.articleRead) { $0.reader = .unavailable }
	}

	/// A link in the article closes reading mode and the page follows it.
	@Test
	internal func aLinkInTheArticleOpensInThePage() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.reader = .article(Self.article)
		initial.urlBarPageButton = .readingMode(isReading: true)
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.browserEngine.command = { _, command in commands.withValue { $0.append(command) } }
		}

		// An email link goes to Mail and leaves the article open.
		let mail = URL(string: "mailto:editor@news.example")!
		await store.send(.ui(.readerLinkOpened(mail)))
		await store.receive(\.ui.command)

		let link = URL(string: "https://news.example/related")!
		await store.send(.ui(.readerLinkOpened(link))) {
			$0.reader = nil
			$0.urlBarPageButton = nil
		}
		await store.receive(\.ui.command)
		await store.finish()
		expectNoDifference(commands.value, [.navigate(mail), .navigate(link)])
	}

	/// DEV-1066: in reading mode, ⌘F, ⌘G and ⇧⌘G search the article and leave reading mode open;
	/// nothing reaches the page under it. The bar's count is the article's, for the latest search.
	@Test
	internal func findSearchesTheArticleInReadingMode() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.reader = .article(Self.article)
		initial.urlBarPageButton = .readingMode(isReading: true)
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.browserEngine.command = { _, command in commands.withValue { $0.append(command) } }
		}

		await store.send(.ui(.findPresented)) {
			$0.findQuery = ""
			$0.findFocusRequests = 1
		}
		await store.send(.ui(.findChanged("river"))) {
			$0.findQuery = "river"
			$0.readerFind = .init(query: "river", forward: true, newSession: true, serial: 1)
		}
		await store.send(.ui(.readerFound(serial: 1, .init(matches: 3, active: 1)))) {
			$0.readerFindResult = .init(matches: 3, active: 1)
		}
		await store.send(.ui(.findStepped(forward: true))) {
			$0.readerFind = .init(query: "river", forward: true, newSession: false, serial: 2)
		}
		await store.send(.ui(.findStepped(forward: false))) {
			$0.readerFind = .init(query: "river", forward: false, newSession: false, serial: 3)
		}

		// An answer to an earlier search changes nothing.
		await store.send(.ui(.readerFound(serial: 2, .init(matches: 3, active: 2))))
		await store.send(.ui(.readerFound(serial: 3, .init(matches: 3, active: 3)))) {
			$0.readerFindResult = .init(matches: 3, active: 3)
		}
		await store.send(.ui(.findDismissed)) {
			$0.findQuery = nil
			$0.readerFind = .init(query: "", forward: true, newSession: true, serial: 4)
			$0.readerFindResult = nil
		}
		#expect(store.state.reader == .article(Self.article))
		#expect(commands.value.isEmpty)
	}

	/// DEV-1222: in reading mode, ⌘F on a Find bar that's already open, after focus went back to
	/// the article, asks for the field again and keeps the article's search as it was.
	@Test
	internal func findOnAnOpenBarInReadingModeFocusesItsFieldAgain() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.reader = .article(Self.article)
		initial.urlBarPageButton = .readingMode(isReading: true)
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		}

		await store.send(.ui(.findPresented)) {
			$0.findQuery = ""
			$0.findFocusRequests = 1
		}
		await store.send(.ui(.findChanged("river"))) {
			$0.findQuery = "river"
			$0.readerFind = .init(query: "river", forward: true, newSession: true, serial: 1)
		}
		await store.send(.ui(.findPresented)) { $0.findFocusRequests = 2 }
		#expect(store.state.reader == .article(Self.article))
	}

	/// DEV-1066: Use Selection for Find, then ⌘G, searches the article for the selection.
	@Test
	internal func findNextWithASeedSearchesTheArticle() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.reader = .reading
		initial.urlBarPageButton = .readingMode(isReading: true)
		initial.findSeed = "river"
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		}

		await store.send(.ui(.findStepped(forward: true))) {
			$0.findQuery = "river"
			$0.findSeed = nil
			$0.readerFind = .init(query: "river", forward: true, newSession: true, serial: 1)
		}
	}

	/// DEV-1066: Find opened while the article is read searches the page when there's none.
	@Test
	internal func findOpenedWhileReadingSearchesThePageWithoutAnArticle() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.reader = .reading
		initial.urlBarPageButton = .readingMode(isReading: true)
		initial.findQuery = "river"

		// ⇧⌘G: it searches the page backward.
		initial.readerFind = .init(query: "river", forward: false, serial: 1)
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.browserEngine.command = { _, command in commands.withValue { $0.append(command) } }
		}

		await store.send(.event(.articleRead(tab.id, Self.story, nil))) {
			$0.reader = nil
			$0.readerFind = .init(query: "", serial: 2)
			$0.urlBarPageButton = nil
		}
		await store.receive(\.ui.command)
		await store.finish()
		expectNoDifference(commands.value, [.find("river", forward: false, newSession: true)])
	}

	/// DEV-1028: on a page without an article, Find closes reading mode and searches the page.
	@Test
	internal func withoutAnArticleFindSearchesThePage() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.reader = .unavailable
		initial.urlBarPageButton = .readingMode(isReading: true)
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		}

		await store.send(.ui(.findPresented)) {
			$0.reader = nil
			$0.findQuery = ""
			$0.findFocusRequests = 1
			$0.urlBarPageButton = nil
		}

		var stepping = initial
		stepping.findSeed = "river"
		let stepped = TestStore(initialState: stepping) {
			ViewerItemFeature()
		} withDependencies: {
			$0.browserEngine.command = { _, _ in }
		}
		await stepped.send(.ui(.findStepped(forward: true))) {
			$0.reader = nil
			$0.findQuery = "river"
			$0.findSeed = nil
			$0.urlBarPageButton = nil
		}
		await stepped.receive(\.ui.command)
	}

	/// DEV-1066: closing reading mode closes the Find bar searching its article, and the next
	/// reader starts with no search.
	@Test
	internal func closingReadingModeClosesItsFind() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.reader = .article(Self.article)
		initial.urlBarPageButton = .readingMode(isReading: true)
		initial.findQuery = "river"
		initial.readerFind = .init(query: "river", serial: 1)
		initial.readerFindResult = .init(matches: 3, active: 1)
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		}

		await store.send(.ui(.readerClosed)) {
			$0.reader = nil
			$0.findQuery = nil
			$0.readerFind = .init(query: "", serial: 2)
			$0.readerFindResult = nil
			$0.urlBarPageButton = nil
		}
	}

	/// DEV-1066: opening reading mode ends the page's search first, so Find then searches the
	/// article.
	@Test
	internal func openingReadingModeEndsThePagesFind() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		initial.findQuery = "river"
		let store = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.pageReader.isEnabled = { true }
			$0.pageReader.article = { _ in Self.article }
			$0.browserEngine.command = { _, command in commands.withValue { $0.append(command) } }
		}
		store.exhaustivity = .off

		await store.send(.ui(.readerToggled)) {
			$0.findQuery = nil
			$0.reader = .reading
		}
		await store.receive(\.event.articleRead)
		await store.finish()
		expectNoDifference(commands.value, [.stopFind])
	}

	/// With the feature flag off, or on a page that isn't on the web or shows in WebKit, there's
	/// no reading mode.
	@Test
	internal func nothingReadsWithTheFlagOffOrOffTheWeb() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		var initial = ViewerItemFeature.State(tab: tab, generation: 1)
		initial.navigation = loaded()
		let off = TestStore(initialState: initial) {
			ViewerItemFeature()
		} withDependencies: {
			$0.pageReader.isEnabled = { false }
		}
		await off.send(.ui(.readerToggled))

		var webKit = initial
		webKit.navigation.engine = .webKit
		let onWebKit = TestStore(initialState: webKit) {
			ViewerItemFeature()
		} withDependencies: {
			$0.pageReader.isEnabled = { true }
		}
		await onWebKit.send(.ui(.readerToggled))

		var file = initial
		file.navigation.url = URL(fileURLWithPath: "/Users/me/story.html")
		let onFile = TestStore(initialState: file) {
			ViewerItemFeature()
		} withDependencies: {
			$0.pageReader.isEnabled = { true }
		}
		await onFile.send(.ui(.readerToggled))
	}

	/// Reading Mode has its own shortcut, ⌃⌘R, which no other command takes, and it's offered
	/// only with its feature flag on, on an ordinary page that isn't private.
	@Test
	internal func theCommandsShortcutAndAvailability() {
		let shortcut = BrowserCommand.readingMode.shortcut
		#expect(shortcut == KeyboardShortcut(key: "r", modifiers: [.command, .control]))
		let others = BrowserCommand.allCases.filter { $0 != .readingMode }.flatMap(\.defaultShortcuts)
		#expect(!others.contains { $0 == shortcut })

		let page = BrowserCommandContext(host: .main, hasTab: true, canSavePage: true, readingModeEnabled: true)
		#expect(BrowserCommand.readingMode.isEnabled(in: page))
		for host in [BrowserCommandContext.Host.peek, .little] {
			var hosted = page
			hosted.host = host
			#expect(BrowserCommand.readingMode.isEnabled(in: hosted))
		}
		var flagOff = page
		flagOff.readingModeEnabled = false
		#expect(!BrowserCommand.readingMode.isEnabled(in: flagOff))
		var isPrivate = page
		isPrivate.isPrivate = true
		#expect(!BrowserCommand.readingMode.isEnabled(in: isPrivate))
		var webKit = page
		webKit.usesWebKit = true
		#expect(!BrowserCommand.readingMode.isEnabled(in: webKit))
		var notAPage = page
		notAPage.canSavePage = false
		#expect(!BrowserCommand.readingMode.isEnabled(in: notAPage))
		notAPage.isReading = true
		#expect(BrowserCommand.readingMode.isEnabled(in: notAPage))
	}

	/// In Split View, Reading Mode acts on the pane it's for.
	@Test
	internal func readingModeActsOnItsPane() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, readingModeEnabled: true)
		let second = UUID(81)
		state.viewer.item.tab = organization.tabs[0]
		state.viewer.item.navigation = loaded(URL(string: "https://first.example/")!)
		state.viewer.panes.append(.init(id: second, item: .init(tab: organization.tabs[1], navigation: loaded())))
		let store = Store(initialState: state) { MainFeature() } withDependencies: {
			$0.pageReader.isEnabled = { true }
			$0.pageReader.article = { _ in Self.article }
		}

		await store.send(.ui(.paneCommand(.readingMode, second))).finish()

		#expect(store.viewer.panes[id: second]?.item.reader == .article(Self.article))
		#expect(store.viewer.item.reader == nil)
	}
}
