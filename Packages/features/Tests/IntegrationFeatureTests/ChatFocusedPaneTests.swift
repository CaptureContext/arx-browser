import AgentClient
import AppFeature
import BrowserAutomationClient
import BrowserCore
import ChatFeature
import CustomDump
import Foundation
import MainFeature
import Testing
import ViewerFeature
import _ComposableArchitecture
import _TestSupport

/// DEV-835: in a split, a page-context request from the chat is about the focused pane's tab at
/// the moment it's made, whichever pane the panel last rendered for. A chat pinned to a tab keeps
/// its own tab.
@Suite(.dependencies)
@MainActor
internal struct ChatFocusedPaneTests {
	private let profileID: Profile.ID = .init(rawValue: UUID(0))
	private let spaceID: Space.ID = .init(rawValue: UUID(1))
	private let leftTab: BrowserCore.Tab = .init(
		id: .init(rawValue: UUID(3)),
		profileID: .init(rawValue: UUID(0)),
		restoration: .init(title: "Left page", url: URL(string: "https://left.example/")!)
	)
	private let rightTab: BrowserCore.Tab = .init(
		id: .init(rawValue: UUID(4)),
		profileID: .init(rawValue: UUID(0)),
		restoration: .init(title: "Right page", url: URL(string: "https://right.example/")!)
	)
	private let rightPaneID: UUID = UUID(20)
	private let otherProfileID: Profile.ID = .init(rawValue: UUID(9))

	private var left: AgentContextAttachment.Tab {
		.init(title: "Left page", url: "https://left.example/")
	}

	private var right: AgentContextAttachment.Tab {
		.init(title: "Right page", url: "https://right.example/")
	}

	@Test
	internal func summarizingInASplitAsksAboutTheFocusedPaneEveryTime() async throws {
		let store = makeStore()
		let leftPaneID: UUID = store.main.viewer.activePaneID
		let surfaceID: ChatSurfaceID = .window(store.main.id)
		let summarizeLeft = try #require(ChatSuggestion.suggestions(for: left).first)
		let summarizeRight = try #require(ChatSuggestion.suggestions(for: right).first)

		// The right pane gets focus, but the panel still shows what it rendered for the left one.
		await store.send(.main(.viewer(.ui(.focus(rightPaneID))))).finish()
		expectNoDifference(store.main.focusedPageTab?.id, rightTab.id)
		await tap(summarizeLeft, on: surfaceID, in: store)
		expectNoDifference(firstPrompt(on: surfaceID, in: store), .init(text: summarizeRight.prompt, attachments: [.tabs([right])]))

		// Back to the left pane: the next summary is the left page's.
		await store.send(.chats(.element(id: profileID, action: .surfaces(.element(id: surfaceID, action: .ui(.newChatTapped))))))
			.finish()
		await store.send(.main(.viewer(.ui(.focus(leftPaneID))))).finish()
		expectNoDifference(store.main.focusedPageTab?.id, leftTab.id)
		await tap(summarizeRight, on: surfaceID, in: store)
		expectNoDifference(firstPrompt(on: surfaceID, in: store), .init(text: summarizeLeft.prompt, attachments: [.tabs([left])]))

		// And right again, with ⌃Tab's next-pane command this time.
		await store.send(.chats(.element(id: profileID, action: .surfaces(.element(id: surfaceID, action: .ui(.newChatTapped))))))
			.finish()
		await store.send(.main(.ui(.focusOtherPane))).finish()
		expectNoDifference(store.main.focusedPageTab?.id, rightTab.id)
		await tap(summarizeLeft, on: surfaceID, in: store)
		expectNoDifference(firstPrompt(on: surfaceID, in: store), .init(text: summarizeRight.prompt, attachments: [.tabs([right])]))
	}

	@Test
	internal func aChatPinnedToATabKeepsAskingAboutItsTab() async throws {
		let store = makeStore()
		let surfaceID: ChatSurfaceID = .pinned(leftTab.id.rawValue)
		let summarizeLeft = try #require(ChatSuggestion.suggestions(for: left).first)

		await store.send(.main(.viewer(.ui(.focus(rightPaneID))))).finish()
		await tap(summarizeLeft, on: surfaceID, in: store)

		expectNoDifference(firstPrompt(on: surfaceID, in: store), .init(text: summarizeLeft.prompt, attachments: [.tabs([left])]))
	}

