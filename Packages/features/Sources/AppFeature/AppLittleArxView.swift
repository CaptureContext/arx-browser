import AppUI
import BrowserCore
import BrowserSiteIconClient
import BrowserSurfaceClient
import LittleArxFeature
import PeekFeature
import SwiftUI
import ViewerItemFeature
import _ComposableArchitecture

internal struct AppLittleArxView: View {
	private let onCommandHeightChange: (CGFloat) -> Void
	internal let app: StoreOf<AppFeature>
	internal let child: StoreOf<LittleArxFeature>
	internal let surface: BrowserSurfaceClient
	internal let siteIcons: BrowserSiteIconClient

	internal init(
		app: StoreOf<AppFeature>,
		child: StoreOf<LittleArxFeature>,
		surface: BrowserSurfaceClient,
		siteIcons: BrowserSiteIconClient = .init(),
		onCommandHeightChange: @escaping (CGFloat) -> Void
	) {
		self.app = app
		self.child = child
		self.surface = surface
		self.siteIcons = siteIcons
		self.onCommandHeightChange = onCommandHeightChange
	}

	internal var body: some View {
		LittleArxView(
			store: child,
			surface: surface,
			profiles: app.workspace.profiles,
			onCommandHeightChange: onCommandHeightChange,
			destinations: app.workspace.spaces.map { space in
				.init(
					id: space.id,
					profileID: space.profileID,
					name: space.name,
					menuTitle: [
						app.workspace.profiles[id: space.profileID]?.name,
						space.name
					].compactMap { $0 }.joined(separator: " · "),
					icon: space.icon?.rawValue
				)
			},
			// As Page PiP, a drag throws the window to a corner (DEV-1112).
			pictureInPictureDragArea: AnyView(PagePictureInPictureDragArea()),
			// Its header picks the space as Page PiP's does (DEV-1184).
			spaceOptions: child.isPictureInPicture
			? PagePictureInPictureSpacePicker.Option.options(
				spaces: app.workspace.spaces,
				profiles: app.workspace.profiles,
				profileID: child.tab.profileID,
				shortcuts: app.settings.keyboardShortcuts
			)
			: []
		)
		.browserChromeAppearance(child.chromeAppearance)
		.environment(\.browserAccentIsEnabled, ChromeAccent.isEnabled())
		.environment(\.browserChatTab, chatTabContent(store: app, windowID: child.id))
		.environment(\.browserSiteIcons, siteIcons.presentation)
		.modifier(PeekHostPresentation(store: app, windowID: child.id, surface: surface))

		// Outside the Peek modifier, so a Peek opened from Little Arx gets the overlay too.
		.environment(\.browserPageOverlay, pageOverlay(store: app))
		.environment(\.browserSurfaceVisibilityObserver, .init { report in
			app.send(.event(.mediaSurfaceVisibility(child.id, report)))
		})
		.modifier(RoutePreviewPresentation(store: app, windowID: child.id))
		.modifier(AppLinkPromptPresentation(store: app, windowID: child.id))
		.modifier(SendFeedbackSheetPresentation(store: app, host: .window(child.id)))
		.modifier(WebKitPromptPresentation(store: app, windowID: child.id))
		.modifier(BrowserLinkPromptPresentation(store: app, windowID: child.id))
		.modifier(DeviceChooserPresentation(store: app, windowID: child.id))
		.modifier(CastPickerPresentation(store: app, windowID: child.id))
		.environment(\.browserLinkActions, browserLinkActions(store: app, windowID: child.id))

		// The main window's site menu, with what a floating window leaves out (DEV-1257).
		.modifier(FloatingSiteMenuEnvironment(store: app, id: .littleArx(child.id)))
		.overlay(alignment: .bottom) { WorkspaceRecoveryView(store: app) }
		.modifier(SiteShortcutToast(
			store: app,
			windowID: child.id,
			topInset: BrowserMetrics.LittleArx.toolbarHeight + ArxToastMetrics.edgeInset - 4,
			trailingInset: BrowserMetrics.LittleArx.pageInset + ArxToastMetrics.edgeInset - 4
		))
		.modifier(LinkFeedbackToast(
			store: app,
			windowID: child.id,
			topInset: BrowserMetrics.LittleArx.toolbarHeight + ArxToastMetrics.edgeInset - 4,
			trailingInset: BrowserMetrics.LittleArx.pageInset + ArxToastMetrics.edgeInset - 4
		))
		.modifier(PagePictureInPictureHostPresentation(store: app))
		.modifier(PageFullScreenHostPresentation(store: app, windowID: child.id, surface: surface))

		// Outside full screen, so a quiet request's affordance stays above the full-screen page.
		.modifier(PagePermissionPromptPresentation(store: app, windowID: child.id))
	}
}
