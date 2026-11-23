import AgentClient
import AppFeature
import BrowserCore
import ChatFeature
import CustomDump
import Foundation
import MainFeature
import Observation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-761: a window's panel shows its global chat, or the chat pinned to the current tab; a
/// chat can become a chat tab and go back to the panel. The chats stay the profile's.
@Suite(.dependencies)
@MainActor
internal struct ChatPlacementTests {
	private let organization: BrowserOrganization = IntegrationFeatureTests().fixture()

	private var profileID: Profile.ID {
		organization.spaces[0].profileID
	}

	private var first: BrowserCore.Tab.ID {
		organization.tabs[0].id
	}

	private var second: BrowserCore.Tab.ID {
		organization.tabs[1].id
	}

	@Test
	internal func aPinnedChatFollowsItsTabAndOtherTabsShowTheGlobalChat() async throws {
		let store = makeStore()
		let conversationID = try await startChat("What is Arx?", in: store)
		let mainID: UUID = store.main.id

		// What Pin Chat to This Tab sends; the command itself needs a page in the pane.
		await store.send(.main(.ui(.chatPlacement(.togglePinToTab)))).finish()

		expectNoDifference(store.main.chatPins, [first: conversationID.rawValue])
		expectNoDifference(store.main.chatSurfaceID, .pinned(first.rawValue))
		expectNoDifference(store.chats[id: profileID]?.surfaces[.pinned(first.rawValue)]?.selectedID, conversationID)

		// The global chat starts a new one; the pinned chat stays in the chat list.
		expectNoDifference(store.chats[id: profileID]?.surfaces[.window(mainID)]?.selectedID, nil)
		expectNoDifference(store.chats[id: profileID]?.conversations.ids, [conversationID])
		expectNoDifference(
			store.windowLayout.windowPresentations.first { $0.id == mainID }?.chatPins,
			[.init(tabID: first, conversationID: conversationID.rawValue)]
		)

		// Another tab shows the global chat, and coming back shows the pinned one.
		await store.send(.main(.sidebar(.ui(.sidebar(.select(.tab(second.rawValue))))))).finish()
		expectNoDifference(store.main.chatSurfaceID, .window(mainID))
		await store.send(.main(.sidebar(.ui(.sidebar(.select(.tab(first.rawValue))))))).finish()
		expectNoDifference(store.main.chatSurfaceID, .pinned(first.rawValue))

		// Unpinning keeps the chat in view as the window's global chat.
		await store.send(.chat(.unpin(windowID: mainID, tabID: first))).finish()
		expectNoDifference(store.main.chatPins, [:])
		expectNoDifference(store.chats[id: profileID]?.surfaces[.pinned(first.rawValue)], nil)
		expectNoDifference(store.chats[id: profileID]?.surfaces[.window(mainID)]?.selectedID, conversationID)
	}

	@Test
	internal func closingAPinnedTabUnpinsItsChatAndKeepsTheChat() async throws {
		let store = makeStore()
		let conversationID = try await startChat("What is Arx?", in: store)

		await store.send(.chat(.pinToTab(windowID: store.main.id, tabID: first, conversationID: conversationID))).finish()
		expectNoDifference(store.main.chatPins, [first: conversationID.rawValue])

		await store.send(.main(.sidebar(.ui(.sidebar(.close(.tab(first.rawValue))))))).finish()

		expectNoDifference(store.main.chatPins, [:])
		expectNoDifference(store.chats[id: profileID]?.surfaces[.pinned(first.rawValue)], nil)
		expectNoDifference(store.chats[id: profileID]?.conversations.ids, [conversationID])
	}

	@Test
	internal func aChatBecomesAChatTabFollowsItsTitleAndMovesBackToTheSidebar() async throws {
		let store = makeStore()
		let conversationID = try await startChat("What is Arx?", in: store)
		let mainID: UUID = store.main.id

		await store.send(.main(.dispatchCommand(.openChatInTab, store.main.viewer.activePaneID))).finish()

		let tab = try #require(store.main.sidebar.organization.tabs.first { $0.isChat })
		expectNoDifference(tab.chatAddress, .init(conversationID: conversationID.rawValue))
		expectNoDifference(tab.restoration.title, "What is Arx?")
		expectNoDifference(store.main.sidebar.selectedTab?.id, tab.id)
		expectNoDifference(store.main.viewer.item.tab?.id, tab.id)
		#expect(!store.main.isChatOpen)
		expectNoDifference(store.chats[id: profileID]?.surfaces[.window(mainID)]?.selectedID, nil)

		// A chat tab can't be pinned to.
		await store.send(.main(.ui(.chatPlacement(.togglePinToTab)))).finish()
		expectNoDifference(store.main.chatPins, [:])

		// The tab's surface shows its chat; renaming it renames the tab.
		let surface: ChatSurfaceID = .tab(tab.id.rawValue)
		await store.send(.chats(.element(id: profileID, action: .surfaces(.element(id: surface, action: .ui(.show(conversationID))))))).finish()
		await store.send(.chats(.element(id: profileID, action: .surfaces(.element(id: surface, action: .ui(.renamed("Arx")))))))
			.finish()
		expectNoDifference(store.main.sidebar.organization.tabs[id: tab.id]?.restoration.title, "Arx")
		expectNoDifference(store.workspace.tabs[id: tab.id]?.restoration.title, "Arx")

		// A new chat in the tab gives the tab a new chat's address.
		await store.send(.chats(.element(id: profileID, action: .surfaces(.element(id: surface, action: .ui(.newChatTapped))))))
			.finish()
		expectNoDifference(store.main.sidebar.organization.tabs[id: tab.id]?.chatAddress, .init(conversationID: nil))
		await store.send(.chats(.element(id: profileID, action: .surfaces(.element(id: surface, action: .ui(.chatSelected(conversationID)))))))
			.finish()
		expectNoDifference(
			store.main.sidebar.organization.tabs[id: tab.id]?.chatAddress,
			.init(conversationID: conversationID.rawValue)
		)

		await store.send(.chat(.moveToSidebar(windowID: mainID, tabID: tab.id, conversationID: conversationID))).finish()

		#expect(store.main.sidebar.organization.tabs[id: tab.id] == nil)
		#expect(store.main.isChatOpen)
		expectNoDifference(store.chats[id: profileID]?.surfaces[.window(mainID)]?.selectedID, conversationID)
		expectNoDifference(store.chats[id: profileID]?.surfaces[surface], nil)
		expectNoDifference(store.chats[id: profileID]?.conversations.ids, [conversationID])
	}

