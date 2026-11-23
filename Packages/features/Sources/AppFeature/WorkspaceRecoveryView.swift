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

internal struct WorkspaceRecoveryView: View {
	internal let store: StoreOf<AppFeature>

	internal init(
		store: StoreOf<AppFeature>
	) {
		self.store = store
	}

	internal var body: some View {
		if let error = store.persistenceError {
			VStack(alignment: .leading, spacing: 8) {
				Text(error)
					.font(.callout)
					.textSelection(.enabled)

				HStack {
					Button(String.localized(.appUI.persistence.retry)) {
						store.send(.ui(.retrySave))
					}
					.disabled(store.unsavedOrganization == nil)

					Button(String.localized(.appUI.persistence.export)) {
						store.send(.ui(.exportWorkspace))
					}
				}

				if store.quitAfterSaving {
					HStack {
						Button(String.localized(.appUI.persistence.keepOpen)) {
							store.send(.ui(.cancelQuit))
						}

						Button(String.localized(.appUI.persistence.discard), role: .destructive) {
							store.send(.ui(.discardAndQuit))
						}
					}
				}
			}
			.padding()
			.frame(maxWidth: 560, alignment: .leading)
			.pagePopupSurface()
		}
	}
}
