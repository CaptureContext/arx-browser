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

/// Downloads are shared across windows, so each window points them at its own profile as it shows them.
internal struct AppLibraryDownloadsPanel: View {
	internal let store: StoreOf<AppFeature>
	internal let windowID: UUID

	internal init(
		store: StoreOf<AppFeature>,
		windowID: UUID
	) {
		self.store = store
		self.windowID = windowID
	}

	internal var body: some View {
		DownloadsPanelView(
			store: store.scope(state: \.downloads, action: \.downloads),
			profiles: store.workspace.profiles
		)
			.onAppear { store.send(.ui(.downloadsPanelAppeared(windowID))) }
	}
}