	// MARK: - Rendering (DEV-789)

	/// Pin Chat to This Tab hung the app: the panel shows the pinned surface while the last
	/// action came from the window's global chat, and each read of the pinned surface invalidated
	/// the panel that made it, so SwiftUI rendered it forever.
	@Test
	internal func pinningAChatLetsThePinnedPanelSettle() async throws {
		let store = makeStore()
		let conversationID = try await startChat("What is Arx?", in: store)

		await store.send(.main(.ui(.chatPlacement(.togglePinToTab)))).finish()
		let surfaceID: ChatSurfaceID = store.main.chatSurfaceID
		expectNoDifference(surfaceID, .pinned(first.rawValue))

		let panel = try panelStore(surfaceID, in: store)
		expectNoDifference(panel.selectedID, conversationID)
		expectRenderSettles(panel)

		// The window's global chat, shown on another tab, settles too.
		expectRenderSettles(try panelStore(.window(store.main.id), in: store))
	}

	/// Open Chat in Tab hung the app the same way, with the chat tab's surface.
	@Test
	internal func openingAChatInATabLetsTheChatTabSettle() async throws {
		let store = makeStore()
		let conversationID = try await startChat("What is Arx?", in: store)

		await store.send(.main(.dispatchCommand(.openChatInTab, store.main.viewer.activePaneID))).finish()
		let tab = try #require(store.main.sidebar.organization.tabs.first { $0.isChat })

		let chatTab = try panelStore(.tab(tab.id.rawValue), in: store)
		expectRenderSettles(chatTab)

		// What the chat tab's task sends once it shows: its address names the chat.
		chatTab.send(.ui(.show(conversationID)))
		expectNoDifference(chatTab.selectedID, conversationID)
		expectRenderSettles(chatTab)
		expectRenderSettles(try panelStore(.window(store.main.id), in: store))
	}

	@Test
	internal func twoSurfacesOfOneProfileRenderedTogetherSettle() async throws {
		let store = makeStore()
		_ = try await startChat("What is Arx?", in: store)
		await store.send(.main(.dispatchCommand(.openChatInTab, store.main.viewer.activePaneID))).finish()
		let tab = try #require(store.main.sidebar.organization.tabs.first { $0.isChat })

		// A chat tab beside the window's panel, as in Split View or a second window.
		let chatTab = try panelStore(.tab(tab.id.rawValue), in: store)
		let panel = try panelStore(.window(store.main.id), in: store)
		let invalidated: LockIsolated<Bool> = .init(false)
		withObservationTracking {
			render(chatTab)
			render(panel)
		} onChange: {
			invalidated.setValue(true)
		}
		render(chatTab)
		render(panel)
		#expect(!invalidated.value, "Rendering one surface invalidated the other: a render loop")
	}

	@Test
	internal func theChatWidthIsClampedAndSavedWithTheWindow() async throws {
		let store = makeStore()

		await store.send(.main(.ui(.chatWidthCommitted(480)))).finish()
		expectNoDifference(store.main.chatWidth, 480)
		expectNoDifference(store.windowLayout.windowPresentations.first { $0.id == store.main.id }?.chatWidth, 480)

		await store.send(.main(.ui(.chatWidthCommitted(5_000)))).finish()
		expectNoDifference(store.main.chatWidth, BrowserChatWidth.range.upperBound)

		await store.send(.main(.ui(.chatWidthCommitted(10)))).finish()
		expectNoDifference(store.main.chatWidth, BrowserChatWidth.range.lowerBound)
	}

