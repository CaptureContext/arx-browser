import AgentClient
import AppUI
import BrowserAutomationClient
import BrowserCore
import ChatFeature
import Foundation
import MainFeature
import OnboardingFeature
import _ComposableArchitecture

/// The app's side of the built-in assistant.
///
/// - Each ordinary profile has one ``ChatFeature`` in ``AppFeature/State/chats``, outside any
///   window, so turns keep running while a panel is hidden or its window closes. Private
///   windows have no chat.
/// - Each profile's assistant uses its own automation client, scoped to that profile and
///   listed in Settings › Agents like any other, so it gets the same checks as outside
///   agents. The person allows it from the panel.
/// - The client's credential is issued again every time the MCP server starts and is kept
///   only in ``EmbeddedAgentConnections``, never in state, actions, files or logs.
/// - At launch every profile's leftover ephemeral transcripts are swept; at quit the
///   browser sweeps them again (``AgentChatLifecycle``).
@CasePathable
public enum AppChatAction: Sendable {
	/// Sent once at launch.
	case launched

	/// Makes sure a profile's chats exist, such as when a window shows the panel.
	case prepare(Profile.ID)

	/// Settings › Assistant appeared; every profile's defaults are listed.
	case settingsAppeared

	/// Allow on the panel's browser tools note.
	case allowBrowserTools(Profile.ID)

	/// A credential for the profile's assistant client was issued and is in memory.
	/// `isNew` registers the client; otherwise only its digest changes.
	case assistantCredentialIssued(Profile.ID, clientID: UUID, digest: String, isNew: Bool)

	/// Pin to This Tab, from a window's panel (DEV-761).
	case pinToTab(windowID: UUID, tabID: BrowserCore.Tab.ID, conversationID: AgentConversation.ID)

	/// Unpin from This Tab: the chat becomes the window's global chat again.
	case unpin(windowID: UUID, tabID: BrowserCore.Tab.ID)

	/// Open in Tab, from a window's panel: the chat, or a new one, becomes a chat tab.
	case openInTab(windowID: UUID, from: ChatSurfaceID, conversationID: AgentConversation.ID?)

	/// Move to Sidebar, from a chat tab: the tab closes and its chat shows in the window's panel.
	case moveToSidebar(windowID: UUID, tabID: BrowserCore.Tab.ID, conversationID: AgentConversation.ID?)
}

