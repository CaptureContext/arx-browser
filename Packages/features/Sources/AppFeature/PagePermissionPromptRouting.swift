import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// Arx's site permission prompts on the page's own window (DEV-963), while the `ARX_PAGE_PROMPTS`
/// feature flag has the engine hand them over (ABI56).
///
/// The engine reports a prompt for a tab by its token, and 0 when it goes away: answered,
/// replaced, the page navigated or closed, or another tab took its place. The prompt shows on the
/// window showing that tab, never another one; a page no window shows is dismissed, which never
/// blocks. The answer goes back to the engine for that exact token, and the engine rechecks the
/// source window and the input delay before it decides anything.
@Reducer
internal struct PagePermissionPromptRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	internal init() {}

	internal var body: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.event.pagePermissionPromptChanged) { state, value in
				let (tabID, token) = value

				// A tab has one prompt at a time: a new token replaces it, and 0 withdraws it.
				state.pagePermissionPrompts.removeAll { $0.tabID == tabID }
				guard token != 0 else { return .none }

				let prompt = MainActor.assumeIsolated { [engine] in engine.pagePermissionPrompt(tabID, token) }
				guard let prompt else { return .none }

				guard
					!state.automation.isUnattended,
					let windowID = state.permissionPromptWindow(showing: tabID)
				else { return Self.answer(tabID, token: token, decision: .dismiss, accuracy: nil, engine: engine) }

				state.pagePermissionPrompts.append(
					.init(windowID: windowID, tabID: tabID, request: .init(prompt: prompt))
				)
				return .none
			}

			Reduce { state, action in
				guard case let .pagePermissionPrompts(.element(id, .delegate(.answered(answer)))) = action
				else { return .none }

				guard
					let prompt = state.pagePermissionPrompts.remove(id: id),
					let token = UInt64(answer.token)
				else { return .none }

				return Self.answer(
					prompt.tabID,
					token: token,
					decision: Self.decision(answer.decision),
					accuracy: answer.accuracy.map(Self.accuracy),
					engine: engine
				)
			}
		}
		.forEach(\.pagePermissionPrompts, action: \.pagePermissionPrompts) { PagePermissionPrompt() }
	}

	/// A stale answer needs nothing more: the engine already withdrew that prompt.
	private static func answer(
		_ tabID: BrowserCore.Tab.ID,
		token: UInt64,
		decision: BrowserPagePermissionDecision,
		accuracy: BrowserPagePermissionPrompt.Accuracy?,
		engine: BrowserEngineClient
	) -> Effect<Action> {
		.run { @MainActor _ in
			_ = engine.answerPagePermissionPrompt(tabID, token, decision, accuracy)
		}
	}

	private static func decision(_ decision: PagePermissionPrompt.Decision) -> BrowserPagePermissionDecision {
		switch decision {
		case .allow: .allow
		case .allowOnce: .allowOnce
		case .block: .block
		case .dismiss: .dismiss
		}
	}

	private static func accuracy(_ accuracy: PagePermissionRequest.Accuracy) -> BrowserPagePermissionPrompt.Accuracy {
		switch accuracy {
		case .approximate: .approximate
		case .precise: .precise
		}
	}
}

extension AppFeature.State {
	/// The window showing the tab's page: a main, additional or Little Arx window, or the window
	/// a Peek of it opened over. None for a page floating in Page PiP: its window shows only a
	/// placeholder, and the engine takes no answer away from the page's own window.
	internal func permissionPromptWindow(showing tabID: BrowserCore.Tab.ID) -> UUID? {
		if pagePictureInPicture?.tabID == tabID { return nil }
		if let windowID = windowShowing(tabID) { return windowID }

		return peeks.first { $0.tab.id == tabID && $0.viewer.tab?.id == tabID }?.source.windowID
	}
}
