import AppKit
import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Puts "Arx can't open this" for a `chrome://` or `arc://` link (DEV-1193) on its window as a
/// sheet, like the app-link prompt.
internal struct BrowserLinkPromptPresentation: ViewModifier {
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
		let isPresented = store.browserLinkPrompt?.windowID == windowID
		content.sheet(
			isPresented: Binding(
				get: { isPresented },
				set: { presented in

					// The sheet closing on its own (Escape) is OK.
					if !presented, store.browserLinkPrompt?.windowID == windowID {
						store.send(.browserLinkPrompt(.ui(.dismissButtonTapped)))
					}
				}
			)
		) {
			if let child = store.scope(state: \.browserLinkPrompt, action: \.browserLinkPrompt) {
				BrowserLinkPromptView(store: child)
			}
		}
	}
}

internal struct BrowserLinkPromptView: View {
	private let store: StoreOf<BrowserLinkPrompt>

	internal init(store: StoreOf<BrowserLinkPrompt>) {
		self.store = store
	}

	private var browserName: String { store.link.browser.name }

	internal var body: some View {
		cannotOpen
	}

	private var cannotOpen: some View {
		AppLinkPromptCard(
			icon: nil,
			symbol: "nosign",
			title: String.localized(.appUI.browserLinks.cannotOpenTitle),
			source: sourceText,
			link: store.link.url.absoluteString,
			details: {
				Text(localized: .appUI.browserLinks.cannotOpenMessage(browserName))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			},
			actions: {
				AppLinkPromptButton(
					String.localized(.appUI.webKitPrompt.ok),
					prominence: .primary,
					keyHint: .return
				) {
					store.send(.ui(.dismissButtonTapped))
				}
				.keyboardShortcut(.defaultAction)
			}
		)
	}

	private var sourceText: String {
		switch store.source {
		case .page: String.localized(.appUI.browserLinks.fromPage)
		case .otherApp: String.localized(.appUI.browserLinks.fromOtherApp)
		}
	}
}
