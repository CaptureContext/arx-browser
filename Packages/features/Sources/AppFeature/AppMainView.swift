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

internal struct AppMainView: View {
	internal let store: StoreOf<AppFeature>
	internal let surface: BrowserSurfaceClient

	/// The store's engine, for what the views ask outside the reducer (DEV-1116).
	internal let engine: BrowserEngineClient
	internal let siteIcons: BrowserSiteIconClient
	internal let previewClients: SidebarPreviewClients

	internal init(
		store: StoreOf<AppFeature>,
		surface: BrowserSurfaceClient,
		engine: BrowserEngineClient,
		siteIcons: BrowserSiteIconClient = .init(),
		previewClients: SidebarPreviewClients = .init()
	) {
		self.store = store
		self.surface = surface
		self.engine = engine
		self.siteIcons = siteIcons
		self.previewClients = previewClients
	}

	internal var body: some View {
		MainView(
			store: store.scope(state: \.main, action: \.main),
			surface: surface,
			chatPanel: AnyView(AppChatPanel(store: store, windowID: store.main.id)),
			recentDownloads: recentDownloads(store: store, window: store.scope(state: \.main, action: \.main)),
			mediaPlayer: AnyView(AppSidebarMediaPlayer(store: store, windowID: store.main.id, position: previewClients.mediaPosition))
		) {
			AppLibraryDownloadsPanel(store: store, windowID: store.main.id)
		} mediaPanel: {
			AppLibraryMediaPanel(store: store, windowID: store.main.id)
		}
			.modifier(PeekHostPresentation(store: store, windowID: store.main.id, surface: surface))
			.environment(\.browserSurfaceVisibilityObserver, .init { report in
				store.send(.event(.mediaSurfaceVisibility(store.main.id, report)))
			})
			.modifier(RoutePreviewPresentation(store: store, windowID: store.main.id))
			.modifier(AppLinkPromptPresentation(store: store, windowID: store.main.id))
			.modifier(SendFeedbackSheetPresentation(store: store, host: .window(store.main.id)))
			.modifier(WebKitPromptPresentation(store: store, windowID: store.main.id))
			.modifier(BrowserLinkPromptPresentation(store: store, windowID: store.main.id))
			.modifier(DeviceChooserPresentation(store: store, windowID: store.main.id))
			.modifier(CastPickerPresentation(store: store, windowID: store.main.id))
			.modifier(WhatsNewSheetPresentation(store: store))
			.modifier(ProblemReportSheetPresentation(store: store))
			.environment(\.browserSiteIcons, siteIcons.presentation)
			.environment(\.browserPageOverlay, pageOverlay(store: store))
			.environment(\.browserPageNotice, pageNotices(store: store, windowID: store.main.id))
			.environment(\.browserChatTab, chatTabContent(store: store, windowID: store.main.id))
			.browserChromeAppearance(store.settings.chromeAppearance)
			.environment(\.browserAccentIsEnabled, ChromeAccent.isEnabled())
			.environment(\.reorderHapticsEnabled, store.settings.general.hapticsEnabled)
			.environment(\.highlightsLocalTabs, store.settings.general.localTabHighlightEnabled)
			.environment(\.sidebarEdge, store.settings.general.sidebarPosition == .right ? .trailing : .leading)
			.modifier(ShowsFullURLEnvironment(store: store.scope(state: \.main, action: \.main)))
			.environment(\.browserLinkActions, browserLinkActions(store: store, windowID: store.main.id))
			.modifier(SidebarWindowTargetsEnvironment(store: store, windowID: store.main.id, isPrivate: false))
			.environment(\.sidebarHoverPreviews, sidebarHoverPreviews(store: store, windowID: store.main.id, clients: previewClients))
			.pagePopups {
				Group {
					AutomationSignInView(store: store)
					AutomationApprovalView(store: store)
					PasswordSaveView(store: store, windowID: store.main.id)
					RoutingInboxView(store: store)
					WorkspaceRecoveryView(store: store)
				}

					// Under a page in full screen (DEV-991).
					.accessibilityHidden(store.pageFullScreen?.windowID == store.main.id)
			}
			.modifier(SiteShortcutToast(
				store: store,
				windowID: store.main.id,
				topInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset,
				trailingInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset
			))
			.modifier(LinkFeedbackToast(
				store: store,
				windowID: store.main.id,
				topInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset,
				trailingInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset
			))
			.modifier(PagePictureInPictureHostPresentation(store: store, windowID: store.main.id, engine: engine))
			.modifier(PageFullScreenHostPresentation(store: store, windowID: store.main.id, surface: surface))

			// Outside full screen, so a quiet request's affordance stays above the full-screen page.
			.modifier(PagePermissionPromptPresentation(store: store, windowID: store.main.id))
	}
}

/// What a chat tab shows (DEV-761): the profile's chat, full pane width. Little Arx shows a
/// chat tab dropped outside every window the same way (DEV-793).
internal func chatTabContent(
	store: StoreOf<AppFeature>,
	windowID: UUID
) -> BrowserChatTabContent {
	.init { tab in
		AnyView(AppChatTab(store: store, windowID: windowID, tab: tab))
	}
}

/// The downloads the Library button fans out: the window's profile's, or its private transfers.
/// They're read as the rows draw, so a download's progress never redraws the window.
@MainActor
internal func recentDownloads(
	store: StoreOf<AppFeature>,
	window: StoreOf<MainFeature>
) -> SidebarRecentDownloads {
	.init(
		downloads: {
			let queue = store.downloads.queue
			guard !window.isPrivate else { return queue.privateDownloads }

			let profileID = window.sidebar.space.profileID
			return queue.downloads.filter { $0.id.profileID == profileID }
		},
		open: { store.send(.downloads(.ui(.openRecent($0)))) },
		// The queue is observed only while something shows it, as the Library's panel does.
		watchingChanged: { store.send(.downloads(.ui($0 ? .panelAppeared : .panelDisappeared))) }
	)
}

extension BrowserSiteIconClient {
	internal var presentation: BrowserSiteIconLoader {
		.init(
			icons: { key in
				icons(.init(profileID: .init(rawValue: key.profileID), pageURL: key.pageURL))
			},
			cachedIcons: { key in
				cachedIcons(.init(profileID: .init(rawValue: key.profileID), pageURL: key.pageURL))
			}
		)
	}
}
