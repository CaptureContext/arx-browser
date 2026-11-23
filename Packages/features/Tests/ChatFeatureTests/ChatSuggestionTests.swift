import AgentClient
import BrowserCore
import ChatFeature
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-735: a new chat's suggested prompts about the window's tab.
@Suite(.dependencies)
@MainActor
internal struct ChatSuggestionTests {
	private typealias ID = AgentConversation.ID

	private let profileID: Profile.ID = ChatWorld.profileID
	private let start: Date = ChatWorld.start

	@Test
	internal func promptsComeFromThePagesTitleAndSite() {
		let tab: AgentContextAttachment.Tab = .init(title: "Raycast for iOS", url: "https://www.raycast.com/ios")

		expectNoDifference(
			ChatSuggestion.suggestions(for: tab).map(\.prompt),
			[
				"Summarize “Raycast for iOS” in a few points",
				"What are the key takeaways from raycast.com?",
				"Explain “Raycast for iOS” in simple terms",
			]
		)
		#expect(ChatSuggestion.suggestions(for: tab).allSatisfy { $0.tab == tab })
	}

	@Test
	internal func aPageWithoutATitleIsNamedByItsSite() {
		let tab: AgentContextAttachment.Tab = .init(title: "", url: "https://docs.example/guide")

		expectNoDifference(
			ChatSuggestion.suggestions(for: tab).map(\.prompt).first,
			"Summarize “docs.example” in a few points"
		)
	}

	@Test(arguments: ["arx://newtab", "about:blank", "file:///Users/me/notes.txt", "not a url"])
	internal func pagesOffTheWebOfferNothing(url: String) {
		#expect(ChatSuggestion.suggestions(for: .init(title: "Page", url: url)).isEmpty)
	}

	@Test
	internal func longTitlesAreShortened() throws {
		let title = String(repeating: "a", count: 80)
		let prompt = try #require(ChatSuggestion.suggestions(for: .init(title: title, url: "https://a.example")).first?.prompt)

		#expect(prompt == "Summarize “\(String(repeating: "a", count: 59))…” in a few points")
	}

	@Test
	internal func tappingASuggestionAttachesItsTabAndSendsIt() async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.events([.text("Sure.")]))
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		let tab: AgentContextAttachment.Tab = .init(title: "Docs", url: "https://docs.example/")
		let suggestion = try #require(ChatSuggestion.suggestions(for: tab).first)
		let attachment: AgentContextAttachment = .tabs([tab])

		await store.send(.ui(.suggestionTapped(suggestion))) {
			$0.conversations = [
				.init(
					id: ID(0),
					profileID: profileID,
					provider: .claude,
					title: AgentConversation.title(from: suggestion.prompt),
					createdAt: start,
					updatedAt: start,
					retention: .ephemeral,
					messages: [
						.init(id: UUID(1), role: .user, text: suggestion.prompt, attachments: [attachment], createdAt: start),
						.init(id: UUID(2), role: .assistant, text: "", createdAt: start),
					]
				),
			]
			$0.selectedID = ID(0)
			$0.turns[ID(0)] = .init(
				prompt: suggestion.prompt,
				attachments: [attachment],
				promptID: UUID(1),
				replyID: UUID(2)
			)
		}
		#expect(store.state.draft.isEmpty)
		#expect(store.state.attachments.isEmpty)

		// Once a chat exists, suggestions no longer apply.
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.skipReceivedActions()
		let sent = store.state.conversations[id: ID(0)]?.messages.count
		await store.send(.ui(.suggestionTapped(suggestion)))
		#expect(store.state.conversations[id: ID(0)]?.messages.count == sent)
		await store.skipInFlightEffects()
	}

	// MARK: - The page at request time (DEV-835)

	@Test
	internal func aSuggestionRetargetsToAnotherPageAsTheSameRequest() throws {
		let left: AgentContextAttachment.Tab = .init(title: "Left", url: "https://left.example/")
		let right: AgentContextAttachment.Tab = .init(title: "Right", url: "https://right.example/")
		let suggestions = ChatSuggestion.suggestions(for: left)

		expectNoDifference(
			suggestions.compactMap { $0.retargeted(to: right) },
			ChatSuggestion.suggestions(for: right)
		)
		let summarize = try #require(suggestions.first)
		expectNoDifference(summarize.retargeted(to: left), summarize)
		#expect(summarize.retargeted(to: .init(title: "New Tab", url: "arx://newtab")) == nil)
	}

	@Test
	internal func aPlacedSurfaceAsksTheAppForThePageBeforeSending() async throws {
		let world: ChatWorld = .init()
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		let surfaceID: ChatSurfaceID = .window(UUID(70))
		let tab: AgentContextAttachment.Tab = .init(title: "Docs", url: "https://docs.example/")
		let suggestion = try #require(ChatSuggestion.suggestions(for: tab).first)

		// Nothing is sent until the app answers with the page focused now.
		await store.send(.surfaces(.element(id: surfaceID, action: .ui(.suggestionTapped(suggestion))))) {
			// The surface opens with the chat's defaults, as any surface's first action does.
			$0.activeSurfaceID = surfaceID
			$0.surfaces[surfaceID] = $0.surface
		}
		await store.receive(\.delegate.suggestionTapped)
		#expect(store.state.conversations.isEmpty)
		#expect(store.state[surface: surfaceID].attachments.isEmpty)
	}
}
