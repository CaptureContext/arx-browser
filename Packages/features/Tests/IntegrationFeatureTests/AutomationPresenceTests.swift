@testable import AppFeature
import AppUI
import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// The page's agent indicator and its Stop (DEV-899).
@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationPresenceTests {
	private let now: Date = .init(timeIntervalSince1970: 1_000)

	@Test
	internal func onlyPageChangingOperationsNameATab() throws {
		let state = fixture()
		let tab = try #require(state.workspace.tabs.first)
		let click: AutomationOperation = .click(.init(
			operationID: UUID(1),
			targetID: tab.id.rawValue,
			expectedRevision: "r",
			snapshotID: "s",
			reference: "x"
		))
		let inspect: AutomationOperation = .inspect(.init(targetID: tab.id.rawValue, expectedRevision: "r"))
		let reload: AutomationOperation = .command(.init(
			operationID: UUID(2),
			action: .reload,
			targetID: tab.id.rawValue,
			expectedRevision: "r"
		))
		let folder: AutomationOperation = .command(.init(
			operationID: UUID(3),
			action: .createFolder,
			targetID: state.workspace.spaces[0].id.rawValue,
			expectedRevision: "r",
			name: "Folder"
		))

		expectNoDifference(click.presenceTabID, tab.id)
		expectNoDifference(reload.presenceTabID, tab.id)
		expectNoDifference(inspect.presenceTabID, nil)
		let dismiss: AutomationOperation = .dialog(.init(action: .dismiss, targetID: tab.id.rawValue, expectedRevision: "r"))
		let readDialog: AutomationOperation = .dialog(.init(action: .read, targetID: tab.id.rawValue, expectedRevision: "r"))
		expectNoDifference(dismiss.presenceTabID, tab.id)
		expectNoDifference(readDialog.presenceTabID, nil)
		expectNoDifference(folder.presenceTabID, nil)
	}

	@Test
	internal func presenceLingersAfterTheLastOperationAndReachesEverySidebar() throws {
		var state = fixture()
		let tab = try #require(state.workspace.tabs.first)
		let request = reloadRequest(tab.id)
		state.automation.pending[request.id] = .init(request: request, grantRevision: UUID(82), approved: true)

		state.beginAgentPresence(request.id, now: now)
		let active = try #require(state.agentPresence(on: tab.id))
		expectNoDifference(active.clientName, "Fixture client")
		#expect(active.presence.isActive)
		#expect(active.presence.isVisible(at: now.addingTimeInterval(3_600)))
		state.publish(agentBadges: state.agentPresenceBadges)
		expectNoDifference(state.main.sidebar.tabAgents, [tab.id: .init(name: "Fixture client")])
		expectNoDifference(state.main.sidebar.tabItem(tab.id)?.agent, .init(name: "Fixture client"))

		let ended = now.addingTimeInterval(2)
		state.endAgentPresence(request.id, now: ended)
		let presence = try #require(state.automation.presence[tab.id])
		expectNoDifference(presence.fadesAt, ended.addingTimeInterval(AgentPresence.linger))
		#expect(presence.isVisible(at: ended.addingTimeInterval(AgentPresence.linger - 1)))
		#expect(!presence.isVisible(at: ended.addingTimeInterval(AgentPresence.linger)))
	}

	@Test
	internal func aSecondClientDoesntEraseTheFirst() throws {
		var state = fixture()
		var second = state.automationPreferences.clients[0]
		second.id = UUID(90)
		second.name = "Second client"
		state.automationPreferences.clients.append(second)
		let tab = try #require(state.workspace.tabs.first)
		let long = reloadRequest(tab.id)
		var click = reloadRequest(tab.id)
		click.id = UUID(87)
		click.clientID = second.id
		state.automation.pending[long.id] = .init(request: long, grantRevision: UUID(82), approved: true)
		state.automation.pending[click.id] = .init(request: click, grantRevision: UUID(82), approved: true)

		state.beginAgentPresence(long.id, now: now)
		state.beginAgentPresence(click.id, now: now)
		expectNoDifference(state.agentPresence(on: tab.id)?.clientName, "Second client")
		state.endAgentPresence(click.id, now: now)

		// The first client is still acting: its indicator stays, under its name.
		expectNoDifference(state.agentPresence(on: tab.id)?.clientName, "Fixture client")
		#expect(state.automation.presence[tab.id]?.isActive == true)

		state.stopAgentPresence(of: UUID(80), now: now)
		#expect(state.automation.presence[tab.id]?.isStopped == true)
	}

	@Test
	internal func readsAndUnapprovedTabsShowNothing() throws {
		var state = fixture()
		let tab = try #require(state.workspace.tabs.first)
		let read = AutomationRequest(
			id: UUID(85),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .inspect(.init(targetID: tab.id.rawValue, expectedRevision: "r"))
		)
		state.automation.pending[read.id] = .init(request: read, grantRevision: UUID(82))
		state.beginAgentPresence(read.id, now: now)
		#expect(state.automation.presence.isEmpty)
	}

	@Test
	internal func stopEndsTheClientsOperationsAndPausesItsGrantUntilResumed() async throws {
		var state = fixture()
		state.automationPreferences.clients[0].mutationGrantUntil = now.addingTimeInterval(600)
		let tab = try #require(state.workspace.tabs.first)
		let request = reloadRequest(tab.id)
		state.automation.pending[request.id] = .init(
			request: request,
			grantRevision: UUID(82),
			approved: true,
			executing: true
		)
		state.beginAgentPresence(request.id, now: now)
		var responses: [UUID: AutomationResult] = [:]
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { id, result in responses[id] = result }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_010)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.automation(.ui(.stopClient(UUID(80)))))
		await store.finish()
		let client = try #require(store.state.automationPreferences.clients.first)
		#expect(client.isPaused)
		expectNoDifference(client.mutationGrantUntil, nil)
		#expect(client.grantRevision != UUID(82))
		expectNoDifference(responses, [request.id: .failure(.paused)])
		#expect(store.state.automation.pending.isEmpty)
		let stopped = try #require(store.state.automation.presence[tab.id])
		#expect(stopped.isStopped)
		#expect(!stopped.isActive)
		// The pill offers Resume; the sidebar badge goes at once.
		expectNoDifference(store.state.main.sidebar.tabAgents, [:])

		// A paused client's next request fails before it reaches the page.
		var next = reloadRequest(tab.id)
		next.id = UUID(86)
		await store.send(.automation(.event(.host(.request(next)))))
		await store.finish()
		expectNoDifference(responses[next.id], .failure(.paused))

		await store.send(.automation(.ui(.resumeClient(UUID(80)))))
		#expect(store.state.automationPreferences.clients.first?.isPaused == false)
		#expect(store.state.automation.presence[tab.id] == nil)
	}

	@Test
	internal func stopReloadsAPageWhereTheClientsScriptIsRunning() async throws {
		var state = fixture()
		let tab = try #require(state.workspace.tabs.first)
		let script = AutomationRequest(
			id: UUID(88),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .script(.init(operationID: UUID(89), targetID: tab.id.rawValue, expectedRevision: "r", script: "await 0"))
		)
		state.automation.pending[script.id] = .init(request: script, grantRevision: UUID(82), approved: true, executing: true)

		// The script ran in this document; it may have returned and left timers behind.
		state.automation.scriptDocuments = [.init(tabID: tab.id, clientID: UUID(80))]
		let reloaded = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, _ in }
			$0.browserEngine.command = { id, command in
				if case .reload = command { reloaded.withValue { $0.append(id) } }
			}
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_010)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.automation(.ui(.stopClient(UUID(80)))))
		await store.finish()
		expectNoDifference(reloaded.value, [tab.id])
	}

	@Test
	internal func pausedClientsAreSavedAndOlderGrantsDecodeUnpaused() throws {
		var client = fixture().automationPreferences.clients[0]
		let running = try JSONEncoder().encode(client)
		#expect(!String(decoding: running, as: UTF8.self).contains("isPaused"))
		expectNoDifference(try JSONDecoder().decode(AutomationClient.self, from: running), client)

		client.isPaused = true
		let paused = try JSONEncoder().encode(client)
		expectNoDifference(try JSONDecoder().decode(AutomationClient.self, from: paused), client)
	}

	private func reloadRequest(_ tabID: BrowserCore.Tab.ID) -> AutomationRequest {
		.init(
			id: UUID(84),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .command(.init(
				operationID: UUID(83),
				action: .reload,
				targetID: tabID.rawValue,
				expectedRevision: "r"
			))
		)
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture client",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.profile(organization.profiles[0].id)],
			allowsRead: true,
			allowsManagement: true,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		return state
	}
}
