import AgentToolsClient
import BrowserAutomationClient
import _ComposableArchitecture

/// The `arx` command, the MCP switch and the agent apps, shared by onboarding's
/// "Outside agents" page and Settings.
///
/// Nothing changes without a click. Install, Update and Uninstall act on the command;
/// adding Arx to an agent app first shows the exact file and change, and only Add in that
/// review writes it. The MCP switch is owned by the parent, which supplies ``State/mcp``
/// and receives ``Action/Delegate/setMCPEnabled(_:)``.
@Reducer
public struct OutsideAgents {
	@ObservableState
	public struct State: Equatable, Sendable {
		/// The installed command, `nil` until the first check.
		public var tool: CommandLineToolClient.Status?

		/// What the command's buttons are doing now.
		public var toolActivity: ToolActivity?

		/// Whether the last Install, Update or Uninstall failed.
		public var toolFailed: Bool

		/// The MCP server, supplied by the parent. Off by default.
		public var mcp: MCPStatus

		/// Every supported agent app, `nil` until the first check.
		public var apps: [AgentApp]?

		/// The app whose change is shown, waiting for Add or Cancel.
		public var review: AgentSetup.Agent?

		/// The app being changed now.
		public var adding: AgentSetup.Agent?

		/// The app whose last change failed.
		public var failedAgent: AgentSetup.Agent?

		public init(
			tool: CommandLineToolClient.Status? = nil,
			toolActivity: ToolActivity? = nil,
			toolFailed: Bool = false,
			mcp: MCPStatus = .off,
			apps: [AgentApp]? = nil,
			review: AgentSetup.Agent? = nil,
			adding: AgentSetup.Agent? = nil,
			failedAgent: AgentSetup.Agent? = nil
		) {
			self.tool = tool
			self.toolActivity = toolActivity
			self.toolFailed = toolFailed
			self.mcp = mcp
			self.apps = apps
			self.review = review
			self.adding = adding
			self.failedAgent = failedAgent
		}

		/// Whether the command is at `~/.local/bin/arx`, current or not.
		public var isToolInstalled: Bool {
			switch tool?.installation {
			case .current, .outdated: true
			case .unavailable, .notInstalled, .blocked, nil: false
			}
		}

		/// Why agents can't be added yet, or `nil` when they can.
		public var addBlocker: AddBlocker? {
			guard isToolInstalled
			else { return .needsTool }

			guard mcp == .on
			else { return .needsMCP }

			return nil
		}

		/// The app under review, when it still has a change to make.
		public var reviewedApp: AgentApp? {
			guard let review
			else { return nil }

			return apps?.first { $0.agent == review && $0.change != nil }
		}
	}

	public enum ToolActivity: Equatable, Sendable {
		case installing
		case uninstalling
	}

	public enum MCPStatus: Equatable, Sendable {
		case off
		case starting
		case on
		case failed
	}

	public enum AddBlocker: Equatable, Sendable {
		/// Every agent runs the installed command.
		case needsTool

		/// The server must run to issue the agent's credential.
		case needsMCP
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			/// The component appeared; checks the command and the apps.
			case task

			/// Install, or Update when the bundled command is newer.
			case installTool

			case uninstallTool

			/// The MCP switch.
			case setMCPEnabled(Bool)

			/// Add… on an app: shows its file and change without writing anything.
			case review(AgentSetup.Agent)

			/// Add in the review: writes the change shown.
			case confirmAdd

			/// Cancel in the review.
			case cancelReview

			/// Copy on the PATH line or an app's setup snippet.
			case copy(String)
		}

		@CasePathable
		public enum Event: Sendable {
			/// The app became active again; the person may have changed things in a terminal.
			case applicationBecameActive
			case toolChecked(CommandLineToolClient.Status)
			case toolChanged(succeeded: Bool)
			case appsDetected([AgentApp])
			case added(AgentSetup.Agent, succeeded: Bool)
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// The parent turns the MCP server on or off and reports it back through ``State/mcp``.
			case setMCPEnabled(Bool)

			/// Arx was added to the app's configuration; the parent issues its credential.
			case connect(AgentSetup.Agent)

			/// The parent puts the text on the pasteboard.
			case copy(String)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.agentApps)
	private var agentApps

