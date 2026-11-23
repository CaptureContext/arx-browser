@testable import AppFeature
import BrowserAutomationClient
import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func automationRequiresApprovalAndUsesExistingUndoForOrganizationEdits() async throws {
		let state = automationFixture()
		let command = try automationCommand(.createFolder, state: state)
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = automationRequest(command)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		expectNoDifference(store.state.workspace, state.workspace)
		#expect(store.state.automation.pending[request.id]?.awaitingApproval == true)
		#expect(responses.isEmpty)
		await store.send(.automation(.ui(.approve(request.id))))
		await store.receive(\.automation.event.inspected)
		await store.finish()
		expectNoDifference(store.state.workspace.folders.map(\.name), ["Assistant folder"])
		expectNoDifference(store.state.main.sidebar.undo.last?.before, state.workspace)
		guard case .command = responses.last else {
			Issue.record("Approved edit did not commit")
			return
		}
		#expect(store.state.automation.pending.isEmpty)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		expectNoDifference(responses.last, .failure(.duplicateOperation))
		expectNoDifference(store.state.workspace.folders.count, 1)
	}

	@Test
	internal func automationApprovalRechecksTargetAfterUserEditsAndNavigation() async throws {
		let state = automationFixture()
		let command = try automationCommand(.createFolder, state: state)
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = automationRequest(command)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		var changed = state.workspace
		changed.spaces[0].name = "Changed while awaiting approval"
		await store.send(.main(.reconcile(changed)))
		await store.send(.main(.delegate(.organizationChanged(changed))))
		await store.send(.automation(.ui(.approve(request.id))))
		await store.receive(\.automation.event.inspected)
		await store.finish()
		expectNoDifference(responses.last, .failure(.staleTarget))
		#expect(store.state.workspace.folders.isEmpty)
	}

	@Test
	internal func automationPermissionChangesCancelPendingWorkAndKeepTheSession() async throws {
		let state = automationFixture()
		var revoked: [UUID] = []
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.revoke = { revoked.append($0) }
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = automationRequest(try automationCommand(.createFolder, state: state))
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		var client = state.automationPreferences.clients[0]
		client.scopes = []
		await store.send(.automation(.ui(.updateClient(client))))
		await store.finish()

		// The helper follows the new grant with tools/list_changed; only revocation disconnects.
		// The request bound to the old grant answers at once instead of waiting for a timeout.
		expectNoDifference(revoked, [])
		expectNoDifference(responses, [.failure(.denied)])
		#expect(store.state.automation.pending.isEmpty)
		expectNoDifference(store.state.automation.sessions, state.automation.sessions)
		await store.send(.automation(.ui(.approve(request.id))))
		expectNoDifference(store.state.workspace, state.workspace)

		await store.send(.automation(.ui(.revokeClient(client.id))))
		await store.finish()
		expectNoDifference(revoked, [client.id])
		#expect(store.state.automation.sessions.isEmpty)
	}

	@Test(arguments: [AutomationApprovalPolicy.alwaysAsk, .destructiveOnly, .never])
	internal func standingPolicyDecidesWhichTiersAsk(policy: AutomationApprovalPolicy) async throws {
		var state = automationFixture()
		state.automationPreferences.clients[0].approvalPolicy = policy
		let command = try automationCommand(.createFolder, state: state)
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = automationRequest(command)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		await store.finish()

		switch policy {
		case .alwaysAsk:
			#expect(store.state.automation.pending[request.id]?.awaitingApproval == true)
			#expect(store.state.workspace.folders.isEmpty)

		case .destructiveOnly, .never:
			#expect(store.state.automation.pending[request.id] == nil)
			expectNoDifference(store.state.workspace.folders.map(\.name), ["Assistant folder"])
			guard case .command = responses.last else {
				Issue.record("A standing grant did not run a non-destructive edit")
				return
			}
		}
	}

	@Test(arguments: [AutomationApprovalPolicy.destructiveOnly, .never])
	internal func destructiveActionsAskUnlessThePolicyNeverAsks(policy: AutomationApprovalPolicy) async throws {
		var state = automationFixture()
		state.automationPreferences.clients[0].approvalPolicy = policy
		let client = state.automationPreferences.clients[0]
		let tab = try #require(
			AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: [:])
				.first(where: { $0.kind == .tab })
		)
		let command = AutomationCommand(
			operationID: UUID(83),
			action: .closeTab,
			targetID: tab.id,
			expectedRevision: tab.revision
		)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = automationRequest(command)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		let pending = store.state.automation.pending[request.id]
		switch policy {
		case .destructiveOnly:
			#expect(pending?.awaitingApproval == true && pending?.approved == false)

		default:
			#expect(pending?.awaitingApproval != true)
			#expect(pending == nil || pending?.approved == true)
		}
		await store.finish()
	}

	@Test
	internal func batchApprovalCoversExactlyItsStepsInOrder() async throws {
		let state = automationFixture()
		let first = try automationCommand(.createFolder, state: state)
		var second = first
		second.operationID = UUID(85)
		second.name = "Second folder"
		let plan = AutomationBatchPlan(batchID: UUID(86), steps: [.command(first), .command(second)])
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let planRequest = AutomationRequest(id: UUID(87), clientID: UUID(80), sessionID: UUID(81), operation: .batch(plan))
		await store.send(.automation(.event(.host(.request(planRequest)))))
		await store.receive(\.automation.event.inspected)
		#expect(store.state.automation.pending[planRequest.id]?.awaitingApproval == true)
		await store.send(.automation(.ui(.approve(planRequest.id))))
		await store.receive(\.automation.event.inspected)
		await store.finish()

		// The answer says when the approval lapses, for a client that collects it later (DEV-1072).
		expectNoDifference(responses.last, .batch(.init(
			batchID: plan.batchID,
			approvedSteps: 2,
			expiresAt: Date(timeIntervalSince1970: 100 + AutomationBatchPlan.approvalWindow)
		)))

		// A step that is not next in the plan ends the approval and asks as usual.
		let outOfOrder = AutomationRequest(
			id: UUID(88),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .command(second)
		)
		await store.send(.automation(.event(.host(.request(outOfOrder)))))
		await store.receive(\.automation.event.inspected)
		#expect(store.state.automation.pending[outOfOrder.id]?.awaitingApproval == true)
		#expect(store.state.automation.batchApprovals.isEmpty)
		await store.send(.automation(.ui(.decline(outOfOrder.id))))
		#expect(store.state.workspace.folders.isEmpty)
	}

	@Test
	internal func approvedBatchStepRunsWithoutAskingAgain() async throws {
		let state = automationFixture()
		let command = try automationCommand(.createFolder, state: state)
		let plan = AutomationBatchPlan(batchID: UUID(86), steps: [.command(command)])
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let planRequest = AutomationRequest(id: UUID(87), clientID: UUID(80), sessionID: UUID(81), operation: .batch(plan))
		await store.send(.automation(.event(.host(.request(planRequest)))))
		await store.receive(\.automation.event.inspected)
		await store.send(.automation(.ui(.approve(planRequest.id))))
		await store.receive(\.automation.event.inspected)
		await store.finish()

		// The approval belongs to the connection that asked for it.
		expectNoDifference(Array(store.state.automation.batchApprovals.keys), [UUID(81)])

		let step = automationRequest(command)
		await store.send(.automation(.event(.host(.request(step)))))
		await store.receive(\.automation.event.inspected)
		await store.finish()
		expectNoDifference(store.state.workspace.folders.map(\.name), ["Assistant folder"])
		guard case .command = responses.last else {
			Issue.record("An approved batch step did not run")
			return
		}
		#expect(store.state.automation.batchApprovals.isEmpty)
	}

	@Test
	internal func batchWithAnUngrantedTargetIsDeniedBeforeAsking() async throws {
		let state = automationFixture()
		var command = try automationCommand(.createFolder, state: state)
		command.targetID = state.workspace.spaces[1].id.rawValue
		let plan = AutomationBatchPlan(batchID: UUID(86), steps: [.command(command)])
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = AutomationRequest(id: UUID(87), clientID: UUID(80), sessionID: UUID(81), operation: .batch(plan))
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		await store.finish()
		expectNoDifference(responses, [.failure(.denied)])
	}

	@Test
	internal func inventoryNamesGrantedProfilesAndChangesListOnlyGrantedTabs() throws {
		let state = automationFixture()
		let client = state.automationPreferences.clients[0]
		let items = AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: [:])
		expectNoDifference(
			AutomationInventoryBuilder.profiles(client: client, organization: state.workspace, items: items),
			[.init(id: state.workspace.profiles[0].id.rawValue, name: state.workspace.profiles[0].name)]
		)

		let digest = try #require(state.automationChanges(for: client, snapshots: { _ in nil }))
		let granted = Set(items.filter { $0.kind == .tab }.map(\.id))
		expectNoDifference(Set(digest.tabs.keys), granted)

		var unread = client
		unread.allowsRead = false
		#expect(state.automationChanges(for: unread, snapshots: { _ in nil }) == nil)
	}

	@Test
	internal func profileGrantCoversSpacesCreatedLater() throws {
		var state = automationFixture()
		let profileID = state.workspace.profiles[0].id
		state.automationPreferences.clients[0].scopes = [.profile(profileID)]
		let later = Space(id: .init(rawValue: UUID(90)), profileID: profileID, name: "Created later")
		var organization = state.workspace
		organization.spaces.append(later)
		let items = AutomationInventoryBuilder.items(
			client: state.automationPreferences.clients[0],
			organization: organization,
			snapshots: [:]
		)
		#expect(items.contains { $0.kind == .space && $0.id == later.id.rawValue })
		#expect(items.filter { $0.kind == .space }.count == organization.spaces.count)
	}

	@Test
	internal func focusedTabResolvesOnlyForOptedInClientsWithinTheirGrant() throws {
		var state = automationFixture()
		var client = state.automationPreferences.clients[0]
		let spaceID = state.main.sidebar.spaceID
		let selected = try #require(state.workspace.spaces[id: spaceID]?.unpinnedTabs.first)
		state.main.sidebar.organization.spaces[id: spaceID]?.selectedTabID = selected
		#expect(state.automationFocusedTab(for: client, snapshots: [:]) == nil)

		client.allowsFocusedTab = true
		let resolved = try #require(state.automationFocusedTab(for: client, snapshots: [:]))
		expectNoDifference(resolved.tabID, selected.rawValue)
		let item = AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: [:])
			.first { $0.id == selected.rawValue }
		expectNoDifference(resolved.revision, item?.revision)

		client.scopes = []
		#expect(state.automationFocusedTab(for: client, snapshots: [:]) == nil)
	}

	@Test
	internal func automationDoesNotLeakPrivateWindowsOrUnpermittedInventory() async throws {
		var state = automationFixture()
		state.automationPreferences.clients[0].scopes = []
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = AutomationRequest(
			id: UUID(90),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .inventory(cursor: nil, limit: 100)
		)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		await store.finish()
		expectNoDifference(responses, [.inventory(.init(items: [], chromeAppearance: store.state.settings.chromeAppearance))])
		expectNoDifference(store.state.main, state.main)
	}

	@Test
	internal func inventoryCarriesTheAppWideChromeAppearance() async throws {
		var preferences = BrowserPreferences()
		preferences.chromeAppearance = .init(tint: .init(hue: 30, intensity: 0.6), grain: .init(isEnabled: false))

		// A shared preference, so the fixture gets its own document.
		let document = WorkspaceDocument.unsaved(preferences)
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			automationFixture()
		}
		let responses = LockIsolated<[AutomationResult]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.automationControl.respond = { _, value in responses.withValue { $0.append(value) } }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = AutomationRequest(
			id: UUID(90),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .inventory(cursor: nil, limit: 100)
		)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()

		guard case let .inventory(inventory) = responses.value.last else {
			Issue.record("No inventory: \(String(describing: responses.value.last))")
			return
		}

		// MCP resolves profile and space appearances over this, not over the built-in default.
		expectNoDifference(inventory.chromeAppearance, preferences.chromeAppearance)
		#expect(inventory.chromeAppearance != .default)
	}

	@Test
	internal func executionGuardRejectsRevokedMovedNavigatedExpiredAndPrivateTargets() throws {
		var state = automationFixture()
		let tab = state.workspace.tabs[0]
		let snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [
			tab.id: .init(navigation: .init(url: tab.restoration.url, title: "Example"), revision: 1)
		]
		let client = state.automationPreferences.clients[0]
		let items = AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: snapshots)
		let item = try #require(items.first(where: { $0.id == tab.id.rawValue }))
		let command = AutomationCommand(
			operationID: UUID(85),
			action: .reload,
			targetID: item.id,
			expectedRevision: item.revision
		)
		let request = automationRequest(command)
		state.automation.pending[request.id] = .init(
			request: request,
			grantRevision: client.grantRevision,
			approved: true,
			executing: true
		)
		let now = Date(timeIntervalSince1970: 100)
		#expect(state.automationCanExecute(request.id, snapshots: snapshots, now: now))
		var changed = snapshots
		changed[tab.id]?.revision = 2
		#expect(!state.automationCanExecute(request.id, snapshots: changed, now: now))
		var expired = state
		expired.automation.pending[request.id]?.approvalExpiresAt = now
		#expect(!expired.automationCanExecute(request.id, snapshots: snapshots, now: now))
		var busy = state
		busy.main.transferInProgress = true
		#expect(!busy.automationCanExecute(request.id, snapshots: snapshots, now: now))
		var revoked = state
		revoked.automationPreferences.clients[0].grantRevision = UUID(99)
		#expect(!revoked.automationCanExecute(request.id, snapshots: snapshots, now: now))
		state.workspace.tabs.removeAll { $0.id == tab.id }
		#expect(!state.automationCanExecute(request.id, snapshots: snapshots, now: now))
	}

	@Test
	internal func automationIgnoresWindowSelectionAndPrivateWorkspaceDifferences() throws {
		var state = automationFixture()
		var window = MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: UUID(70))
		window.sidebar.organization.spaces[0].selectedTabID = nil
		state.windows.append(window)
		var privateWindow = MainFeature.State(
			organization: state.workspace,
			spaceID: state.main.sidebar.spaceID,
			isPrivate: true,
			id: UUID(71)
		)
		privateWindow.sidebar.organization.spaces[0].name = "Private workspace"
		state.windows.append(privateWindow)
		let request = automationRequest(try automationCommand(.createFolder, state: state))
		state.automation.pending[request.id] = .init(
			request: request,
			grantRevision: state.automationPreferences.clients[0].grantRevision,
			approved: true,
			executing: true
		)
		#expect(state.automationCanExecute(request.id, snapshots: [:], now: Date(timeIntervalSince1970: 100)))
	}

	@Test(arguments: [false, true], ["folder", "archive", "transfer", "close", "publication", "peek"])
	internal func automationWaitsForLifecycleAndWorkspacePublication(
		additionalWindow: Bool,
		transition: String
	) async throws {
		var state = automationFixture()
		let command = try automationCommand(.createFolder, state: state)
		var host = additionalWindow
		? MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: UUID(70))
		: state.main
		switch transition {
		case "folder":
			host.pendingFolderDeletion = .init(rawValue: UUID(71))

		case "archive":
			host.archive.isWorking = true

		case "transfer":
			host.transferInProgress = true

		case "close":
			host.pendingTabCloses.insert(state.workspace.tabs[0].id)

		case "peek":
			state.peeks.append(.init(id: UUID(72), source: .init(
			windowID: host.id,
			paneID: host.viewer.activePaneID,
			tabID: host.viewer.item.tab?.id,
			spaceID: host.sidebar.spaceID,
			profileID: state.workspace.tabs[0].profileID,
			identity: "Default · Work"
		), tab: state.workspace.tabs[0], isTemporary: false))

		default:
			host.sidebar.organization.spaces[0].name = "Unpublished user edit"
		}
		if additionalWindow { state.windows.append(host) } else { state.main = host }
		let request = automationRequest(command)
		state.automation.pending[request.id] = .init(
			request: request,
			grantRevision: state.automationPreferences.clients[0].grantRevision,
			approved: true,
			executing: true
		)
		#expect(!state.automationCanExecute(request.id, snapshots: [:], now: Date(timeIntervalSince1970: 100)))
		state.automation.pending = [:]
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		await store.finish()
		expectNoDifference(responses, [.failure(.busy)])
		expectNoDifference(store.state.workspace, state.workspace)
		expectNoDifference(store.state.main.sidebar.organization, state.main.sidebar.organization)
	}

	@Test
	internal func temporaryGrantCanCommitWithoutPromptButManagementDenialWins() async throws {
		var state = automationFixture()
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		state.automationPreferences.clients[0].allowsManagement = false
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.event(.host(.request(automationRequest(try automationCommand(.createFolder, state: state)))))))
		await store.receive(\.automation.event.inspected)
		await store.finish()
		expectNoDifference(responses, [.failure(.denied)])
		#expect(store.state.workspace.folders.isEmpty)
	}

	@Test
	internal func automationOpensBackgroundTabWithoutSelectingAndRecordsItsOrigin() async throws {
		var state = automationFixture()
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		var command = try automationCommand(.openTab, state: state)
		command.url = URL(string: "https://capturecontext.dev/new")!
		var responses: [AutomationResult] = []
		var opened: [BrowserCore.Tab] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.openAuthorized = { tab, authorize in
				guard authorize() else { throw AutomationFailure.denied }
				opened.append(tab)
			}
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.event(.host(.request(automationRequest(command))))))
		await store.receive(\.automation.event.inspected)
		await store.receive(\.automation.event.opened)
		await store.finish()
		let tab = try #require(opened.first)
		expectNoDifference(store.state.workspace.tabs.last, tab)
		expectNoDifference(tab.automationClientID, UUID(80))
		expectNoDifference(store.state.main.sidebar.selectedTab?.id, state.main.sidebar.selectedTab?.id)
		expectNoDifference(store.state.main.viewer, state.main.viewer)
		expectNoDifference(
			responses.last,
			.command(.init(operationID: command.operationID, status: .acceptedLoading, targetID: tab.id.rawValue))
		)
	}

	@Test
	internal func automationSelectsAnInactivePaneWithoutRehostingItsSession() async throws {
		var state = automationFixture()
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		let target = state.workspace.tabs[0]
		let other = state.workspace.tabs[1]
		let windowID = UUID(70)
		let paneID = UUID(71)
		var window = MainFeature.State(
			organization: state.workspace,
			spaceID: state.main.sidebar.spaceID,
			id: windowID
		)
		window.viewer.item.tab = other
		window.sidebar.select(other.id)
		window.viewer.panes.append(.init(id: paneID, item: .init(tab: target)))
		state.windows.append(window)
		let snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [
			target.id: .init(navigation: .init(url: target.restoration.url), revision: 1)
		]
		let items = AutomationInventoryBuilder.items(
			client: state.automationPreferences.clients[0],
			organization: state.workspace,
			snapshots: snapshots
		)
		let item = try #require(items.first(where: { $0.id == target.id.rawValue }))
		let command = AutomationCommand(
			operationID: UUID(85),
			action: .selectTab,
			targetID: item.id,
			expectedRevision: item.revision
		)
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.browserEngine.snapshot = { snapshots[$0] }
			$0.browserEngine.open = { _ in Issue.record("Selecting a mounted pane must not open a new session") }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.event(.host(.request(automationRequest(command))))))
		await store.receive(\.automation.event.inspected)
		await store.finish()
		expectNoDifference(
			responses.last,
			.command(.init(operationID: command.operationID, status: .committed, targetID: target.id.rawValue))
		)
		expectNoDifference(store.state.focusedWindowID, windowID)
		expectNoDifference(store.state.windows[id: windowID]?.viewer.activePaneID, paneID)
		expectNoDifference(store.state.windows[id: windowID]?.viewer.panes.map { $0.item.tab?.id }, [other.id, target.id])
		#expect(store.state.main.viewer.item.tab == nil)
	}

	@Test
	internal func automationSelectionAcrossSpacesPreservesTheOutgoingSplit() async throws {
		var state = automationFixture()
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		let target = state.workspace.tabs[0]
		let otherSpace = state.workspace.spaces[1].id
		state.main.sidebar.selectSpace(otherSpace)
		state.main.viewer.spaceID = otherSpace
		state.main.viewer.requestedSpaceID = otherSpace
		state.main.viewer.panes.append(.init(id: UUID(71)))
		state.main.viewer.preservesPresentation = true
		let originalLayout = state.main.viewer.currentPresentation
		let snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [
			target.id: .init(navigation: .init(url: target.restoration.url), revision: 1)
		]
		let items = AutomationInventoryBuilder.items(
			client: state.automationPreferences.clients[0],
			organization: state.workspace,
			snapshots: snapshots
		)
		let item = try #require(items.first(where: { $0.id == target.id.rawValue }))
		let command = AutomationCommand(
			operationID: UUID(85),
			action: .selectTab,
			targetID: item.id,
			expectedRevision: item.revision
		)
		var responses: [AutomationResult] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.browserEngine.snapshot = { snapshots[$0] }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		await store.send(.automation(.event(.host(.request(automationRequest(command)))))).finish()
		expectNoDifference(
			responses.last,
			.command(.init(operationID: command.operationID, status: .committed, targetID: target.id.rawValue))
		)
		expectNoDifference(store.main.viewer.spaceID, state.workspace.spaces[0].id)
		expectNoDifference(store.main.viewer.panes.compactMap { $0.item.tab?.id }, [target.id])
		await store.send(.main(.sidebar(.ui(.spaceSelected(otherSpace))))).finish()
		expectNoDifference(store.main.viewer.currentPresentation, originalLayout)
	}

	@Test
	internal func responseValidationRejectsMovedTargetsAndSecretBearingNavigationAfterInventoryWasBuilt() throws {
		let state = automationFixture()
		let client = state.automationPreferences.clients[0]
		let request = AutomationRequest(
			id: UUID(90),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .inventory(cursor: nil, limit: 100)
		)
		let tab = state.workspace.tabs[0]
		let snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [
			tab.id: .init(navigation: .init(url: tab.restoration.url), revision: 1)
		]
		let inventoryItems = AutomationInventoryBuilder.items(
			client: client,
			organization: state.workspace,
			snapshots: snapshots
		)
		let inventory = AutomationInventory(
			items: inventoryItems,
			profiles: AutomationInventoryBuilder.profiles(
				client: client,
				organization: state.workspace,
				items: inventoryItems
			),
			windows: state.automationWindows(for: client),
			chromeAppearance: state.settings.chromeAppearance
		)
		#expect(state.automationResponseValidation(request, result: .inventory(inventory), snapshots: snapshots) == nil)

		// The app-wide appearance changed after the inventory was built.
		var restyled = inventory
		restyled.chromeAppearance = .init(tint: .init(hue: 30, intensity: 0.6))
		expectNoDifference(
			state.automationResponseValidation(request, result: .inventory(restyled), snapshots: snapshots),
			.staleTarget
		)

		var navigated = snapshots
		let secretURL = URL(string: "https://capturecontext.dev/auth/synthetic-path?otp=synthetic-query#synthetic-fragment")!
		navigated[tab.id] = .init(navigation: .init(url: secretURL), revision: 2)
		expectNoDifference(
			state.automationResponseValidation(request, result: .inventory(inventory), snapshots: navigated),
			.staleTarget
		)
		var titled = state
		titled.workspace.tabs[0].restoration.title = "Synthetic OTP in page title"
		titled.main.sidebar.organization = titled.workspace
		expectNoDifference(
			titled.automationResponseValidation(request, result: .inventory(inventory), snapshots: snapshots),
			.staleTarget
		)

		var moved = state
		moved.workspace.spaces[0].unpinnedTabs.removeAll { $0 == tab.id }
		moved.workspace.profiles[0].favorites.append(tab.id)
		moved.main.sidebar.organization = moved.workspace
		expectNoDifference(
			moved.automationResponseValidation(request, result: .inventory(inventory), snapshots: snapshots),
			.staleTarget
		)
		var pendingPublication = state
		pendingPublication.main.sidebar.organization = moved.workspace
		expectNoDifference(
			pendingPublication.automationResponseValidation(request, result: .inventory(inventory), snapshots: snapshots),
			.busy
		)
		var disconnected = state
		disconnected.automation.sessions.removeAll()
		expectNoDifference(
			disconnected.automationResponseValidation(request, result: .inventory(inventory), snapshots: snapshots),
			.denied
		)
	}

	@Test
	internal func responseValidationRejectsStalePaginationAndUnpermittedCommandMetadata() throws {
		var state = automationFixture()
		let client = state.automationPreferences.clients[0]
		let items = AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: [:])
		let first = try AutomationInventoryBuilder.page(items, cursor: nil, limit: 1)
		var second = try AutomationInventoryBuilder.page(items, cursor: first.nextCursor, limit: 1)
		second.profiles = AutomationInventoryBuilder.profiles(client: client, organization: state.workspace, items: items)
		second.windows = state.automationWindows(for: client)
		second.chromeAppearance = state.settings.chromeAppearance
		let request = AutomationRequest(
			id: UUID(90),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .inventory(cursor: first.nextCursor, limit: 1)
		)
		#expect(state.automationResponseValidation(request, result: .inventory(second), snapshots: [:]) == nil)
		state.workspace.tabs[0].restoration.url = URL(string: "https://capturecontext.dev/?synthetic=changed")!
		state.main.sidebar.organization = state.workspace
		expectNoDifference(
			state.automationResponseValidation(request, result: .inventory(second), snapshots: [:]),
			.staleCursor
		)

		let command = try automationCommand(.createFolder, state: state)
		let commandRequest = automationRequest(command)
		let response = AutomationCommandResult(operationID: command.operationID, status: .committed, targetID: items[0].id)
		#expect(state.automationResponseValidation(commandRequest, result: .command(response), snapshots: [:]) == nil)
		var wrongTarget = response
		wrongTarget.targetID = UUID(999)
		expectNoDifference(
			state.automationResponseValidation(commandRequest, result: .command(wrongTarget), snapshots: [:]),
			.denied
		)
		var changedItem = response
		changedItem.item = items[1]
		expectNoDifference(
			state.automationResponseValidation(commandRequest, result: .command(changedItem), snapshots: [:]),
			.staleTarget
		)
		expectNoDifference(
			state.automationResponseValidation(commandRequest, result: .inventory(first), snapshots: [:]),
			.invalidRequest
		)
	}

	private func automationFixture() -> AppFeature.State {
		let organization = fixture()
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture client",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [
				.space(organization.spaces[0].id, profileID: organization.profiles[0].id),
			],
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

	private func automationCommand(
		_ action: AutomationCommand.Action,
		state: AppFeature.State
	) throws -> AutomationCommand {
		let items = AutomationInventoryBuilder.items(
			client: state.automationPreferences.clients[0],
			organization: state.workspace,
			snapshots: [:]
		)
		let item = try #require(items.first)
		return .init(
			operationID: UUID(83),
			action: action,
			targetID: item.id,
			expectedRevision: item.revision,
			name: "Assistant folder"
		)
	}

	private func automationRequest(_ command: AutomationCommand) -> AutomationRequest {
		.init(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .command(command))
	}
}

