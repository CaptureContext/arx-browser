import AgentClient
import AppUI
import BrowserCore
import Foundation
import _ComposableArchitecture

/// One profile's chats with the embedded assistant: the panel's screens, the composer,
/// running turns, retention and the profile's defaults.
///
/// The app keeps one per profile, outside any window, so a turn keeps running while the
/// panel is hidden or its window closes. Turns stream through ``AgentProviderClient`` in an
/// effect and reach the store in coalesced batches, at most about ten a second.
@Reducer
public struct ChatFeature {
	@ObservableState
	public struct State: Equatable, Identifiable {
		public let id: Profile.ID

		/// Whether the profile's settings and kept chats were read.
		public var isLoaded: Bool
		public var isLoading: Bool

		/// Text + Tab that arrived before the profile's defaults were read. It's sent once they are,
		/// so the chat starts with the profile's provider, model and retention.
		public var pendingPrompt: String?

		/// A provider connected from onboarding before the profile's defaults were read.
		/// It replaces the read provider once they are, so a load already in flight can't undo it.
		public var pendingProvider: AgentProvider?

		/// The profile's defaults for new chats and its retention preference.
		public var settings: AgentProfileSettings

		/// Kept chats and the ephemeral chats still open, newest first.
		public var conversations: IdentifiedArrayOf<AgentConversation>

		/// Every place the profile's chats show (DEV-761): each window's panel, a panel on a tab
		/// a chat is pinned to, and each chat tab. Each keeps its own chat, screen and composer.
		public var surfaces: [ChatSurfaceID: ChatSurface]

		/// The surface the surface-level properties below read and write: the one an action
		/// last came from (``Action/surface(_:_:)``), or ``ChatSurfaceID/standalone``.
		///
		/// It's a cursor, not something a view shows, so it isn't observed (DEV-789).
		/// ``subscript(surface:)`` sets it on a copy each time a view reads its surface, and the
		/// copy shares the state's observation registrar: if setting it notified, every view
		/// scoped to a surface other than the last active one would invalidate itself on each
		/// read and render forever. Views follow their surface through ``surfaces``.
		@ObservationStateIgnored
		public var activeSurfaceID: ChatSurfaceID

		public var turns: [AgentConversation.ID: ChatTurn]
		public var failures: [AgentConversation.ID: ChatFailure]

		/// Chats that got an answer while the person looked elsewhere.
		public var unreadIDs: Set<AgentConversation.ID>

		public var accounts: [AgentProvider: AgentAccount]
		public var models: [AgentProvider: [AgentModel]]
		public var browserAccess: ChatBrowserAccess

		/// What plain Return does in the composer, from Settings › Assistant (DEV-798).
		@Shared(.chatReturnKey)
		public var returnKey: ChatReturnKeyBehavior

		public init(
			id: Profile.ID,
			isLoaded: Bool = false,
			settings: AgentProfileSettings = .init(provider: .claude),
			conversations: IdentifiedArrayOf<AgentConversation> = [],
			selectedID: AgentConversation.ID? = nil,
			screen: Screen = .conversation,
			draft: String = "",
			attachments: [AgentContextAttachment] = [],
			turns: [AgentConversation.ID: ChatTurn] = [:],
			failures: [AgentConversation.ID: ChatFailure] = [:],
			unreadIDs: Set<AgentConversation.ID> = [],
			accounts: [AgentProvider: AgentAccount] = [:],
			models: [AgentProvider: [AgentModel]] = [:],
			browserAccess: ChatBrowserAccess = .unknown
		) {
			self.id = id
			self.isLoaded = isLoaded
			self.isLoading = false
			self.pendingPrompt = nil
			self.pendingProvider = nil
			self.settings = settings
			self.conversations = conversations
			self.surfaces = [
				.standalone: .init(
					selectedID: selectedID,
					screen: screen,
					draft: draft,
					attachments: attachments,
					newChatProvider: settings.provider,
					newChatModelID: settings.modelID
				),
			]
			self.activeSurfaceID = .standalone
			self.turns = turns
			self.failures = failures
			self.unreadIDs = unreadIDs
			self.accounts = accounts
			self.models = models
			self.browserAccess = browserAccess
		}

		/// The active surface. Reading one that doesn't exist yet gives a new chat with the
		/// profile's defaults; writing it adds it.
		public var surface: ChatSurface {
			get {
				surfaces[activeSurfaceID] ?? .init(
					newChatProvider: settings.provider,
					newChatModelID: settings.modelID
				)
			}
			set { surfaces[activeSurfaceID] = newValue }
		}

		/// This state as `id` sees it: its surface becomes the active one. Views scope to it,
		/// and the actions they send arrive wrapped in ``Action/surface(_:_:)``.
		public subscript(surface id: ChatSurfaceID) -> Self {
			get {
				var state: Self = self
				state.activeSurfaceID = id
				return state
			}
			set {
				var state: Self = newValue
				state.activeSurfaceID = activeSurfaceID
				self = state
			}
		}

		/// The chat the panel shows. `nil` is a new, empty chat.
		public var selectedID: AgentConversation.ID? {
			get { surface.selectedID }
			set { surface.selectedID = newValue }
		}

		public var screen: Screen {
			get { surface.screen }
			set { surface.screen = newValue }
		}

		/// The composer's text and the context attached to it with the + picker.
		public var draft: String {
			get { surface.draft }
			set { surface.draft = newValue }
		}

