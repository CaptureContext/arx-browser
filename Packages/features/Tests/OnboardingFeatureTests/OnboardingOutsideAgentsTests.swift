import AgentToolsClient
import BrowserAutomationClient
import BrowserCore
import Foundation
import OnboardingFeature
import OutsideAgentsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// Onboarding's "Outside agents" page. Every client is a double that records what it
/// was asked to do, so nothing is installed or written.
@Suite(.dependencies)
@MainActor
internal struct OnboardingOutsideAgentsTests {
	private static let earlierSteps: [OnboardingStep] = [.welcome, .tour, .migration]

	private static let cursor: AgentApp = .init(
		agent: .cursor,
		isInstalled: true,
		isConfigured: false,
		change: .file(path: "~/.cursor/mcp.json", entry: #"{"mcpServers":{"arx":{}}}"#),
		snippet: #"{"mcpServers":{"arx":{}}}"#
	)

	private static let codex: AgentApp = .init(
		agent: .codex,
		isInstalled: false,
		isConfigured: false,
		change: nil,
		snippet: "[mcp_servers.arx]"
	)

	// MARK: - Opening

	@Test
	internal func thePageOpensWithMCPOffAndChecksTheCommandAndApps() async {
		let world: AgentToolsDouble = .init()
		let store = TestStore(initialState: OnboardingFeature.State(completedSteps: Self.earlierSteps)) {
			OnboardingFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		#expect(store.state.page == .outsideAgents(.init()))
		#expect(store.state.page.outsideAgents?.mcp == .off)

		await store.send(.page(.outsideAgents(.ui(.task))))
		await store.receive(\.page.outsideAgents.event.toolChecked) {
			$0.page.modify(\.outsideAgents) { $0.tool = .init(installation: .notInstalled, isOnPath: false) }
		}
		await store.receive(\.page.outsideAgents.event.appsDetected) {
			$0.page.modify(\.outsideAgents) { $0.apps = [Self.cursor, Self.codex] }
		}
		#expect(store.state.page.outsideAgents?.addBlocker == .needsTool)
		#expect(world.added.value.isEmpty)
		#expect(world.installs.value == 0)
	}

	// MARK: - MCP switch

	@Test
	internal func theSwitchOnlyAsksTheParent() async {
		let store = TestStore(initialState: page()) {
			OnboardingFeature()
		}

		await store.send(.page(.outsideAgents(.ui(.setMCPEnabled(true))))) {
			$0.page.modify(\.outsideAgents) { $0.mcp = .starting }
		}
		await store.receive(\.page.outsideAgents.delegate.setMCPEnabled, true)

		// Asking again while it starts is a no-op.
		await store.send(.page(.outsideAgents(.ui(.setMCPEnabled(true)))))

		await store.send(.page(.outsideAgents(.ui(.setMCPEnabled(false))))) {
			$0.page.modify(\.outsideAgents) { $0.mcp = .off }
		}
		await store.receive(\.page.outsideAgents.delegate.setMCPEnabled, false)
	}

	// MARK: - Command-line tool

	@Test
	internal func installUpdateAndUninstallGoThroughTheClient() async {
		let world: AgentToolsDouble = .init()
		let store = TestStore(initialState: page(tool: .init(installation: .notInstalled, isOnPath: true))) {
			OnboardingFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.page(.outsideAgents(.ui(.installTool)))) {
			$0.page.modify(\.outsideAgents) { $0.toolActivity = .installing }
		}
		#expect(!store.state.canClose)
		await store.receive(\.page.outsideAgents.event.toolChanged) {
			$0.page.modify(\.outsideAgents) { $0.toolActivity = nil }
		}
		await store.receive(\.page.outsideAgents.event.toolChecked) {
			$0.page.modify(\.outsideAgents) { $0.tool = .init(installation: .current, isOnPath: false) }
		}
		#expect(store.state.canClose)
		#expect(world.installs.value == 1)

		// Install on a current copy does nothing; Update appears only when it's outdated.
		await store.send(.page(.outsideAgents(.ui(.installTool))))
		world.installation.setValue(.outdated)
		await store.send(.page(.outsideAgents(.event(.applicationBecameActive))))
		await store.receive(\.page.outsideAgents.event.toolChecked) {
			$0.page.modify(\.outsideAgents) { $0.tool = .init(installation: .outdated, isOnPath: false) }
		}
		await store.receive(\.page.outsideAgents.event.appsDetected)
		await store.send(.page(.outsideAgents(.ui(.installTool)))) {
			$0.page.modify(\.outsideAgents) { $0.toolActivity = .installing }
		}
		await store.receive(\.page.outsideAgents.event.toolChanged) {
			$0.page.modify(\.outsideAgents) { $0.toolActivity = nil }
		}
		await store.receive(\.page.outsideAgents.event.toolChecked) {
			$0.page.modify(\.outsideAgents) { $0.tool = .init(installation: .current, isOnPath: false) }
		}
		#expect(world.installs.value == 2)

		await store.send(.page(.outsideAgents(.ui(.uninstallTool)))) {
			$0.page.modify(\.outsideAgents) { $0.toolActivity = .uninstalling }
		}
		await store.receive(\.page.outsideAgents.event.toolChanged) {
			$0.page.modify(\.outsideAgents) { $0.toolActivity = nil }
		}
		await store.receive(\.page.outsideAgents.event.toolChecked) {
			$0.page.modify(\.outsideAgents) { $0.tool = .init(installation: .notInstalled, isOnPath: false) }
		}
		#expect(world.uninstalls.value == 1)
		#expect(store.state.completedSteps == Self.earlierSteps)
	}

	@Test
	internal func aFailedInstallIsShown() async {
		let world: AgentToolsDouble = .init()
		world.installFails.setValue(true)
		let store = TestStore(initialState: page(tool: .init(installation: .notInstalled))) {
			OnboardingFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.page(.outsideAgents(.ui(.installTool)))) {
			$0.page.modify(\.outsideAgents) { $0.toolActivity = .installing }
		}
		await store.receive(\.page.outsideAgents.event.toolChanged) {
			$0.page.modify(\.outsideAgents) {
				$0.toolActivity = nil
				$0.toolFailed = true
			}
		}
		await store.receive(\.page.outsideAgents.event.toolChecked) {
			$0.page.modify(\.outsideAgents) { $0.tool = .init(installation: .notInstalled, isOnPath: false) }
		}
	}

	// MARK: - Agent apps

	@Test
	internal func nothingIsWrittenWithoutConfirmingTheShownChange() async {
		// The test client's `add` is unimplemented, so any write fails the test.
		let store = TestStore(initialState: page(mcp: .on)) {
			OnboardingFeature()
		}

		// Add with nothing under review.
		await store.send(.page(.outsideAgents(.ui(.confirmAdd))))

		// An app with no supported way can't be reviewed.
		await store.send(.page(.outsideAgents(.ui(.review(.codex)))))

		// Reviewing shows the change; Cancel closes it without writing.
		await store.send(.page(.outsideAgents(.ui(.review(.cursor))))) {
			$0.page.modify(\.outsideAgents) { $0.review = .cursor }
		}
		#expect(store.state.page.outsideAgents?.reviewedApp == Self.cursor)
		await store.send(.page(.outsideAgents(.ui(.cancelReview)))) {
			$0.page.modify(\.outsideAgents) { $0.review = nil }
		}
		await store.send(.page(.outsideAgents(.ui(.confirmAdd))))
	}

	@Test
	internal func agentsCantBeAddedUntilTheCommandIsInstalledAndMCPIsOn() async {
		let withoutMCP = TestStore(initialState: page(mcp: .off)) {
			OnboardingFeature()
		}
		#expect(withoutMCP.state.page.outsideAgents?.addBlocker == .needsMCP)
		await withoutMCP.send(.page(.outsideAgents(.ui(.review(.cursor)))))

		let withoutTool = TestStore(initialState: page(tool: .init(installation: .notInstalled), mcp: .on)) {
			OnboardingFeature()
		}
		#expect(withoutTool.state.page.outsideAgents?.addBlocker == .needsTool)
		await withoutTool.send(.page(.outsideAgents(.ui(.review(.cursor)))))
	}

	@Test
	internal func confirmingWritesTheChangeConnectsTheAgentAndRecordsTheStep() async {
		let world: AgentToolsDouble = .init()
		let store = TestStore(initialState: page(mcp: .on)) {
			OnboardingFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.page(.outsideAgents(.ui(.review(.cursor))))) {
			$0.page.modify(\.outsideAgents) { $0.review = .cursor }
		}
		await store.send(.page(.outsideAgents(.ui(.confirmAdd)))) {
			$0.page.modify(\.outsideAgents) {
				$0.review = nil
				$0.adding = .cursor
			}
		}
		#expect(!store.state.canClose)
		await store.receive(\.page.outsideAgents.event.added) {
			$0.page.modify(\.outsideAgents) { $0.adding = nil }
		}
		await store.receive(\.page.outsideAgents.delegate.connect, .cursor) {
			$0.completedSteps = Self.earlierSteps + [.outsideAgents]
		}
		await store.receive(\.delegate.stepCompleted, .outsideAgents)
		var configured: AgentApp = Self.cursor
		configured.isConfigured = true
		await store.receive(\.page.outsideAgents.event.appsDetected) {
			$0.page.modify(\.outsideAgents) { $0.apps = [configured, Self.codex] }
		}
		#expect(world.added.value == [.cursor])
		#expect(store.state.step == .outsideAgents)
	}

	@Test
	internal func aFailedWriteIsShownAndRecordsNothing() async {
		let world: AgentToolsDouble = .init()
		world.addFails.setValue(true)
		let store = TestStore(initialState: page(mcp: .on)) {
			OnboardingFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.page(.outsideAgents(.ui(.review(.cursor))))) {
			$0.page.modify(\.outsideAgents) { $0.review = .cursor }
		}
		await store.send(.page(.outsideAgents(.ui(.confirmAdd)))) {
			$0.page.modify(\.outsideAgents) {
				$0.review = nil
				$0.adding = .cursor
			}
		}
		await store.receive(\.page.outsideAgents.event.added) {
			$0.page.modify(\.outsideAgents) {
				$0.adding = nil
				$0.failedAgent = .cursor
			}
		}
		await store.receive(\.page.outsideAgents.event.appsDetected)
		#expect(store.state.completedSteps == Self.earlierSteps)
	}

	@Test
	internal func copyHandsTheTextToTheParent() async {
		let store = TestStore(initialState: page()) {
			OnboardingFeature()
		}

		await store.send(.page(.outsideAgents(.ui(.copy("export PATH")))))
		await store.receive(\.page.outsideAgents.delegate.copy, "export PATH")
	}

	@Test
	internal func skipMovesOnWithoutRecordingTheStep() async {
		let store = TestStore(initialState: page()) {
			OnboardingFeature()
		}

		await store.send(.ui(.skip)) {
			$0.index = 4
			$0.page = .defaultBrowser(.init())
		}
		#expect(store.state.completedSteps == Self.earlierSteps)
	}

	// MARK: - Helpers

	/// The flow on the outside-agents page, with the command installed and the apps found.
	private func page(
		tool: CommandLineToolClient.Status = .init(installation: .current, isOnPath: true),
		mcp: OutsideAgents.MCPStatus = .off
	) -> OnboardingFeature.State {
		var state = OnboardingFeature.State(completedSteps: Self.earlierSteps)
		state.page = .outsideAgents(.init(tool: tool, mcp: mcp, apps: [Self.cursor, Self.codex]))
		return state
	}
}

/// Records every request instead of touching the file system.
private final class AgentToolsDouble: Sendable {
	internal let installation: LockIsolated<CommandLineToolClient.Installation> = .init(.notInstalled)
	internal let installs: LockIsolated<Int> = .init(0)
	internal let uninstalls: LockIsolated<Int> = .init(0)
	internal let installFails: LockIsolated<Bool> = .init(false)
	internal let added: LockIsolated<[AgentSetup.Agent]> = .init([])
	internal let addFails: LockIsolated<Bool> = .init(false)

	internal func install(into dependencies: inout DependencyValues) {
		dependencies.commandLineTool = .init(
			status: { [self] in .init(installation: installation.value, isOnPath: false) },
			install: { [self] in
				guard !installFails.value
				else { throw CommandLineTool.Failure.occupied }

				installs.withValue { $0 += 1 }
				installation.setValue(.current)
			},
			uninstall: { [self] in
				uninstalls.withValue { $0 += 1 }
				installation.setValue(.notInstalled)
			}
		)
		dependencies.agentApps = .init(
			detect: { [self] in
				[
					.init(
						agent: .cursor,
						isInstalled: true,
						isConfigured: added.value.contains(.cursor),
						change: .file(path: "~/.cursor/mcp.json", entry: #"{"mcpServers":{"arx":{}}}"#),
						snippet: #"{"mcpServers":{"arx":{}}}"#
					),
					.init(agent: .codex, isInstalled: false, isConfigured: false, change: nil, snippet: "[mcp_servers.arx]"),
				]
			},
			add: { [self] agent in
				guard !addFails.value
				else { throw AgentAppsFailure.commandFailed }

				added.withValue { $0.append(agent) }
			}
		)
	}
}
