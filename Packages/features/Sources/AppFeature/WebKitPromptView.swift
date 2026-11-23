import AppKit
import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Puts the fallback prompt (DEV-877) on the page's window as a sheet, like the app-link prompt.
internal struct WebKitPromptPresentation: ViewModifier {
	@Bindable
	private var store: StoreOf<AppFeature>

	private let windowID: UUID

	internal init(
		store: StoreOf<AppFeature>,
		windowID: UUID
	) {
		self.store = store
		self.windowID = windowID
	}

	internal func body(content: Content) -> some View {
		let isPresented = store.webKitPrompt?.windowID == windowID
		content.sheet(
			isPresented: Binding(
				get: { isPresented },
				set: { presented in

					// The sheet closing on its own (Escape) is Stay on Page.
					if !presented, store.webKitPrompt?.windowID == windowID {
						store.send(.webKitPrompt(.ui(.stayButtonTapped)))
					}
				}
			)
		) {
			if let child = store.scope(state: \.webKitPrompt, action: \.webKitPrompt) {
				WebKitPromptView(store: child)
			}
		}
	}
}

internal struct WebKitPromptView: View {
	private let store: StoreOf<WebKitPrompt>

	internal init(store: StoreOf<WebKitPrompt>) {
		self.store = store
	}

	internal var body: some View {
		switch store.kind {
		case .offer: offer
		case let .unavailable(app): unavailable(app)
		}
	}

	private var offer: some View {
		AppLinkPromptCard(
			icon: nil,
			symbol: "play.tv",
			title: String.localized(.appUI.webKitPrompt.title(store.host)),
			source: store.host,
			link: store.request.url.absoluteString,
			details: {
				Text(localized: .appUI.webKitPrompt.message)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				dontAskAgain
			},
			actions: {
				// Stay first, the main action last, as the app-link prompt orders them.
				AppLinkPromptButton(String.localized(.appUI.webKitPrompt.stay), keyHint: .escape) {
					store.send(.ui(.stayButtonTapped))
				}
				.keyboardShortcut(.cancelAction)
				AppLinkPromptButton(
					String.localized(.appUI.webKitPrompt.open),
					prominence: .primary,
					keyHint: .return
				) {
					store.send(.ui(.openInWebKitButtonTapped))
				}
				.keyboardShortcut(.defaultAction)

				// Don't ask again keeps the page here; it means nothing with Open in WebKit.
				.disabled(store.dontAskAgain)
			}
		)
	}

	/// WebKit pages are off (DEV-1000): why the page can't play, and its app when there is one.
	private func unavailable(_ app: WebKitPrompt.SiteApp?) -> some View {
		AppLinkPromptCard(
			icon: app?.path.map { NSWorkspace.shared.icon(forFile: $0) },
			symbol: "play.slash",
			title: String.localized(.appUI.webKitPrompt.unavailableTitle(store.host)),
			source: store.host,
			link: store.request.url.absoluteString,
			details: {
				Text(localized: .appUI.webKitPrompt.unavailableMessage)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				dontAskAgain
			},
			actions: {
				if let app {
					AppLinkPromptButton(String.localized(.appUI.webKitPrompt.ok), keyHint: .escape) {
						store.send(.ui(.stayButtonTapped))
					}
					.keyboardShortcut(.cancelAction)
					AppLinkPromptButton(
						String.localized(.appUI.webKitPrompt.openApp(app.name)),
						prominence: .primary,
						keyHint: .return
					) {
						store.send(.ui(.openAppButtonTapped))
					}
					.keyboardShortcut(.defaultAction)
				} else {
					AppLinkPromptButton(
						String.localized(.appUI.webKitPrompt.ok),
						prominence: .primary,
						keyHint: .return
					) {
						store.send(.ui(.stayButtonTapped))
					}
					.keyboardShortcut(.defaultAction)
				}
			}
		)
	}

	private var dontAskAgain: some View {
		Toggle(
			String.localized(.appUI.webKitPrompt.dontAsk),
			isOn: Binding(
				get: { store.dontAskAgain },
				set: { store.send(.ui(.dontAskAgainChanged($0))) }
			)
		)
		.toggleStyle(.checkbox)
	}
}