	@Test
	internal func aSuggestionNeverCarriesAnotherProfilesPage() async throws {
		let store = makeStore()
		let summarizeLeft = try #require(ChatSuggestion.suggestions(for: left).first)

		// A panel rendered for another profile, tapped after the window moved to this one's space.
		await store.send(.chat(.prepare(otherProfileID))).finish()
		#expect(store.chats[id: otherProfileID] != nil)
		await store.send(.chats(.element(
			id: otherProfileID,
			action: .surfaces(.element(id: .window(store.main.id), action: .ui(.suggestionTapped(summarizeLeft))))
		)))
		.finish()

		#expect(store.chats[id: otherProfileID]?.conversations.isEmpty == true)
	}

	@Test
	internal func theWindowsCurrentTabAttachableIsTheFocusedPanes() async throws {
		let store = makeStore()

		await store.send(.main(.viewer(.ui(.focus(rightPaneID))))).finish()
		expectNoDifference(store.main.chatTab?.id, rightTab.id)
		expectNoDifference(
			store.main.chatSurfaceID,
			.window(store.main.id)
		)
	}

	@Test
	internal func theAssistantsFocusedTabIsTheFocusedPanesEvenWhenTheSidebarSaysOtherwise() throws {
		var client = AutomationClient(
			id: UUID(60),
			name: "Assistant",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.space(spaceID, profileID: profileID)],
			allowsRead: true,
			allowsManagement: false,
			grantRevision: UUID(61)
		)
		client.allowsFocusedTab = true
		var state = AppFeature.State(main: makeMain(), automation: .init(isEnabled: true, clients: [client]))
		state.main.viewer.activePaneID = rightPaneID

		// A selection that lags behind the panes, as during a space swipe.
		state.main.sidebar.organization.spaces[id: spaceID]?.selectedTabID = leftTab.id

		let resolved = try #require(state.automationFocusedTab(for: client, snapshots: [:]))
		expectNoDifference(resolved.tabID, rightTab.id.rawValue)
	}

	// MARK: - Fixtures

	private struct Prompt: Equatable {
		var text: String
		var attachments: [AgentContextAttachment]
	}

	private func tap(
		_ suggestion: ChatSuggestion,
		on surfaceID: ChatSurfaceID,
		in store: StoreOf<AppFeature>
	) async {
		await store.send(.chat(.prepare(profileID))).finish()
		await store.send(.chats(.element(
			id: profileID,
			action: .surfaces(.element(id: surfaceID, action: .ui(.suggestionTapped(suggestion))))
		)))
		.finish()
	}

	/// The first message of the chat the surface shows.
	private func firstPrompt(
		on surfaceID: ChatSurfaceID,
		in store: StoreOf<AppFeature>
	) -> Prompt? {
		guard
			let chat = store.chats[id: profileID],
			let id = chat.surfaces[surfaceID]?.selectedID,
			let message = chat.conversations[id: id]?.messages.first
		else { return nil }

		return .init(text: message.text, attachments: message.attachments)
	}

	/// A window split in two: the left pane shows the left page and is focused.
	private func makeMain() -> MainFeature.State {
		let organization: BrowserOrganization = .init(
			profiles: [.init(id: profileID, name: "Default"), .init(id: otherProfileID, name: "Other")],
			spaces: [
				.init(
					id: spaceID,
					profileID: profileID,
					name: "Work",
					unpinnedTabs: [leftTab.id, rightTab.id],
					selectedTabID: leftTab.id
				),
			],
			tabs: [leftTab, rightTab]
		)
		var main = MainFeature.State(organization: organization, spaceID: spaceID)
		main.viewer.item = .init(
			tab: leftTab,
			navigation: .init(url: leftTab.restoration.url, title: leftTab.restoration.title)
		)
		main.viewer.panes.append(.init(
			id: rightPaneID,
			item: .init(tab: rightTab, navigation: .init(url: rightTab.restoration.url, title: rightTab.restoration.title))
		))
		return main
	}

	private func makeStore() -> StoreOf<AppFeature> {
		Store(initialState: AppFeature.State(main: makeMain())) {
			AppFeature()
		} withDependencies: {
			$0.continuousClock = EndingClock()
			let next: LockIsolated<Int> = .init(1_000)
			$0.uuid = .init {
				next.withValue { value in
					value += 1
					return UUID(value)
				}
			}
			$0.date = .constant(Date(timeIntervalSince1970: 1_800_000_000))
			$0.browserEngine.open = { _ in }
			$0.agentProviders = .init(
				clients: [
					.init(
						provider: .claude,
						account: { .init(provider: .claude, status: .signedIn(.init(id: "test"))) },
						models: { [] },
						send: { _ in
							AsyncThrowingStream { continuation in
								continuation.yield(.text("A summary."))
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
}
