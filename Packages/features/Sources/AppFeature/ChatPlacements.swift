import AgentClient
import AppUI
import BrowserCore
import ChatFeature
import Foundation
import MainFeature
import _ComposableArchitecture

/// Where the profile's chats show (DEV-761): each window's panel shows the window's global chat,
/// or the chat pinned to its current tab, and a chat can become a chat tab and back.
///
/// The chats stay in the profile's ``ChatFeature``. A window keeps only its pins
/// (``MainFeature/State/chatPins``), saved with its presentation, and a chat tab keeps its chat
/// in its address (``ChatTabAddress``), saved with the tab. Each placement is a
/// ``ChatSurfaceID`` in the profile's chats, with its own chat, screen and composer.
@Reducer
internal struct ChatPlacements {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.chat.pinToTab) { state, value in
			let (windowID, tabID, conversationID) = value
			guard
				let window = state.window(windowID),
				!window.isPrivate,
				let tab = window.sidebar.organization.tabs[id: tabID],
				!tab.isChat
			else { return .none }

			let profileID: Profile.ID = window.sidebar.space.profileID
			state.prepareChat(profileID)

			// The pinned chat leaves the window's global chat, which starts a new one.
			return .concatenate(
				state.send(.ui(.chatPinned(tabID, conversationID.rawValue)), to: windowID),
				.send(.chats(.element(id: profileID, action: .surfaces(.element(
					id: .pinned(tabID.rawValue),
					action: .ui(.show(conversationID))
				))))),
				.send(.chats(.element(id: profileID, action: .surfaces(.element(
					id: .window(windowID),
					action: .ui(.show(nil))
				)))))
			)
		}

		Pullback(\.chat.unpin) { state, value in
			let (windowID, tabID) = value
			guard
				let window = state.window(windowID),
				let conversationID = window.chatPins[tabID]
			else { return .none }

			let profileID: Profile.ID = window.sidebar.space.profileID
			state.chats[id: profileID]?.surfaces[.pinned(tabID.rawValue)] = nil

			// The chat stays in view: it becomes the window's global chat.
			return .concatenate(
				state.send(.ui(.chatUnpinned(tabID)), to: windowID),
				.send(.chats(.element(id: profileID, action: .surfaces(.element(
					id: .window(windowID),
					action: .ui(.show(.init(rawValue: conversationID)))
				)))))
			)
		}

		Pullback(\.chat.openInTab) { state, value in
			let (windowID, surfaceID, conversationID) = value
			guard
				let window = state.window(windowID),
				!window.isPrivate
			else { return .none }

			let profileID: Profile.ID = window.sidebar.space.profileID
			state.prepareChat(profileID)
			let title: String = state.chatTabTitle(conversationID, in: profileID)
			var effects: [Effect<Action>] = [
				state.send(.ui(.chatOpenChanged(false)), to: windowID),
				state.send(
					.ui(.openChatTab(.init(conversationID: conversationID?.rawValue), title: title)),
					to: windowID
				),
			]

			// The chat moves into the tab: a pin goes, and the global chat starts a new one.
			switch surfaceID {
			case let .pinned(tabID):
				state.chats[id: profileID]?.surfaces[surfaceID] = nil
				effects.append(state.send(.ui(.chatUnpinned(.init(rawValue: tabID))), to: windowID))

			case .window:
				effects.append(.send(.chats(.element(id: profileID, action: .surfaces(.element(
					id: surfaceID,
					action: .ui(.show(nil))
				))))))

			case .standalone, .tab:
				break
			}
			return .concatenate(effects)
		}

		Pullback(\.chat.moveToSidebar) { state, value in
			let (windowID, tabID, conversationID) = value
			guard
				let window = state.window(windowID),
				!window.isPrivate,
				window.sidebar.organization.tabs[id: tabID]?.isChat == true
			else { return .none }

			let profileID: Profile.ID = window.sidebar.space.profileID
			state.prepareChat(profileID)
			state.chats[id: profileID]?.surfaces[.tab(tabID.rawValue)] = nil
			return .concatenate(
				.send(.chats(.element(id: profileID, action: .surfaces(.element(
					id: .window(windowID),
					action: .ui(.show(conversationID))
				))))),
				state.send(.ui(.chatOpenChanged(true)), to: windowID),
				state.send(.sidebar(.ui(.sidebar(.close(.tab(tabID.rawValue))))), to: windowID)
			)
		}

		// Closed tabs take their placements with them; the chats stay.
		Pullback(\.main.delegate.organizationChanged) { state, organization in
			state.forgetClosedChatPlacements(keeping: organization)
			return .none
		}

		Pullback(\.windows) { state, action in
			guard
				case let .element(id, .delegate(.organizationChanged(organization))) = action,
				state.windows[id: id]?.isPrivate == false
			else { return .none }

			state.forgetClosedChatPlacements(keeping: organization)
			return .none
		}
	}
}

