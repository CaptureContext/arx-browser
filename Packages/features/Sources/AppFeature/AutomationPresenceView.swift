import AppUI
import BrowserCore
import BrowserSurfaceClient
import SwiftUI
import _ComposableArchitecture

/// The notices a window draws over each page: the link toast at the top-right corner, the site
/// shortcut toast over a page in full screen (DEV-1264) and,
/// while an MCP client acts on the page, its indicator at the top centre (DEV-899).
@MainActor
internal func pageNotices(
	store: StoreOf<AppFeature>,
	windowID: UUID
) -> BrowserPageOverlay {
	let links: BrowserPageOverlay = pageLinkFeedbackNotice(store: store, windowID: windowID)
	return .init { tabID in
		AnyView(
			ZStack {
				links.content(tabID)
				AgentPresenceNotice(store: store, tabID: tabID)

				// Over a page in HTML full screen, which covers the window's corner (DEV-1264).
				if store.pageFullScreen?.windowID == windowID, store.pageFullScreen?.tabID == tabID {
					Color.clear
						.allowsHitTesting(false)
						.modifier(SiteShortcutToast(
							store: store,
							windowID: windowID,
							topInset: ArxToastMetrics.edgeInset,
							trailingInset: ArxToastMetrics.edgeInset
						))
				}
			}
		)
	}
}

/// A page's agent indicator, with Stop. It sits in the window, never in the page, so the page
/// can't read, hide or press it.
internal struct AgentPresenceNotice: View {
	internal let store: StoreOf<AppFeature>
	internal let tabID: BrowserCore.Tab.ID

	internal var body: some View {
		if let entry = store.state.agentPresence(on: tabID) {
			let presence: AgentPresence = entry.presence
			AgentPresencePill(
				clientName: entry.clientName,
				isStopped: presence.isStopped,
				fadesAt: presence.fadesAt,
				onStop: { store.send(.automation(.ui(.stopClient(presence.clientID)))) },
				onResume: { store.send(.automation(.ui(.resumeClient(presence.clientID)))) }
			)
		}
	}
}
