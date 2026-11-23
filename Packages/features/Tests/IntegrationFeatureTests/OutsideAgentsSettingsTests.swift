import AgentToolsClient
import AppFeature
import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import OnboardingFeature
import OutsideAgentsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// The outside-agents component in Settings and on onboarding's page, driving the MCP
/// server AppFeature owns. Every client is a double: nothing reaches the file system.
@Suite(.dependencies)
@MainActor
internal struct OutsideAgentsSettingsTests {
	private func store(
		replies: LockIsolated<[AgentSetup.Reply]> = .init([]),
		starts: LockIsolated<Int> = .init(0)
	) -> StoreOf<AppFeature> {
		let organization = IntegrationFeatureTests().fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		return Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.automationControl = .init(
				start: {
					starts.withValue { $0 += 1 }
					return "/tmp/arx-test.sock"
				},
				credential: { .init(token: "token") },
				replyToAgentSetup: { reply, _ in replies.withValue { $0.append(reply) } }
			)
			$0.commandLineTool = .init(
				status: { .init(installation: .current, isOnPath: true) },
				install: {},
				uninstall: {}
			)
			$0.agentApps = .init(detect: { [] }, add: { _ in })
		}
	}

	@Test
	internal func mcpIsOffByDefault() {
		#expect(AutomationPreferences().isEnabled == false)
		#expect(BrowserPreferences().automation.isEnabled == false)
		#expect(OutsideAgents.State().mcp == .off)

		let organization = IntegrationFeatureTests().fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		#expect(state.outsideAgents.mcp == .off)
		#expect(state.automation.socketPath == nil)
	}

	@Test
	internal func theSettingsSwitchTurnsTheServerOnAndShowsIt() async {
		let starts: LockIsolated<Int> = .init(0)
		let store = store(starts: starts)
		await store.send(.automation(.ui(.present(true)))).finish()
		#expect(store.outsideAgents.mcp == .off)
		#expect(starts.value == 0)

		await store.send(.outsideAgents(.ui(.setMCPEnabled(true)))).finish()

		#expect(store.automationPreferences.isEnabled)
		#expect(store.automation.socketPath == "/tmp/arx-test.sock")
		#expect(store.outsideAgents.mcp == .on)
		#expect(starts.value == 1)

		await store.send(.outsideAgents(.ui(.setMCPEnabled(false)))).finish()
		#expect(!store.automationPreferences.isEnabled)
		#expect(store.outsideAgents.mcp == .off)
	}

	@Test
	internal func addingAnAgentIssuesItsCredentialWithNoAccess() async throws {
		let replies = LockIsolated<[AgentSetup.Reply]>([])
		let store = store(replies: replies)
		await store.send(.automation(.ui(.present(true)))).finish()
		await store.send(.outsideAgents(.ui(.setMCPEnabled(true)))).finish()

		await store.send(.outsideAgents(.delegate(.connect(.cursor)))).finish()

		let client = try #require(store.automationPreferences.clients.first)
		expectNoDifference(store.automationPreferences.clients.map(\.name), ["Cursor"])
		#expect(client.scopes.isEmpty)
		#expect(client.capabilities.isEmpty)
		expectNoDifference(replies.value.last?.credential?.clientID, client.id)
		expectNoDifference(replies.value.last?.credential?.socket, "/tmp/arx-test.sock")
	}

	@Test
	internal func theOnboardingPageFollowsTheServer() async {
		let starts: LockIsolated<Int> = .init(0)
		let store = store(starts: starts)
		await store.send(.ui(.openOnboardingStep(.outsideAgents))).finish()
		#expect(store.onboarding?.page.outsideAgents?.mcp == .off)
		#expect(starts.value == 0)

		await store.send(.onboarding(.page(.outsideAgents(.ui(.setMCPEnabled(true)))))).finish()

		#expect(store.automationPreferences.isEnabled)
		#expect(store.onboarding?.page.outsideAgents?.mcp == .on)
	}
}