extension AppFeature.State {
	internal func window(_ id: UUID) -> MainFeature.State? {
		id == main.id ? main : windows[id: id]
	}

	internal func send(
		_ action: MainFeature.Action,
		to windowID: UUID
	) -> Effect<AppFeature.Action> {
		windowID == main.id
		? .send(.main(action))
		: .send(.windows(.element(id: windowID, action: action)))
	}

	/// The Pin Chat to This Tab and Open Chat in Tab commands, with the chat the window shows.
	internal mutating func placeChat(
		_ request: ChatPlacementRequest,
		in windowID: UUID
	) -> Effect<AppFeature.Action> {
		guard
			let window = window(windowID),
			!window.isPrivate
		else { return .none }

		let profileID: Profile.ID = window.sidebar.space.profileID
		prepareChat(profileID)
		let tab: BrowserCore.Tab? = window.chatTab
		let pinned: UUID? = tab.flatMap { window.chatPins[$0.id] }
		let surfaceID: ChatSurfaceID = window.chatSurfaceID
		let shown: AgentConversation.ID? = chats[id: profileID]?[surface: surfaceID].selectedID
		switch request {
		case .togglePinToTab:
			guard let tab, !tab.isChat
			else { return .none }

			if pinned != nil {
				return .send(.chat(.unpin(windowID: windowID, tabID: tab.id)))
			}

			// A new, empty chat has nothing to pin yet; the panel opens so it can start.
			guard let shown else {
				return send(.ui(.chatOpenChanged(true)), to: windowID)
			}

			return .concatenate(
				.send(.chat(.pinToTab(windowID: windowID, tabID: tab.id, conversationID: shown))),
				send(.ui(.chatOpenChanged(true)), to: windowID)
			)

		case .openInTab:
			// From a chat tab, the command opens the window's global chat in another tab.
			return .send(.chat(.openInTab(windowID: windowID, from: surfaceID, conversationID: shown)))
		}
	}

	/// A pinned panel or a chat tab moved to another chat: the pin or the tab follows it.
	internal mutating func followSurface(
		_ surfaceID: ChatSurfaceID,
		to conversationID: AgentConversation.ID?,
		in profileID: Profile.ID
	) -> Effect<AppFeature.Action> {
		switch surfaceID {
		case let .pinned(rawTabID):
			let tabID = BrowserCore.Tab.ID(rawValue: rawTabID)

			// A new chat on a pinned tab is pinned once it starts.
			guard
				let conversationID,
				let window = ([main] + Array(windows)).first(where: { $0.chatPins[tabID] != nil })
			else { return .none }

			return send(.ui(.chatPinned(tabID, conversationID.rawValue)), to: window.id)

		case let .tab(rawTabID):
			let tabID = BrowserCore.Tab.ID(rawValue: rawTabID)
			let address: ChatTabAddress = .init(conversationID: conversationID?.rawValue)
			let title: String = chatTabTitle(conversationID, in: profileID)

			// A chat tab dropped outside every window lives in Little Arx, not in the sidebar.
			if retargetLittleChatTab(tabID, address, title: title) { return .none }

			return .send(.main(.retargetChatTab(tabID, address, title: title)))

		case .standalone, .window:
			return .none
		}
	}

