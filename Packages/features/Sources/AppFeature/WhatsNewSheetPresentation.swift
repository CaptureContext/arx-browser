import AppUpdaterClient
import SettingsFeature
import SwiftUI
import _ComposableArchitecture

/// Puts What's New on the main window as a sheet. Escape, Continue and the link all close it.
internal struct WhatsNewSheetPresentation: ViewModifier {
	@Bindable
	private var store: StoreOf<AppFeature>

	internal init(store: StoreOf<AppFeature>) {
		self.store = store
	}

	internal func body(content: Content) -> some View {
		content.sheet(
			isPresented: Binding(
				get: { store.settings.whatsNew != nil },
				set: { presented in
					if !presented, store.settings.whatsNew != nil {
						store.send(.settings(.ui(.dismissWhatsNew)))
					}
				}
			)
		) {
			if let whatsNew = store.settings.whatsNew {
				WhatsNewView(
					whatsNew: whatsNew,
					openFullNotes: { store.send(.settings(.ui(.openReleaseNotes))) },
					dismiss: { store.send(.settings(.ui(.dismissWhatsNew))) }
				)
			}
		}
	}
}
