@testable import AppFeature
import BrowserCore
import BrowserWorkspaceClient
import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import SearchSuggestionsClient
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-646: the provider's search suggestions in the command bar.
@Suite(.dependencies)
@MainActor
internal struct RemoteSearchSuggestionsTests {
	private static func client(asked: LockIsolated<[String]>) -> SearchSuggestionsClient {
		.init(isAvailable: true, fetch: { query, _ in
			asked.withValue { $0.append(query) }
			return [query, query + " browser", query + "ade"]
		})
	}

	private func candidates() -> [CommandBarFeature.Entry] {
		[
			.init(
				presentation: .init(id: "tab", title: "Arc tab", actionTitle: "Switch", symbol: "globe"),
				intent: .selectTab(.init(rawValue: UUID(1)))
			),
			.init(
				presentation: .init(id: "command", title: "Arc sidebar", actionTitle: "Command", symbol: "sidebar.left"),
				intent: .toggleSidebar
			),
		]
	}

	@Test
	internal func newTabLeadsWithSuggestionsAfterAPause() async {
		let asked = LockIsolated<[String]>([])
		let clock = TestClock()
		var state = CommandBarFeature.State()
		state.suggestsRemotely = true
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.searchSuggestions = Self.client(asked: asked)
			$0.continuousClock = clock
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.present(.newTab, "", candidates()))
		await store.send(.ui(.queryChanged("ar")))
		await store.send(.ui(.queryChanged("arc")))
		await clock.advance(by: .milliseconds(100))

		// Still typing: nothing has gone out.
		expectNoDifference(asked.value, [])

		await clock.advance(by: CommandBarFeature.suggestionDelay)
		await store.receive(\.event.suggestionsLoaded)

		// Only the last text was sent, once.
		expectNoDifference(asked.value, ["arc"])