extension IntegrationFeatureTests {
	@Test
	internal func unattendedMutationFailsInsteadOfWaitingForApproval() async throws {
		var state = automationFixture()
		state.automation.isUnattended = true
		let command = try automationCommand(.createFolder, state: state)
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = automationRequest(command)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		expectNoDifference(store.state.workspace, state.workspace)
		#expect(store.state.automation.pending[request.id] == nil)
		expectNoDifference(responses, [.failure(.userActionRequired)])
	}

	@Test
	internal func onlyTheUnattendedRunClientKeepsAGrantBeyondTheTemporaryWindow() async throws {
		var state = automationFixture()
		var other = state.automationPreferences.clients[0]
		other.id = UUID(90)
		other.name = "Other client"
		state.automationPreferences.clients.append(other)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// An attended session cannot mark a run client.
		await store.send(.automation(.ui(.unattendedClient(UUID(80)))))
		#expect(store.state.automation.unattendedClientID == nil)

		await store.send(.automation(.ui(.unattended)))
		await store.send(.automation(.ui(.temporaryGrantWindow(5_000))))
		#expect(store.state.automation.temporaryGrantWindow == 900)
		await store.send(.automation(.ui(.temporaryGrantWindow(5))))
		#expect(store.state.automation.temporaryGrantWindow == 5)
		await store.send(.automation(.ui(.unattendedClient(UUID(80)))))

		var run = store.state.automationPreferences.clients[0]
		run.mutationGrantUntil = .distantFuture
		await store.send(.automation(.ui(.updateClient(run))))
		other.mutationGrantUntil = .distantFuture
		await store.send(.automation(.ui(.updateClient(other))))
		await store.finish()
		let clients = store.state.automationPreferences.clients
		expectNoDifference(clients[0].mutationGrantUntil, .distantFuture)
		expectNoDifference(clients[1].mutationGrantUntil, Date(timeIntervalSince1970: 105))

		let later = Date(timeIntervalSince1970: 100 + 3_600)
		#expect(store.state.automation.mutationGrantIsActive(for: clients[0], now: later))
		#expect(!store.state.automation.mutationGrantIsActive(for: clients[1], now: later))

		// Revoking the run client at stop ends its grant and its standing.
		await store.send(.automation(.ui(.revokeClient(UUID(80)))))
		await store.finish()
		#expect(store.state.automation.unattendedClientID == nil)
		#expect(!store.state.automationPreferences.clients.contains { $0.id == UUID(80) })
	}

