import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct AutomationFolderMoveTests {
	@Test(arguments: [false, true], [false, true])
	internal func movesWholeTreeWithoutRecreatingSessions(
		intoFolder: Bool,
		additionalWindow: Bool
	) async throws {
		var state = fixture()
		let root = state.workspace.folders[0]
		let nested = state.workspace.folders[1]
		let destination = state.workspace.spaces[1]
		let target = state.workspace.tabs[0]
		let other = state.workspace.tabs[1]
		var host = MainFeature.State(
			organization: state.workspace,
			spaceID: state.main.sidebar.spaceID,
			id: additionalWindow ? UUID(72) : state.main.id
		)
		host.viewer.item = .init(tab: other, generation: 7)
		host.viewer.panes.append(.init(id: UUID(71), item: .init(tab: target, generation: 9)))
		host.sidebar.select(other.id)
		if additionalWindow {
			state.windows.append(host)
		} else {
			state.main = host
		}

		let command = try command(
			state: state,
			destinationID: intoFolder ? state.workspace.folders[2].id.rawValue : destination.id.rawValue
		)
		var responses: [AutomationResult] = []
		var nativeCalls: [String] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.automationControl.respond = { _, result in responses.append(result) }
			$0.browserEngine.open = { _ in nativeCalls.append("open") }
			$0.browserEngine.close = { _ in nativeCalls.append("close") }
		}

		await store.send(.automation(.event(.host(.request(request(command)))))).finish()
		try store.workspace.validate()
		expectNoDifference(nativeCalls, [])
		expectNoDifference(store.workspace.tabs, state.workspace.tabs)
		expectNoDifference(store.workspace.folders[0].children, root.children)
		expectNoDifference(store.workspace.folders[1].children, nested.children)
		expectNoDifference(store.workspace.folders.prefix(2).map(\.spaceID), [destination.id, destination.id])
		expectNoDifference(store.workspace.spaces[0].savedItems, [])
		if intoFolder {
			expectNoDifference(store.workspace.folders[2].children, [.folder(root.id)])
		} else {
			expectNoDifference(store.workspace.spaces[1].savedItems, [.folder(state.workspace.folders[2].id), .folder(root.id)])
		}

		let updatedHost = try #require(additionalWindow ? store.windows[id: host.id] : store.main)
		expectNoDifference(updatedHost.viewer.item.tab?.id, other.id)
		expectNoDifference(updatedHost.viewer.item.generation, 7)
		#expect(!updatedHost.viewer.panes.contains { $0.item.tab?.id == target.id })
		expectNoDifference(store.focusedWindowID, state.focusedWindowID)
		expectNoDifference(store.main.sidebar.undo.last?.before, state.workspace)

		// The agent's change is its step in the window (DEV-1030).
		#expect(store.main.sidebar.undo.last?.author != .person)
		let response = AutomationResult.command(.init(
			operationID: command.operationID,
			status: .committed,
			targetID: root.id.rawValue
		))
		expectNoDifference(responses, [response])
		expectNoDifference(
			store.state.automationResponseValidation(request(command), result: response, snapshots: [:]),
			nil
		)

		await store.send(.main(.sidebar(.ui(.undo)))).finish()
		expectNoDifference(store.workspace.folders, state.workspace.folders)
		expectNoDifference(store.workspace.tabs, state.workspace.tabs)
		expectNoDifference(store.workspace.spaces.map(\.savedItems), state.workspace.spaces.map(\.savedItems))
	}

	@Test(arguments: ["membership", "order", "nestedName", "destination", "deletedDestination"])
	internal func approvalRejectsChangedTreeOrDestination(change: String) async throws {
		let state = fixture(temporaryGrant: false)
		let command = try command(state: state, destinationID: state.workspace.folders[2].id.rawValue)
		var responses: [AutomationResult] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.automationControl.respond = { _, result in responses.append(result) }
		}

		await store.send(.automation(.event(.host(.request(request(command)))))).finish()
		#expect(store.automation.pending[UUID(84)]?.awaitingApproval == true)
		var changed = state.workspace
		switch change {
		case "membership":
			changed.folders[1].children.removeAll()
			changed.spaces[0].savedItems.append(.tab(changed.tabs[2].id))

		case "order":
			changed.folders[0].children.reverse()

		case "nestedName":
			changed.folders[1].name = "User renamed the nested folder"

		case "destination":
			changed.folders[2].name = "User changed the destination"

		default:
			changed.folders.removeLast()
			changed.spaces[1].savedItems.removeAll()
		}
		try changed.validate()
		await publish(changed, to: store)
		await store.send(.automation(.ui(.approve(UUID(84))))).finish()
		expectNoDifference(store.workspace, changed)
		expectNoDifference(responses, [.failure(change == "deletedDestination" ? .denied : .staleTarget)])
		#expect(store.automation.pending.isEmpty)
	}

	@Test
	internal func approvalPreservesNewNavigationAndDisclosure() async throws {
		let state = fixture(temporaryGrant: false)
		let command = try command(state: state)
		var responses: [AutomationResult] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.automationControl.respond = { _, result in responses.append(result) }
		}

		await store.send(.automation(.event(.host(.request(request(command)))))).finish()
		var changed = state.workspace
		changed.tabs[0].restoration = .init(title: "A newer page", url: URL(string: "https://capturecontext.dev/newer")!)
		changed.folders[0].isExpanded = false
		await publish(changed, to: store)
		await store.send(.automation(.ui(.approve(UUID(84))))).finish()
		expectNoDifference(store.workspace.tabs, changed.tabs)
		expectNoDifference(store.workspace.folders[0].isExpanded, false)
		expectNoDifference(store.workspace.folders[0].spaceID, changed.spaces[1].id)
		expectNoDifference(responses.last, .command(.init(
			operationID: command.operationID,
			status: .committed,
			targetID: command.targetID
		)))
	}

	@Test(arguments: [
		"sourceScope", "destinationScope", "individualTabs", "tabDestination",
		"crossProfile", "foreignTab", "foreignFolder", "self", "descendant"
	])
	internal func rejectsUnpermittedOrInvalidTrees(change: String) async throws {
		var state = fixture()
		var destinationID = state.workspace.spaces[1].id.rawValue
		switch change {
		case "crossProfile":
			let profile = Profile(id: .init(rawValue: UUID(69)), name: "Other profile")
			state.workspace.profiles.append(profile)
			let destination = state.workspace.spaces[1]
			state.workspace.spaces[1] = .init(
				id: destination.id,
				profileID: profile.id,
				name: destination.name,
				savedItems: destination.savedItems
			)
			state.main.sidebar.organization = state.workspace
			state.automationPreferences.clients[0].scopes = state.workspace.spaces.map {
				.space($0.id, profileID: $0.profileID)
			}

		case "foreignTab":
			let tab = state.workspace.tabs[2]
			state.workspace.tabs[2] = .init(
				id: tab.id,
				profileID: .init(rawValue: UUID(69)),
				savedDestination: tab.savedDestination,
				restoration: tab.restoration
			)
			state.main.sidebar.organization = state.workspace

		case "foreignFolder":
			state.workspace.folders[1].spaceID = state.workspace.spaces[1].id
			state.main.sidebar.organization = state.workspace

		case "tabDestination":
			destinationID = state.workspace.tabs[1].id.rawValue

		case "self":
			destinationID = state.workspace.folders[0].id.rawValue

		case "descendant":
			destinationID = state.workspace.folders[1].id.rawValue

		default:
			break
		}
		let command = try command(state: state, destinationID: destinationID)
		switch change {
		case "sourceScope":
			state.automationPreferences.clients[0].scopes.removeFirst()

		case "destinationScope":
			state.automationPreferences.clients[0].scopes.removeLast()

		case "individualTabs":
			state.automationPreferences.clients[0].scopes = state.workspace.tabs.map {
				.tab($0.id, profileID: $0.profileID, location: .space(state.workspace.spaces[0].id))
			}

		default:
			break
		}

		var responses: [AutomationResult] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.automationControl.respond = { _, result in responses.append(result) }
		}
		await store.send(.automation(.event(.host(.request(request(command)))))).finish()
		expectNoDifference(store.workspace, state.workspace)
		let failure: AutomationFailure = switch change {
		case "sourceScope", "destinationScope", "individualTabs", "foreignTab", "foreignFolder": .denied
		case "crossProfile": .crossProfileTransferUnsupported
		default: .invalidRequest
		}
		expectNoDifference(responses, [.failure(failure)])
		#expect(store.main.sidebar.undo.isEmpty)
	}

	@Test(arguments: ["decline", "cancel", "disconnect", "revoke", "disabled"])
	internal func lateApprovalAndInspectionCannotRestoreCancelledAuthority(change: String) async throws {
		let state = fixture(temporaryGrant: false)
		let command = try command(state: state)
		var responses: [AutomationResult] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.automationControl.respond = { _, result in responses.append(result) }
			$0.automationControl.revoke = { _ in }
			$0.automationControl.stop = {}
		}
		await store.send(.automation(.event(.host(.request(request(command)))))).finish()
		#expect(store.automation.pending[UUID(84)]?.awaitingApproval == true)
		switch change {
		case "decline":
			await store.send(.automation(.ui(.decline(UUID(84))))).finish()

		case "cancel":
			await store.send(.automation(.event(.host(.cancel(UUID(84)))))).finish()

		case "disconnect":
			await store.send(.automation(.event(.host(.disconnected(sessionID: UUID(81)))))).finish()

		case "revoke":
			await store.send(.automation(.ui(.revokeClient(UUID(80))))).finish()

		default:
			await store.send(.automation(.ui(.enabled(false)))).finish()
		}
		await store.send(.automation(.ui(.approve(UUID(84))))).finish()
		await store.send(.automation(.event(.inspected(UUID(84), [:])))).finish()
		expectNoDifference(store.workspace, state.workspace)
		#expect(store.automation.pending.isEmpty)
		#expect(!responses.contains { if case .command = $0 { true } else { false } })
	}

	@Test
	internal func expiryAndFinalResponseRevocationRemainFailClosed() throws {
		var state = fixture()
		let command = try command(state: state)
		let request = request(command)
		var pending = AutomationState.Pending(
			request: request,
			grantRevision: UUID(82),
			approved: true,
			executing: true
		)
		pending.approvalExpiresAt = Date(timeIntervalSince1970: 100)
		expectNoDifference(
			state.automationValidation(pending, snapshots: [:], now: Date(timeIntervalSince1970: 100)),
			.denied
		)

		let response = AutomationResult.command(.init(
			operationID: command.operationID,
			status: .committed,
			targetID: command.targetID
		))
		state.automationPreferences.clients[0].scopes.removeAll()
		expectNoDifference(state.automationResponseValidation(request, result: response, snapshots: [:]), .denied)
	}

	private func fixture(temporaryGrant: Bool = true) -> AppFeature.State {
		var organization = IntegrationFeatureTests().fixture()
		let rootID = Folder.ID(rawValue: UUID(60))
		let nestedID = Folder.ID(rawValue: UUID(61))
		let destinationID = Folder.ID(rawValue: UUID(62))
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(5)),
			profileID: organization.profiles[0].id,
			restoration: organization.tabs[0].restoration,
			automationClientID: UUID(80)
		)
		organization.tabs.append(tab)
		for index in [0, 2] {
			let restoration = organization.tabs[index].restoration
			organization.tabs[index].savedDestination = .init(title: restoration.title, url: restoration.url)
		}
		organization.folders = [
			.init(
				id: rootID,
				spaceID: organization.spaces[0].id,
				name: "Source",
				children: [.tab(organization.tabs[0].id), .folder(nestedID)]
			),
			.init(
				id: nestedID,
				spaceID: organization.spaces[0].id,
				name: "Nested",
				children: [.tab(tab.id)]
			),
			.init(id: destinationID, spaceID: organization.spaces[1].id, name: "Destination"),
		]
		organization.spaces[0].savedItems = [.folder(rootID)]
		organization.spaces[0].unpinnedTabs = [organization.tabs[1].id]
		organization.spaces[1].savedItems = [.folder(destinationID)]
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture client",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: organization.spaces.map { .space($0.id, profileID: $0.profileID) },
			allowsRead: true,
			allowsManagement: true,
			mutationGrantUntil: temporaryGrant ? Date(timeIntervalSince1970: 200) : nil,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		return state
	}

	private func command(
		state: AppFeature.State,
		destinationID: UUID? = nil
	) throws -> AutomationCommand {
		let items = AutomationInventoryBuilder.items(
			client: state.automationPreferences.clients[0],
			organization: state.workspace,
			snapshots: [:]
		)
		let target = try #require(items.first { $0.id == state.workspace.folders[0].id.rawValue })
		let destination = try #require(items.first { $0.id == (destinationID ?? state.workspace.spaces[1].id.rawValue) })
		return .init(
			operationID: UUID(83),
			action: .moveFolder,
			targetID: target.id,
			expectedRevision: target.revision,
			destinationID: destination.id,
			destinationRevision: destination.revision
		)
	}

	private func request(_ command: AutomationCommand) -> AutomationRequest {
		.init(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .command(command))
	}

	private func publish(
		_ organization: BrowserOrganization,
		to store: StoreOf<AppFeature>
	) async {
		await store.send(.main(.reconcile(organization))).finish()
		await store.send(.main(.delegate(.organizationChanged(organization)))).finish()
	}
}