		public var attachments: [AgentContextAttachment] {
			get { surface.attachments }
			set { surface.attachments = newValue }
		}

		public var attachmentIssue: ChatAttachmentIssue? {
			get { surface.attachmentIssue }
			set { surface.attachmentIssue = newValue }
		}

		/// Why the attachments can't go to the chat's provider, if they can't.
		public var attachmentProblem: ChatAttachmentIssue? {
			provider.attachmentLimits.problem(with: attachments).map { .limit($0, provider: provider) }
		}

		/// The provider and model a new chat starts with, from Settings until changed.
		public var newChatProvider: AgentProvider {
			get { surface.newChatProvider }
			set { surface.newChatProvider = newValue }
		}

		public var newChatModelID: String? {
			get { surface.newChatModelID }
			set { surface.newChatModelID = newValue }
		}

		public var chatsQuery: String {
			get { surface.chatsQuery }
			set { surface.chatsQuery = newValue }
		}

		public var showsUnreadOnly: Bool {
			get { surface.showsUnreadOnly }
			set { surface.showsUnreadOnly = newValue }
		}

		public var showsArchived: Bool {
			get { surface.showsArchived }
			set { surface.showsArchived = newValue }
		}

		/// Raised to move focus into the composer.
		public var focusRequest: Int {
			get { surface.focusRequest }
			set { surface.focusRequest = newValue }
		}

		/// Whether any surface shows this chat's transcript now.
		public func isShown(_ id: AgentConversation.ID) -> Bool {
			surfaces.values.contains { $0.selectedID == id && $0.screen == .conversation }
		}

		/// Applies `body` to every surface, such as when a chat ends or the defaults change.
		internal mutating func updateSurfaces(_ body: (inout ChatSurface) -> Void) {
			for (id, value) in surfaces {
				var surface: ChatSurface = value
				body(&surface)
				surfaces[id] = surface
			}
		}

		public var selected: AgentConversation? {
			selectedID.flatMap { conversations[id: $0] }
		}

		/// The provider and model the panel shows: the selected chat's, or a new chat's.
		public var provider: AgentProvider {
			selected?.provider ?? newChatProvider
		}

		public var modelID: String? {
			selected.map(\.modelID) ?? newChatModelID
		}

		public var turn: ChatTurn? {
			selectedID.flatMap { turns[$0] }
		}

		public var failure: ChatFailure? {
			selectedID.flatMap { failures[$0] }
		}

		public var isRunning: Bool {
			turn != nil
		}

		public var canSend: Bool {
			!isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		}

		/// A chat's provider can change only before its first turn, because the provider's
		/// handle can't move to another provider.
		public var canChangeProvider: Bool {
			selected?.resumeToken == nil && !isRunning
		}

		/// What Your Chats lists for the current search and filters.
		public var listedConversations: [AgentConversation] {
			let query: String = chatsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
			return conversations
				.filter { ($0.archivedAt != nil) == showsArchived }
				.filter { !showsUnreadOnly || unreadIDs.contains($0.id) }
				.filter { conversation in
					guard !query.isEmpty
					else { return true }

					return conversation.title.localizedCaseInsensitiveContains(query)
					|| (conversation.lastAnswer?.localizedCaseInsensitiveContains(query) ?? false)
				}
				.sorted { $0.updatedAt > $1.updatedAt }
		}
	}

	public enum Screen: Equatable, Sendable {
		/// The selected chat, or a new one.
		case conversation

		/// Your Chats: search and cards.
		case chats

		/// Chat info, opened from the title tile.
		case info
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		/// An action from one surface's view: that surface becomes the active one, then the
		/// action runs as usual (DEV-761).
		indirect case surfaces(IdentifiedAction<ChatSurfaceID, Action>)

		@CasePathable
		public enum UI: Sendable {
			/// The panel appeared. Reads the profile's chats the first time and checks the connection.
			case task

			/// Text + Tab in the command bar: a new chat that sends the text at once.
			case start(String)

			case draftChanged(String)

			/// Done, or ⌘↩.
			case sendTapped
			case stopTapped

			/// Sends the prompt that failed again.
			case retryTapped
			case dismissFailureTapped

			case newChatTapped
			case historyTapped
			case infoTapped
			case backTapped
			case chatSelected(AgentConversation.ID)

			/// The app places a chat on this surface (DEV-761): a pin's or a chat tab's chat, or
			/// a new one (`nil`). Unlike a pick from Your Chats, the chat may not be read yet.
			case show(AgentConversation.ID?)

			case copyAnswerTapped
			case pinTapped
			case renamed(String)
			case archiveTapped
			case deleteTapped

			case providerSelected(AgentProvider)
			case modelSelected(String?)

			case attached(AgentContextAttachment)

			/// A new chat's suggested prompt: attaches its tab and sends it. A surface the app
			/// places asks it for the page first, through ``Delegate/suggestionTapped(_:_:)``.
			case suggestionTapped(ChatSuggestion)
			case detached(Int)

			/// Files dropped on the chat or picked with Files… (DEV-798).
			case filesAdded([URL])

			/// An image pasted into the composer, or a page capture sent to the chat.
			case imageAdded(Data, name: String, pageURL: String?)

			case attachmentIssueDismissed

			case chatsQueryChanged(String)
			case unreadOnlyToggled
			case archivedToggled