	@Test
	internal func runTimeoutBoundsTheUnattendedGrant() async throws {
		var state = automationFixture()
		state.automation.isUnattended = true
		state.automation.unattendedClientID = UUID(80)
		var client = state.automationPreferences.clients[0]
		client.mutationGrantUntil = Date(timeIntervalSince1970: 100 + 3_600)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.ui(.updateClient(client))))
		await store.finish()
		client = store.state.automationPreferences.clients[0]
		expectNoDifference(client.mutationGrantUntil, Date(timeIntervalSince1970: 100 + 3_600))
		#expect(store.state.automation.mutationGrantIsActive(for: client, now: Date(timeIntervalSince1970: 3_699)))
		#expect(!store.state.automation.mutationGrantIsActive(for: client, now: Date(timeIntervalSince1970: 3_700)))
	}

	@Test
	internal func unboundedGrantLeftByACrashedRunIsVoidInAnAttendedSession() async throws {
		var state = automationFixture()
		state.automationPreferences.clients[0].mutationGrantUntil = .distantFuture
		let command = try automationCommand(.createFolder, state: state)
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = automationRequest(command)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		#expect(store.state.automation.pending[request.id]?.awaitingApproval == true)
		#expect(store.state.workspace.folders.isEmpty)
	}

	@Test
	internal func attendedSessionRevokesTheGrantACrashedRunLeftBehind() async throws {
		let state = automationFixture()
		var preferences = state.automationPreferences
		var run = preferences.clients[0]
		run.name = "Arx headless run"
		run.mutationGrantUntil = .distantFuture
		var interactive = preferences.clients[0]
		interactive.id = UUID(90)
		interactive.mutationGrantUntil = Date(timeIntervalSince1970: 100 + 900)
		preferences.clients = [run, interactive]

		let attended = AutomationState.attendedPreferences(preferences, now: Date(timeIntervalSince1970: 100), makeID: { UUID(91) })
		expectNoDifference(attended.clients.map(\.mutationGrantUntil), [nil, Date(timeIntervalSince1970: 100 + 900)])
		expectNoDifference(attended.clients.map(\.grantRevision), [UUID(91), UUID(82)])

		// The client keeps its other grants; only its unbounded approval is gone.
		#expect(attended.clients[0].allowsRead && attended.clients[0].allowsManagement && !attended.clients[0].scopes.isEmpty)
		expectNoDifference(AutomationState.attendedPreferences(attended, now: Date(timeIntervalSince1970: 100)), attended)
	}

	@Test
	internal func settingsPresentsARunGrantForTheRunInsteadOfADate() async throws {
		var automation = AutomationState()
		var client = automationFixture().automationPreferences.clients[0]
		let now = Date(timeIntervalSince1970: 100)
		expectNoDifference(automation.mutationGrant(for: client, now: now), .none)

		client.mutationGrantUntil = Date(timeIntervalSince1970: 100 + 900)
		expectNoDifference(automation.mutationGrant(for: client, now: now), .temporary(until: Date(timeIntervalSince1970: 1_000)))

		client.mutationGrantUntil = .distantFuture
		expectNoDifference(automation.mutationGrant(for: client, now: now), .headlessRun(until: nil))

		client.mutationGrantUntil = Date(timeIntervalSince1970: 100 + 3_600)
		expectNoDifference(automation.mutationGrant(for: client, now: now), .headlessRun(until: Date(timeIntervalSince1970: 3_700)))

		// A shortened test window still separates a run's grant from a temporary one.
		automation.temporaryGrantWindow = 5
		client.mutationGrantUntil = Date(timeIntervalSince1970: 104)
		expectNoDifference(automation.mutationGrant(for: client, now: now), .temporary(until: Date(timeIntervalSince1970: 104)))

		client.mutationGrantUntil = Date(timeIntervalSince1970: 99)
		expectNoDifference(automation.mutationGrant(for: client, now: now), .none)
	}

	@Test
	internal func unattendedRunClientMutatesPastTheTemporaryWindow() async throws {
		var state = automationFixture()
		state.automation.isUnattended = true
		state.automation.unattendedClientID = UUID(80)
		state.automation.temporaryGrantWindow = 5
		state.automationPreferences.clients[0].mutationGrantUntil = .distantFuture
		let command = try automationCommand(.createFolder, state: state)
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100 + 3_600)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.event(.host(.request(automationRequest(command))))))
		await store.receive(\.automation.event.inspected)
		await store.finish()
		#expect(!responses.contains(.failure(.userActionRequired)))
		#expect(store.state.workspace.folders.count == 1)
	}

	@Test
	internal func becomingUnattendedFinishesWaitingApprovals() async throws {
		let state = automationFixture()
		let command = try automationCommand(.createFolder, state: state)
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = automationRequest(command)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		#expect(store.state.automation.pending[request.id]?.awaitingApproval == true)

		await store.send(.automation(.ui(.unattended)))
		#expect(store.state.automation.isUnattended)
		#expect(store.state.automation.pending[request.id] == nil)
		expectNoDifference(responses, [.failure(.userActionRequired)])
		expectNoDifference(store.state.workspace, state.workspace)
	}
}

