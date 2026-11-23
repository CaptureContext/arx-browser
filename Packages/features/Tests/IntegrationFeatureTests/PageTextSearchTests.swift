@testable import AppFeature
import BrowserCore
import BrowserEngineClient
import BrowserHistoryClient
import Clocks
@testable import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import PageTextIndexClient
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1068: history search finds pages by the words in them, after what matched by title or
/// address, with the passage that matched; the words are read from the pages a profile visits,
/// never in a private window, and go with its history.
@Suite(.dependencies)
@MainActor
internal struct PageTextSearchTests {
	private nonisolated static let profileID: Profile.ID = .init(rawValue: UUID(1))
	private nonisolated static let spaceID: Space.ID = .init(rawValue: UUID(2))
	private nonisolated static let mill: URL = URL(string: "https://news.example/mill")!
	private nonisolated static let bridge: URL = URL(string: "https://news.example/bridge")!
	private nonisolated static let watermill: URL = URL(string: "https://watermill.example/")!

	// MARK: - Command bar

	/// A page found only by a word in its text is listed after the pages whose title or address
	/// has the word, with the passage as its subtitle; more visited pages first.
	@Test
	internal func aWordFromAPageFindsItWithThePassage() async throws {
		let clock = TestClock()
		let searched = LockIsolated<[String]>([])
		var state = CommandBarFeature.State(isPresented: true, mode: .newTab, candidates: Self.candidates)
		state.pageTextProfileID = Self.profileID
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTextIndex = .init(isAvailable: true, search: { profileID, query, _ in
				#expect(profileID == Self.profileID)
				searched.withValue { $0.append(query) }
				return [
					.init(url: Self.bridge, passage: "…the old watermill below the bridge…"),
					.init(url: Self.mill, passage: "…the watermill turned the river's fall…"),
				]
			})
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.queryChanged("watermill")))
		await clock.advance(by: CommandBarFeature.pageTextDelay)
		await store.receive(\.event.pageTextFound)

		let history = store.state.entries.filter(\.isHistory)

		// The address with the word first, then the pages found by their words, the more
		// visited first, each with its passage.
		expectNoDifference(history.map(\.pageURL), [Self.watermill, Self.mill, Self.bridge])
		expectNoDifference(history[1].presentation.subtitle, "…the watermill turned the river's fall…")
		expectNoDifference(history[2].presentation.subtitle, "…the old watermill below the bridge…")
		expectNoDifference(searched.value, ["watermill"])
	}

	/// A private window has no page text to search; two letters, or the address the bar opened
	/// with, aren't searched; and an answer for text typed since is dropped.
	@Test
	internal func searchesOnlyItsProfileForWhatsTypedNow() async throws {
		let clock = TestClock()
		let searched = LockIsolated(0)
		let index = PageTextIndexClient(isAvailable: true, search: { _, _, _ in
			searched.withValue { $0 += 1 }
			return [.init(url: Self.mill, passage: "…")]
		})

		let privateWindow = TestStore(initialState: CommandBarFeature.State(isPresented: true, mode: .newTab, candidates: Self.candidates)) {
			CommandBarFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.pageTextIndex = index
		}
		privateWindow.exhaustivity = .off(showSkippedAssertions: false)
		await privateWindow.send(.ui(.queryChanged("watermill")))
		await clock.advance(by: .seconds(1))

		var state = CommandBarFeature.State(isPresented: true, mode: .newTab, candidates: Self.candidates)
		state.pageTextProfileID = Self.profileID
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTextIndex = index
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.queryChanged("wa")))
		await clock.advance(by: .seconds(1))
		#expect(searched.value == 0)

		// An answer for older text is dropped.
		await store.send(.event(.pageTextFound(query: "water", [.init(url: Self.mill, passage: "…")])))
		#expect(store.state.pageTextHits.isEmpty)
	}

	/// The command bar's history mode lists the pages found by their words too, after the others.
	@Test
	internal func historyModeListsThemToo() async throws {
		var state = CommandBarFeature.State(isPresented: true, mode: .history, candidates: Self.candidates)
		state.query = "watermill"
		state.pageTextQuery = "watermill"
		state.pageTextHits = [.init(url: Self.mill, passage: "…the watermill…")]
		expectNoDifference(state.entries.map(\.pageURL), [Self.watermill, Self.mill])
	}

	// MARK: - The app

	/// A new visit's page text is read after a moment and kept for its profile; a clear in
	/// between wins.
	@Test
	internal func aVisitedPagesTextIsKeptUnlessHistoryWasClearedSince() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let profile = organization.profiles[0].id
		let tab = organization.tabs[0]
		state.main.viewer.item.tab = tab
		state.history.snapshots[profile] = .init(profileID: profile)
		state.history.knownProfiles = Set(organization.profiles.map(\.id))
		let clock = TestClock()
		let saved = LockIsolated<[PageText]>([])
		let cleared = LockIsolated<[Profile.ID]>([])
		let url = URL(string: "https://news.example/mill")!

		// The page read is the one visited; a fragment doesn't change that.
		let readAt = LockIsolated("https://news.example/mill#history")
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.continuousClock = clock
			$0.browserHistory = .init()
			$0.browserEngine.evaluateScript = { id, script, _, _, _ in
				#expect(id == tab.id)
				#expect(script == ProfileHistory.pageTextScript)
				let address = readAt.value
				return .value(#"{"url":"\#(address)","text":"Built in 1724, the watermill turned the river's fall."}"#)
			}
			$0.pageTextIndex = .init(
				isAvailable: true,
				save: { _, page, _ in saved.withValue { $0.append(page) } },
				clear: { profileID, _ in cleared.withValue { $0.append(profileID) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.viewer(.item(.delegate(.navigation(tab.id, .init(url: url, title: "The mill")))))))
		await clock.advance(by: ProfileHistory.pageTextDelay)
		await store.receive(\.history.pageTextRead)
		await store.finish()
		expectNoDifference(saved.value, [.init(url: url, title: "The mill", text: "Built in 1724, the watermill turned the river's fall.", visited: Date(timeIntervalSince1970: 100))])

		// Another page loaded in the tab meanwhile: its text isn't kept under this address.
		readAt.setValue("https://news.example/next")
		let other = URL(string: "https://news.example/other")!
		await store.send(.main(.viewer(.item(.delegate(.navigation(tab.id, .init(url: other, title: "Other")))))))
		await clock.advance(by: ProfileHistory.pageTextDelay)
		await store.finish()
		#expect(saved.value.count == 1)

		// Read, then history cleared or a page deleted before it arrived: it isn't kept.
		let late = PageText(url: url, title: "The mill", text: "late", visited: Date(timeIntervalSince1970: 100))
		await store.send(.settings(.delegate(.clearHistory(profile))))
		await store.send(.history(.pageTextRead(tab.id, profile, late, generation: 0)))
		await store.send(.main(.delegate(.removeHistory(profile, .site("news.example")))))
		await store.send(.history(.pageTextRead(tab.id, profile, late, generation: 1)))
		await store.finish()
		#expect(saved.value.count == 1)
		#expect(cleared.value == [profile])
	}

	/// Reading mode's check for an article can hold the page as its text is read: the read asks
	/// again, and the page keeps its text (DEV-1164).
	@Test
	internal func aReadThatFindsThePageBusyAsksAgain() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let profile = organization.profiles[0].id
		let tab = organization.tabs[0]
		state.main.viewer.item.tab = tab
		state.history.snapshots[profile] = .init(profileID: profile)
		state.history.knownProfiles = Set(organization.profiles.map(\.id))
		let clock = TestClock()
		let saved = LockIsolated<[PageText]>([])
		let reads = LockIsolated(0)
		let url = URL(string: "https://news.example/mill")!
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.continuousClock = clock
			$0.browserHistory = .init()
			$0.browserEngine.evaluateScript = { _, _, _, _, _ throws(BrowserDeveloperFailure) in
				let read = reads.withValue { $0 += 1; return $0 }
				guard read > 2 else { throw .busy }

				return .value(#"{"url":"https://news.example/mill","text":"The watermill."}"#)
			}
			$0.pageTextIndex = .init(isAvailable: true, save: { _, page, _ in saved.withValue { $0.append(page) } })
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.viewer(.item(.delegate(.navigation(tab.id, .init(url: url, title: "The mill")))))))
		await clock.advance(by: ProfileHistory.pageTextDelay)
		await clock.advance(by: BrowserEngineClient.busyPause * 2)
		await store.receive(\.history.pageTextRead)
		await store.finish()
		#expect(reads.value == 3)
		#expect(saved.value.map(\.text) == ["The watermill."])
		#expect(store.state.history.pageTextReads.isEmpty)
	}

	/// A reload before the page was read cuts the read short; the page is read once it settles
	/// again, and a title update meanwhile doesn't put the read off.
	@Test
	internal func aReloadBeforeTheReadReadsThePageOnceItSettles() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let profile = organization.profiles[0].id
		let tab = organization.tabs[0]
		state.main.viewer.item.tab = tab
		state.history.snapshots[profile] = .init(profileID: profile)
		state.history.knownProfiles = Set(organization.profiles.map(\.id))
		let clock = TestClock()
		let saved = LockIsolated<[PageText]>([])
		let reads = LockIsolated(0)
		let url = URL(string: "https://news.example/mill")!
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.continuousClock = clock
			$0.browserHistory = .init()
			$0.browserEngine.evaluateScript = { _, _, _, _, _ in
				reads.withValue { $0 += 1 }
				return .value(#"{"url":"https://news.example/mill","text":"The watermill."}"#)
			}
			$0.pageTextIndex = .init(isAvailable: true, save: { _, page, _ in saved.withValue { $0.append(page) } })
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let navigate: (Bool, String) async -> Void = { isLoading, title in
			await store.send(.main(.viewer(.item(.delegate(.navigation(tab.id, .init(url: url, title: title, isLoading: isLoading)))))))
		}

		await navigate(false, "The mill")
		await clock.advance(by: .seconds(1))
		await navigate(true, "The mill")
		await clock.advance(by: ProfileHistory.pageTextDelay)
		#expect(reads.value == 0)

		await navigate(false, "The mill")
		await clock.advance(by: .seconds(1))

		// A title update while the read waits leaves it as it is.
		await navigate(false, "The mill · News")
		await clock.advance(by: .seconds(1))
		await store.receive(\.history.pageTextRead)
		await store.finish()
		#expect(reads.value == 1)
		#expect(saved.value.map(\.text) == ["The watermill."])
		#expect(store.state.history.pageTextReads.isEmpty)

		// Read once, a reload doesn't read it again.
		await navigate(true, "The mill · News")
		await navigate(false, "The mill · News")
		await clock.advance(by: ProfileHistory.pageTextDelay)
		await store.finish()
		#expect(reads.value == 1)
	}

	/// Delete from History keeps only the pages history still has, and so does Clear Browsing
	/// Data with a range: the index's visit times can lag behind history's, after a reload. A
	/// clear synced from another Mac (DEV-984) takes its pages' words here too.
	@Test
	internal func deletingFromHistoryPrunesTheIndex() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let profile = organization.profiles[0].id
		let kept = BrowsingHistoryEntry(id: UUID(10), url: Self.mill, title: "Mill", lastVisited: Date(timeIntervalSince1970: 10))
		let removed = BrowsingHistoryEntry(id: UUID(11), url: Self.bridge, title: "Bridge", lastVisited: Date(timeIntervalSince1970: 11))
		state.history.snapshots[profile] = .init(profileID: profile, entries: [kept, removed])
		state.history.knownProfiles = Set(organization.profiles.map(\.id))

		// Matched to its history at launch already.
		state.history.pageTextReconciled = [profile]
		let retained = LockIsolated<[Set<URL>]>([])
		let since = LockIsolated<[Date]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)

			// The store answers with the page it kept, as it would.
			$0.browserHistory = .init(
				clearSince: { id, _ in .init(snapshot: .init(profileID: id, entries: [kept], revision: 2)) },
				removeEntries: { id, _, _ in .init(snapshot: .init(profileID: id, entries: [kept], revision: 1)) }
			)
			$0.pageTextIndex = .init(
				isAvailable: true,
				clearSince: { _, date, _ in since.withValue { $0.append(date) } },
				retain: { _, urls, _ in retained.withValue { $0.append(urls) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.delegate(.removeHistory(profile, .entries([removed.id])))))
		await store.send(.settings(.delegate(.clearHistorySince(profile, Date(timeIntervalSince1970: 50)))))
		await store.finish()
		expectNoDifference(retained.value, [[Self.mill], [Self.mill]])
		expectNoDifference(since.value, [])

		// Another Mac cleared history: the synced answer has no pages, so neither has the index.
		let epoch = store.state.history.epochs[profile, default: 0]
		let cleared = BrowserHistoryClient.Outcome(snapshot: .init(profileID: profile, revision: 3))
		await store.send(.history(.syncApplied([cleared], epochs: [profile: epoch])))
		await store.finish()
		expectNoDifference(retained.value, [[Self.mill], [Self.mill], []])

		// An answer with every page history has prunes nothing.
		let unchanged = BrowserHistoryClient.Outcome(snapshot: .init(profileID: profile, entries: [kept], revision: 4))
		await store.send(.history(.syncApplied([unchanged], epochs: [profile: epoch])))
		await store.finish()
		#expect(retained.value.count == 3)
	}

	/// The first history a profile loads in a launch matches its page text to it, once: a clear
	/// synced from another Mac while Arx was closed takes its pages' words. A synced answer older
	/// than the history shown, overtaken by a visit, prunes nothing.
	@Test
	internal func historyLoadedAtLaunchAndStaleSyncAnswers() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let profile = organization.profiles[0].id
		state.history.knownProfiles = Set(organization.profiles.map(\.id))
		let kept = BrowsingHistoryEntry(id: UUID(10), url: Self.mill, title: "Mill", lastVisited: Date(timeIntervalSince1970: 10))
		let visited = BrowsingHistoryEntry(id: UUID(11), url: Self.bridge, title: "Bridge", lastVisited: Date(timeIntervalSince1970: 11))
		let retained = LockIsolated<[Set<URL>]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserHistory = .init()
			$0.pageTextIndex = .init(isAvailable: true, retain: { _, urls, _ in retained.withValue { $0.append(urls) } })
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let loaded = BrowserHistoryClient.Outcome(snapshot: .init(profileID: profile, entries: [kept], revision: 5))
		await store.send(.history(.received(loaded, epoch: 0)))
		let visit = BrowserHistoryClient.Outcome(snapshot: .init(profileID: profile, entries: [visited, kept], revision: 6))
		await store.send(.history(.received(visit, epoch: 0)))
		await store.finish()
		expectNoDifference(retained.value, [[Self.mill]])

		// Synced before the visit: older than the history shown, so the visited page keeps its words.
		let stale = BrowserHistoryClient.Outcome(snapshot: .init(profileID: profile, entries: [kept], revision: 5))
		await store.send(.history(.syncApplied([stale], epochs: [profile: 0])))
		await store.finish()
		expectNoDifference(retained.value, [[Self.mill]])
	}

	// MARK: - Fixture

	/// History pages, the more visited first: one with the word in its address, two without.
	private static var candidates: [CommandBarFeature.Entry] {
		[
			history(1, Self.watermill, title: "Watermills of Europe", frecency: 1),
			history(2, Self.mill, title: "How the river shaped the town", frecency: 9),
			history(3, Self.bridge, title: "The stone bridge", frecency: 4),
		]
	}

	private static func history(
		_ id: Int,
		_ url: URL,
		title: String,
		frecency: Double
	) -> CommandBarFeature.Entry {
		.init(
			presentation: .init(
				id: "history-\(id)",
				title: title,
				subtitle: url.absoluteString,
				actionTitle: "Open URL",
				symbol: "clock.arrow.circlepath"
			),
			intent: .openHistory(.init(id: UUID(id), profileID: profileID, spaceID: spaceID, url: url)),
			frecency: frecency
		)
	}
}
