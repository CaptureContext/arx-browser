import OnboardingFeature
import OutsideAgentsFeature
import _ComposableArchitecture

/// Connects the outside-agents component, in Settings and on onboarding's page, to the
/// MCP server this feature owns.
///
/// The component shows the server's state and asks to change it through its delegate;
/// a connected agent gets its credential through the same path as `arx setup`, with the
/// click in Arx as the approval. Only a visible component is kept in step, so the rest of
/// the app's state doesn't change when nobody is looking at it.
@Reducer
internal struct OutsideAgentsBridge {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.linkSharing)
	private var sharing

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.outsideAgents.delegate.setMCPEnabled) { _, isEnabled in
			.send(.automation(.ui(.enabled(isEnabled))))
		}

		Pullback(\.onboarding.page.outsideAgents.delegate.setMCPEnabled) { _, isEnabled in
			.send(.automation(.ui(.enabled(isEnabled))))
		}

		Pullback(\.outsideAgents.delegate.connect) { _, agent in
			.send(.automation(.ui(.connectAgent(agent))))
		}

		Pullback(\.onboarding.page.outsideAgents.delegate.connect) { _, agent in
			.send(.automation(.ui(.connectAgent(agent))))
		}

		Pullback(\.outsideAgents.delegate.copy) { _, text in
			copy(text)
		}

		Pullback(\.onboarding.page.outsideAgents.delegate.copy) { _, text in
			copy(text)
		}

		Pullback(\.event.applicationBecameActive) { state in
			var effects: [Effect<Action>] = []
			if state.automation.isPresented {
				effects.append(.send(.outsideAgents(.event(.applicationBecameActive))))
			}
			if state.onboarding?.page.outsideAgents != nil {
				effects.append(.send(.onboarding(.page(.outsideAgents(.event(.applicationBecameActive))))))
			}
			return .merge(effects)
		}

		Reduce { state, _ in
			state.mirrorMCPStatus()
			return .none
		}
	}

	private func copy(_ text: String) -> Effect<Action> {
		.run { [sharing] _ in _ = await sharing.copy(text) }
	}
}

extension AppFeature.State {
	/// The MCP server as the component shows it.
	internal var mcpStatus: OutsideAgents.MCPStatus {
		guard automationPreferences.isEnabled
		else { return .off }

		if automation.error != nil {
			return .failed
		}

		return automation.socketPath == nil ? .starting : .on
	}

	/// Copies the server's state into each visible component, writing only on a change.
	fileprivate mutating func mirrorMCPStatus() {
		let status: OutsideAgents.MCPStatus = mcpStatus
		if automation.isPresented, outsideAgents.mcp != status {
			outsideAgents.mcp = status
		}
		if onboarding?.page.outsideAgents?.mcp != nil, onboarding?.page.outsideAgents?.mcp != status {
			onboarding?.page.modify(\.outsideAgents) { $0.mcp = status }
		}
	}
}