extension IntegrationFeatureTests {
	/// Back-to-back toggles race to register their server transitions off the main actor. Only
	/// the newest transition may reach the control client, so the server ends up running once.
	@Test
	internal func backToBackAutomationTogglesLeaveOnlyTheNewestServerTransition() async throws {
		let organization = fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		var lost = 0

		for _ in 0..<200 {
			let server = LockIsolated<(isRunning: Bool, stops: Int, starts: Int)>((false, 0, 0))
			let store = Store(initialState: state) { AppFeature() } withDependencies: {
				$0.uuid = .incrementing
				$0.automationControl.stop = {
					server.withValue { server in
						server.isRunning = false
						server.stops += 1
					}
				}
				$0.automationControl.start = {
					server.withValue { server in
						server.isRunning = true
						server.starts += 1
					}
					return "/tmp/arx-automation.sock"
				}
			}
			let toggles = [true, false, true].map { store.send(.automation(.ui(.enabled($0)))) }
			for toggle in toggles { await toggle.finish() }

			let value = server.value
			if !value.isRunning || value.stops != 1 || value.starts != 1 || store.automation.socketPath == nil { lost += 1 }
		}

		#expect(lost == 0)
	}

	/// DEV-1001: Add Client… opens a form; Cancel clears it, and a created client closes it.
	@Test
	internal func addClientOpensAFormThatCancelAndCreationClose() async throws {
		let organization = fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.ui(.newClient))) {
			$0.automation.isAddingClient = true
		}
		await store.send(.automation(.ui(.clientName("Claude")))) {
			$0.automation.newClientName = "Claude"
		}
		await store.send(.automation(.ui(.cancelNewClient))) {
			$0.automation.isAddingClient = false
			$0.automation.newClientName = ""
		}

		await store.send(.automation(.ui(.newClient))) {
			$0.automation.isAddingClient = true
		}
		let client = AutomationClient(id: UUID(7), name: "Claude", credentialDigest: "abc123", capabilities: [], grantRevision: UUID(8))
		await store.send(.automation(.event(.clientCreated(client, "token")))) {
			$0.automation.isAddingClient = false
		}
		#expect(store.state.automationPreferences.clients.contains { $0.id == client.id })
	}

	@Test
	internal func automationServerTransitionReportsInBeforeReachingTheControlClient() async throws {
		let organization = fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.automationControl.start = { "/tmp/arx-automation.sock" }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.ui(.enabled(true))))
		await store.receive(\.automation.event.serverRequested, UUID(0))
		await store.receive(\.automation.event.started) {
			$0.automation.socketPath = "/tmp/arx-automation.sock"
		}

		// A transition superseded before it reported in changes nothing.
		await store.send(.automation(.event(.serverRequested(UUID(99)))))
		await store.finish()
	}
}
