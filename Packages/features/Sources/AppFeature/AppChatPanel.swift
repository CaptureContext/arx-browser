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

/// The chat panel of a window: the chats of the profile its current space belongs to. It shows
/// the chat pinned to the current tab, or the window's global chat (DEV-761).
internal struct AppChatPanel: View {
	internal let store: StoreOf<AppFeature>
	internal let windowID: UUID

	internal init(
		store: StoreOf<AppFeature>,
		windowID: UUID
	) {
		self.store = store
		self.windowID = windowID
	}

	private var window: MainFeature.State? {
		store.state.window(windowID)
	}

	internal var body: some View {
		if let window, !window.isPrivate {
			let profileID = window.sidebar.space.profileID
			let surfaceID: ChatSurfaceID = window.chatSurfaceID
			let tab: BrowserCore.Tab? = window.chatTab
			let pin: UUID? = tab.flatMap { window.chatPins[$0.id] }
			Group {
				if let chat = store.scope(state: \.chats[id: profileID], action: \.chats[id: profileID]) {
					let surface = chat.scope(state: \.[surface: surfaceID], action: \.surfaces[id: surfaceID])
					ChatPanelView(
						store: surface,
						attachables: window.chatAttachables,
						placement: placement(surfaceID: surfaceID, tab: tab, isPinned: pin != nil),
						onHide: hide
					)
					.id(surfaceID)

					// A restored pin's chat is placed once the panel shows it.
					.task(id: pin) {
						guard let pin, surface.selectedID?.rawValue != pin
						else { return }

						surface.send(.ui(.show(.init(rawValue: pin))))
					}
				} else {
					ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			.onChange(of: profileID, initial: true) { _, profileID in
				store.send(.chat(.prepare(profileID)))
			}
		}
	}

	private func placement(
		surfaceID: ChatSurfaceID,
		tab: BrowserCore.Tab?,
		isPinned: Bool
	) -> ChatPlacement {
		let windowID: UUID = windowID
		let store: StoreOf<AppFeature> = store
		var placement: ChatPlacement = .init(kind: isPinned ? .pinned : .panel)
		placement.openInTab = { conversationID in
			store.send(.chat(.openInTab(windowID: windowID, from: surfaceID, conversationID: conversationID)))
		}
		if let tab, !tab.isChat {
			// Capture Visible Area and Capture Area… in the + menu send the page to this chat (DEV-798).
			if store.captureAvailable {
				placement.capture = { area in
					store.send(.ui(.capturePageForChat(windowID: windowID, region: area)))
				}
			}
			let tabID: BrowserCore.Tab.ID = tab.id
			if isPinned {
				placement.unpin = {
					store.send(.chat(.unpin(windowID: windowID, tabID: tabID)))
				}
			} else {
				placement.pinToTab = { conversationID in
					store.send(.chat(.pinToTab(windowID: windowID, tabID: tabID, conversationID: conversationID)))
				}
			}
		}
		return placement
	}

	private func hide() {
		let action: MainFeature.Action = .ui(.chatOpenChanged(false))
		if windowID == store.main.id {
			store.send(.main(action))
		} else {
			store.send(.windows(.element(id: windowID, action: action)))
		}
	}
}