			/// Allow on the browser tools note.
			case allowBrowserToolsTapped

			/// Settings: the defaults new chats start with, and the retention preference.
			case defaultProviderChanged(AgentProvider)
			case defaultModelChanged(String?)
			case retentionChanged(AgentRetention)
		}

		@CasePathable
		public enum Event: Sendable {
			case loaded(AgentProfileSettings?, [AgentConversation])

			/// Connect on onboarding's connect-your-agent page: the provider becomes the profile's
			/// default, now or as soon as its defaults are read.
			case providerConnected(AgentProvider)
			case connectionsChecked([AgentAccount], [AgentProvider: [AgentModel]])
			case browserAccessChecked(ChatBrowserAccess)
			case turnStarted(AgentConversation.ID, ChatBrowserAccess)
			case turnEvents(AgentConversation.ID, [AgentEvent])
			case turnFinished(AgentConversation.ID)
			case turnFailed(AgentConversation.ID, AgentFailure)

			/// The provider sent nothing for ``turnSilenceLimit`` while no browser tool ran.
			case turnTimedOut(AgentConversation.ID)
			case expiryFired(AgentConversation.ID)

			/// Files and images read for a surface's composer.
			case attachmentsLoaded(ChatSurfaceID, [ChatAttachmentLoad])

			/// The app's answer to ``Delegate/suggestionTapped(_:_:)``: the suggestion about the
			/// page the surface stands for now. Attaches that page and sends the prompt.
			case suggestionResolved(ChatSuggestion)
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// The parent puts the answer on the pasteboard.
			case copy(String)

			/// The parent registers the profile's assistant client, turning on the MCP server
			/// when it's off, and reports back through ``Event/browserAccessChecked(_:)``.
			case allowBrowserTools

			/// A surface moved to another chat, or to a new one (`nil`). The parent keeps a pin
			/// or a chat tab following its chat.
			case surfaceChanged(ChatSurfaceID, AgentConversation.ID?)

			/// A chat's title changed, so chat tabs showing it can follow.
			case titlesChanged

			/// A suggestion was picked on a surface the app places. The suggestion was built when
			/// the panel last rendered; the app retargets it to the page the surface stands for
			/// now (a window's focused pane, or a pinned chat's own tab) and answers with
			/// ``Event/suggestionResolved(_:)`` (DEV-835).
			case suggestionTapped(ChatSurfaceID, ChatSuggestion)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	/// Process-wide, so each chat's turn and timer are keyed by its ID.
	internal struct TurnID: Hashable, Sendable {
		var id: AgentConversation.ID
	}

	internal struct ExpiryID: Hashable, Sendable {
		var id: AgentConversation.ID
	}

	internal struct TurnWatchID: Hashable, Sendable {
		var id: AgentConversation.ID
	}

	/// How long a running turn may stay silent before it fails with
	/// ``AgentFailure/timedOut``. A browser tool that's still running, such as one waiting for the
	/// person's approval, doesn't count as silence.
	public static let turnSilenceLimit: Duration = .seconds(180)

	@Dependency(\.agentBrowserAccess)
	private var browserAccess

	@Dependency(\.agentConversations)
	private var store

	@Dependency(\.chatSaves)
	private var saves

	@Dependency(\.agentProviders)
	private var providers

	@Dependency(\.chatAttachmentLoader)
	private var attachmentLoader

	@Dependency(\.continuousClock)
	private var clock

	@Dependency(\.date.now)
	private var now

	@Dependency(\.uuid)
	private var uuid

	public init() {}

	public var body: some ReducerOf<Self> {
		surfaceRouting
		loading
		composing
		turns
		chatActions
		listing
		settings
	}

	// MARK: - Surfaces

	private var surfaceRouting: some ReducerOf<Self> {
		Reduce { state, action in
			guard case let .surfaces(.element(id, child)) = action
			else { return .none }

			// Surfaces don't nest.
			if case .surfaces = child { return .none }
			state.activeSurfaceID = id
			if state.surfaces[id] == nil {
				state.surface = state.surface
			}
			let selection: AgentConversation.ID? = state.selectedID
			let titles: [String] = state.conversations.map(\.title)
			let effect: Effect<Action> = _reduce(into: &state, action: child)
			var delegates: [Effect<Action>] = []
			if state.selectedID != selection {
				delegates.append(.send(.delegate(.surfaceChanged(id, state.selectedID))))
			}
			if state.conversations.map(\.title) != titles {
				delegates.append(.send(.delegate(.titlesChanged)))
			}
			return .merge([effect] + delegates)
		}
	}

	// MARK: - Loading

	private var loading: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.task) { state in
				.merge(
					load(&state),
					checkConnections(state.id)
				)
			}

			Pullback(\.event.loaded) { state, value in
				let (settings, kept) = value
				state.isLoaded = true
				state.isLoading = false
				if let settings {
					state.settings = settings
					state.updateSurfaces { surface in
						guard surface.selectedID == nil
						else { return }

						surface.newChatProvider = settings.provider
						surface.newChatModelID = settings.modelID
					}
				} else {
					let provider: AgentProvider = providers.defaultProvider
					state.settings.provider = provider
					state.updateSurfaces { $0.newChatProvider = provider }
				}
				for conversation in kept where conversation.profileID == state.id {
					guard state.conversations[id: conversation.id] == nil
					else { continue }

					state.conversations.append(conversation)
				}
				state.conversations.sort { $0.updatedAt > $1.updatedAt }
				var saving: Effect<Action> = .none
				if let provider = state.pendingProvider {
					state.pendingProvider = nil
					saving = changeProvider(to: provider, &state)
				}
				guard let prompt = state.pendingPrompt
				else { return saving }

				state.pendingPrompt = nil
				return .merge(saving, start(prompt, state: &state))
			}