@Reducer
internal struct AppChats {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.agentConversations)
	private var conversations

	@Dependency(\.agentProviders)
	private var providers

	@Dependency(\.automationControl)
	private var control

	@Dependency(\.date)
	private var date

	@Dependency(\.embeddedAgentConnections)
	private var connections

	@Dependency(\.linkSharing)
	private var sharing

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.chat.launched) { state in
			guard providers.isEnabled
			else { return .none }

			let profiles: [Profile.ID] = state.workspace.profiles.map(\.id)
			let discard: AgentProviderClient = providers.discardingEverywhere
			let launch: Date = date.now
			return .run { [conversations] _ in

				// A crash can leave ephemeral transcripts and running turns' tool configurations,
				// with the profile's automation credential, behind; nothing about them may stay.
				// Only what predates this launch goes, so a turn started meanwhile keeps its files.
				// Turn folders go first, for every profile: they're local files, while sweeping
				// waits on provider processes.
				for profileID in profiles {
					await withErrorReporting { try await conversations.clearTurns(profileID, launch) }
				}
				for profileID in profiles {
					await withErrorReporting { try await conversations.sweep(profileID, provider: discard) }
				}
			}
		}

		Pullback(\.chat.prepare) { state, profileID in
			state.prepareChat(profileID)
			return .none
		}

		Pullback(\.chat.settingsAppeared) { state in
			for profile in state.workspace.profiles {
				state.prepareChat(profile.id)
			}
			return .none
		}

		// Connect on onboarding's connect-your-agent page makes the provider every profile's
		// assistant. Every profile goes through its chats, created when needed: they read the
		// profile's defaults before saving, so the profile keeps its other settings, and a read
		// already in flight can't put the old provider back.
		Pullback(\.onboarding.delegate.agentConnected) { state, provider in
			guard providers.providers.contains(provider)
			else { return .none }

			for profile in state.workspace.profiles {
				state.prepareChat(profile.id)
			}
			return .merge(
				state.chats.ids.map { profileID in
					.send(.chats(.element(id: profileID, action: .event(.providerConnected(provider)))))
				}
			)
		}

		Pullback(\.main.delegate.chatOpened) { state, profileID in
			state.prepareChat(profileID)
			return .none
		}

		Pullback(\.main.delegate.startChat) { state, value in
			let (prompt, profileID) = value
			return state.startChat(prompt, in: profileID, windowID: state.main.id)
		}

		Pullback(\.windows) { state, action in
			switch action {
			case let .element(_, .delegate(.chatOpened(profileID))):
				state.prepareChat(profileID)
				return .none

			case let .element(windowID, .delegate(.startChat(prompt, profileID))):
				return state.startChat(prompt, in: profileID, windowID: windowID)

			case let .element(windowID, .delegate(.chatPlacement(request))):
				return state.placeChat(request, in: windowID)

			default:
				return .none
			}
		}

		Pullback(\.main.delegate.chatPlacement) { state, request in
			state.placeChat(request, in: state.main.id)
		}

		Pullback(\.chats) { state, action in
			switch action {
			case let .element(_, .delegate(.copy(text))):
				return .run { [sharing] _ in _ = await sharing.copy(text) }

			case let .element(profileID, .delegate(.allowBrowserTools)):
				return .send(.chat(.allowBrowserTools(profileID)))

			case let .element(profileID, .delegate(.surfaceChanged(surfaceID, conversationID))):
				return state.followSurface(surfaceID, to: conversationID, in: profileID)

			case let .element(profileID, .delegate(.titlesChanged)):
				return state.retitleChatTabs(of: profileID)

			case let .element(profileID, .delegate(.suggestionTapped(surfaceID, suggestion))):
				guard let resolved = state.resolveSuggestion(suggestion, on: surfaceID, of: profileID)
				else { return .none }

				return .send(.chats(.element(
					id: profileID,
					action: .surfaces(.element(id: surfaceID, action: .event(.suggestionResolved(resolved))))
				)))

			default:
				return .none
			}
		}

		ChatPlacements()

		Pullback(\.chat.allowBrowserTools) { state, profileID in
			guard
				!state.automation.isUnattended,
				state.workspace.profiles[id: profileID] != nil
			else { return .none }

			state.pendingAssistantProfiles.insert(profileID)
			guard state.automation.socketPath != nil else {
				// The server issues credentials only while it runs; they're issued once it starts.
				return state.automationPreferences.isEnabled ? .none : .send(.automation(.ui(.enabled(true))))
			}

			return issueAssistantCredentials(&state)
		}

		Pullback(\.automation.event.started) { state, value in
			let (generation, result) = value
			guard
				generation == state.automation.generation,
				case .success = result
			else { return .none }

			// Credentials last one run, so each start issues new ones for every assistant client.
			return issueAssistantCredentials(&state)
		}

		Pullback(\.automation.ui.enabled) { state, _ in

			// Turning the server off or on again ends every issued credential.
			connections.removeAll()
			return state.reportBrowserAccess(.notGranted, to: Array(state.chats.ids))
		}

		Pullback(\.chat.assistantCredentialIssued) { state, value in
			let (profileID, clientID, digest, isNew) = value
			state.pendingAssistantProfiles.remove(profileID)
			var preferences: AutomationPreferences = state.automationPreferences
			if isNew {
				guard
					preferences.clients.count < 32,
					let profile = state.workspace.profiles[id: profileID]
				else {
					connections.remove(profileID)
					return .none
				}

				preferences.clients.append(.init(
					id: clientID,
					name: String(String.localized(.appUI.chat.assistantClientName(profile.name)).prefix(80)),
					credentialDigest: digest,
					scopes: [.profile(profileID)],
					capabilities: AssistantAutomation.capabilities,
					approvalPolicy: .alwaysAsk,
					allowsFocusedTab: true,
					grantRevision: uuid()
				))
				preferences.assistantClients.removeAll { $0.profileID == profileID }
				preferences.assistantClients.append(.init(profileID: profileID, clientID: clientID))
			} else {
				guard let index = preferences.clients.firstIndex(where: { $0.id == clientID }) else {
					connections.remove(profileID)
					return .none
				}

				preferences.clients[index].credentialDigest = digest
			}
			guard (try? preferences.validate()) != nil else {
				connections.remove(profileID)
				return .none
			}

			state.automationPreferences = preferences
			return .merge(
				state.saveWorkspace(),
				state.reportBrowserAccess(.granted, to: [profileID])
			)
		}

		Pullback(\.automation.ui.revokeClient) { state, clientID in
			let revoked: [Profile.ID] = state.automationPreferences.assistantClients
				.filter { $0.clientID == clientID }
				.map(\.profileID)
			guard !revoked.isEmpty
			else { return .none }

			state.automationPreferences.assistantClients.removeAll { $0.clientID == clientID }
			for profileID in revoked {
				connections.remove(profileID)
			}
			return .merge(
				state.saveWorkspace(),
				state.reportBrowserAccess(.notGranted, to: revoked)
			)
		}
	}

	/// Issues a credential for every registered assistant client that has none in memory,
	/// and registers clients for the profiles waiting on Allow.
	private func issueAssistantCredentials(_ state: inout State) -> Effect<Action> {
		guard let socket = state.automation.socketPath
		else { return .none }

		let profiles: Set<Profile.ID> = Set(state.workspace.profiles.map(\.id))
		var plan: [(profileID: Profile.ID, clientID: UUID, isNew: Bool)] = []
		for entry in state.automationPreferences.assistantClients where profiles.contains(entry.profileID) {
			guard
				state.automationPreferences.clients.contains(where: { $0.id == entry.clientID }),
				connections[entry.profileID] == nil
			else { continue }

			plan.append((entry.profileID, entry.clientID, false))
		}
		for profileID in state.pendingAssistantProfiles.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
			guard state.automationPreferences.assistantClient(for: profileID) == nil else {
				if connections[profileID] != nil {
					state.pendingAssistantProfiles.remove(profileID)
				}
				continue
			}

			plan.append((profileID, uuid(), true))
		}
		guard !plan.isEmpty
		else { return state.reportBrowserAccess(.granted, to: Array(state.chats.ids).filter { connections[$0] != nil }) }

		let helper: URL = AssistantAutomation.helper
		return .run { [plan, control, connections] send in
			for item in plan {
				do {
					let credential: AutomationCredential = try control.credential()
					connections.set(
						.init(
							helper: helper,
							credential: .init(socket: socket, clientID: item.clientID, token: credential.token)
						),
						for: item.profileID
					)
					await send(.chat(.assistantCredentialIssued(
						item.profileID,
						clientID: item.clientID,
						digest: credential.digest,
						isNew: item.isNew
					)))
				} catch {
					reportIssue("The assistant's automation credential couldn't be issued.")
				}
			}
		}
	}
}