		// The plain search for what's typed leads, then the provider's suggestions (DEV-978).
		expectNoDifference(store.state.entries.map(\.presentation.id), [
			"destination", "suggestion-arc browser", "suggestion-arcade", "tab", "command",
		])
		let suggestion = store.state.entries[1]
		expectNoDifference(suggestion.intent, .open(SearchEngine.google.url(for: "arc browser")!))
	}

	@Test
	internal func commandsKeepActionsFirst() async {
		let asked = LockIsolated<[String]>([])
		var state = CommandBarFeature.State()
		state.suggestsRemotely = true
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.searchSuggestions = Self.client(asked: asked)
			$0.continuousClock = ImmediateClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.present(.commands, "", candidates()))
		await store.send(.ui(.queryChanged("arc")))
		await store.receive(\.event.suggestionsLoaded)
		expectNoDifference(store.state.entries.map(\.presentation.id), [
			"command", "tab", "suggestion-arc browser", "suggestion-arcade", "destination",
		])
	}

	@Test
	internal func suggestionsUseTheProfilesSearchEngine() async {
		var state = CommandBarFeature.State(searchEngine: .duckDuckGo)
		state.suggestsRemotely = true
		let engines = LockIsolated<[SearchEngine]>([])
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.searchSuggestions = .init(isAvailable: true, fetch: { query, engine in
				engines.withValue { $0.append(engine) }
				return [query + " browser"]
			})
			$0.continuousClock = ImmediateClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged("arc")))
		await store.receive(\.event.suggestionsLoaded)

		// The plain search uses the profile's engine too (DEV-978), then the suggestion.
		expectNoDifference(store.state.entries.first?.intent, .open(SearchEngine.duckDuckGo.url(for: "arc")!))
		expectNoDifference(store.state.entries[1].intent, .open(SearchEngine.duckDuckGo.url(for: "arc browser")!))
		expectNoDifference(store.state.entries[1].presentation.subtitle, SearchEngine.duckDuckGo.title)
		expectNoDifference(engines.value, [.duckDuckGo])
	}

	@Test
	internal func switchingProvidersCancelsOldRequestsAndDropsLateResults() async throws {
		let engines = LockIsolated<[SearchEngine]>([])
		let clock = TestClock()
		var state = CommandBarFeature.State()
		state.suggestsRemotely = true
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.searchSuggestions = .init(isAvailable: true, fetch: { query, engine in
				engines.withValue { $0.append(engine) }
				return [query + " browser"]
			})
			$0.continuousClock = clock
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged("arc")))
		await store.send(.useSearchEngine(.duckDuckGo))
		await clock.advance(by: .seconds(1))
		await store.receive(\.event.suggestionsLoaded)
		expectNoDifference(engines.value, [.duckDuckGo])

		await store.send(.event(.suggestionsLoaded(query: "arc", engine: .google, ["wrong provider"])))
		expectNoDifference(store.state.suggestions, ["arc browser"])
		await store.send(.useSearchEngine(.kagi))
		await store.finish()
		#expect(store.state.suggestions.isEmpty)
		expectNoDifference(engines.value, [.duckDuckGo])
	}

	@Test
	internal func aCancelledOldProviderSleepCannotSendWhenItFinishesLate() async throws {
		let clock = NonCancellingSuggestionClock()
		let engines = LockIsolated<[SearchEngine]>([])
		var state = CommandBarFeature.State()
		state.suggestsRemotely = true
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.searchSuggestions = .init(isAvailable: true, fetch: { query, engine in
				engines.withValue { $0.append(engine) }
				return [query + " browser"]
			})
			$0.continuousClock = clock
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged("arc")))
		try await pollUntil("the first provider's sleep") { clock.pending.value.count == 1 }
		await store.send(.useSearchEngine(.duckDuckGo))
		try await pollUntil("the second provider's sleep") { clock.pending.value.count == 2 }
		let sleeps = clock.pending.withValue { pending in
			let result = pending
			pending.removeAll()
			return result
		}
		#expect(sleeps.count == 2)
		// The newer effect finishes first; the canceled older sleep ignores cancellation.
		for sleep in sleeps.reversed() { sleep.resume() }
		await store.receive(\.event.suggestionsLoaded)
		await store.finish()
		expectNoDifference(engines.value, [.duckDuckGo])
	}

	@Test
	internal func providerFailureAfterASwitchNeverKeepsOldProviderResults() async throws {
		var state = CommandBarFeature.State(isPresented: true, query: "arc")
		state.suggestsRemotely = true
		state.suggestions = ["old provider result"]
		state.suggestionsQuery = "arc"
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.searchSuggestions = .init(isAvailable: true, fetch: { _, _ in
				throw SearchSuggestionsClient.Failure.unexpectedResponse
			})
			$0.continuousClock = ImmediateClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.useSearchEngine(.brave))
		await store.finish()
		#expect(store.state.suggestions.isEmpty)
		#expect(store.state.suggestionsQuery == nil)
	}

	@Test
	internal func addressesWithASchemeAreNeverSent() {
		for text in [
			"https://capturecontext.dev", "mailto:person@example.com", "data:text/plain,private",
			"file:/Users/name/private.txt", "about:blank", "x-apple.systempreferences:com.apple",
			"file:///Users/alice/Private Notes.txt", "data:text/plain,private information",
		] {
			#expect(CommandBarFeature.State.hasScheme(text), "\(text)")
		}
		for text in ["arc browser", "c++ tutorial", "note: buy milk", "10:30", "arc", ":colon"] {
			#expect(!CommandBarFeature.State.hasScheme(text), "\(text)")
		}
	}

	@Test(arguments: [
		"off", "unavailable", "address", "bang", "scheme", "host", "completed",
	])
	internal func nothingGoesOutWhenItShouldnt(_ reason: String) async {
		let asked = LockIsolated<[String]>([])
		var state = CommandBarFeature.State()
		state.suggestsRemotely = reason != "off"
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.searchSuggestions = reason == "unavailable"
			? .init(isAvailable: false, fetch: { query, _ in asked.withValue { $0.append(query) }; return [] })
			: Self.client(asked: asked)
			$0.continuousClock = ImmediateClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		if reason == "address" {
			// An unedited address is never sent.
			await store.send(.present(.currentTab, "https://capturecontext.dev/private", []))
		} else {
			await store.send(.present(.newTab, "", []))
			let text: String = switch reason {
			case "bang": "!yt arc"

			case "scheme": "mailto:person@example.com"

			case "host": "capturecontext.dev"

			// An accepted inline completion writes the whole history address into the field.
			case "completed": "capturecontext.dev/account/reset?token=secret"

			default: "arc"
			}
			await store.send(.ui(.queryChanged(text)))
		}
		await store.finish()
		expectNoDifference(asked.value, [])
		#expect(!store.state.entries.contains { $0.presentation.id.hasPrefix("suggestion-") })
	}

	@Test(arguments: ["return", "chat", "optOut", "reopened"])
	internal func closingOrOptingOutBeforeThePauseSendsNothing(_ exit: String) async {
		let asked = LockIsolated<[String]>([])
		let clock = TestClock()
		var state = CommandBarFeature.State()
		state.suggestsRemotely = true
		state.isChatAvailable = true
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.searchSuggestions = Self.client(asked: asked)
			$0.continuousClock = clock
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged("arc")))
		switch exit {
		case "return": await store.send(.ui(.selected("destination")))

		case "chat": await store.send(.ui(.tabPressed))

		// ⌘L before the pause: the field now shows the page's address.
		case "reopened": await store.send(.present(.currentTab, "https://capturecontext.dev", []))

		default: await store.send(.allowSuggestions(false))
		}
		await clock.advance(by: .seconds(1))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(asked.value, [])
		#expect(store.state.suggestions.isEmpty)
		#expect(store.state.suggestsRemotely == (exit != "optOut"))
	}

	@Test
	internal func goingBackToShownSuggestionsCancelsTheNewerRequest() async {
		let asked = LockIsolated<[String]>([])
		let clock = TestClock()
		var state = CommandBarFeature.State()
		state.suggestsRemotely = true
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.searchSuggestions = Self.client(asked: asked)
			$0.continuousClock = clock
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged("arc")))
		await clock.advance(by: .seconds(1))
		await store.receive(\.event.suggestionsLoaded)
		await store.send(.ui(.queryChanged("arcs")))
		await store.send(.ui(.queryChanged("arc")))
		await clock.advance(by: .seconds(1))
		await store.finish()

		expectNoDifference(asked.value, ["arc"])
	}

	@Test
	internal func turningSuggestionsOffInAnOpenBarCancelsTheRequest() async {
		let organization = IntegrationFeatureTests().fixture()
		let profile = organization.profiles[0].id
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)

		// A page is already shown, so reconciling it sends nothing that could cancel later.
		initial.viewer.item = .init(tab: organization.tabs[0], navigation: .init(url: URL(string: "https://origin.example")))
		let asked = LockIsolated<[String]>([])
		let clock = TestClock()
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.searchSuggestions = Self.client(asked: asked)
			$0.continuousClock = clock
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openCommand(.newTab)))
		await store.send(.commandBar(.ui(.queryChanged("arc"))))
		var turnedOff = store.state.sidebar.organization
		turnedOff.profiles[id: profile]?.remoteSearchSuggestions = false
		await store.send(.reconcile(turnedOff))
		#expect(!store.state.commandBar.suggestsRemotely)

		await clock.advance(by: .seconds(1))
		await store.skipInFlightEffects(strict: false)
		expectNoDifference(asked.value, [])
	}

	@Test
	internal func anOpenBarFollowsAChangedProfileEngineBeforeSending() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let profile = organization.profiles[0].id
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		initial.viewer.item = .init(tab: organization.tabs[0], navigation: .init(url: URL(string: "https://origin.example")))
		let engines = LockIsolated<[SearchEngine]>([])
		let clock = TestClock()
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.searchSuggestions = .init(isAvailable: true, fetch: { query, engine in
				engines.withValue { $0.append(engine) }
				return [query + " browser"]
			})
			$0.continuousClock = clock
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openCommand(.newTab)))
		await store.send(.commandBar(.ui(.queryChanged("arc"))))
		var updated = store.state.sidebar.organization
		updated.profiles[id: profile]?.searchEngine = .duckDuckGo
		await store.send(.reconcile(updated))
		await clock.advance(by: .seconds(1))
		await store.receive(\.commandBar.event.suggestionsLoaded)
		expectNoDifference(engines.value, [.duckDuckGo])
		expectNoDifference(store.state.commandBar.searchEngine, .duckDuckGo)
	}

	@Test
	internal func closingTheMainWindowCancelsTheRequest() async {
		let organization = IntegrationFeatureTests().fixture()
		let asked = LockIsolated<[String]>([])
		let clock = TestClock()
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.searchSuggestions = Self.client(asked: asked)
			$0.continuousClock = clock
			$0.browserEngine = .init(status: { .notIntegrated })
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.ui(.openCommand(.newTab))))
		await store.send(.main(.commandBar(.ui(.queryChanged("arc")))))
		await store.send(.ui(.closeWindow))
		await clock.advance(by: .seconds(1))
		await store.skipInFlightEffects(strict: false)

		expectNoDifference(asked.value, [])
	}

	@Test
	internal func lateSuggestionsForOlderTextAreDropped() async {
		var state = CommandBarFeature.State()
		state.suggestsRemotely = true
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.searchSuggestions = .init(isAvailable: false, fetch: { _, _ in [] })
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged("arc b")))
		await store.send(.event(.suggestionsLoaded(query: "arc", engine: .google, ["arc browser"])))
		#expect(store.state.suggestions.isEmpty)

		await store.send(.event(.suggestionsLoaded(query: "arc b", engine: .google, ["arc browser"])))
		expectNoDifference(store.state.suggestions, ["arc browser"])

		await store.send(.ui(.dismissed))
		#expect(store.state.suggestions.isEmpty)
	}

	@Test
	internal func windowsFollowTheirProfileAndPrivacy() async {
		var organization = IntegrationFeatureTests().fixture()
		let profile = organization.profiles[0].id
		let space = organization.spaces[0].id

		let normal = TestStore(initialState: MainFeature.State(organization: organization, spaceID: space)) {
			MainFeature()
		}
		normal.exhaustivity = .off(showSkippedAssertions: false)
		await normal.send(.ui(.openCommand(.newTab)))
		#expect(normal.state.commandBar.suggestsRemotely)

		organization.profiles[id: profile]?.remoteSearchSuggestions = false
		let off = TestStore(initialState: MainFeature.State(organization: organization, spaceID: space)) {
			MainFeature()
		}
		off.exhaustivity = .off(showSkippedAssertions: false)
		await off.send(.ui(.openCommand(.newTab)))
		#expect(!off.state.commandBar.suggestsRemotely)

	}
}

private struct NonCancellingSuggestionClock: Clock {
	fileprivate let pending = LockIsolated<[CheckedContinuation<Void, Never>]>([])

	var now: ContinuousClock.Instant { ContinuousClock.now }
	var minimumResolution: Duration { .nanoseconds(1) }

	func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
		await withCheckedContinuation { continuation in
			pending.withValue { $0.append(continuation) }
		}
	}
}
