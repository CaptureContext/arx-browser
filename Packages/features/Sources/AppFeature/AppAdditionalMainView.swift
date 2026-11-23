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

internal struct AppAdditionalMainView: View {
	internal let store: StoreOf<AppFeature>
	internal let child: StoreOf<MainFeature>
	internal let surface: BrowserSurfaceClient

	/// The store's engine, for what the views ask outside the reducer (DEV-1116).
	internal let engine: BrowserEngineClient
	internal let siteIcons: BrowserSiteIconClient
	internal let previewClients: SidebarPreviewClients

	internal init(
		store: StoreOf<AppFeature>,
		child: StoreOf<MainFeature>,
		surface: BrowserSurfaceClient,
		engine: BrowserEngineClient,
		siteIcons: BrowserSiteIconClient = .init(),
		previewClients: SidebarPreviewClients = .init()
	) {
		self.store = store
		self.child = child
		self.surface = surface
		self.engine = engine
		self.siteIcons = siteIcons
		self.previewClients = previewClients
	}

	internal var body: some View {
		MainView(
			store: child,
			surface: surface,
			chatPanel: child.isPrivate ? nil : AnyView(AppChatPanel(store: store, windowID: child.id)),
			recentDownloads: recentDownloads(store: store, window: child),
			mediaPlayer: child.isPrivate
			? nil
			: AnyView(AppSidebarMediaPlayer(store: store, windowID: child.id, position: previewClients.mediaPosition))
		) {
			AppLibraryDownloadsPanel(store: store, windowID: child.id)
		} mediaPanel: {
			AppLibraryMediaPanel(store: store, windowID: child.id)
		}
			.modifier(PeekHostPresentation(store: store, windowID: child.id, surface: surface))
			.environment(\.browserSurfaceVisibilityObserver, .init { report in
				store.send(.event(.mediaSurfaceVisibility(child.id, report)))
			})
			.modifier(RoutePreviewPresentation(store: store, windowID: child.id))
			.modifier(AppLinkPromptPresentation(store: store, windowID: child.id))
			.modifier(SendFeedbackSheetPresentation(store: store, host: .window(child.id)))
			.modifier(WebKitPromptPresentation(store: store, windowID: child.id))
			.modifier(BrowserLinkPromptPresentation(store: store, windowID: child.id))
			.modifier(DeviceChooserPresentation(store: store, windowID: child.id))
			.modifier(CastPickerPresentation(store: store, windowID: child.id))
			.environment(\.browserSiteIcons, siteIcons.presentation)
			.environment(\.browserPageOverlay, pageOverlay(store: store))
			.environment(\.browserPageNotice, pageNotices(store: store, windowID: child.id))
			.environment(\.browserChatTab, child.isPrivate ? nil : chatTabContent(store: store, windowID: child.id))
			.browserChromeAppearance(store.settings.chromeAppearance)
			.environment(\.browserAccentIsEnabled, ChromeAccent.isEnabled())
			.environment(\.reorderHapticsEnabled, store.settings.general.hapticsEnabled)
			.environment(\.highlightsLocalTabs, store.settings.general.localTabHighlightEnabled)
			.environment(\.sidebarEdge, store.settings.general.sidebarPosition == .right ? .trailing : .leading)
			.modifier(ShowsFullURLEnvironment(store: child))
			.environment(\.browserLinkActions, browserLinkActions(store: store, windowID: child.id))
			.modifier(SidebarWindowTargetsEnvironment(store: store, windowID: child.id, isPrivate: child.isPrivate))
			.environment(\.sidebarHoverPreviews, sidebarHoverPreviews(store: store, windowID: child.id, clients: previewClients))
			.pagePopups {
				Group {
					AutomationSignInView(store: store)
					PasswordSaveView(store: store, windowID: child.id)
					WorkspaceRecoveryView(store: store)
				}

					// Under a page in full screen (DEV-991).
					.accessibilityHidden(store.pageFullScreen?.windowID == child.id)
			}
			.modifier(SiteShortcutToast(
				store: store,
				windowID: child.id,
				topInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset,
				trailingInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset
			))
			.modifier(LinkFeedbackToast(
				store: store,
				windowID: child.id,
				topInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset,
				trailingInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset
			))
			.modifier(PagePictureInPictureHostPresentation(store: store, windowID: child.id, engine: engine))
			.modifier(PageFullScreenHostPresentation(store: store, windowID: child.id, surface: surface))

			// Outside full screen, so a quiet request's affordance stays above the full-screen page.
			.modifier(PagePermissionPromptPresentation(store: store, windowID: child.id))
	}
}