/// What a profile's assistant client may do when the person allows it. They can widen or
/// narrow it in Settings › Agents like any other client.
internal enum AssistantAutomation {
	internal static let capabilities: Set<AutomationCapability> = [.read, .pageContent, .screenshots]

	internal static var helper: URL {
		Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ArxMCP")
	}
}

extension AppFeature.State {
	/// Adds the profile's chats when they don't exist yet. Private profiles never get one.
	internal mutating func prepareChat(_ profileID: Profile.ID) {
		guard
			chats[id: profileID] == nil,
			workspace.profiles[id: profileID] != nil
		else { return }

		chats.append(.init(id: profileID))
	}

	/// A picked suggestion about the page its surface stands for when it's picked (DEV-835): a
	/// window's panel asks about the focused pane's tab, whichever pane the panel rendered for,
	/// and a chat pinned to a tab keeps asking about that tab. `nil` drops the request: the page
	/// it was about is gone, the focused one offers no such suggestion, or the page belongs to
	/// another profile than the chat's: profiles never share pages, even while a window switches.
	internal func resolveSuggestion(
		_ suggestion: ChatSuggestion,
		on surfaceID: ChatSurfaceID,
		of profileID: Profile.ID
	) -> ChatSuggestion? {
		switch surfaceID {
		case let .window(windowID):
			guard
				let window = window(windowID),
				let tab = window.focusedPageTab,
				tab.profileID == profileID
			else { return nil }

			return suggestion.retargeted(to: window.chatAttachment(tab))

		case let .pinned(tabID):
			let id: BrowserCore.Tab.ID = .init(rawValue: tabID)
			let windows: [MainFeature.State] = [main] + windows.elements
			let pinned = workspace.tabs[id: id]
			?? windows.lazy.compactMap({ $0.sidebar.organization.tabs[id: id] }).first
			guard let tab = pinned, tab.profileID == profileID else { return nil }

			let owner: MainFeature.State? = windows.first { window in
				window.viewer.panes.contains { $0.item.tab?.id == id }
			}
			return suggestion.retargeted(to: (owner ?? main).chatAttachment(tab))

		case .tab, .standalone:
			return suggestion
		}
	}

	/// Text + Tab in a window's command bar starts a new chat in the panel the window shows: on a
	/// pinned tab that's the tab's panel, which then pins the new chat.
	fileprivate mutating func startChat(
		_ prompt: String,
		in profileID: Profile.ID,
		windowID: UUID
	) -> Effect<AppFeature.Action> {
		prepareChat(profileID)
		guard
			chats[id: profileID] != nil,
			let window = window(windowID)
		else { return .none }

		return .send(.chats(.element(id: profileID, action: .surfaces(.element(
			id: window.chatSurfaceID,
			action: .ui(.start(prompt))
		)))))
	}

