import AppKit
import AppUI
import SwiftUI
import _ComposableArchitecture

/// Puts Arx's site permission prompts (DEV-963) on the page's own window: a sheet where the
/// engine's `NSAlert` went, or for a quiet request first an affordance at the window's lower
/// trailing corner that opens it. The sheet closing on its own (Esc) is Cancel, which dismisses
/// and never blocks. Nothing presents while the `ARX_PAGE_PROMPTS` feature flag is off: the engine
/// keeps its own sheet and reports nothing.
internal struct PagePermissionPromptPresentation: ViewModifier {
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
		let prompts = store.pagePermissionPrompts.filter { $0.windowID == windowID }
		let shown = prompts.first(where: \.isRevealed)
		let quiet = prompts.first { !$0.isRevealed }
		content
			.overlay(alignment: .bottomTrailing) {
				if let quiet, let child = store.scope(state: \.pagePermissionPrompts[id: quiet.id], action: \.pagePermissionPrompts[id: quiet.id]) {
					PagePermissionQuietRequest(store: child)
						.padding(16)
				}
			}
			.sheet(
				isPresented: Binding(
					get: { shown != nil },
					set: { presented in
						guard
							!presented,
							let shown,
							store.pagePermissionPrompts[id: shown.id]?.isAnswered == false
						else { return }

						store.send(.pagePermissionPrompts(.element(id: shown.id, action: .ui(.cancel))))
					}
				)
			) {
				if let shown, let child = store.scope(state: \.pagePermissionPrompts[id: shown.id], action: \.pagePermissionPrompts[id: shown.id]) {
					PagePermissionPromptView(store: child)
				}
			}
	}
}

/// A quiet request's affordance: the permission's symbol and "Permission request", which opens
/// the prompt. The page asked quietly, so nothing louder shows until the person clicks it.
private struct PagePermissionQuietRequest: View {
	private let store: StoreOf<PagePermissionPrompt>

	internal init(store: StoreOf<PagePermissionPrompt>) {
		self.store = store
	}

	internal var body: some View {
		Button {
			store.send(.ui(.review))
		} label: {
			Label(
				String.localized(.appUI.pagePrompts.quietRequest),
				systemImage: store.request.permissions.first.map(PagePromptPresentation.symbol) ?? "hand.raised"
			)
		}
		.buttonStyle(.arx(.secondary))
		.help(PagePromptPresentation.title(site: store.request.site, permissions: store.request.permissions))
		.accessibilityHint(Text(PagePromptPresentation.title(site: store.request.site, permissions: store.request.permissions)))
	}
}

internal struct PagePermissionPromptView: View {
	@Bindable
	private var store: StoreOf<PagePermissionPrompt>

	/// Input protection, as the engine's sheet and the app link prompt have: Block and Allow take
	/// no click or key for a moment after the prompt appears or Arx comes back to the front, so a
	/// click or Return meant for the page can't answer it. Esc (Cancel) always works.
	@SwiftUI.State
	private var isArmed: Bool = false

	/// Only the newest timer arms the buttons: coming back to the front restarts the wait.
	@SwiftUI.State
	private var armGeneration: Int = 0

	/// The engine's own sheet waits 500 ms.
	private static let inputProtection: Duration = .milliseconds(500)

	internal init(store: StoreOf<PagePermissionPrompt>) {
		self.store = store
	}

	internal var body: some View {
		PagePermissionPromptCard(
			site: store.request.site,
			embedder: store.request.embedder,
			permissions: store.request.permissions,
			otherRequests: store.request.otherRequests,
			offersAllowOnce: store.request.offersAllowOnce,
			accuracies: store.request.accuracies.map(Self.accuracy),
			accuracy: Binding(
				get: { Self.accuracy(store.accuracy) },
				set: { store.send(.ui(.accuracyChanged(Self.accuracy($0)))) }
			),
			isArmed: isArmed && !store.isAnswered,
			icon: { BrowserSiteIcon(key: nil, size: 56) },
			onCancel: { store.send(.ui(.cancel)) },
			onBlock: { store.send(.ui(.block)) },
			onAllowOnce: { store.send(.ui(.allowOnce)) },
			onAllow: { store.send(.ui(.allow)) }
		)
		.background(ArxModalMetrics.background)
		.task(id: store.id) { await arm() }
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
			Task { await arm() }
		}
	}

	private func arm() async {
		armGeneration += 1
		let generation = armGeneration
		isArmed = false
		do {
			try await Task.sleep(for: Self.inputProtection)
		} catch {
			return
		}
		guard generation == armGeneration else { return }
		isArmed = true
	}

	private static func accuracy(
		_ accuracy: PagePermissionRequest.Accuracy
	) -> PagePermissionPromptCard<BrowserSiteIcon>.Accuracy {
		switch accuracy {
		case .approximate: .approximate
		case .precise: .precise
		}
	}

	private static func accuracy(
		_ accuracy: PagePermissionPromptCard<BrowserSiteIcon>.Accuracy
	) -> PagePermissionRequest.Accuracy {
		switch accuracy {
		case .approximate: .approximate
		case .precise: .precise
		}
	}
}
