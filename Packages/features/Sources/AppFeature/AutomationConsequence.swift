import BrowserCore
import Foundation

extension AppFeature.State {
	/// What the operation pays, sends, posts or deletes, read from the snapshot this session
	/// released for its reference (DEV-1008). Nil for anything that isn't a press, or whose
	/// snapshot is gone: the click check then fails it as a stale reference.
	internal func automationConsequence(
		of operation: AutomationOperation,
		request: AutomationRequest,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date
	) -> AutomationConsequence? {
		let target: AutomationClickRequest
		switch operation {
		case let .click(click):
			target = click

		case let .form(form):
			target = form.target

		case let .script(script):
			let url = snapshots[.init(rawValue: script.targetID)]?.navigation.url
			return AutomationConsequence.of(operation, snapshot: nil, url: url)

		case .inventory, .wait, .command, .capture, .inspect, .scroll, .signIn, .batch, .data, .link, .load,
			.pdf, .findInPage, .dialog, .media, .settings, .logs, .passwordSignIn:
			return nil
		}

		guard let released = releasedInspection(for: request, click: target, now: now)
		else { return nil }

		let url = snapshots[released.result.source.tabID]?.navigation.url
		return AutomationConsequence.of(operation, snapshot: released.result.snapshot, url: url)
	}

	/// A batch's consequential steps, by position. Any one makes the whole batch ask.
	internal func automationStepConsequences(
		of plan: AutomationBatchPlan,
		request: AutomationRequest,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		now: Date
	) -> [Int: AutomationConsequence] {
		var result: [Int: AutomationConsequence] = [:]
		for (offset, step) in plan.steps.enumerated() {
			result[offset] = automationConsequence(of: step, request: request, snapshots: snapshots, now: now)
		}
		return result
	}
}