	fileprivate func reportBrowserAccess(
		_ access: ChatBrowserAccess,
		to profiles: [Profile.ID]
	) -> Effect<AppFeature.Action> {
		.merge(
			profiles
				.filter { chats[id: $0] != nil }
				.map { .send(.chats(.element(id: $0, action: .event(.browserAccessChecked(access))))) }
		)
	}
}

// MARK: - Connections

/// Each profile's assistant connection for this run. The credential lives here only, in
/// memory, and reaches nothing but the MCP helper's environment.
public final class EmbeddedAgentConnections: Sendable {
	private let storage: LockIsolated<[Profile.ID: AgentBrowserAccess.Connection]>

	public init() {
		self.storage = .init([:])
	}

	public subscript(_ profileID: Profile.ID) -> AgentBrowserAccess.Connection? {
		storage.value[profileID]
	}

	public func set(
		_ connection: AgentBrowserAccess.Connection,
		for profileID: Profile.ID
	) {
		storage.withValue { $0[profileID] = connection }
	}

	public func remove(_ profileID: Profile.ID) {
		storage.withValue { $0[profileID] = nil }
	}

	public func removeAll() {
		storage.withValue { $0.removeAll() }
	}
}

extension EmbeddedAgentConnections: DependencyKey {
	/// The app installs one shared instance with `prepareDependencies`, together with
	/// ``AgentBrowserAccess/embedded(_:)``, so both read the same connections.
	public static var liveValue: EmbeddedAgentConnections { .init() }
	public static var testValue: EmbeddedAgentConnections { .init() }
}

extension DependencyValues {
	public var embeddedAgentConnections: EmbeddedAgentConnections {
		get { self[EmbeddedAgentConnections.self] }
		set { self[EmbeddedAgentConnections.self] = newValue }
	}
}

extension AgentBrowserAccess {
	/// The profile's assistant connection, when the person allowed it and the server runs.
	public static func embedded(_ connections: EmbeddedAgentConnections) -> Self {
		.init { profileID in
			guard let connection = connections[profileID]
			else { throw Failure.notGranted }

			return connection
		}
	}
}

// MARK: - Lifecycle

/// Ends every ephemeral chat's provider transcript when the browser quits.
public enum AgentChatLifecycle {
	public static func sweep(_ profiles: [Profile.ID]) async {
		@Dependency(\.agentConversations)
		var conversations

		@Dependency(\.agentProviders)
		var providers

		guard providers.isEnabled
		else { return }

		let discard: AgentProviderClient = providers.discardingEverywhere
		for profileID in profiles {
			await withErrorReporting { try await conversations.sweep(profileID, provider: discard) }
		}
	}
}

// MARK: - Window panels

extension MainFeature.State {
	/// The current tab, the profile's other tabs and the space's folders, for the + picker.
	internal var chatAttachables: [ChatAttachable] {
		let organization: BrowserOrganization = sidebar.organization
		let profileID: Profile.ID = sidebar.space.profileID
		let current: BrowserCore.Tab? = focusedPageTab
		let attachment: (BrowserCore.Tab) -> AgentContextAttachment.Tab = chatAttachment

		var result: [ChatAttachable] = []
		if let current {
			result.append(.init(
				id: ChatAttachable.currentID,
				title: String.localized(.appUI.chat.attachCurrent) + " · " + attachment(current).title,
				symbol: "macwindow",
				tabs: [attachment(current)]
			))
		}
		for folder in organization.folders where folder.spaceID == sidebar.spaceID {
			let tabs: [AgentContextAttachment.Tab] = organization.tabs(in: folder.id, includingDescendants: true)
				.compactMap { organization.tabs[id: $0] }
				.map(attachment)
			guard !tabs.isEmpty
			else { continue }

			result.append(.init(id: folder.id.rawValue.uuidString, title: folder.name, symbol: "folder", tabs: tabs))
		}
		for tab in organization.tabs where tab.profileID == profileID && tab.id != current?.id {
			result.append(.init(
				id: tab.id.rawValue.uuidString,
				title: tab.displayTitle,
				symbol: "globe",
				tabs: [attachment(tab)]
			))
		}
		return result
	}

	/// A tab as the chat attaches it: what its pane shows now when a pane shows it, otherwise
	/// what it last showed.
	internal func chatAttachment(_ tab: BrowserCore.Tab) -> AgentContextAttachment.Tab {
		let item = viewer.panes.first { $0.item.tab?.id == tab.id }?.item
		let url: URL = item?.navigation.url ?? tab.restoration.url
		let title: String = item.map(\.navigation.title).flatMap { $0.isEmpty ? nil : $0 } ?? tab.displayTitle
		return .init(title: title, url: url.absoluteString)
	}
}
