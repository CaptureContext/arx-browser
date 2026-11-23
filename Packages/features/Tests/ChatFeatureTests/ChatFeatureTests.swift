import AgentClient
import BrowserCore
import ChatFeature
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct ChatFeatureTests {
	private typealias ID = AgentConversation.ID

	private let profileID: Profile.ID = ChatWorld.profileID
	private let start: Date = ChatWorld.start

	// MARK: - Entry

	@Test
	internal func textFromTheCommandBarWaitsForTheProfilesDefaultsThenStartsAChat() async throws {
		let world: ChatWorld = .init()
		world.storedSettings.setValue(.init(provider: .claude, modelID: "sonnet", retention: .persistent))
		world.script.setValue(.events([
			.started(resumeToken: "session-1", modelID: "sonnet"),
			.text("Here's the summary."),
			.completed(.init(resumeToken: "session-1")),
		]))
		let store = TestStore(initialState: ChatFeature.State(id: profileID)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		// Loading and the connection check finish in either order.
		store.exhaustivity = .off

		await store.send(.ui(.start("  Summarize the page  "))) {
			$0.pendingPrompt = "Summarize the page"
			$0.isLoading = true
		}
		await store.receive(\.event.loaded)
		await store.receive(\.event.turnFinished)
		await store.finish()

		let conversation = try #require(store.state.selected)
		expectNoDifference(conversation.retention, .persistent)
		expectNoDifference(conversation.modelID, "sonnet")
		expectNoDifference(conversation.resumeToken, "session-1")
		expectNoDifference(conversation.title, "Summarize the page")
		expectNoDifference(conversation.messages.map(\.text), ["Summarize the page", "Here's the summary."])
		expectNoDifference(store.state.pendingPrompt, nil)
		expectNoDifference(store.state.turns, [:])
		expectNoDifference(world.requests.value.map(\.prompt), ["Summarize the page"])

		// Without the person's Allow the turn runs without browser tools.
		expectNoDifference(world.requests.value.map(\.browserAccess), [nil])
		expectNoDifference(store.state.browserAccess, .notGranted)

		// A kept chat is saved, and its transcript is never queued for the sweeps.
		#expect(world.saved.value.last?.id == conversation.id)
		#expect(world.transcripts.value.isEmpty)
	}

	@Test
	internal func aGrantedProfileSendsItsBrowserToolsWithTheTurn() async throws {
		let world: ChatWorld = .init()
		world.access.setValue(nil)
		world.script.setValue(.events([.text("Done.")]))
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		await store.send(.ui(.start("Close the duplicate tabs")))
		await store.receive(\.event.turnFinished)
		await store.skipInFlightEffects(strict: false)

		expectNoDifference(store.state.browserAccess, .granted)
		expectNoDifference(world.requests.value.first?.browserAccess?.credential.clientID, UUID(0))
		expectNoDifference(world.requests.value.first?.profileID, profileID)
	}

	// MARK: - Turns and expiry

	@Test
	internal func anEphemeralChatStreamsItsAnswerAndExpiresAfterTwentyIdleMinutes() async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.events([
			.started(resumeToken: "session-1", modelID: "sonnet"),
			.text("Hi! What can I help you with?"),
			.completed(.init(resumeToken: "session-1")),
		]))
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.ui(.draftChanged("hey"))) {
			$0.draft = "hey"
		}
		await store.send(.ui(.sendTapped)) {
			$0.conversations = [
				.init(
					id: ID(0),
					profileID: profileID,
					provider: .claude,
					title: "hey",
					createdAt: start,
					updatedAt: start,
					retention: .ephemeral,
					messages: [
						.init(id: UUID(1), role: .user, text: "hey", createdAt: start),
						.init(id: UUID(2), role: .assistant, text: "", createdAt: start),
					]
				),
			]
			$0.selectedID = ID(0)
			$0.turns[ID(0)] = .init(prompt: "hey", attachments: [], promptID: UUID(1), replyID: UUID(2))
			$0.draft = ""
		}
		await store.receive(\.event.turnStarted) {
			$0.browserAccess = .notGranted
		}
		await store.receive(\.event.turnEvents) {
			$0.conversations[id: ID(0)]?.resumeToken = "session-1"
			$0.conversations[id: ID(0)]?.modelID = "sonnet"
		}
		await store.receive(\.event.turnEvents) {
			$0.conversations[id: ID(0)]?.messages[1].text = "Hi! What can I help you with?"
		}
		await store.receive(\.event.turnEvents)
		await store.receive(\.event.turnFinished) {
			$0.turns = [:]
		}

		// The transcript is remembered, so even a crash can't leave it behind.
		expectNoDifference(world.transcripts.value, ["session-1"])
		#expect(world.saved.value.isEmpty)

		await world.advance(by: 19 * 60)
		#expect(store.state.conversations.count == 1)

		await world.advance(by: 60)
		await store.receive(\.event.expiryFired) {
			$0.conversations = []
			$0.selectedID = nil
		}
		await store.finish()

		expectNoDifference(world.discarded.value, ["session-1"])
		expectNoDifference(world.deleted.value, [ID(0)])
		#expect(world.transcripts.value.isEmpty)
	}

	@Test
	internal func aFollowUpRestartsTheIdleTimer() async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.events([.text("One.")]))
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		await store.send(.ui(.start("first")))
		await store.receive(\.event.turnFinished)

		await world.advance(by: 15 * 60)
		world.script.setValue(.events([.text("Two.")]))
		await store.send(.ui(.draftChanged("second")))
		await store.send(.ui(.sendTapped))
		await store.receive(\.event.turnFinished)

		// Twenty minutes after the first answer, but only five after the second.
		await world.advance(by: 5 * 60)
		#expect(store.state.conversations.count == 1)

		await world.advance(by: 15 * 60)
		await store.receive(\.event.expiryFired)
		#expect(store.state.conversations.isEmpty)
		await store.finish()
	}

	// MARK: - Failures

	@Test(arguments: [
		AgentFailure.signedOut,
		.loginExpired,
		.usageLimit(.init(resetsAt: ChatWorld.start.addingTimeInterval(3600))),
		.usageCreditsRequired,
		.turnLimitReached,
		.browserToolsUnavailable,
		.runtimeMissing,
		.interrupted,
		.runtimeFailed("unexpected status 500"),
	])
	internal func aFailedTurnKeepsThePromptAndRetrySendsItAgain(failure: AgentFailure) async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.failure([], failure))
		let attachment: AgentContextAttachment = .tabs([.init(title: "Arx", url: "https://arx.example/")])
		var initialState: ChatFeature.State = .init(id: profileID, isLoaded: true, browserAccess: .notGranted)
		initialState.draft = "Summarize this"
		initialState.attachments = [attachment]
		let store = TestStore(initialState: initialState) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.ui(.sendTapped)) {
			$0.conversations = [
				.init(
					id: ID(0),
					profileID: profileID,
					provider: .claude,
					title: "Summarize this",
					createdAt: start,
					updatedAt: start,
					messages: [
						.init(id: UUID(1), role: .user, text: "Summarize this", attachments: [attachment], createdAt: start),
						.init(id: UUID(2), role: .assistant, text: "", createdAt: start),
					]
				),
			]
			$0.selectedID = ID(0)
			$0.turns[ID(0)] = .init(prompt: "Summarize this", attachments: [attachment], promptID: UUID(1), replyID: UUID(2))
			$0.draft = ""
			$0.attachments = []
		}
		await store.receive(\.event.turnStarted)

		// The prompt stays in the transcript with the failure under it, so a new chat whose
		// first message failed still shows both (DEV-643).
		await store.receive(\.event.turnFailed) {
			$0.turns = [:]
			$0.conversations[id: ID(0)]?.messages = [
				.init(id: UUID(1), role: .user, text: "Summarize this", attachments: [attachment], createdAt: start),
			]
			$0.failures[ID(0)] = .init(reason: failure, prompt: "Summarize this", attachments: [attachment], promptID: UUID(1))
		}
		expectNoDifference(store.state.failure?.reason, failure)

		// Try Again adds only a new reply under the same message.
		world.script.setValue(.events([.text("Here it is.")]))
		await store.send(.ui(.retryTapped)) {
			$0.failures = [:]
			$0.conversations[id: ID(0)]?.messages.append(
				.init(id: UUID(3), role: .assistant, text: "", createdAt: start)
			)
			$0.turns[ID(0)] = .init(prompt: "Summarize this", attachments: [attachment], promptID: UUID(1), replyID: UUID(3))
		}
		await store.receive(\.event.turnStarted)
		await store.receive(\.event.turnEvents) {
			$0.conversations[id: ID(0)]?.messages[1].text = "Here it is."
		}
		await store.receive(\.event.turnFinished) {
			$0.turns = [:]
		}
		expectNoDifference(world.requests.value.map(\.prompt), ["Summarize this", "Summarize this"])

		// A `.run` effect registers for cancellation only once its task runs. Under load, a turn
		// that ends at once can cancel its silence watch before that, and the watch's timeout
		// then arrives in this wait. It's a no-op once the turn is gone (`turnTimedOut` checks
		// `turns`), so it's skipped here; the state is still checked (DEV-965).
		store.exhaustivity = .off(showSkippedAssertions: false)
		await world.advance(by: 20 * 60)
		await store.receive(\.event.expiryFired) {
			$0.conversations = []
			$0.selectedID = nil
		}
		expectNoDifference(store.state.turns, [:])
		expectNoDifference(store.state.failures, [:])
		await store.skipReceivedActions(strict: false)
		await store.finish()
	}

	@Test
	internal func aPartialAnswerStaysWhenTheTurnFails() async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.failure([.text("Part of it")], .interrupted))
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		await store.send(.ui(.start("Explain")))
		await store.receive(\.event.turnFailed)
		await store.skipInFlightEffects(strict: false)

		expectNoDifference(store.state.selected?.messages.map(\.text), ["Explain", "Part of it"])
		expectNoDifference(store.state.failure?.reason, .interrupted)
		expectNoDifference(store.state.draft, "")
	}

	@Test
	internal func aKeptChatIsSavedWithThePromptBeforeTheProviderRuns() async throws {
		let world: ChatWorld = .init()
		world.storedSettings.setValue(.init(provider: .claude, retention: .persistent))
		world.script.setValue(.endless)
		let store = TestStore(
			initialState: ChatFeature.State(
				id: profileID,
				isLoaded: true,
				settings: .init(provider: .claude, retention: .persistent)
			)
		) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		await store.send(.ui(.start("Keep this")))
		await store.receive(\.event.turnStarted)

		// Saved before the provider was asked, with the prompt and nothing else: not the reply
		// that's still empty.
		expectNoDifference(world.saved.value.count, 1)
		expectNoDifference(world.saved.value.first?.messages.map(\.text), ["Keep this"])
		expectNoDifference(world.requests.value.count, 1)

		await store.send(.ui(.stopTapped))
		await world.waitForCancellation()
		await store.skipInFlightEffects(strict: false)
	}

	@Test
	internal func aFailedKeptChatIsSavedWithItsPrompt() async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.failure([.started(resumeToken: "thread-1", modelID: nil)], .signedOut))
		let store = TestStore(
			initialState: ChatFeature.State(
				id: profileID,
				isLoaded: true,
				settings: .init(provider: .claude, retention: .persistent)
			)
		) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		await store.send(.ui(.start("Still here?")))
		await store.receive(\.event.turnFailed)

		// Waits for the saves: skipping in-flight effects would cancel the failure's save.
		await store.finish()

		// Every save, the one as the turn started too, holds the prompt alone: whichever lands
		// last, the chat reads back without an empty answer.
		let saved: AgentConversation = try #require(world.saved.value.last)
		expectNoDifference(world.saved.value.map { $0.messages.map(\.text) }, world.saved.value.map { _ in ["Still here?"] })
		expectNoDifference(saved.messages.map(\.text), ["Still here?"])
		expectNoDifference(saved.resumeToken, "thread-1")
		expectNoDifference(store.state.failure?.reason, .signedOut)
	}

	// MARK: - Silence

	@Test
	internal func aSilentProviderTimesOutWithTheFailureShownAndThePromptKept() async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.endless)
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true, browserAccess: .notGranted)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		await store.send(.ui(.start("Hello?")))
		await store.receive(\.event.turnStarted)

		await world.advance(by: 179)
		#expect(store.state.isRunning)

		await world.advance(by: 1)
		await store.receive(\.event.turnTimedOut)
		await world.waitForCancellation()

		expectNoDifference(world.cancelledTurns.value, 1)
		expectNoDifference(store.state.turns, [:])
		expectNoDifference(store.state.failure?.reason, .timedOut)
		expectNoDifference(store.state.selected?.messages.map(\.text), ["Hello?"])

		world.script.setValue(.events([.text("Hi.")]))
		await store.send(.ui(.retryTapped))
		await store.receive(\.event.turnFinished)
		expectNoDifference(store.state.selected?.messages.map(\.text), ["Hello?", "Hi."])
		expectNoDifference(world.requests.value.map(\.prompt), ["Hello?", "Hello?"])
		await store.skipInFlightEffects(strict: false)
	}

	@Test
	internal func eachBatchOfEventsRestartsTheWait() async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.endless)
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true, browserAccess: .notGranted)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		await store.send(.ui(.start("Slow one")))
		await store.receive(\.event.turnStarted)

		await world.advance(by: 170)
		await store.send(.event(.turnEvents(ID(0), [.retrying(attempt: 2, maxAttempts: 5, reason: .interrupted)])))
		await world.advance(by: 179)
		#expect(store.state.isRunning)

		await world.advance(by: 1)
		await store.receive(\.event.turnTimedOut)
		expectNoDifference(store.state.failure?.reason, .timedOut)
		await store.skipInFlightEffects(strict: false)
	}

	@Test
	internal func aRunningBrowserToolIsNotSilence() async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.endless)
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true, browserAccess: .notGranted)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		await store.send(.ui(.start("Click Buy")))
		await store.receive(\.event.turnStarted)
		await store.send(.event(.turnEvents(ID(0), [.toolStarted(.init(id: "t/1", name: "browser_click", input: "{}"))])))

		// Waiting for the person's approval can take longer than the limit.
		await world.advance(by: 180)
		await store.receive(\.event.turnTimedOut)
		#expect(store.state.isRunning)
		#expect(store.state.failure == nil)

		await store.send(.event(.turnEvents(ID(0), [.toolFinished(id: "t/1", isError: false)])))
		await world.advance(by: 180)
		await store.receive(\.event.turnTimedOut)
		expectNoDifference(store.state.failure?.reason, .timedOut)
		await store.skipInFlightEffects(strict: false)
	}

	// MARK: - Stop

	@Test
	internal func stopEndsTheRunningTurnAndKeepsTheChat() async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.endless)
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true, browserAccess: .notGranted)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.ui(.draftChanged("Open my mail"))) {
			$0.draft = "Open my mail"
		}
		await store.send(.ui(.sendTapped)) {
			$0.conversations = [
				.init(
					id: ID(0),
					profileID: profileID,
					provider: .claude,
					title: "Open my mail",
					createdAt: start,
					updatedAt: start,
					messages: [
						.init(id: UUID(1), role: .user, text: "Open my mail", createdAt: start),
						.init(id: UUID(2), role: .assistant, text: "", createdAt: start),
					]
				),
			]
			$0.selectedID = ID(0)
			$0.turns[ID(0)] = .init(prompt: "Open my mail", attachments: [], promptID: UUID(1), replyID: UUID(2))
			$0.draft = ""
		}
		await store.receive(\.event.turnStarted)
		#expect(store.state.isRunning)

		await store.send(.ui(.stopTapped)) {
			$0.turns = [:]
			$0.conversations[id: ID(0)]?.messages.removeLast()
		}
		await world.waitForCancellation()
		expectNoDifference(world.cancelledTurns.value, 1)
		#expect(store.state.failures.isEmpty)

		// A stopped chat is idle, so its timer runs from the stop.
		await world.advance(by: 20 * 60)
		await store.receive(\.event.expiryFired) {
			$0.conversations = []
			$0.selectedID = nil
		}
		await store.finish()
	}

	@Test
	internal func leavingTheChatDoesNotStopItsTurn() async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.endless)
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		await store.send(.ui(.start("Find the cheapest flight")))
		await store.receive(\.event.turnStarted)
		await store.send(.ui(.historyTapped))
		await store.send(.ui(.newChatTapped))

		#expect(store.state.turns[ID(0)] != nil)
		expectNoDifference(world.cancelledTurns.value, 0)

		// Stop applies to the chat on screen, so it waits until that chat is selected again.
		await store.send(.ui(.stopTapped))
		#expect(store.state.turns[ID(0)] != nil)
		await store.send(.ui(.chatSelected(ID(0))))
		await store.send(.ui(.stopTapped))
		await world.waitForCancellation()
		expectNoDifference(world.cancelledTurns.value, 1)
		await store.skipInFlightEffects(strict: false)
	}

	@Test
	internal func anAnswerThatArrivesElsewhereIsUnread() async throws {
		let world: ChatWorld = .init()
		let running: AgentConversation = conversation(5, title: "Check the build", answer: "Green", updated: 0)
		let other: AgentConversation = conversation(6, title: "Lunch", answer: "Soup", updated: 0)
		var initialState: ChatFeature.State = .init(id: profileID, isLoaded: true, conversations: [running, other])
		initialState.screen = .chats
		initialState.turns[ID(5)] = .init(prompt: "Check the build", attachments: [], promptID: UUID(500), replyID: UUID(501))
		let store = TestStore(initialState: initialState) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		// The answer lands while the person looks at Your Chats.
		await store.send(.event(.turnFinished(ID(5))))
		expectNoDifference(store.state.unreadIDs, [ID(5)])

		await store.send(.ui(.unreadOnlyToggled))
		expectNoDifference(store.state.listedConversations.map(\.id), [ID(5)])

		await store.send(.ui(.chatSelected(ID(5))))
		expectNoDifference(store.state.unreadIDs, [])
		await store.skipInFlightEffects(strict: false)
	}

	// MARK: - Panel

	@Test
	internal func thePanelMovesBetweenTheChatYourChatsAndInfo() async throws {
		let world: ChatWorld = .init()
		let older: AgentConversation = conversation(1, title: "Weather", answer: "Sunny", updated: 10)
		let newer: AgentConversation = conversation(2, title: "Flights", answer: "Cheapest on Friday", updated: 20)
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true, conversations: [older, newer])) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.ui(.infoTapped))
		await store.send(.ui(.historyTapped)) {
			$0.screen = .chats
		}
		expectNoDifference(store.state.listedConversations.map(\.id), [ID(2), ID(1)])

		await store.send(.ui(.chatsQueryChanged("sunny"))) {
			$0.chatsQuery = "sunny"
		}
		expectNoDifference(store.state.listedConversations.map(\.id), [ID(1)])

		await store.send(.ui(.chatSelected(ID(1)))) {
			$0.selectedID = ID(1)
			$0.screen = .conversation
			$0.focusRequest = 1
		}
		await store.send(.ui(.infoTapped)) {
			$0.screen = .info
		}
		await store.send(.ui(.backTapped)) {
			$0.screen = .conversation
		}
		await store.send(.ui(.copyAnswerTapped))
		await store.receive(\.delegate.copy, "Sunny")

		await store.send(.ui(.newChatTapped)) {
			$0.selectedID = nil
			$0.focusRequest = 2
		}
		await store.send(.ui(.allowBrowserToolsTapped))
		await store.receive(\.delegate.allowBrowserTools)
	}

	@Test
	internal func attachingIsExplicitAndRemovable() async throws {
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true)) {
			ChatFeature()
		}
		let tab: AgentContextAttachment = .tabs([.init(title: "Docs", url: "https://docs.example/")])

		await store.send(.ui(.attached(tab))) {
			$0.attachments = [tab]
			$0.focusRequest = 1
		}
		await store.send(.ui(.attached(tab)))
		await store.send(.ui(.detached(0))) {
			$0.attachments = []
		}
	}

	// MARK: - This chat

	@Test
	internal func pinningKeepsAnEphemeralChatAndUnpinningLetsItExpire() async throws {
		let world: ChatWorld = .init()
		world.transcripts.setValue(["session-7"])
		var chat: AgentConversation = conversation(7, title: "Recipes", answer: "Pasta", updated: 0)
		chat.resumeToken = "session-7"
		var initialState: ChatFeature.State = .init(id: profileID, isLoaded: true, conversations: [chat])
		initialState.selectedID = ID(7)
		let store = TestStore(initialState: initialState) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.ui(.pinTapped)) {
			$0.conversations[id: ID(7)]?.retention = .persistent
			$0.conversations[id: ID(7)]?.updatedAt = start
		}
		await store.finish()
		expectNoDifference(world.saved.value.map(\.id), [ID(7)])
		#expect(world.transcripts.value.isEmpty)

		await store.send(.ui(.renamed("  Dinner ideas "))) {
			$0.conversations[id: ID(7)]?.title = "Dinner ideas"
		}
		await store.send(.ui(.archiveTapped)) {
			$0.conversations[id: ID(7)]?.archivedAt = start
			$0.selectedID = nil
			$0.screen = .chats
		}
		await store.send(.ui(.archivedToggled)) {
			$0.showsArchived = true
		}
		expectNoDifference(store.state.listedConversations.map(\.id), [ID(7)])

		await store.send(.ui(.chatSelected(ID(7)))) {
			$0.selectedID = ID(7)
			$0.screen = .conversation
			$0.focusRequest = 1
		}
		await store.send(.ui(.pinTapped)) {
			$0.conversations[id: ID(7)]?.retention = .ephemeral
			$0.conversations[id: ID(7)]?.archivedAt = nil
		}

		// Unpinned, it's temporary again: its saved copy goes and its transcript is queued.
		for _ in 0..<1_000 where world.transcripts.value.isEmpty {
			await Task.yield()
		}
		expectNoDifference(world.deleted.value, [ID(7)])
		expectNoDifference(world.transcripts.value, ["session-7"])

		await world.advance(by: 20 * 60)
		await store.receive(\.event.expiryFired) {
			$0.conversations = []
			$0.selectedID = nil
		}
		await store.finish()
		expectNoDifference(world.discarded.value, ["session-7"])
		#expect(world.transcripts.value.isEmpty)
	}

	@Test
	internal func deletingAChatDiscardsWhatTheProviderKept() async throws {
		let world: ChatWorld = .init()
		var chat: AgentConversation = conversation(3, title: "Taxes", answer: "Due in April", updated: 0)
		chat.resumeToken = "session-3"
		var initialState: ChatFeature.State = .init(id: profileID, isLoaded: true, conversations: [chat])
		initialState.selectedID = ID(3)
		initialState.screen = .info
		let store = TestStore(initialState: initialState) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.ui(.deleteTapped)) {
			$0.conversations = []
			$0.selectedID = nil
			$0.screen = .conversation
		}
		await store.finish()
		expectNoDifference(world.discarded.value, ["session-3"])
		expectNoDifference(world.deleted.value, [ID(3)])
	}

	@Test
	internal func eachChatPicksItsModelAndTheProviderOnlyBeforeItsFirstTurn() async throws {
		let world: ChatWorld = .init()
		var started: AgentConversation = conversation(4, title: "Started", answer: "Yes", updated: 0)
		started.resumeToken = "session-4"
		started.retention = .persistent
		var initialState: ChatFeature.State = .init(id: profileID, isLoaded: true, conversations: [started])
		initialState.selectedID = ID(4)
		let store = TestStore(initialState: initialState) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.ui(.modelSelected("sonnet"))) {
			$0.conversations[id: ID(4)]?.modelID = "sonnet"
		}
		await store.finish()
		expectNoDifference(world.saved.value.last?.modelID, "sonnet")

		// The provider's handle can't move to another provider.
		#expect(!store.state.canChangeProvider)
		await store.send(.ui(.providerSelected(.claude)))

		await store.send(.ui(.newChatTapped)) {
			$0.selectedID = nil
			$0.focusRequest = 1
		}
		await store.send(.ui(.modelSelected("haiku"))) {
			$0.newChatModelID = "haiku"
		}
		expectNoDifference(store.state.modelID, "haiku")
	}

	// MARK: - Settings

	/// DEV-700: Connect on onboarding can arrive before the profile's defaults are read; the
	/// chat reads them, then saves the new provider without losing the rest.
	@Test
	internal func aProviderConnectedWhileLoadingReplacesTheReadOne() async throws {
		let world: ChatWorld = .init()
		let read: AgentProfileSettings = .init(provider: .claude, modelID: "opus", retention: .persistent)
		let store = TestStore(initialState: ChatFeature.State(id: profileID)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
			$0.agentProviders = .init(clients: [world.provider, .unavailable(.openAI)], isEnabled: false)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		world.storedSettings.setValue(read)
		await store.send(.event(.providerConnected(.openAI))) {
			$0.pendingProvider = .openAI
			$0.isLoading = true
		}
		await store.receive(\.event.loaded)
		await store.finish()
		let connected: AgentProfileSettings = .init(provider: .openAI, retention: .persistent)
		expectNoDifference(store.state.settings, connected)
		expectNoDifference(store.state.newChatProvider, .openAI)
		#expect(store.state.pendingProvider == nil)
		expectNoDifference(world.storedSettings.value, connected)

		// Once loaded it applies at once; a provider the build doesn't ship is ignored.
		await store.send(.event(.providerConnected(.claude)))
		await store.finish()
		expectNoDifference(world.storedSettings.value?.provider, .claude)
		await store.send(.event(.providerConnected(.init(rawValue: "gemini"))))
		expectNoDifference(store.state.settings.provider, .claude)
	}

	@Test
	internal func settingsHoldTheDefaultsNewChatsStartWith() async throws {
		let world: ChatWorld = .init()
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.ui(.defaultModelChanged("sonnet"))) {
			$0.settings.modelID = "sonnet"
			$0.newChatModelID = "sonnet"
		}
		await store.send(.ui(.retentionChanged(.persistent))) {
			$0.settings.retention = .persistent
		}
		await store.finish()
		expectNoDifference(
			world.storedSettings.value,
			.init(provider: .claude, modelID: "sonnet", retention: .persistent)
		)

		// A provider this build doesn't offer is ignored.
		await store.send(.ui(.defaultProviderChanged(.openAI)))
	}

	// MARK: - Helpers

	private func conversation(
		_ id: Int,
		title: String,
		answer: String,
		updated: TimeInterval
	) -> AgentConversation {
		.init(
			id: ID(id),
			profileID: profileID,
			provider: .claude,
			title: title,
			createdAt: start.addingTimeInterval(updated),
			updatedAt: start.addingTimeInterval(updated),
			messages: [
				.init(id: UUID(id * 100), role: .user, text: title, createdAt: start),
				.init(id: UUID(id * 100 + 1), role: .assistant, text: answer, createdAt: start),
			]
		)
	}
}
