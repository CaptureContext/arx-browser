import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import Foundation

internal struct AutomationRoutedCommand: Equatable, Sendable {
	internal var command: AutomationCommand
	internal var route: AutomationRoute

	internal init(
		command: AutomationCommand,
		route: AutomationRoute
	) {
		self.command = command
		self.route = route
	}
}

extension AppFeature.State {
	/// Resolves an opted-in `openTab` through the Air Traffic Control resolver that
	/// external links and Route URL use. The routed command replaces the request
	/// before approval, so a person approves, and the run executes, the routed
	/// destination with its revision captured now.
	internal func automationRoute(
		_ command: AutomationCommand,
		clientID: UUID,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) throws(AutomationFailure) -> AutomationRoutedCommand {
		guard
			command.action == .openTab,
			command.route,
			let url = command.url
		else { throw .invalidRequest }
		let clients = automationPreferences.clients
		guard let client = clients.first(where: { $0.id == clientID })
		else { throw .denied }

		// The explicit source space stands in for the current space. A focused private
		// window never supplies it, and private spaces never enter the workspace.
		guard let source = workspace.spaces.first(where: { $0.id.rawValue == command.targetID })
		else { throw .staleTarget }

		let preferences = settings.routingPreferences
		let decision = URLRouter.decide(
			url,
			preferences: preferences,
			organization: workspace,
			currentSpaceID: source.id,
			recentSpaceIDs: recentSpaceIDs
		)
		guard case let .success(target) = decision.result
		else { throw .routeUnresolved }

		// Routing never widens access: the routed space needs its own grant.
		let destination = AutomationInventoryBuilder.item(
			target.spaceID.rawValue,
			kind: .space,
			client: client,
			organization: workspace,
			snapshots: snapshots
		)
		guard let destination else { throw .denied }

		// Little Arx is a visible window, like every other host opening.
		if target.mode == .littleArx {
			guard command.focus, !automation.isUnattended
			else { throw .unsupported }
		}

		let rule = decision.matchedRuleID.flatMap { id in
			preferences.rules.first { $0.id == id }
		}
		return .init(
			command: .init(
				operationID: command.operationID,
				action: target.mode == .littleArx ? .openLittleArx : .openTab,
				targetID: target.spaceID.rawValue,
				expectedRevision: destination.revision,
				url: url,
				focus: command.focus
			),
			route: .init(
				profileID: target.profileID.rawValue,
				spaceID: target.spaceID.rawValue,
				mode: target.mode,
				source: rule == nil ? .fallback : .rule,
				ruleID: rule?.id,
				ruleName: rule?.name
			)
		)
	}
}
