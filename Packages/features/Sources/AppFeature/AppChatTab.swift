import AgentClient
import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserMediaClient
import BrowserSurfaceClient
import BrowserSiteIconClient
import ChatFeature
import MainFeature
import DownloadsFeature
import SwiftUI
import ViewerItemFeature
import _ComposableArchitecture

internal struct AppChatTab: View {
	internal let store: StoreOf<AppFeature>
	internal let windowID: UUID
	internal let tab: BrowserCore.Tab

	/// Moving to the sidebar needs an ordinary window: Little Arx has none (DEV-793).
	private var moveToSidebar: (@MainActor (AgentConversation.ID?) -> Void)? {
		guard store.state.window(windowID) != nil
		else { return nil }

		return { [store, windowID, tab] conversationID in
			store.send(
				.chat(
					.moveToSidebar(
						windowID: windowID,
						tabID: tab.id,
						conversationID: conversationID
					)
				)
			)
		}
	}

	internal var body: some View {
		let surfaceID: ChatSurfaceID = .tab(tab.id.rawValue)
		let address: ChatTabAddress? = tab.chatAddress
		Group {
			if let chat = store.scope(state: \.chats[id: tab.profileID], action: \.chats[id: tab.profileID]) {
				let surface = chat.scope(state: \.[surface: surfaceID], action: \.surfaces[id: surfaceID])
				ChatPanelView(
					store: surface,
					attachables: store.state.window(windowID)?.chatAttachables ?? [],
					placement: .init(
						kind: .tab,
						moveToSidebar: moveToSidebar
					),
					onHide: { surface.send(.ui(.backTapped)) }
				)
				.id(surfaceID)

				// The tab's address names its chat; the surface shows it, also after a restore.
				.task(id: address) {
					let conversationID: AgentConversation.ID? = address?.conversationID.map { .init(rawValue: $0) }
					guard surface.selectedID != conversationID
					else { return }

					surface.send(.ui(.show(conversationID)))
				}
			} else {
				ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.onAppear { store.send(.chat(.prepare(tab.profileID))) }
	}
}
