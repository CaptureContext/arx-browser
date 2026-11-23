@testable import AppFeature
import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func automationPeekUsesExplicitSourceWithoutBorrowingAnotherVisiblePane() async throws {
		var state = hostFixture()
		let source = state.workspace.tabs[0]
		let other = BrowserCore.Tab(
			id: .init(rawValue: UUID(90)),
			profileID: source.profileID,
			restoration: source.restoration
		)
		state.workspace.tabs.append(other)
		state.workspace.spaces[0].unpinnedTabs.append(other.id)
		state.main.sidebar.organization = state.workspace
		state.main.viewer.panes.append(.init(id: UUID(91), item: .init(tab: other)))
		let snapshots = hostSnapshots(state)
		let command = try hostCommand(.openPeek, state: state, snapshots: snapshots, target: other.id.rawValue)
		let request = hostRequest(command)
		let pending = AutomationState.Pending(request: request, grantRevision: UUID(82), approved: true)
		let context = state.automationHostContext(
			for: pending,
			snapshots: snapshots,
			now: Date(timeIntervalSince1970: 100)
		)
		#expect(context == nil)
	}

	@Test
	internal func automationHostApprovalRejectsMovedSourceNavigationAndProfileSubstitution() async throws {
		let state = hostFixture()
		let snapshots = hostSnapshots(state)
		var command = try hostCommand(.openPeek, state: state, snapshots: snapshots)
		command.url = URL(string: "https://owned.example/preview")!
		var pending = AutomationState.Pending(request: hostRequest(command), grantRevision: UUID(82), approved: true)
		let context = try #require(state.automationHostContext(
			for: pending,
			snapshots: snapshots,
			now: Date(timeIntervalSince1970: 100)
		))
		pending.hostContext = context
		let client = state.automationPreferences.clients[0]
		var moved = state
		moved.main.viewer.item.tab = nil
		expectNoDifference(
			moved.automationHostValidation(
				pending,
				command: command,
				client: client,
				snapshots: snapshots,
				now: Date(timeIntervalSince1970: 100)
			),
			.staleTarget
		)
		var hidden = snapshots
		hidden[state.workspace.tabs[0].id]?.isVisibleForCapture.toggle()

		// Surface release changes host visibility, never the bound document.
		expectNoDifference(
			state.automationHostValidation(
				pending,
				command: command,
				client: client,
				snapshots: hidden,
				now: Date(timeIntervalSince1970: 100)
			),
			nil
		)
		var navigated = snapshots
		navigated[state.workspace.tabs[0].id] = .init(
			navigation: .init(url: URL(string: "https://changed.example")!),
			revision: 2,
			documentRevision: 8
		)
		expectNoDifference(
			state.automationHostValidation(
				pending,
				command: command,
				client: client,
				snapshots: navigated,
				now: Date(timeIntervalSince1970: 100)
			),
			.staleTarget
		)
		var crossed = state
		crossed.workspace.tabs[0] = .init(
			id: state.workspace.tabs[0].id,
			profileID: .init(rawValue: UUID(99)),
			restoration: state.workspace.tabs[0].restoration
		)
		let crossedValidation = crossed.automationHostValidation(
			pending,
			command: command,
			client: client,
			snapshots: snapshots,
			now: Date(timeIntervalSince1970: 100)
		)
		#expect(crossedValidation != nil)
	}

	@Test
	internal func automationPresentationInventoryIsConnectionBoundExpiringAndRefreshesAfterLoad() async throws {
		var state = hostFixture()
		let command = try hostCommand(.openPeek, state: state, snapshots: hostSnapshots(state))
		let request = hostRequest(command)
		let source = try #require(state.peekSource(windowID: state.main.id, paneID: state.main.viewer.activePaneID))
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(90)),
			profileID: source.profileID,
			restoration: .init(title: "Hidden title", url: URL(string: "https://secret.example")!)
		)
		state.peeks.append(.init(id: UUID(91), source: source, tab: tab, isTemporary: true))
		let handle = AutomationHostHandle(
			id: UUID(92),
			clientID: request.clientID,
			sessionID: request.sessionID,
			grantRevision: UUID(82),
			expiresAt: Date(timeIntervalSince1970: 200),
			kind: .peek,
			hostID: UUID(91),
			tabID: tab.id,
			profileID: tab.profileID,
			targetID: command.targetID,
			source: source
		)
		state.automation.hostHandles[handle.id] = handle
		let first = state.automationPresentations(for: request, snapshots: [:], now: Date(timeIntervalSince1970: 100))
		#expect(first.count == 1)
		let loaded = [
			tab.id: BrowserSessionSnapshot(navigation: .init(url: tab.restoration.url), revision: 3, documentRevision: 7)
		]
		let refreshed = state.automationPresentations(
			for: request,
			snapshots: loaded,
			now: Date(timeIntervalSince1970: 100)
		)
		#expect(first[0].revision != refreshed[0].revision)
		var foreign = request
		foreign.sessionID = UUID(95)
		state.automation.sessions[foreign.sessionID] = foreign.clientID
		expectNoDifference(state.automationPresentations(for: foreign, snapshots: loaded, now: Date(timeIntervalSince1970: 100)), [])
		foreign.clientID = UUID(96)
		expectNoDifference(state.automationPresentations(for: foreign, snapshots: loaded, now: Date(timeIntervalSince1970: 100)), [])
		expectNoDifference(state.automationPresentations(for: request, snapshots: loaded, now: Date(timeIntervalSince1970: 200)), [])
		#expect(state.peeks.count == 1) // Expiration never closes content.
		state.automationPreferences.clients[0].grantRevision = UUID(97)
		expectNoDifference(state.automationPresentations(for: request, snapshots: loaded, now: Date(timeIntervalSince1970: 100)), [])
	}

	@Test
	internal func automationPeekPublishesAcceptedLoadingAndReplaysNoMutation() async throws {
		let state = hostFixture()
		let snapshots = hostSnapshots(state)
		var command = try hostCommand(.openPeek, state: state, snapshots: snapshots)
		command.url = URL(string: "https://owned.example/preview")!
		var responses: [AutomationResult] = []
		var opened: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.snapshot = { snapshots[$0] }
			$0.browserEngine.open = { opened.append($0.id) }
			$0.browserEngine.events = { _ in .finished }
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.automationControl.respond = { _, response in responses.append(response) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = hostRequest(command)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.receive(\.automation.event.inspected)
		await store.finish()
		let peek = try #require(store.state.peeks.first)
		expectNoDifference(peek.source.tabID, state.workspace.tabs[0].id)
		expectNoDifference(store.state.workspace, state.workspace)
		guard case let .command(result) = responses.last else {
			Issue.record("No accepted host receipt")
			return
		}
		expectNoDifference(result.status, .acceptedLoading)
		expectNoDifference(result.presentation?.tabID, peek.tab.id.rawValue)
		#expect(opened.contains(peek.tab.id))
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		expectNoDifference(responses.last, .failure(.duplicateOperation))
		#expect(store.state.peeks.count == 1)
	}

	@Test
	internal func automationPromotionCommitsExactPeekSessionThroughExistingRelease() async throws {
		var state = hostFixture()
		let source = try #require(state.peekSource(windowID: state.main.id, paneID: state.main.viewer.activePaneID))
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(90)),
			profileID: source.profileID,
			restoration: .init(title: "Preview", url: URL(string: "https://owned.example/preview")!)
		)
		state.peeks.append(.init(id: UUID(91), source: source, tab: tab, isTemporary: true))
		let handle = AutomationHostHandle(
			id: UUID(92),
			clientID: UUID(80),
			sessionID: UUID(81),
			grantRevision: UUID(82),
			expiresAt: Date(timeIntervalSince1970: 200),
			kind: .peek,
			hostID: UUID(91),
			tabID: tab.id,
			profileID: tab.profileID,
			targetID: source.tabID!.rawValue,
			source: source
		)
		state.automation.hostHandles[handle.id] = handle
		var snapshots = hostSnapshots(state)
		snapshots[tab.id] = .init(navigation: .init(url: tab.restoration.url), revision: 1, documentRevision: 7)
		let base = try hostCommand(.openPeek, state: state, snapshots: snapshots)
		let projection = try #require(state.automationPresentations(
			for: hostRequest(base),
			snapshots: snapshots,
			now: Date(timeIntervalSince1970: 100)
		).first)
		let command = AutomationCommand(
			operationID: UUID(93),
			action: .promotePeekToTab,
			targetID: source.tabID!.rawValue,
			expectedRevision: base.expectedRevision,
			focus: true,
			presentationID: projection.id,
			presentationRevision: projection.revision
		)
		let capturedSnapshots = snapshots
		var responses: [AutomationResult] = []
		var closed: [BrowserCore.Tab.ID] = []
		var released: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.snapshot = { capturedSnapshots[$0] }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.events = { _ in .finished }
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in }, release: { released.append($0) })
			$0.automationControl.respond = { _, response in responses.append(response) }
		}
		await store.send(.automation(.event(.host(.request(hostRequest(command)))))).finish()
		#expect(store.peeks.isEmpty)
		expectNoDifference(store.workspace.tabs.last?.id, tab.id)
		expectNoDifference(closed, [])
		#expect(released.contains(tab.id))
		guard case let .command(response) = responses.last else {
			Issue.record("No promotion receipt")
			return
		}
		expectNoDifference(response.status, .committed)
		expectNoDifference(response.targetID, tab.id.rawValue)
	}

	@Test
	internal func expiredOrCanceledPromotionFenceRefusesOnceWithoutClosingUserContent() async throws {
		var state = hostFixture()
		state.automation.hostTransitions[UUID(90)] = UUID(91)
		expectNoDifference(
			state.automationAllowsHostTransition(
				UUID(90),
				requestID: UUID(91),
				snapshots: [:],
				now: Date(timeIntervalSince1970: 100)
			),
			false
		)
		#expect(state.automation.hostTransitions.isEmpty)
		// The stale callback has spent its fence. Later ordinary user actions retain
		// the existing UI handler; an expired MCP lease never takes ownership of it.
		expectNoDifference(
			state.automationAllowsHostTransition(UUID(90), snapshots: [:], now: Date(timeIntervalSince1970: 100)),
			true
		)
		expectNoDifference(state.main.viewer.item.tab?.id, state.workspace.tabs[0].id)
	}

	@Test
	internal func automationLittleArxOpeningRequiresForegroundAndNeverEntersWorkspace() async throws {
		let state = hostFixture()
		let client = state.automationPreferences.clients[0]
		let item = try #require(
			AutomationInventoryBuilder
				.items(client: client, organization: state.workspace, snapshots: [:])
				.first(where: { $0.kind == .space })
		)
		let command = AutomationCommand(
			operationID: UUID(83),
			action: .openLittleArx,
			targetID: item.id,
			expectedRevision: item.revision,
			url: URL(string: "https://owned.example/little")!,
			focus: true
		)
		var responses: [AutomationResult] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.snapshot = { _ in nil }
			$0.automationControl.respond = { _, response in responses.append(response) }
		}
		await store.send(.automation(.event(.host(.request(hostRequest(command)))))).finish()
		expectNoDifference(store.workspace, state.workspace)
		let little = try #require(store.littleWindows.first)
		expectNoDifference(little.tab.profileID, state.workspace.spaces[0].profileID)
		expectNoDifference(little.tab.automationClientID, UUID(80))
		guard case let .command(response) = responses.last else {
			Issue.record("No Little Arx receipt")
			return
		}
		expectNoDifference(response.status, .acceptedLoading)
		expectNoDifference(response.presentation?.kind, .littleArx)
		var background = command
		background.focus = false
		#expect(throws: AutomationFailure.unsupported) { try background.validate() }
	}

	@Test
	internal func automationLittlePromotionPreservesExactSameProfileSession() async throws {
		var state = hostFixture()
		let space = state.workspace.spaces[0]
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(90)),
			profileID: space.profileID,
			restoration: .init(title: "Little", url: URL(string: "https://owned.example/little")!)
		)
		state.littleWindows.append(.init(id: UUID(91), spaceID: space.id, tab: tab))
		let handle = AutomationHostHandle(
			id: UUID(92),
			clientID: UUID(80),
			sessionID: UUID(81),
			grantRevision: UUID(82),
			expiresAt: Date(timeIntervalSince1970: 200),
			kind: .littleArx,
			hostID: UUID(91),
			tabID: tab.id,
			profileID: tab.profileID,
			targetID: space.id.rawValue,
			source: nil
		)
		state.automation.hostHandles[handle.id] = handle
		var snapshots = hostSnapshots(state)
		snapshots[tab.id] = .init(navigation: .init(url: tab.restoration.url), revision: 1, documentRevision: 7)
		let client = state.automationPreferences.clients[0]
		let item = try #require(
			AutomationInventoryBuilder
				.items(client: client, organization: state.workspace, snapshots: snapshots)
				.first(where: { $0.id == space.id.rawValue })
		)
		let request = hostRequest(.init(
			operationID: UUID(83),
			action: .openLittleArx,
			targetID: item.id,
			expectedRevision: item.revision
		))
		let projection = try #require(state.automationPresentations(
			for: request,
			snapshots: snapshots,
			now: Date(timeIntervalSince1970: 100)
		).first)
		let command = AutomationCommand(
			operationID: UUID(93),
			action: .promoteLittleArx,
			targetID: item.id,
			expectedRevision: item.revision,
			focus: true,
			presentationID: projection.id,
			presentationRevision: projection.revision
		)
		let capturedSnapshots = snapshots
		var responses: [AutomationResult] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.snapshot = { capturedSnapshots[$0] }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.events = { _ in .finished }
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.automationControl.respond = { _, response in responses.append(response) }
		}
		await store.send(.automation(.event(.host(.request(hostRequest(command)))))).finish()
		#expect(store.littleWindows.isEmpty)
		expectNoDifference(store.workspace.tabs.last?.id, tab.id)
		expectNoDifference(closed, [])
		guard case let .command(response) = responses.last else {
			Issue.record("No promotion receipt")
			return
		}
		expectNoDifference(response.status, .committed)
		expectNoDifference(response.targetID, tab.id.rawValue)
	}

	@Test
	internal func unattendedRunsRefuseHostOperationsAsUnsupported() async throws {
		var state = hostFixture()
		state.automation.isUnattended = true
		let snapshots = hostSnapshots(state)
		let command = try hostCommand(.openPeek, state: state, snapshots: snapshots)
		let pending = AutomationState.Pending(request: hostRequest(command), grantRevision: UUID(82), approved: true)
		let client = state.automationPreferences.clients[0]

		expectNoDifference(
			state.automationHostValidation(
				pending,
				command: command,
				client: client,
				snapshots: snapshots,
				now: Date(timeIntervalSince1970: 100)
			),
			.unsupported
		)
	}

	@Test
	internal func outdatedPresentationRevisionIsStale() async throws {
		var state = hostFixture()
		let source = try #require(state.peekSource(windowID: state.main.id, paneID: state.main.viewer.activePaneID))
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(90)),
			profileID: source.profileID,
			restoration: .init(title: "Preview", url: URL(string: "https://owned.example/preview")!)
		)
		state.peeks.append(.init(id: UUID(91), source: source, tab: tab, isTemporary: true))
		state.automation.hostHandles[UUID(92)] = AutomationHostHandle(
			id: UUID(92),
			clientID: UUID(80),
			sessionID: UUID(81),
			grantRevision: UUID(82),
			expiresAt: Date(timeIntervalSince1970: 200),
			kind: .peek,
			hostID: UUID(91),
			tabID: tab.id,
			profileID: tab.profileID,
			targetID: source.tabID!.rawValue,
			source: source
		)
		var snapshots = hostSnapshots(state)
		snapshots[tab.id] = .init(navigation: .init(url: tab.restoration.url), revision: 1, documentRevision: 7)
		let base = try hostCommand(.openPeek, state: state, snapshots: snapshots)
		let command = AutomationCommand(
			operationID: UUID(93),
			action: .promotePeekToTab,
			targetID: source.tabID!.rawValue,
			expectedRevision: base.expectedRevision,
			focus: true,
			presentationID: UUID(92),
			presentationRevision: String(repeating: "f", count: 64)
		)
		let pending = AutomationState.Pending(request: hostRequest(command), grantRevision: UUID(82), approved: true)

		expectNoDifference(
			state.automationHostValidation(
				pending,
				command: command,
				client: state.automationPreferences.clients[0],
				snapshots: snapshots,
				now: Date(timeIntervalSince1970: 100)
			),
			.staleTarget
		)
	}

	@Test
	internal func retiredRequestCallbackCannotPromoteUserPeek() async throws {
		var state = hostFixture()
		let source = try #require(state.peekSource(windowID: state.main.id, paneID: state.main.viewer.activePaneID))
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(90)),
			profileID: source.profileID,
			restoration: .init(title: "Preview", url: URL(string: "https://owned.example/preview")!)
		)
		var peek = PeekFeature.State(id: UUID(91), source: source, tab: tab, isTemporary: true)
		peek.phase = .promoting
		state.peeks.append(peek)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
		}

		// A delayed callback of a canceled MCP attempt carries a request ID the fence no longer holds.
		await store.send(.event(.peekPromotionReady(UUID(91), .tab, automationRequestID: UUID(99)))).finish()
		await store.send(.event(.peekReleased(UUID(91), automationRequestID: UUID(99)))).finish()

		expectNoDifference(store.peeks.map(\.id), [UUID(91)])
		expectNoDifference(store.workspace, state.workspace)
	}

	private func hostFixture() -> AppFeature.State {
		let organization = fixture()
		let client = AutomationClient(
			id: UUID(80),
			name: "Host fixture",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.space(organization.spaces[0].id, profileID: organization.profiles[0].id)],
			allowsRead: true,
			allowsManagement: true,
			mutationGrantUntil: Date(timeIntervalSince1970: 200),
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.windowIsOpen = true
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.sidebar.select(organization.tabs[0].id)
		state.automation.sessions[UUID(81)] = client.id
		return state
	}

	private func hostSnapshots(_ state: AppFeature.State) -> [BrowserCore.Tab.ID: BrowserSessionSnapshot] {
		Dictionary(uniqueKeysWithValues: state.workspace.tabs.map { tab in
			(tab.id, .init(navigation: .init(url: tab.restoration.url), revision: 1, documentRevision: 7))
		})
	}

	private func hostCommand(
		_ action: AutomationCommand.Action,
		state: AppFeature.State,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		target: UUID? = nil
	) throws -> AutomationCommand {
		let client = state.automationPreferences.clients[0]
		let items = AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: snapshots)
		let source = try #require(items.first(where: { $0.id == state.workspace.tabs[0].id.rawValue }))
		let target = try #require(items.first(where: { $0.id == (target ?? source.id) }))
		return .init(
			operationID: UUID(83),
			action: action,
			targetID: target.id,
			expectedRevision: target.revision,
			focus: true,
			sourceTabID: source.id,
			sourceRevision: source.revision
		)
	}

	private func hostRequest(_ command: AutomationCommand) -> AutomationRequest {
		.init(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .command(command))
	}
}
