import AgentClient
import AppFeature
import BrowserAutomationClient
import BrowserCore
import BrowserWorkspaceClient
import ChatFeature
import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import OnboardingFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-720: text + Tab in the command bar starts a chat in the window's profile, and the
/// app registers each profile's assistant as an ordinary, profile-scoped automation client.
@Suite(.dependencies)
@MainActor
internal struct ChatEntryTests {
	private let organization: BrowserOrganization = IntegrationFeatureTests().fixture()

	private var profileID: Profile.ID {
		organization.spaces[0].profileID
	}

	// MARK: - Command bar

	@Test
	internal func textAndTabStartsAChatInsteadOfFollowingAResult() async throws {
		var state: CommandBarFeature.State = .init()
		state.isChatAvailable = true
		let store = TestStore(initialState: state) { CommandBarFeature() }
		store.exhaustivity = .off

		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged("what changed in Swift 6.4?")))
		await store.send(.ui(.tabPressed)) {
			$0.isPresented = false
			$0.query = ""
		}
		await store.receive(\.delegate.startChat, "what changed in Swift 6.4?")
	}

	@Test(arguments: ["fixture", "!fixture swift", "!g"])
	internal func aKeywordOrBangAndTabStaysASearch(query: String) async throws {
		let shortcut = SearchShortcut(name: "Fixture", keyword: "fixture", template: "https://search.example/?q={query}")
		let document = WorkspaceDocument.unsaved(BrowserPreferences(searchShortcuts: [shortcut]))
		var state: CommandBarFeature.State = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			CommandBarFeature.State()
		}
		state.isChatAvailable = true
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off

		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged(query)))
		await store.send(.ui(.tabPressed))
		#expect(store.state.isPresented)
		#expect(store.state.chatPrompt == nil)
		expectNoDifference(store.state.siteSearchKeyword, query == "fixture" ? "fixture" : nil)
	}

	@Test
	internal func anUneditedAddressAndTabStaysPut() async throws {
		var state: CommandBarFeature.State = .init()
		state.isChatAvailable = true
		let store = TestStore(initialState: state) { CommandBarFeature() }
		store.exhaustivity = .off

		await store.send(.present(.currentTab, "https://capturecontext.dev/", []))
		await store.send(.ui(.tabPressed))
		#expect(store.state.isPresented)
	}

	/// DEV-751: the "Ask an agent ⇥" hint shows exactly when Tab would start a chat.
	@Test(arguments: [
		("what changed?", true, true),
		("", true, false),
		("   ", true, false),
		("gh", true, false),
		("!gh swift", true, false),
		("!g", true, false),
		("what changed?", false, false),
	])
	internal func theAgentHintShowsOnlyWhenTabStartsAChat(
		query: String,
		chat: Bool,
		shows: Bool
	) async throws {
		let document = WorkspaceDocument.unsaved(Self.preferencesWithASearchShortcut)
		var state: CommandBarFeature.State = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			CommandBarFeature.State()
		}
		state.isChatAvailable = chat
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off

		await store.send(.present(.newTab, "", []))
		await store.send(.ui(.queryChanged(query)))
		expectNoDifference(store.state.showsAgentHint, shows)
		expectNoDifference(store.state.showsAgentHint, store.state.pendingShortcutKeyword == nil && store.state.chatPrompt != nil)
	}

	@Test
	internal func theAgentHintHidesForAnUneditedAddressAndInASiteSearch() async throws {
		let document = WorkspaceDocument.unsaved(Self.preferencesWithASearchShortcut)
		var state: CommandBarFeature.State = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			CommandBarFeature.State()
		}
		state.isChatAvailable = true
		let store = TestStore(initialState: state) { CommandBarFeature() } withDependencies: {
			$0.workspaceDocument = document
		}
		store.exhaustivity = .off

		await store.send(.present(.currentTab, "https://capturecontext.dev/", []))
		#expect(!store.state.showsAgentHint)
		await store.send(.ui(.queryChanged("summarize this page")))
		#expect(store.state.showsAgentHint)

		await store.send(.ui(.queryChanged("gh")))
		await store.send(.ui(.tabPressed))
		await store.send(.ui(.queryChanged("swift")))
		#expect(store.state.siteSearchKeyword != nil)
		#expect(!store.state.showsAgentHint)
	}

	/// Arx ships no search shortcuts of its own since bangs took their place (DEV-1321), so the
	/// site-search cases bring one.
	private static var preferencesWithASearchShortcut: BrowserPreferences {
		var preferences = BrowserPreferences()
		preferences.searchShortcuts.append(
			.init(name: "GitHub", keyword: "gh", template: "https://github.com/search?q={query}")
		)
		return preferences
	}

	// MARK: - Windows

	/// DEV-779: ⌘T, ⌘L and ⌘K arrive as pane commands, not `ui.openCommand`, and used to leave
	/// chat unavailable, so the "Ask an agent ⇥" hint never showed and Tab did nothing.
	@Test(arguments: [
		(BrowserCommand.newTab, false, true),
		(.commandBar, false, true),
		(.address, false, true),
		(.newTab, true, false),
		(.commandBar, true, false),
	])
	internal func everyShortcutOffersTheAgentOutsidePrivateWindows(
		command: BrowserCommand,
		isPrivate: Bool,
		shows: Bool
	) async throws {
		let state = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: isPrivate
		)
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off

		await store.send(.dispatchCommand(command, state.viewer.activePaneID))
		await store.receive(\.commandBar.present)
		#expect(store.state.commandBar.isPresented)
		expectNoDifference(store.state.commandBar.isChatAvailable, !isPrivate)

		await store.send(.commandBar(.ui(.queryChanged("test"))))
		expectNoDifference(store.state.commandBar.showsAgentHint, shows)
		await store.finish()
	}

	@Test
	internal func tabOpensThePanelAndTheProfilesChatAnswers() async throws {
		let requests: LockIsolated<[AgentTurnRequest]> = .init([])
		let store = Store(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) {
			AppFeature()
		} withDependencies: {
			// Timers such as a turn's silence watch never fire here: these tests don't drive time (DEV-643).
			$0.continuousClock = EndingClock()
			$0.uuid = .incrementing
			$0.date = .constant(Date(timeIntervalSince1970: 1_800_000_000))
			$0.agentProviders = .init(
				clients: [
					.init(
						provider: .claude,
						account: { .init(provider: .claude, status: .signedIn(.init(id: "test"))) },
						models: { [] },
						send: { request in
							requests.withValue { $0.append(request) }
							return AsyncThrowingStream { continuation in
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
				// A kept chat has no idle timer, so the run ends with the answer.
				settings: { _ in .init(provider: .claude, retention: .persistent) },
				setSettings: { _, _ in },
				rememberTranscript: { _, _ in },
				forgetTranscript: { _, _ in },
				rememberedTranscripts: { _ in [] },
				clearTurns: { _, _ in }
			)
			$0.agentBrowserAccess = .embedded(.init())
		}

		await store.send(.main(.ui(.openCommand(.newTab)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged("What is Arx?"))))).finish()
		await store.send(.main(.commandBar(.ui(.tabPressed)))).finish()

		#expect(store.main.isChatOpen)
		#expect(!store.main.commandBar.isPresented)
		#expect(store.main.commandBarContext == nil)
		let chat = try #require(store.chats[id: profileID])
		expectNoDifference(chat.selected?.messages.map(\.text), ["What is Arx?", "It's a browser."])
		expectNoDifference(chat.selected?.retention, .persistent)
		expectNoDifference(requests.value.map(\.profileID), [profileID])

		// Hiding the panel belongs to the window; the chat stays with the profile.
		await store.send(.main(.ui(.chatOpenChanged(false)))).finish()
		#expect(!store.main.isChatOpen)
		#expect(store.chats[id: profileID]?.conversations.count == 1)

		await store.send(.main(.dispatchCommand(.chats, store.main.viewer.activePaneID))).finish()
		#expect(store.main.isChatOpen)
	}

	// MARK: - Onboarding

	/// DEV-700: Connect on onboarding's connect-your-agent page makes the provider every
	/// ordinary profile's assistant, keeping how long each profile keeps its chats.
	@Test
	internal func connectingFromOnboardingMakesTheProviderEveryProfilesAssistant() async throws {
		let saved: LockIsolated<[Profile.ID: AgentProfileSettings]> = .init([:])
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.onboarding = .init()
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			// Timers such as a turn's silence watch never fire here: these tests don't drive time (DEV-643).
			$0.continuousClock = EndingClock()
			$0.uuid = .incrementing
			$0.agentProviders = .init(
				clients: [.unimplemented(.claude), .unimplemented(.openAI)],
				isEnabled: false
			)
			$0.agentConversations = .init(
				list: { _ in [] },
				save: { _ in },
				delete: { _, _ in },
				deleteProfile: { _ in },
				settings: { _ in .init(provider: .claude, accountID: "~/.claude", modelID: "opus", retention: .persistent) },
				setSettings: { settings, profileID in saved.withValue { $0[profileID] = settings } },
				rememberTranscript: { _, _ in },
				forgetTranscript: { _, _ in },
				rememberedTranscripts: { _ in [] },
				clearTurns: { _, _ in }
			)
		}

		await store.send(.onboarding(.delegate(.agentConnected(.openAI)))).finish()

		let profiles: [Profile.ID] = organization.profiles.map(\.id)
		#expect(!profiles.isEmpty)
		expectNoDifference(
			saved.value,
			Dictionary(uniqueKeysWithValues: profiles.map { ($0, AgentProfileSettings(provider: .openAI, retention: .persistent)) })
		)

		// Every profile's chats exist and use the provider now.
		for profileID in profiles {
			expectNoDifference(store.chats[id: profileID]?.settings.provider, .openAI)
			expectNoDifference(store.chats[id: profileID]?.pendingProvider, nil)
		}

		// A provider this build doesn't ship changes nothing.
		saved.setValue([:])
		await store.send(.onboarding(.delegate(.agentConnected(.init(rawValue: "gemini"))))).finish()
		#expect(saved.value.isEmpty)
	}

	@Test
	internal func privateWindowsHaveNoChat() async throws {
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let privateWindow = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true,
			id: UUID(90)
		)
		state.windows.append(privateWindow)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			// Timers such as a turn's silence watch never fire here: these tests don't drive time (DEV-643).
			$0.continuousClock = EndingClock()
			$0.uuid = .incrementing
		}

		#expect(!BrowserCommand.chats.isEnabled(in: privateWindow.commandContext))
		await store.send(.windows(.element(id: privateWindow.id, action: .ui(.openCommand(.newTab))))).finish()
		await store.send(.windows(.element(id: privateWindow.id, action: .commandBar(.ui(.queryChanged("hello")))))).finish()
		await store.send(.windows(.element(id: privateWindow.id, action: .commandBar(.ui(.tabPressed))))).finish()
		await store.send(.windows(.element(id: privateWindow.id, action: .ui(.chatOpenChanged(true))))).finish()

		#expect(store.windows[id: privateWindow.id]?.isChatOpen == false)
		#expect(store.chats.isEmpty)
	}

	// MARK: - Browser tools

	@Test
	internal func allowRegistersAProfileScopedClientAndRevokingItEndsAccess() async throws {
		let connections: EmbeddedAgentConnections = .init()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.automation.socketPath = "/tmp/ipc.sock"
		state.automationPreferences.isEnabled = true
		state.chats.append(.init(id: profileID, isLoaded: true, browserAccess: .notGranted))
		let revoked: LockIsolated<[UUID]> = .init([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			// Timers such as a turn's silence watch never fire here: these tests don't drive time (DEV-643).
			$0.continuousClock = EndingClock()
			$0.uuid = .incrementing
			$0.embeddedAgentConnections = connections
			$0.automationControl = .init(
				revoke: { id in revoked.withValue { $0.append(id) } },
				credential: { .init(token: "token") }
			)
		}

		await store.send(.chats(.element(id: profileID, action: .ui(.allowBrowserToolsTapped)))).finish()

		let client = try #require(store.automationPreferences.assistantClient(for: profileID))
		expectNoDifference(client.scopes, [.profile(profileID)])
		expectNoDifference(client.capabilities, [.read, .pageContent, .screenshots])
		expectNoDifference(client.approvalPolicy, .alwaysAsk)

		// Only the digest is kept; the credential itself stays in memory for this run.
		expectNoDifference(client.credentialDigest, AutomationCredential(token: "token").digest)
		expectNoDifference(connections[profileID]?.credential.clientID, client.id)
		expectNoDifference(connections[profileID]?.credential.token, "token")
		expectNoDifference(store.chats[id: profileID]?.browserAccess, .granted)

		// Allow again doesn't add a second client.
		await store.send(.chat(.allowBrowserTools(profileID))).finish()
		expectNoDifference(store.automationPreferences.clients.map(\.id), [client.id])

		await store.send(.automation(.ui(.revokeClient(client.id)))).finish()
		#expect(connections[profileID] == nil)
		#expect(store.automationPreferences.assistantClients.isEmpty)
		expectNoDifference(store.chats[id: profileID]?.browserAccess, .notGranted)
		expectNoDifference(revoked.value, [client.id])
	}

	@Test
	internal func eachServerStartIssuesTheAssistantANewCredential() async throws {
		let connections: EmbeddedAgentConnections = .init()
		let clientID = UUID(70)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.automationPreferences = .init(
			isEnabled: true,
			clients: [.init(
				id: clientID,
				name: "Arx Assistant · Default",
				credentialDigest: AutomationCredential(token: "from-last-run").digest,
				scopes: [.profile(profileID)],
				capabilities: [.read],
				grantRevision: UUID(71)
			)],
			assistantClients: [.init(profileID: profileID, clientID: clientID)]
		)
		state.automation.generation = UUID(72)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			// Timers such as a turn's silence watch never fire here: these tests don't drive time (DEV-643).
			$0.continuousClock = EndingClock()
			$0.uuid = .incrementing
			$0.embeddedAgentConnections = connections
			$0.automationControl = .init(credential: { .init(token: "this-run") })
		}

		await store.send(.automation(.event(.started(UUID(72), .success("/tmp/ipc.sock"))))).finish()

		expectNoDifference(
			store.automationPreferences.clients.map(\.credentialDigest),
			[AutomationCredential(token: "this-run").digest]
		)

		// The person's grants stay as they set them.
		expectNoDifference(store.automationPreferences.clients.first?.capabilities, [.read])
		expectNoDifference(connections[profileID]?.credential.token, "this-run")
		expectNoDifference(connections[profileID]?.credential.socket, "/tmp/ipc.sock")
	}
}