	@Test
	internal func widthsAndPinsAreRestoredWithTheWindow() {
		let space = organization.spaces[0].id
		let main = MainFeature.State(organization: organization, spaceID: space)
		let gone = BrowserCore.Tab.ID(rawValue: UUID(999))
		let preferences = BrowserPreferences(windowPresentations: [
			.init(
				id: main.id,
				activeSpaceID: space,
				spaces: [],
				chatWidth: 9_000,
				chatPins: [
					.init(tabID: first, conversationID: UUID(50)),
					.init(tabID: gone, conversationID: UUID(51)),
				]
			),
		])

		let state = AppFeature.State.launching(main: main, preferences: preferences)

		expectNoDifference(state.main.chatWidth, BrowserChatWidth.range.upperBound)
		expectNoDifference(state.main.chatPins, [first: UUID(50)])
	}

	@Test(arguments: [
		("arx://chat", ChatTabAddress(conversationID: nil)),
		("arx://chat/", ChatTabAddress(conversationID: nil)),
		("arx://chat/00000000-0000-0000-0000-000000000007", ChatTabAddress(conversationID: UUID(7))),
		("ARX://Chat/00000000-0000-0000-0000-000000000007", ChatTabAddress(conversationID: UUID(7))),
	])
	internal func chatTabAddressesRoundTrip(text: String, expected: ChatTabAddress) throws {
		let url = try #require(URL(string: text))
		expectNoDifference(ChatTabAddress(url: url), expected)
		expectNoDifference(ChatTabAddress(url: expected.url), expected)
	}

	@Test(arguments: ["https://chat.example", "arx://extensions", "about:blank"])
	internal func otherAddressesAreNotChatTabs(text: String) throws {
		let url = try #require(URL(string: text))
		#expect(ChatTabAddress(url: url) == nil)
	}

	// MARK: - Fixtures

	/// The store a window's panel or a chat tab scopes to, as `AppMainView` scopes it.
	private func panelStore(
		_ surfaceID: ChatSurfaceID,
		in store: StoreOf<AppFeature>
	) throws -> StoreOf<ChatFeature> {
		let profileID: Profile.ID = profileID
		let scoped: StoreOf<ChatFeature>? = store.scope(state: \.chats[id: profileID], action: \.chats[id: profileID])
		let chat: StoreOf<ChatFeature> = try #require(scoped)
		return chat.scope(state: \.[surface: surfaceID], action: \.surfaces[id: surfaceID])
	}

	/// What `ChatPanelView` reads as it renders.
	private func render(_ store: StoreOf<ChatFeature>) {
		_ = store.selectedID
		_ = store.selected
		_ = store.screen
		_ = store.draft
		_ = store.isLoaded
	}

	/// A render that reads the state must not invalidate itself, or SwiftUI renders it again
	/// forever on the main thread.
	private func expectRenderSettles(
		_ store: StoreOf<ChatFeature>,
		sourceLocation: SourceLocation = #_sourceLocation
	) {
		let invalidated: LockIsolated<Bool> = .init(false)
		withObservationTracking {
			render(store)
		} onChange: {
			invalidated.setValue(true)
		}

		// The next render reads the same state again.
		render(store)
		#expect(!invalidated.value, "Reading the surface invalidated its own view: a render loop", sourceLocation: sourceLocation)
	}

	private func makeStore() -> StoreOf<AppFeature> {
		Store(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) {
			AppFeature()
		} withDependencies: {
			// Timers such as a turn's silence watch never fire here: these tests don't drive time (DEV-643).
			$0.continuousClock = EndingClock()

			// Past the fixture's IDs, so new tabs and chats never collide with them.
			let next: LockIsolated<Int> = .init(1_000)
			$0.uuid = .init {
				next.withValue { value in
					value += 1
					return UUID(value)
				}
			}
			$0.date = .constant(Date(timeIntervalSince1970: 1_800_000_000))
			$0.agentProviders = .init(
				clients: [
					.init(
						provider: .claude,
						account: { .init(provider: .claude, status: .signedIn(.init(id: "test"))) },
						models: { [] },
						send: { _ in
							AsyncThrowingStream { continuation in
								continuation.yield(.text("It's a browser."))
								continuation.finish()
							}
						},
						discard: { _ in }
					),
				],
				isEnabled: false
			)
			$0.agentConversations = .init(
				list: { _ in [] },
				save: { _ in },
				delete: { _, _ in },
				deleteProfile: { _ in },
				settings: { _ in .init(provider: .claude, retention: .persistent) },
				setSettings: { _, _ in },
				rememberTranscript: { _, _ in },
				forgetTranscript: { _, _ in },
				rememberedTranscripts: { _ in [] },
				clearTurns: { _, _ in }
			)
			$0.agentBrowserAccess = .embedded(.init())
		}
	}

	/// Text + Tab in the command bar: a kept chat in the main window's panel.
	private func startChat(
		_ prompt: String,
		in store: StoreOf<AppFeature>
	) async throws -> AgentConversation.ID {
		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged(prompt))))).finish()
		await store.send(.main(.commandBar(.ui(.tabPressed)))).finish()
		let chat = try #require(store.chats[id: profileID])
		return try #require(chat.surfaces[.window(store.main.id)]?.selectedID)
	}
}
