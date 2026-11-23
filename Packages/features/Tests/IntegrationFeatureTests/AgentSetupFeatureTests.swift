import AppFeature
import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct AgentSetupFeatureTests {
	private func store(replies: LockIsolated<[AgentSetup.Reply]>) -> StoreOf<AppFeature> {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.automation.socketPath = "/tmp/ipc.sock"
		return Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.automationControl = .init(
				credential: { .init(token: "token") },
				replyToAgentSetup: { reply, _ in replies.withValue { $0.append(reply) } }
			)
		}
	}

	@Test
	internal func aRequestOnlyAsksUntilAPersonAnswers() async {
		let replies = LockIsolated<[AgentSetup.Reply]>([])
		let store = store(replies: replies)
		let request = AgentSetup.Request(id: UUID(), agent: .claude)

		await store.send(.automation(.event(.agentSetupRequested(request)))).finish()
		expectNoDifference(store.automation.pendingAgentSetup, request)
		#expect(store.automation.isPresented)
		#expect(store.automationPreferences.clients.isEmpty)
		#expect(replies.value.isEmpty)

		await store.send(.automation(.ui(.declineAgentSetup))).finish()
		#expect(store.automation.pendingAgentSetup == nil)
		#expect(store.automationPreferences.clients.isEmpty)
		expectNoDifference(replies.value, [.init(requestID: request.id, credential: nil)])
	}

	@Test
	internal func approvalCreatesAClientWithNoAccessAndReplacesTheOldOne() async throws {
		let replies = LockIsolated<[AgentSetup.Reply]>([])
		let store = store(replies: replies)
		for _ in 0..<2 {
			let request = AgentSetup.Request(id: UUID(), agent: .codex)
			await store.send(.automation(.event(.agentSetupRequested(request)))).finish()
			await store.send(.automation(.ui(.approveAgentSetup))).finish()
		}
		let clients = store.automationPreferences.clients
		expectNoDifference(clients.map(\.name), ["Codex"])
		let client = try #require(clients.first)
		#expect(!client.allowsRead && !client.allowsManagement && !client.allowsPageInteraction)
		#expect(client.scopes.isEmpty)
		expectNoDifference(replies.value.last?.credential?.clientID, client.id)
		expectNoDifference(replies.value.last?.credential?.token, "token")
	}

	@Test
	internal func unattendedRunsIgnoreRequests() async {
		let replies = LockIsolated<[AgentSetup.Reply]>([])
		let attended = store(replies: replies)
		var state = attended.state
		state.automation.isUnattended = true
		let store = Store(initialState: state) { AppFeature() }
		await store.send(.automation(.event(.agentSetupRequested(.init(id: UUID(), agent: .claude))))).finish()
		#expect(store.automation.pendingAgentSetup == nil)
	}
}
