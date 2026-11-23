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

/// Whether the address bar shows the whole URL, read in its own body: it depends on the window's
/// organization, which changes with every tab, and the window's views above everything shouldn't.
internal struct ShowsFullURLEnvironment: ViewModifier {
	internal let store: StoreOf<MainFeature>

	internal func body(content: Content) -> some View {
		content.environment(\.showsFullURL, store.showsFullURL)
	}
}