			Pullback(\.event.providerConnected) { state, provider in
				guard providers.providers.contains(provider)
				else { return .none }

				guard state.isLoaded else {
					// A chat nobody has opened yet reads its defaults now, so the choice is saved.
					state.pendingProvider = provider
					return load(&state)
				}

				return changeProvider(to: provider, &state)
			}

			Pullback(\.event.connectionsChecked) { state, value in
				let (accounts, models) = value
				for account in accounts {
					state.accounts[account.provider] = account
				}
				state.models.merge(models) { $1 }
				return .none
			}

			Pullback(\.event.browserAccessChecked) { state, access in
				state.browserAccess = access
				return .none
			}
		}
	}

	/// Reads the profile's settings and kept chats once.
	private func load(_ state: inout State) -> Effect<Action> {
		guard !state.isLoaded, !state.isLoading
		else { return .none }

		state.isLoading = true
		let profileID: Profile.ID = state.id
		return .run { [store] send in
			let settings: AgentProfileSettings? = await withErrorReporting {
				try await store.settings(profileID)
			} ?? nil
			let kept: [AgentConversation] = await withErrorReporting {
				try await store.list(profileID)
			} ?? []
			await send(.event(.loaded(settings, kept)))
		}
	}

	private func checkConnections(_ profileID: Profile.ID) -> Effect<Action> {
		.run { [providers, browserAccess] send in
			var accounts: [AgentAccount] = []
			var models: [AgentProvider: [AgentModel]] = [:]
			for client in providers.clients {
				accounts.append(await client.account())
				models[client.provider] = await client.models()
			}
			await send(.event(.connectionsChecked(accounts, models)))
			await send(.event(.browserAccessChecked(await Self.connect(browserAccess, profileID).access)))
		}
	}

	private static func connect(
		_ client: AgentBrowserAccess,
		_ profileID: Profile.ID
	) async -> (access: ChatBrowserAccess, connection: AgentBrowserAccess.Connection?) {
		do {
			return (.granted, try await client.connection(profileID))
		} catch AgentBrowserAccess.Failure.notGranted {
			return (.notGranted, nil)
		} catch {
			return (.unavailable, nil)
		}
	}

	// MARK: - Composing

	private var composing: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.start) { state, text in
				let prompt: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
				guard !prompt.isEmpty
				else { return .none }

				guard state.isLoaded else {
					state.pendingPrompt = prompt
					state.screen = .conversation
					return .merge(load(&state), checkConnections(state.id))
				}

				return start(prompt, state: &state)
			}

			Pullback(\.ui.draftChanged) { state, text in
				state.draft = text
				return .none
			}

			Pullback(\.ui.sendTapped) { state in
				send(&state)
			}

			Pullback(\.ui.retryTapped) { state in
				guard
					let id = state.selectedID,
					state.turns[id] == nil,
					let failure = state.failures.removeValue(forKey: id)
				else { return .none }

				return retry(failure, in: id, state: &state)
			}

			Pullback(\.ui.dismissFailureTapped) { state in
				guard let id = state.selectedID
				else { return .none }

				state.failures[id] = nil
				return .none
			}

			Pullback(\.ui.attached) { state, attachment in
				guard !state.attachments.contains(attachment)
				else { return .none }

				state.attachments.append(attachment)
				state.focusRequest += 1
				return .none
			}

			Pullback(\.ui.suggestionTapped) { state, suggestion in
				guard state.selected == nil, !state.isRunning
				else { return .none }

				// Only a store with no placement has no app to ask for the page.
				guard state.activeSurfaceID == .standalone
				else { return .send(.delegate(.suggestionTapped(state.activeSurfaceID, suggestion))) }

				return suggest(suggestion, state: &state)
			}

			Pullback(\.event.suggestionResolved) { state, suggestion in
				guard state.selected == nil, !state.isRunning
				else { return .none }

				return suggest(suggestion, state: &state)
			}

			Pullback(\.ui.detached) { state, index in
				guard state.attachments.indices.contains(index)
				else { return .none }

				state.attachments.remove(at: index)
				state.attachmentIssue = nil
				return .none
			}

			Pullback(\.ui.filesAdded) { state, urls in
				guard !urls.isEmpty
				else { return .none }

				let surfaceID: ChatSurfaceID = state.activeSurfaceID
				return .run { [attachmentLoader] send in
					await send(.event(.attachmentsLoaded(surfaceID, await attachmentLoader.files(urls))))
				}
			}

			Pullback(\.ui.imageAdded) { state, value in
				let (data, name, pageURL) = value
				let surfaceID: ChatSurfaceID = state.activeSurfaceID
				return .run { [attachmentLoader] send in
					await send(.event(.attachmentsLoaded(surfaceID, [await attachmentLoader.image(data, name, pageURL)])))
				}
			}

			Pullback(\.event.attachmentsLoaded) { state, value in
				let (surfaceID, loads) = value
				state.activeSurfaceID = surfaceID
				state.attachmentIssue = nil
				for load in loads {
					switch load {
					case var .loaded(file):
						file.id = uuid()
						let attachments: [AgentContextAttachment] = state.attachments + [.file(file)]
						if let problem = state.provider.attachmentLimits.problem(with: attachments) {
							state.attachmentIssue = .limit(problem, provider: state.provider)
						} else {
							state.attachments = attachments
						}

					case let .failed(issue):
						state.attachmentIssue = issue
					}
				}
				state.focusRequest += 1
				return .none
			}

			Pullback(\.ui.attachmentIssueDismissed) { state in
				state.attachmentIssue = nil
				return .none
			}

			Pullback(\.ui.providerSelected) { state, provider in
				guard state.canChangeProvider, providers.providers.contains(provider)
				else { return .none }

				let modelID: String? = provider == state.settings.provider ? state.settings.modelID : nil
				guard let id = state.selectedID else {
					state.newChatProvider = provider
					state.newChatModelID = modelID
					return .none
				}

				state.conversations[id: id]?.provider = provider
				state.conversations[id: id]?.modelID = modelID
				return save(state.conversations[id: id])
			}

			Pullback(\.ui.modelSelected) { state, modelID in
				guard let id = state.selectedID else {
					state.newChatModelID = modelID
					return .none
				}

				state.conversations[id: id]?.modelID = modelID
				return save(state.conversations[id: id])
			}
		}
	}

	/// A new chat that sends `prompt` at once. A draft the person was writing is replaced,
	/// as the command bar is where they typed this time.
	private func start(
		_ prompt: String,
		state: inout State
	) -> Effect<Action> {
		state.selectedID = nil
		state.screen = .conversation
		state.newChatProvider = state.settings.provider
		state.newChatModelID = state.settings.modelID
		state.draft = prompt
		state.attachments = []
		return send(&state)
	}

	/// A suggestion's prompt with its page attached, sent at once.
	private func suggest(
		_ suggestion: ChatSuggestion,
		state: inout State
	) -> Effect<Action> {
		state.draft = suggestion.prompt
		let attachment: AgentContextAttachment = .tabs([suggestion.tab])
		if !state.attachments.contains(attachment) {
			state.attachments.append(attachment)
		}
		return send(&state)
	}

	/// Sends the composer's text in the selected chat, or in a new one.
	private func send(_ state: inout State) -> Effect<Action> {
		let prompt: String = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !prompt.isEmpty, !state.isRunning
		else { return .none }

		// The provider may have changed since the files were attached.
		if let problem = state.attachmentProblem {
			state.attachmentIssue = problem
			return .none
		}

		let date: Date = now
		let conversationID: AgentConversation.ID
		if let id = state.selectedID, state.conversations[id: id] != nil {
			conversationID = id
		} else {
			conversationID = .init(rawValue: uuid())
			state.conversations.insert(
				.init(
					id: conversationID,
					profileID: state.id,
					provider: state.newChatProvider,
					modelID: state.newChatModelID,
					title: AgentConversation.title(from: prompt),
					createdAt: date,
					updatedAt: date,
					retention: state.settings.retention
				),
				at: 0
			)
			state.selectedID = conversationID
		}

		let attachments: [AgentContextAttachment] = state.attachments
		let turn: ChatTurn = .init(
			prompt: prompt,
			attachments: attachments,
			promptID: uuid(),
			replyID: uuid()
		)
		state.conversations[id: conversationID]?.messages.append(
			// The transcript keeps a file's name and preview; only the turn carries its bytes.
			.init(id: turn.promptID, role: .user, text: prompt, attachments: attachments.map(\.withoutData), createdAt: date)
		)
		state.conversations[id: conversationID]?.messages.append(
			.init(id: turn.replyID, role: .assistant, text: "", createdAt: date)
		)
		state.conversations[id: conversationID]?.updatedAt = date
		state.turns[conversationID] = turn
		state.failures[conversationID] = nil
		state.draft = ""
		state.attachments = []
		state.attachmentIssue = nil
		state.screen = .conversation

		return start(turn, in: conversationID, state: state)
	}

	/// Sends a failed prompt again. The prompt is still in the transcript, so only a new reply
	/// is added under it.
	private func retry(
		_ failure: ChatFailure,
		in id: AgentConversation.ID,
		state: inout State
	) -> Effect<Action> {
		guard state.conversations[id: id] != nil
		else { return .none }

		let date: Date = now
		let turn: ChatTurn = .init(
			prompt: failure.prompt,
			attachments: failure.attachments,
			promptID: failure.promptID,
			replyID: uuid()
		)
		if state.conversations[id: id]?.messages.contains(where: { $0.id == failure.promptID }) == false {
			// The prompt is gone from the transcript, so it goes back with this try.
			state.conversations[id: id]?.messages.append(
				.init(
					id: failure.promptID,
					role: .user,
					text: failure.prompt,
					attachments: failure.attachments.map(\.withoutData),
					createdAt: date
				)
			)
		}
		state.conversations[id: id]?.messages.append(
			.init(id: turn.replyID, role: .assistant, text: "", createdAt: date)
		)
		state.conversations[id: id]?.updatedAt = date
		state.turns[id] = turn
		return start(turn, in: id, state: state)
	}

	/// Saves the chat with the person's prompt in it, then runs the turn: the prompt is kept
	/// even if the provider never answers or Arx quits (DEV-643).
	private func start(
		_ turn: ChatTurn,
		in id: AgentConversation.ID,
		state: State
	) -> Effect<Action> {
		guard let conversation = state.conversations[id: id]
		else { return .none }

		return .merge(
			save(conversation)
				.concatenate(with: run(turn, in: conversation))
				.cancellable(id: TurnID(id: id), cancelInFlight: true),
			watch(id),
			// A running turn keeps its chat; the timer starts over when it ends.
			.cancel(id: ExpiryID(id: id))
		)
	}

	/// Fails the turn when the provider stays silent for ``turnSilenceLimit``. Each batch of
	/// events starts the wait over.
	private func watch(_ id: AgentConversation.ID) -> Effect<Action> {
		.run { [clock] send in
			try await clock.sleep(for: Self.turnSilenceLimit)
			await send(.event(.turnTimedOut(id)))
		}
		.cancellable(id: TurnWatchID(id: id), cancelInFlight: true)
	}

	private func run(
		_ turn: ChatTurn,
		in conversation: AgentConversation
	) -> Effect<Action> {
		let id: AgentConversation.ID = conversation.id
		let client: AgentProviderClient = providers[conversation.provider]
		return .run { [browserAccess] send in

			// Without the person's grant the turn still runs, only without browser tools.
			let (access, connection) = await Self.connect(browserAccess, conversation.profileID)
			await send(.event(.turnStarted(id, access)))

			let request: AgentTurnRequest = .init(
				profileID: conversation.profileID,
				conversationID: id,
				resumeToken: conversation.resumeToken,
				prompt: turn.prompt,
				attachments: turn.attachments,
				modelID: conversation.modelID,
				browserAccess: connection
			)
			do {
				for try await batch in client.send(request).coalesced() {
					await send(.event(.turnEvents(id, batch)))
				}

				// A cancelled stream just ends; Stop already settled the chat.
				guard !Task.isCancelled
				else { return }

				await send(.event(.turnFinished(id)))
			} catch is CancellationError {
				return
			} catch let failure as AgentFailure {
				await send(.event(.turnFailed(id, failure)))
			} catch {
				guard !Task.isCancelled
				else { return }

				// The error's text may come from the provider; only its kind is shown.
				await send(.event(.turnFailed(id, .interrupted)))
			}
		}
	}

	// MARK: - Turns

	private var turns: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.event.turnStarted) { state, value in
				let (_, access) = value
				state.browserAccess = access
				return .none
			}

			Pullback(\.event.turnEvents) { state, value in
				let (id, events) = value
				guard
					var turn = state.turns[id],
					var conversation = state.conversations[id: id],
					let replyIndex = conversation.messages.firstIndex(where: { $0.id == turn.replyID })
				else { return .none }

				var effects: [Effect<Action>] = []
				for event in events {
					switch event {
					case let .started(resumeToken, modelID):
						let isNew: Bool = conversation.resumeToken != resumeToken
						conversation.resumeToken = resumeToken
						if conversation.modelID == nil { conversation.modelID = modelID }
						if isNew { effects.append(remember(conversation, resumeToken: resumeToken)) }

					case let .text(text):
						conversation.messages[replyIndex].text += text
						turn.retry = nil

					case let .toolStarted(tool):
						conversation.messages[replyIndex].tools.append(tool)
						turn.runningTools.insert(tool.id)

					case let .toolFinished(toolID, isError):
						turn.runningTools.remove(toolID)
						if isError { turn.failedTools.insert(toolID) }

					case let .toolDenied(name):
						let tool: AgentToolActivity = .init(id: "denied-" + name, name: name, input: "")
						conversation.messages[replyIndex].tools.append(tool)
						turn.failedTools.insert(tool.id)

					case let .usageWarning(limit):
						turn.usageWarning = limit

					case let .retrying(attempt, maxAttempts, _):
						turn.retry = .init(attempt: attempt, maxAttempts: maxAttempts)

					case let .completed(summary):
						if conversation.resumeToken != summary.resumeToken {
							conversation.resumeToken = summary.resumeToken
							effects.append(remember(conversation, resumeToken: summary.resumeToken))
						}
					}
				}
				state.turns[id] = turn
				state.conversations[id: id] = conversation
				effects.append(watch(id))
				return .merge(effects)
			}

			Pullback(\.event.turnFinished) { state, id in
				guard let turn = state.turns.removeValue(forKey: id)
				else { return .none }

				state.conversations[id: id]?.updatedAt = now

				// A reply that holds nothing at all is dropped rather than shown empty.
				if
					let reply = state.conversations[id: id]?.messages.first(where: { $0.id == turn.replyID }),
					reply.text.isEmpty,
					reply.tools.isEmpty
				{
					state.conversations[id: id]?.messages.removeAll { $0.id == turn.replyID }
				}
				if !state.isShown(id) {
					state.unreadIDs.insert(id)
				}
				return .merge(
					.cancel(id: TurnWatchID(id: id)),
					save(state.conversations[id: id]),
					scheduleExpiry(state.conversations[id: id])
				)
			}

			Pullback(\.event.turnFailed) { state, value in
				let (id, reason) = value
				return fail(id, reason: reason, state: &state)
			}

			Pullback(\.event.turnTimedOut) { state, id in
				guard let turn = state.turns[id]
				else { return .none }

				// A tool may be waiting for the person's approval; that isn't the provider's silence.
				guard turn.runningTools.isEmpty
				else { return watch(id) }

				return .merge(
					.cancel(id: TurnID(id: id)),
					fail(id, reason: .timedOut, state: &state)
				)
			}

			Pullback(\.ui.stopTapped) { state in
				guard
					let id = state.selectedID,
					let turn = state.turns.removeValue(forKey: id)
				else { return .none }

				if
					let reply = state.conversations[id: id]?.messages.first(where: { $0.id == turn.replyID }),
					reply.text.isEmpty,
					reply.tools.isEmpty
				{
					state.conversations[id: id]?.messages.removeAll { $0.id == turn.replyID }
				}
				state.conversations[id: id]?.updatedAt = now
				return .merge(
					.cancel(id: TurnID(id: id)),
					.cancel(id: TurnWatchID(id: id)),
					save(state.conversations[id: id]),
					scheduleExpiry(state.conversations[id: id])
				)
			}

			Pullback(\.event.expiryFired) { state, id in
				guard let conversation = state.conversations[id: id]
				else { return .none }

				// A chat whose turn is still running isn't idle; it's checked again when it ends.
				guard state.turns[id] == nil
				else { return .none }

				guard conversation.isExpired(at: now)
				else { return scheduleExpiry(conversation) }

				return end(conversation, state: &state)
			}
		}
	}

	/// Ends a turn that couldn't finish. The prompt stays in the transcript with the failure
	/// under it, so the chat never looks empty or new, and the chat is saved that way
	/// (DEV-643). Only a reply that holds nothing is dropped.
	private func fail(
		_ id: AgentConversation.ID,
		reason: AgentFailure,
		state: inout State
	) -> Effect<Action> {
		guard let turn = state.turns.removeValue(forKey: id)
		else { return .none }

		if
			let reply = state.conversations[id: id]?.messages.first(where: { $0.id == turn.replyID }),
			reply.text.isEmpty,
			reply.tools.isEmpty
		{
			state.conversations[id: id]?.messages.removeAll { $0.id == turn.replyID }
		}
		state.failures[id] = .init(
			reason: reason,
			prompt: turn.prompt,
			attachments: turn.attachments,
			promptID: turn.promptID
		)
		if reason == .browserToolsUnavailable {
			state.browserAccess = .notGranted
		}
		state.conversations[id: id]?.updatedAt = now
		return .merge(
			.cancel(id: TurnWatchID(id: id)),
			save(state.conversations[id: id]),
			scheduleExpiry(state.conversations[id: id])
		)
	}

	/// Remembers an ephemeral chat's provider transcript as soon as it exists, so it's
	/// discarded later even if Arx doesn't quit cleanly. A kept chat is saved instead.
	private func remember(
		_ conversation: AgentConversation,
		resumeToken: String
	) -> Effect<Action> {
		guard conversation.retention == .ephemeral
		else { return save(conversation) }

		return .run { [store] _ in
			await withErrorReporting {
				try await store.started(conversation, resumeToken: resumeToken)
			}
		}
	}

	/// Writes a kept chat, after any earlier save of it and never over a newer one
	/// (``ChatSaves``). A reply that holds nothing yet, as one does while its turn starts, isn't
	/// written: a chat read back never shows an empty answer.
	private func save(_ conversation: AgentConversation?) -> Effect<Action> {
		guard var conversation, conversation.isKept
		else { return .none }

		conversation.messages.removeAll(where: \.isEmptyReply)
		let serial: Int = saves.next()
		return .run { [conversation, saves, store] _ in
			await saves.save(conversation, serial: serial, with: store.save)
		}
	}

	/// Starts the ephemeral chat's idle timer over from its last activity.
	private func scheduleExpiry(_ conversation: AgentConversation?) -> Effect<Action> {
		guard let conversation
		else { return .none }

		guard let expiresAt = conversation.expiresAt
		else { return .cancel(id: ExpiryID(id: conversation.id)) }

		let id: AgentConversation.ID = conversation.id
		let delay: TimeInterval = max(0, expiresAt.timeIntervalSince(now))
		return .run { [clock] send in
			try await clock.sleep(for: .seconds(delay))
			await send(.event(.expiryFired(id)))
		}
		.cancellable(id: ExpiryID(id: id), cancelInFlight: true)
	}

	/// Removes a chat and everything its provider kept on this Mac for it.
	private func end(
		_ conversation: AgentConversation,
		state: inout State
	) -> Effect<Action> {
		let id: AgentConversation.ID = conversation.id
		state.conversations.remove(id: id)
		state.turns[id] = nil
		state.failures[id] = nil
		state.unreadIDs.remove(id)
		let settings: AgentProfileSettings = state.settings
		state.updateSurfaces { surface in
			guard surface.selectedID == id
			else { return }

			surface.selectedID = nil
			surface.newChatProvider = settings.provider
			surface.newChatModelID = settings.modelID
			if surface.screen == .info { surface.screen = .conversation }
		}
		let client: AgentProviderClient = providers[conversation.provider]
		return .merge(
			.cancel(id: TurnID(id: id)),
			.cancel(id: TurnWatchID(id: id)),
			.cancel(id: ExpiryID(id: id)),
			.run { [store] _ in
				await withErrorReporting { try await store.delete(conversation, provider: client) }
			}
		)
	}

	// MARK: - This chat

	private var chatActions: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.copyAnswerTapped) { state in
				guard let answer = state.selected?.lastAnswer
				else { return .none }

				return .send(.delegate(.copy(answer)))
			}

			Pullback(\.ui.pinTapped) { state in
				guard let conversation = state.selected
				else { return .none }

				let id: AgentConversation.ID = conversation.id
				let isKept: Bool = !conversation.isKept
				state.conversations[id: id]?.retention = isKept ? .persistent : .ephemeral
				if !isKept { state.conversations[id: id]?.archivedAt = nil }
				state.conversations[id: id]?.updatedAt = now
				guard let updated = state.conversations[id: id]
				else { return .none }

				let profileID: Profile.ID = state.id
				return .merge(
					.run { [store] _ in
						await withErrorReporting {
							if isKept {
								try await store.save(updated)

								// A kept chat's transcript must survive the launch and quit sweeps.
								if let token = updated.resumeToken {
									try await store.forgetTranscript(token, profileID)
								}
							} else {
								try await store.delete(id, profileID)
								if let token = updated.resumeToken {
									try await store.rememberTranscript(token, profileID)
								}
							}
						}
					},
					state.turns[id] == nil ? scheduleExpiry(updated) : .cancel(id: ExpiryID(id: id))
				)
			}

			Pullback(\.ui.renamed) { state, title in
				let title: String = title.trimmingCharacters(in: .whitespacesAndNewlines)
				guard let id = state.selectedID, !title.isEmpty
				else { return .none }

				state.conversations[id: id]?.title = String(title.prefix(80))
				return save(state.conversations[id: id])
			}

			Pullback(\.ui.archiveTapped) { state in
				guard let conversation = state.selected, conversation.isKept
				else { return .none }

				let id: AgentConversation.ID = conversation.id
				state.conversations[id: id]?.archivedAt = conversation.archivedAt == nil ? now : nil
				if state.conversations[id: id]?.archivedAt != nil {
					state.selectedID = nil
					state.screen = .chats
				}
				return save(state.conversations[id: id])
			}

			Pullback(\.ui.deleteTapped) { state in
				guard let conversation = state.selected
				else { return .none }

				return end(conversation, state: &state)
			}

			Pullback(\.ui.allowBrowserToolsTapped) { _ in
				.send(.delegate(.allowBrowserTools))
			}
		}
	}

	// MARK: - Screens and Your Chats

	private var listing: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.newChatTapped) { state in
				state.selectedID = nil
				state.screen = .conversation
				state.newChatProvider = state.settings.provider
				state.newChatModelID = state.settings.modelID
				state.focusRequest += 1
				return .none
			}

			Pullback(\.ui.historyTapped) { state in
				state.screen = state.screen == .chats ? .conversation : .chats
				return .none
			}

			Pullback(\.ui.infoTapped) { state in
				guard state.selected != nil
				else { return .none }

				state.screen = .info
				return .none
			}

			Pullback(\.ui.backTapped) { state in
				state.screen = .conversation
				return .none
			}

			Pullback(\.ui.show) { state, id in
				guard state.selectedID != id
				else { return .none }

				state.selectedID = id
				state.screen = .conversation
				if let id {
					state.unreadIDs.remove(id)
				} else {
					state.newChatProvider = state.settings.provider
					state.newChatModelID = state.settings.modelID
				}
				return .none
			}

			Pullback(\.ui.chatSelected) { state, id in
				guard state.conversations[id: id] != nil
				else { return .none }

				state.selectedID = id
				state.screen = .conversation
				state.unreadIDs.remove(id)
				state.focusRequest += 1
				return .none
			}

			Pullback(\.ui.chatsQueryChanged) { state, query in
				state.chatsQuery = query
				return .none
			}

			Pullback(\.ui.unreadOnlyToggled) { state in
				state.showsUnreadOnly.toggle()
				return .none
			}

			Pullback(\.ui.archivedToggled) { state in
				state.showsArchived.toggle()
				return .none
			}
		}
	}

	// MARK: - Settings

	private var settings: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.defaultProviderChanged) { state, provider in
				guard providers.providers.contains(provider)
				else { return .none }

				return changeProvider(to: provider, &state)
			}

			Pullback(\.ui.defaultModelChanged) { state, modelID in
				state.settings.modelID = modelID
				return saveSettings(&state)
			}

			Pullback(\.ui.retentionChanged) { state, retention in
				state.settings.retention = retention
				return saveSettings(&state)
			}
		}
	}

	/// Makes the provider the profile's default with its own default model and account.
	private func changeProvider(
		to provider: AgentProvider,
		_ state: inout State
	) -> Effect<Action> {
		guard provider != state.settings.provider
		else { return .none }

		state.settings.provider = provider
		state.settings.modelID = nil
		state.settings.accountID = nil
		return saveSettings(&state)
	}

	/// Saves the profile's defaults. An empty, unselected chat follows them at once;
	/// existing chats keep what they started with.
	private func saveSettings(_ state: inout State) -> Effect<Action> {
		let settings: AgentProfileSettings = state.settings
		state.updateSurfaces { surface in
			guard surface.selectedID == nil
			else { return }

			surface.newChatProvider = settings.provider
			surface.newChatModelID = settings.modelID
		}
		let profileID: Profile.ID = state.id
		return .run { [store] _ in
			await withErrorReporting { try await store.setSettings(settings, profileID) }
		}
	}
}