	/// Keeps every chat tab of the profile titled after its chat.
	internal mutating func retitleChatTabs(of profileID: Profile.ID) -> Effect<AppFeature.Action> {
		for little in littleWindows where little.tab.profileID == profileID {
			guard let address = little.tab.chatAddress
			else { continue }

			let title: String = chatTabTitle(address.conversationID.map { .init(rawValue: $0) }, in: profileID)
			retargetLittleChatTab(little.tab.id, address, title: title)
		}

		let effects: [Effect<AppFeature.Action>] = main.sidebar.organization.tabs
			.filter { $0.profileID == profileID }
			.compactMap { tab in
				guard let address = tab.chatAddress
				else { return nil }

				let title: String = chatTabTitle(address.conversationID.map { .init(rawValue: $0) }, in: profileID)
				guard title != tab.restoration.title
				else { return nil }

				return .send(.main(.retargetChatTab(tab.id, address, title: title)))
			}
		return .merge(effects)
	}

	/// Points a chat tab Little Arx holds (DEV-793) at `address`, with its tab and viewer.
	///
	/// - Returns: Whether a Little Arx window holds the tab.
	@discardableResult
	internal mutating func retargetLittleChatTab(
		_ tabID: BrowserCore.Tab.ID,
		_ address: ChatTabAddress,
		title: String
	) -> Bool {
		guard
			let little = littleWindows.first(where: { $0.tab.id == tabID }),
			little.tab.isChat
		else { return false }

		let restoration: BrowserCore.Tab.Restoration = .init(title: title, url: address.url)
		guard little.tab.restoration != restoration
		else { return true }

		littleWindows[id: little.id]?.tab.restoration = restoration
		if littleWindows[id: little.id]?.viewer.tab?.id == tabID {
			littleWindows[id: little.id]?.viewer.tab?.restoration = restoration
			littleWindows[id: little.id]?.viewer.navigation.url = address.url
			littleWindows[id: little.id]?.viewer.navigation.title = title
		}
		return true
	}

	internal func chatTabTitle(
		_ conversationID: AgentConversation.ID?,
		in profileID: Profile.ID
	) -> String {
		conversationID
			.flatMap { chats[id: profileID]?.conversations[id: $0]?.title }
			.flatMap { $0.isEmpty ? nil : $0 }
		?? String.localized(.appUI.chat.newChat)
	}

	/// Drops the chat surfaces nothing can show anymore, against the current workspace. Little
	/// Arx calls it whenever a torn-off tab leaves it or changes hands (DEV-793): closing,
	/// switching profile, promotion and a refused tear-off. No window publishes an organization
	/// then, so `forgetClosedChatPlacements` never runs.
	internal mutating func forgetDetachedChatSurfaces() {
		forgetClosedChatPlacements(keeping: workspace)
	}

	/// Drops the surfaces of pins and chat tabs whose tabs are gone. A pin needs its tab in the
	/// organization, since only an ordinary window shows a pinned panel. A chat tab may also live
	/// in Little Arx, or be on its way there (DEV-793).
	fileprivate mutating func forgetClosedChatPlacements(keeping organization: BrowserOrganization) {
		let organizationTabIDs: Set<UUID> = Set(organization.tabs.map(\.id.rawValue))
		let chatTabIDs: Set<UUID> = organizationTabIDs
		.union(littleWindows.map(\.tab.id.rawValue))
		.union(tabsTearingOff.map(\.rawValue))
		for profileID in chats.ids {
			guard let surfaces = chats[id: profileID]?.surfaces
			else { continue }

			let kept = surfaces.filter { id, _ in
				switch id {
				case let .pinned(tabID): organizationTabIDs.contains(tabID)
				case let .tab(tabID): chatTabIDs.contains(tabID)
				case .standalone, .window: true
				}
			}
			if kept.count != surfaces.count {
				chats[id: profileID]?.surfaces = kept
			}
		}
	}
}

extension MainFeature.State {
	/// The tab the window's chat is about: the focused pane's, or the selected one before the
	/// viewer shows it.
	public var chatTab: BrowserCore.Tab? {
		focusedPageTab
	}

	/// The surface the window's panel shows: the chat pinned to the current tab, or the window's
	/// global chat.
	public var chatSurfaceID: ChatSurfaceID {
		guard
			let tab = chatTab,
			chatPins[tab.id] != nil
		else { return .window(id) }

		return .pinned(tab.id.rawValue)
	}
}
