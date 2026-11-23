import AgentClient
import BrowserCore
import ChatFeature
import CustomDump
import Foundation
import Observation
import Testing
import _ComposableArchitecture
import _TestSupport

/// One profile's chats shown in several places at once (DEV-761): each surface keeps its own
/// chat, screen and composer, and tells the app when it moves to another chat.
@Suite(.dependencies)
@MainActor
internal struct ChatSurfaceTests {
	private typealias ID = AgentConversation.ID

	private let profileID: Profile.ID = ChatWorld.profileID
	private let start: Date = ChatWorld.start
	private let window: ChatSurfaceID = .window(UUID(1))
	private let pinned: ChatSurfaceID = .pinned(UUID(2))
	private let tab: ChatSurfaceID = .tab(UUID(3))

	@Test
	internal func eachSurfaceKeepsItsOwnChatAndComposer() async throws {
		let world: ChatWorld = .init()
		let weather: AgentConversation = conversation(1, title: "Weather", updated: 10)
		let flights: AgentConversation = conversation(2, title: "Flights", updated: 20)
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true, conversations: [weather, flights])) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.surfaces(.element(id: window, action: .ui(.chatSelected(ID(1)))))) {
			$0.activeSurfaceID = window
			$0.surfaces[window] = surface(ID(1), focusRequest: 1)
		}
		await store.receive(\.delegate.surfaceChanged)

		await store.send(.surfaces(.element(id: tab, action: .ui(.show(ID(2)))))) {
			$0.activeSurfaceID = tab
			$0.surfaces[tab] = surface(ID(2))
		}
		await store.receive(\.delegate.surfaceChanged)

		await store.send(.surfaces(.element(id: tab, action: .ui(.draftChanged("When?"))))) {
			$0.surfaces[tab]?.draft = "When?"
		}
		expectNoDifference(store.state[surface: window].selectedID, ID(1))
		expectNoDifference(store.state[surface: window].draft, "")
		expectNoDifference(store.state[surface: tab].selectedID, ID(2))
		expectNoDifference(store.state[surface: tab].draft, "When?")

		// Showing the chat a surface already shows changes nothing.
		await store.send(.surfaces(.element(id: tab, action: .ui(.show(ID(2))))))
	}

	/// DEV-789: seeing the state as a surface sees it is a read. It must not tell observers that
	/// the active surface changed, or every view scoped to a surface other than the last active
	/// one invalidates itself each time it renders.
	@Test
	internal func readingASurfaceNotifiesNoObservers() {
		let state = ChatFeature.State(id: profileID, isLoaded: true)
		let store: StoreOf<ChatFeature> = Store(initialState: state[surface: window]) {
			EmptyReducer<ChatFeature.State, ChatFeature.Action>()
		}
		let pinnedStore: StoreOf<ChatFeature> = store.scope(
			state: \ChatFeature.State.[surface: pinned],
			action: \.surfaces[id: pinned]
		)
		let invalidated: LockIsolated<Bool> = .init(false)
		withObservationTracking {
			_ = pinnedStore.selectedID
			_ = pinnedStore.screen
		} onChange: {
			invalidated.setValue(true)
		}
		_ = pinnedStore.selectedID
		_ = store.state[surface: tab].draft
		#expect(!invalidated.value)
	}

	@Test
	internal func aSurfaceThatMovesToAnotherChatTellsTheApp() async throws {
		let world: ChatWorld = .init()
		let weather: AgentConversation = conversation(1, title: "Weather", updated: 10)
		let flights: AgentConversation = conversation(2, title: "Flights", updated: 20)
		var state: ChatFeature.State = .init(id: profileID, isLoaded: true, conversations: [weather, flights])
		state.surfaces[pinned] = surface(ID(1))
		let store = TestStore(initialState: state) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.surfaces(.element(id: pinned, action: .ui(.chatSelected(ID(2)))))) {
			$0.activeSurfaceID = pinned
			$0.surfaces[pinned]?.selectedID = ID(2)
			$0.surfaces[pinned]?.focusRequest = 1
		}
		await store.receive(\.delegate.surfaceChanged)
		expectNoDifference(store.state.surfaces[pinned]?.selectedID, ID(2))

		await store.send(.surfaces(.element(id: pinned, action: .ui(.newChatTapped)))) {
			$0.surfaces[pinned]?.selectedID = nil
			$0.surfaces[pinned]?.focusRequest = 2
		}
		await store.receive(\.delegate.surfaceChanged)

		await store.send(.surfaces(.element(id: pinned, action: .ui(.chatSelected(ID(1)))))) {
			$0.surfaces[pinned]?.selectedID = ID(1)
			$0.surfaces[pinned]?.focusRequest = 3
		}
		await store.receive(\.delegate.surfaceChanged)
		await store.send(.surfaces(.element(id: pinned, action: .ui(.renamed("Rain"))))) {
			$0.conversations[id: ID(1)]?.title = "Rain"
		}
		await store.receive(\.delegate.titlesChanged)
		await store.finish()
	}

	@Test
	internal func endingAChatEmptiesEverySurfaceThatShowsIt() async throws {
		let world: ChatWorld = .init()
		let weather: AgentConversation = conversation(1, title: "Weather", updated: 10)
		var state: ChatFeature.State = .init(id: profileID, isLoaded: true, conversations: [weather])
		state.surfaces[window] = surface(ID(1))
		state.surfaces[tab] = surface(ID(1))
		let store = TestStore(initialState: state) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.surfaces(.element(id: window, action: .ui(.deleteTapped)))) {
			$0.activeSurfaceID = window
			$0.conversations = []
			$0.surfaces[window]?.selectedID = nil
			$0.surfaces[tab]?.selectedID = nil
		}
		await store.receive(\.delegate.surfaceChanged)
		await store.receive(\.delegate.titlesChanged)
		await store.finish()
	}

	@Test
	internal func anAnswerIsUnreadOnlyWhenNoSurfaceShowsItsChat() async throws {
		let world: ChatWorld = .init()
		let weather: AgentConversation = conversation(1, title: "Weather", updated: 10)
		let lunch: AgentConversation = conversation(2, title: "Lunch", updated: 20)
		var state: ChatFeature.State = .init(id: profileID, isLoaded: true, conversations: [weather, lunch])

		// The panel looks at Your Chats, but a chat tab shows the weather.
		var list: ChatSurface = surface(nil)
		list.screen = .chats
		state.surfaces[window] = list
		state.surfaces[tab] = surface(ID(1))
		state.turns[ID(1)] = .init(prompt: "Weather", attachments: [], promptID: UUID(500), replyID: UUID(501))
		state.turns[ID(2)] = .init(prompt: "Lunch", attachments: [], promptID: UUID(600), replyID: UUID(601))
		let store = TestStore(initialState: state) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		await store.send(.event(.turnFinished(ID(1))))
		await store.send(.event(.turnFinished(ID(2))))
		expectNoDifference(store.state.unreadIDs, [ID(2)])
		await store.skipInFlightEffects(strict: false)
	}

	// MARK: - Fixtures

	private func surface(
		_ selectedID: ID?,
		focusRequest: Int = 0
	) -> ChatSurface {
		var surface: ChatSurface = .init(selectedID: selectedID, newChatProvider: .claude)
		surface.focusRequest = focusRequest
		return surface
	}

	private func conversation(
		_ id: Int,
		title: String,
		updated: TimeInterval
	) -> AgentConversation {
		.init(
			id: ID(id),
			profileID: profileID,
			provider: .claude,
			title: title,
			createdAt: start.addingTimeInterval(updated),
			updatedAt: start.addingTimeInterval(updated),
			retention: .persistent,
			messages: [
				.init(id: UUID(id * 100), role: .user, text: title, createdAt: start),
				.init(id: UUID(id * 100 + 1), role: .assistant, text: "Answer", createdAt: start),
			]
		)
	}
}
