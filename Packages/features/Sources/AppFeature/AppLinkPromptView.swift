import AppKit
import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Puts Arx's app-link prompt on the page's window as a sheet, as Chrome's dialog was.
internal struct AppLinkPromptPresentation: ViewModifier {
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
		let prompt = store.appLinkPrompt
		let isPresented = prompt.map { $0.windowID == windowID && $0.isPresented } ?? false
		content.sheet(
			isPresented: Binding(
				get: { isPresented },
				set: { presented in

					// The sheet closing on its own (Escape) is Cancel.
					if !presented, store.appLinkPrompt?.windowID == windowID {
						store.send(.appLinkPrompt(.ui(.cancel)))
					}
				}
			)
		) {
			if let child = store.scope(state: \.appLinkPrompt, action: \.appLinkPrompt) {
				AppLinkPromptView(store: child)
			}
		}
	}
}

internal struct AppLinkPromptView: View {
	private let store: StoreOf<AppLinkPrompt>

	/// Input protection, as Chrome's external-protocol dialog has: the main button takes no
	/// click for a moment after the prompt appears or Arx comes back to the front, so a click
	/// or Return meant for the page can't land or open. Return then presses the main button
	/// (Maxim's call, DEV-872); Esc is Cancel.
	@SwiftUI.State
	private var isArmed: Bool = false

	/// Only the newest timer arms the button: coming back to the front restarts the wait.
	@SwiftUI.State
	private var armGeneration: Int = 0

	private static let inputProtection: Duration = .milliseconds(600)

	internal init(store: StoreOf<AppLinkPrompt>) {
		self.store = store
	}

	private var landsScript: Bool { store.script != nil }

	private var title: String {
		if store.opensInArx { return String.localized(.appUI.appLinks.openInArxTitle) }
		return landsScript
		? String.localized(.appUI.appLinks.landTitle(store.landingName))
		: String.localized(.appUI.appLinks.openTitle(store.appName))
	}

	private var confirmTitle: String {
		if store.opensInArx { return String.localized(.appUI.appLinks.openInArx) }
		return landsScript
		? String.localized(.appUI.appLinks.landButton(store.landingName))
		: String.localized(.appUI.appLinks.openButton(store.appName))
	}

