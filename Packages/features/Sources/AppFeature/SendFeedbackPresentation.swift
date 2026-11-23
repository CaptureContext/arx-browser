import BrowserCore
import FeedbackFeature
import SwiftUI
import _ComposableArchitecture

/// Send Feedback (DEV-1284): opened from the Help menu, the command bar or its shortcut, shown as
/// a card over the window it was asked from, the Settings window included (DEV-1308), or the main
/// window when it came from elsewhere, and closed by the card. With the `ARX_FEEDBACK_FORM`
/// feature flag off, Send Feedback opens Report a Problem instead.
@Reducer
internal struct SendFeedbackPresentation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		EmptyReducer()
			.ifLet(\.feedback, action: \.feedback) { SendFeedbackFeature() }

		Pullback(\.ui.sendFeedback) { state, requested in
			guard FeatureFlag.feedbackForm.isOn()
			else { return .send(.ui(.reportProblem)) }

			// An open card keeps what's typed and moves to the window it was asked from, so a
			// card whose window closed under it comes back.
			let host: AppFeature.FeedbackHost
			switch requested {
			case .settings where state.settingsIsOpen:
				host = .settings

			case let .window(id) where id != state.main.id && (state.windows[id: id] != nil || state.littleWindows[id: id] != nil):
				host = .window(id)

			default:
				guard state.openMainWindow()
				else { return .none }

				host = .window(state.main.id)
			}
			state.feedbackHost = host
			if state.feedback == nil { state.feedback = .init() }
			return .none
		}

		// The card goes with the Settings window, its draft kept for next time. A report on its
		// way, or a file being read, can't close yet: the card moves to the main window instead,
		// so its outcome still shows.
		Pullback(\.ui.closeSettings) { state in
			guard let feedback = state.feedback, state.feedbackHost == .settings
			else { return .none }

			guard feedback.canClose
			else { return .send(.ui(.sendFeedback(nil))) }

			return .send(.feedback(.ui(.close)))
		}

		Pullback(\.feedback.delegate.close) { state in
			state.dismissFeedback()
			return .none
		}

		Pullback(\.feedback.delegate.sent) { state in
			state.dismissFeedback()
			return .none
		}

		// The privacy policy and GitHub's issue forms open in a tab of the main window; the card
		// has kept the draft and closed, so the page isn't behind it.
		Pullback(\.feedback.delegate.open) { state, url in
			state.dismissFeedback()
			guard state.openMainWindow()
			else { return .none }

			state.appActivationRequest += 1
			state.focusedWindowID = state.main.id
			return .send(.main(.ui(.openInNewTab(url))))
		}
	}
}

extension AppFeature.State {
	/// The window a command asks Send Feedback for: its browser window, a Peek's, or Settings.
	internal func feedbackHost(for target: AppFeature.CommandTarget) -> AppFeature.FeedbackHost? {
		switch target {
		case let .window(id, _):
			return .window(id)

		case let .peek(id):
			guard let windowID = peeks[id: id]?.source.windowID
			else { return nil }

			return .window(windowID)

		case .settings:
			return .settings

		case .application, .onboarding, .downloads, .taskManager:
			return nil
		}
	}

	fileprivate mutating func dismissFeedback() {
		feedback = nil
		feedbackHost = nil
	}
}

extension AppFeature {
	/// The window the Send Feedback card is on (DEV-1308).
	public enum FeedbackHost: Hashable, Sendable {
		/// A browser window or Little Arx.
		case window(UUID)

		/// The Settings window.
		case settings
	}
}

/// Puts the Send Feedback card on its window as a sheet, as the open-in-app prompt is, so typing,
/// paste, drop and the file picker belong to the card. Escape is Cancel.
internal struct SendFeedbackSheetPresentation: ViewModifier {
	@Bindable
	private var store: StoreOf<AppFeature>

	private let host: AppFeature.FeedbackHost

	internal init(
		store: StoreOf<AppFeature>,
		host: AppFeature.FeedbackHost
	) {
		self.store = store
		self.host = host
	}

	internal func body(content: Content) -> some View {
		let isPresented: Bool = store.feedback != nil && store.feedbackHost == host
		content.sheet(
			isPresented: Binding(
				get: { isPresented },
				set: { presented in
					if !presented, store.feedback != nil, store.feedbackHost == host {
						store.send(.feedback(.ui(.close)))
					}
				}
			)
		) {
			if let child = store.scope(state: \.feedback, action: \.feedback) {
				SendFeedbackView(store: child)
			}
		}
	}
}
