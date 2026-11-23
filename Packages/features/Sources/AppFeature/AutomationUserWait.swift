import BrowserAutomationClient
import BrowserCore
import Foundation
import _ComposableArchitecture

extension BrowserAutomation {
	/// Tells the request's call that Arx is asking the user, so the agent hears it at once and
	/// the request stays open until they answer (DEV-1024).
	internal func waitForUser(
		_ id: UUID,
		kind: AutomationUserWait.Kind,
		state: State
	) -> Effect<Action> {
		guard let operation = state.automation.pending[id]?.request.operation else { return .none }
		let wait = AutomationUserWait(kind: kind, question: operation.userQuestion(kind))
		return .run { [control] _ in
			await control.waitForUser(id, wait)
		}
	}
}

extension AutomationOperation {
	/// What the user is asked in Arx, as a phrase the agent can pass on. It names the kind of
	/// request only: never page content, values, files or what the agent typed.
	internal func userQuestion(_ kind: AutomationUserWait.Kind) -> String {
		if kind == .extensionReview { return "review installing the extension in Arx" }
		let action: String = switch self {
		case let .command(command): "the \(command.action.rawValue) command"
		case .click: "a click"
		case let .form(request) where request.kind == .upload: "uploading \(request.values?.count ?? 0) file(s)"
		case let .form(request): "page input (\(request.kind.rawValue))"
		case .scroll: "scrolling"
		case let .batch(plan): "\(plan.steps.count) steps"
		case .findInPage: "finding in the page"
		case let .dialog(request): "answering the page's dialog (\(request.action.rawValue))"
		case let .media(request): "media control (\(request.action.rawValue))"
		case .settings: "a settings change"
		case .script: "running a script"
		case .passwordSignIn: "signing in with a saved password"
		case .inventory, .wait, .capture, .inspect, .signIn, .data, .link, .load, .pdf, .logs: "this request"
		}
		return "approve \(action) in Arx"
	}
}