	@Dependency(\.commandLineTool)
	private var commandLineTool

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.task) { _ in
			refresh()
		}

		Pullback(\.event.applicationBecameActive) { state in
			guard state.toolActivity == nil, state.adding == nil
			else { return .none }

			return refresh()
		}

		Pullback(\.event.toolChecked) { state, status in
			state.tool = status
			return .none
		}

		Pullback(\.event.appsDetected) { state, apps in
			state.apps = apps
			return .none
		}

		Pullback(\.ui.installTool) { state in
			guard
				state.toolActivity == nil,
				state.tool?.installation == .notInstalled || state.tool?.installation == .outdated
			else { return .none }

			state.toolActivity = .installing
			state.toolFailed = false
			return .run { [commandLineTool] send in
				do {
					try await commandLineTool.install()
					await send(.event(.toolChanged(succeeded: true)))
				} catch {
					await send(.event(.toolChanged(succeeded: false)))
				}
			}
		}

		Pullback(\.ui.uninstallTool) { state in
			guard state.toolActivity == nil, state.isToolInstalled
			else { return .none }

			state.toolActivity = .uninstalling
			state.toolFailed = false
			return .run { [commandLineTool] send in
				do {
					try await commandLineTool.uninstall()
					await send(.event(.toolChanged(succeeded: true)))
				} catch {
					await send(.event(.toolChanged(succeeded: false)))
				}
			}
		}

		Pullback(\.event.toolChanged) { state, succeeded in
			state.toolActivity = nil
			state.toolFailed = !succeeded
			return checkTool()
		}

		Pullback(\.ui.setMCPEnabled) { state, isEnabled in
			let isOn: Bool = state.mcp == .on || state.mcp == .starting
			guard isEnabled != isOn
			else { return .none }

			state.mcp = isEnabled ? .starting : .off
			return .send(.delegate(.setMCPEnabled(isEnabled)))
		}

		Pullback(\.ui.review) { state, agent in
			guard
				state.addBlocker == nil,
				state.adding == nil,
				state.apps?.first(where: { $0.agent == agent })?.change != nil
			else { return .none }

			state.review = agent
			state.failedAgent = nil
			return .none
		}

		Pullback(\.ui.cancelReview) { state in
			state.review = nil
			return .none
		}

		// Writing happens only here, for the app whose change the review showed.
		Pullback(\.ui.confirmAdd) { state in
			guard
				let app = state.reviewedApp,
				state.addBlocker == nil,
				state.adding == nil
			else { return .none }

			state.review = nil
			state.adding = app.agent
			return .run { [agentApps] send in
				do {
					try await agentApps.add(app.agent)
					await send(.event(.added(app.agent, succeeded: true)))
				} catch {
					await send(.event(.added(app.agent, succeeded: false)))
				}
			}
		}

		Pullback(\.event.added) { state, value in
			let (agent, succeeded) = value
			state.adding = nil
			guard succeeded else {
				state.failedAgent = agent
				return detectApps()
			}

			return .merge(
				.send(.delegate(.connect(agent))),
				detectApps()
			)
		}

		Pullback(\.ui.copy) { _, text in
			.send(.delegate(.copy(text)))
		}
	}

	/// Cancels pending checks, so a parent can drop this state.
	public static func cancelInFlightWork<Action>() -> Effect<Action> {
		.merge(
			.cancel(id: Cancellation.tool),
			.cancel(id: Cancellation.apps)
		)
	}

	/// The command first, then the apps, so results arrive in a fixed order.
	private func refresh() -> Effect<Action> {
		.concatenate(checkTool(), detectApps())
	}

	private func checkTool() -> Effect<Action> {
		.run { [commandLineTool] send in
			await send(.event(.toolChecked(commandLineTool.status())))
		}
		.cancellable(id: Cancellation.tool, cancelInFlight: true)
	}

	private func detectApps() -> Effect<Action> {
		.run { [agentApps] send in
			await send(.event(.appsDetected(agentApps.detect())))
		}
		.cancellable(id: Cancellation.apps, cancelInFlight: true)
	}

	private enum Cancellation: Hashable {
		case tool
		case apps
	}
}
