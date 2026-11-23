import AppUI
import SwiftUI
import _ComposableArchitecture

@main
internal struct AppUIPreviewApp: App {
	private let store: StoreOf<PreviewFeature>

	internal init() {
		self.store = .init(initialState: .init()) { PreviewFeature() }
	}

	internal var body: some Scene {
		Window(Text(localized: .appUI.preview.title), id: "app-ui-preview") {
			PreviewBrowserView(store: store)
				.frame(minWidth: 760, minHeight: 620)
		}
		.windowStyle(.hiddenTitleBar)
		.defaultSize(width: 1120, height: 850)
		.commands {
			CommandGroup(replacing: .newItem) {
				Button(String.localized(.appUI.sidebar.newTab)) { store.send(.ui(.commandOpened)) }
					.keyboardShortcut("t")
				Button(String.localized(.appUI.sidebar.newFolder)) {
					store.send(.ui(.sidebar(.newFolder(nil))))
				}
				.keyboardShortcut("n", modifiers: [.command, .shift])
			}
			CommandGroup(replacing: .undoRedo) {
				Button(String.localized(.appUI.common.undo)) { store.send(.ui(.undo)) }
					.keyboardShortcut("z")
					.disabled(store.undo.isEmpty)
			}
			CommandMenu(Text(localized: .appUI.preview.browserMenu)) {
				Button(String.localized(.appUI.url.search)) { store.send(.ui(.commandOpened)) }
					.keyboardShortcut("l")
				Button(String.localized(.appUI.command.title)) { store.send(.ui(.commandOpened)) }
					.keyboardShortcut("k")
				Button(String.localized(.appUI.sidebar.toggle)) {
					store.send(.ui(.sidebar(.toggleSidebar)))
				}
				.keyboardShortcut("s")
				Divider()
				Button(String.localized(.appUI.preview.reset)) { store.send(.ui(.reset)) }
			}
		}
		Settings {
			PreviewAppearanceView()
		}
	}
}