	/// Portrait (DEV-872): the app's icon and the title, the site and the link, the notes, the
	/// script on request and any failure, then full-width buttons with the primary one last.
	internal var body: some View {
		AppLinkPromptCard(
			icon: store.appPath.flatMap { appLinkIcon(path: $0) },
			symbol: landsScript ? "terminal" : "app",
			title: title,
			source: sourceText,
			link: store.request.link,
			details: { details },
			actions: { buttons }
		)
		.task(id: store.id) { await arm() }
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
			Task { await arm() }
		}
	}

	private var sourceText: String {
		store.request.sourceOrigin.map { String.localized(.appUI.appLinks.requestedBy($0)) }
			?? String.localized(.appUI.appLinks.requestedByPage)
	}

	@ViewBuilder
	private var details: some View {
		notes
		if store.showsScript, let script = store.script {
			Text(script)
				.font(.callout.monospaced())
				.textSelection(.enabled)
				.padding(8)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(.quaternary, in: ArxControlShape())
		}
		if case let .failed(failure) = store.phase {
			failureView(failure)
		}
		if store.phase == .sourceChanged {
			Text(localized: .appUI.appLinks.sourceChanged).foregroundStyle(.red)
		}
		if store.offersAlwaysAllow, store.phase == .asking, let origin = store.request.sourceOrigin {
			Toggle(
				String.localized(.appUI.appLinks.alwaysAllow(origin)),
				isOn: Binding(
					get: { store.alwaysAllow },
					set: { store.send(.ui(.alwaysAllowChanged($0))) }
				)
			)
			.toggleStyle(.checkbox)
		}
		if store.copied {
			Text(localized: .appUI.appLinks.copied).foregroundStyle(.secondary)
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

	@ViewBuilder
	private var notes: some View {
		if store.request.isPrivate {
			Text(localized: .appUI.appLinks.privateNote).foregroundStyle(.secondary)
		} else if let failure = store.failure {
			Text(Self.message(for: failure)).foregroundStyle(.orange)
		} else if landsScript {
			Text(localized: .appUI.appLinks.scriptExplanation).foregroundStyle(.secondary)
		}
	}

	private func failureView(_ failure: AppLinkPrompt.Failure) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			switch failure {
			case let .script(status, message, log):
				Text(localized: .appUI.appLinks.scriptFailed(String(status)))
				if !message.isEmpty {
					Text(message).font(.callout.monospaced()).lineLimit(6).textSelection(.enabled)
				}
				logLine(log)
			case let .timedOut(log):
				Text(localized: .appUI.appLinks.scriptTimedOut)
				logLine(log)
			case let .unavailable(reason):
				Text(localized: .appUI.appLinks.scriptUnavailable(reason))
			case .appDidNotOpen:
				Text(localized: .appUI.appLinks.appDidNotOpen)
			case let .applicationMissing(application):
				Text(localized: .appUI.appLinks.applicationMissing(application.name))
				Text(application.path)
					.font(.caption.monospaced())
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
			}
		}
		.foregroundStyle(.red)
	}

	@ViewBuilder
	private func logLine(_ log: URL?) -> some View {
		if let log {
			Text(localized: .appUI.appLinks.log(log.path(percentEncoded: false)))
				.font(.caption)
				.foregroundStyle(.secondary)
				.textSelection(.enabled)
		}
	}

	/// Show Script, Cancel, then the main button last. Return presses the main button, the
	/// default for the keyboard and VoiceOver, once input protection has armed it; Esc is Cancel.
	@ViewBuilder
	private var buttons: some View {
		if store.phase == .running {
			HStack(spacing: 8) {
				ProgressView().controlSize(.small)
				Text(localized: landsScript ? .appUI.appLinks.landing : .appUI.appLinks.opening)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, minHeight: 36)
		} else {
			if store.script != nil {
				AppLinkPromptButton(
					String.localized(store.showsScript ? .appUI.appLinks.hideScript : .appUI.appLinks.showScript)
				) {
					store.send(.ui(.toggleScript))
				}
			}

			// DEV-1193: the other of Open in Arx and Open ‹app›, for a page of another browser
			// Arx has a place for. Input protection holds it as it holds the main button, and
			// Always allow commits to the main action, which it's the one to remember.
			if store.phase == .asking, store.arxPlace != nil {
				Group {
					if store.opensInArx {
						AppLinkPromptButton(String.localized(.appUI.appLinks.openButton(store.appName))) {
							store.send(.ui(.openApp))
						}
					} else {
						AppLinkPromptButton(String.localized(.appUI.appLinks.openInArx)) {
							store.send(.ui(.openInArx))
						}
					}
				}
				.disabled(!isArmed || store.alwaysAllow)
			}
			AppLinkPromptButton(String.localized(.appUI.appLinks.cancel), keyHint: .escape) {
				store.send(.ui(.cancel))
			}
			.keyboardShortcut(.cancelAction)
			switch store.phase {
			case .asking:
				confirm(confirmTitle) { store.send(.ui(.confirm)) }
			case .failed(.applicationMissing):
				// The chosen app is gone: System default only when the person says so.
				confirm(String.localized(.appUI.appLinks.openWithSystemDefault)) {
					store.send(.ui(.openWithSystemDefault))
				}
			case .failed:
				// Open app is the fallback whatever went wrong.
				confirm(String.localized(.appUI.appLinks.openButton(store.appName))) {
					store.send(.ui(.openApp))
				}
			case .running, .sourceChanged:
				EmptyView()
			}
		}
	}

	/// The main action, with Copy Link in the menu beside it. Copying leaves the prompt open.
	private func confirm(
		_ title: String,
		action: @escaping () -> Void
	) -> some View {
		AppLinkPromptConfirm(
			title,
			copyTitle: String.localized(.appUI.appLinks.copyLink),
			onConfirm: action,
			onCopy: { store.send(.ui(.copyLink)) }
		)
		.disabled(!isArmed)
	}

	internal static func message(for failure: AppLinkError) -> String {
		switch failure {
		case .malformed, .invalidDefinition, .invalidScheme, .reservedScheme, .invalidHost, .invalidPath:
			String.localized(.appUI.appLinks.invalid.malformed)
		case .schemeMismatch: String.localized(.appUI.appLinks.invalid.schemeMismatch)
		case .controlCharacters: String.localized(.appUI.appLinks.invalid.controlCharacters)
		case .tooLong: String.localized(.appUI.appLinks.invalid.tooLong)
		}
	}
}
