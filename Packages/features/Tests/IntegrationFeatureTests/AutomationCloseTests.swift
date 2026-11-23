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
internal struct AutomationCloseTests {
	@Test(arguments: ["ordinary", "pin", "favorite"], [false, true])
	internal func closeCommitsExistingLifecycleAndExactReceipt(
		kind: String,
		additional: Bool
	) async throws {
		let fixture = Fixture(kind: kind, additional: additional)
		let request = try fixture.request()
		await fixture.store.send(.automation(.event(.host(.request(request))))).finish()

		expectNoDifference(fixture.closed, [fixture.tab.id])
		expectNoDifference(fixture.approvals, [fixture.tab.id])
		expectNoDifference(fixture.responseFailures, [nil])
		expectNoDifference(fixture.responses, [.command(.init(
			operationID: UUID(83),
			status: .committed,
			targetID: fixture.tab.id.rawValue
		))])
		let state = fixture.store.state
		#expect(state.automation.pending.isEmpty)
		#expect(state.automation.closeReceipts.isEmpty)
		#expect(state.automationOrdinaryHosts.allSatisfy { $0.pendingTabCloses.isEmpty })
		#expect(state.automationOrdinaryHosts.allSatisfy { !$0.viewer.panes.contains { $0.item.tab?.id == fixture.tab.id } })
		try state.workspace.validate()
		if kind == "ordinary" {
			#expect(!state.workspace.tabs.ids.contains(fixture.tab.id))
			expectNoDifference(state.workspace.archive.last?.tab, fixture.tab)
			for host in state.automationOrdinaryHosts {
				if host.archive.isPresented { expectNoDifference(host.archive.entries, state.workspace.archive) }
			}

			// The agent's close is its step, not the window's (DEV-1030).
			#expect(state.main.sidebar.undo.last.map { $0.author != .person } == true)
		} else {
			let retained = try #require(state.workspace.tabs[id: fixture.tab.id])
			expectNoDifference(retained.savedDestination, fixture.tab.savedDestination)
			expectNoDifference(retained.restoration.url, fixture.tab.savedDestination?.url)
			expectNoDifference(retained.automationClientID, fixture.tab.automationClientID)
			#expect(state.workspace.archive.isEmpty)
			#expect(state.main.sidebar.undo.last.map { $0.author != .person } == true)
			#expect(state.automationOrdinaryHosts.allSatisfy {
				!$0.viewer.allPresentations.contains { $0.panes.contains { $0.tabID == fixture.tab.id } }
			})
		}

		// The response's own removed target is valid only during its receipt lifetime.
		expectNoDifference(
			state.automationResponseValidation(request, result: fixture.responses[0], snapshots: [:]),
			.denied
		)
		await fixture.store.send(.automation(.event(.host(.request(request))))).finish()
		expectNoDifference(fixture.responses.last, .failure(.duplicateOperation))
		expectNoDifference(fixture.closed, [fixture.tab.id])
	}

	@Test
	internal func nativeCompletionCommitsBeforeReturnAndCannotUnloadANewerReopen() async throws {
		let fixture = Fixture(kind: "favorite")
		var committedBeforeReturn = false
		fixture.afterDidClose = {
			committedBeforeReturn = fixture.store.workspace.tabs[0].restoration.url == fixture.tab.savedDestination?.url
			let retained = fixture.store.workspace.tabs[0]
			fixture.store.send(.main(.viewer(.show(retained, in: fixture.store.main.viewer.activePaneID))))
		}
		defer { fixture.afterDidClose = nil }

		let request = try fixture.request()
		await fixture.store.send(.automation(.event(.host(.request(request))))).finish()
		#expect(committedBeforeReturn)
		expectNoDifference(fixture.closed, [fixture.tab.id])
		expectNoDifference(fixture.store.main.viewer.item.tab?.id, fixture.tab.id)
		expectNoDifference(fixture.responseFailures, [.staleTarget])
	}

	@Test(arguments: ["refused", "nativeFailure", "authorization", "unsupported"])
	internal func unsuccessfulClosePreservesWorkspaceAndReleasesOnlyOwnedGuards(reason: String) async throws {
		let fixture = Fixture(supportsClose: reason != "unsupported")
		fixture.permitted = reason != "refused"
		fixture.nativeCloses = reason != "nativeFailure"
		fixture.authorized = reason != "authorization"
		let before = fixture.store.workspace
		await fixture.store.send(.automation(.event(.host(.request(try fixture.request()))))).finish()

		expectNoDifference(fixture.store.workspace, before)
		if reason == "authorization" || reason == "unsupported" {
			expectNoDifference(fixture.approvals, [])
		}
		expectNoDifference(fixture.responses, [.failure(
			reason == "refused" ? .cancelled : reason == "nativeFailure" ? .engineFailed : reason == "unsupported" ? .unsupported : .denied
		)])
		#expect(fixture.store.main.pendingTabCloses.isEmpty)
		#expect(fixture.store.automation.pending.isEmpty)
		#expect(fixture.store.automation.closeReceipts.isEmpty)
	}

	@Test(arguments: ["cancel", "disconnect", "revoke", "disabled", "source", "navigation", "hostClosed"])
	internal func heldBeforeUnloadCannotCloseAfterAuthorityOrSourceChanges(change: String) async throws {
		let fixture = Fixture(kind: "pin")
		let entered = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Bool>.makeStream()
		fixture.permission = {
			entered.continuation.yield(())
			for await value in release.stream { return value }
			return false
		}
		let request = try fixture.request()
		let task = fixture.store.send(.automation(.event(.host(.request(request)))))
		for await _ in entered.stream { break }
		#expect(fixture.store.main.pendingTabCloses.contains(fixture.tab.id))

		switch change {
		case "cancel": fixture.store.send(.automation(.event(.host(.cancel(request.id)))))
		case "disconnect": fixture.store.send(.automation(.event(.host(.disconnected(sessionID: request.sessionID)))))
		case "revoke": fixture.store.send(.automation(.ui(.revokeClient(request.clientID))))
		case "disabled": fixture.store.send(.automation(.ui(.enabled(false))))
		case "source":
			fixture.store.send(.main(.viewer(.show(nil, in: fixture.store.main.viewer.panes.last!.id))))
		case "navigation":
			fixture.snapshots[fixture.tab.id]?.revision += 1
		default:
			fixture.store.send(.ui(.closeWindow))
		}

		// A stale ordinary completion must not clear the operation's token-owned guard.
		if ["source", "navigation"].contains(change) {
			fixture.store.send(.main(.event(.closePermissionDenied(fixture.tab.id))))
			#expect(fixture.store.main.pendingTabCloses.contains(fixture.tab.id))
		}
		release.continuation.yield(true)
		release.continuation.finish()
		await task.finish()
		expectNoDifference(fixture.closed, [])
		#expect(fixture.store.workspace.tabs.ids.contains(fixture.tab.id))
		#expect(fixture.store.automation.closeReceipts.isEmpty)
		#expect(!fixture.store.main.pendingTabCloses.contains(fixture.tab.id))
	}

	@Test
	internal func pendingGuardOwnershipSurvivesStaleUICompletionAndPreservesUnrelatedClose() throws {
		let fixture = Fixture()
		var state = fixture.store.state
		let request = try fixture.request()
		let source = try AutomationCloseRequest(token: UUID(90), tab: fixture.tab, state: state)
		var pending = AutomationState.Pending(request: request, grantRevision: UUID(82), approved: true, executing: true)
		pending.closeRequest = source
		state.automation.pending[request.id] = pending
		state.main.automationCloseRequests[fixture.tab.id] = source.token
		let other = state.workspace.tabs[1].id
		state.main.pendingTabCloses.insert(other)
		state.main.pendingTabCloses.remove(fixture.tab.id)
		expectNoDifference(state.main.pendingTabCloses, [fixture.tab.id, other])

		state.discardAutomationRequest(request.id)
		expectNoDifference(state.main.pendingTabCloses, [other])
		#expect(state.main.automationCloseRequests.isEmpty)
		#expect(state.automation.pending.isEmpty)
	}

	@Test(arguments: ["reopen", "reopenedThenUnloaded", "grant", "scope", "session", "archive", "wrongRequest", "wrongResult"])
	internal func receiptCannotAuthorizeNewStateOrAnotherOperation(change: String) async throws {
		let fixture = Fixture(kind: change == "archive" ? "ordinary" : "favorite")
		let request = try fixture.request()
		await fixture.store.send(.automation(.event(.host(.request(request))))).finish()
		var state = try #require(fixture.stateAtResponse)
		var responseRequest = request
		var result = fixture.responses[0]
		expectNoDifference(state.automationResponseValidation(request, result: result, snapshots: [:]), nil)

		switch change {
		case "reopen":
			state.main.viewer.item = .init(tab: fixture.tab, generation: state.main.viewer.item.generation + 1)
		case "reopenedThenUnloaded":
			state.main.viewer.item = .init(tab: nil, generation: state.main.viewer.item.generation + 2)
		case "grant": state.automationPreferences.clients[0].grantRevision = UUID(99)
		case "scope": state.automationPreferences.clients[0].scopes = []
		case "session": state.automation.sessions[request.sessionID] = nil
		case "archive": state.workspace.archive = []
		case "wrongRequest": responseRequest.sessionID = UUID(99)
		default:
			result = .command(.init(operationID: UUID(83), status: .acceptedLoading, targetID: fixture.tab.id.rawValue))
		}
		state.main.sidebar.organization = state.workspace
		#expect(state.automationResponseValidation(responseRequest, result: result, snapshots: [:]) != nil)
	}

	@Test(.timeLimit(.minutes(1)), arguments: [false, true])
	internal func authenticatedTransportReceivesOnlyItsCommittedRemovalReceipt(revokeBeforeReply: Bool) async throws {
		let fixture = Fixture()
		let directory = URL(filePath: "/tmp/arx-close-" + UUID().uuidString.prefix(12))
		defer { try? FileManager.default.removeItem(at: directory) }
		let host = BrowserAutomationHost(directory: directory)
		host.configure(
			preferences: { fixture.store.automationPreferences },
			receive: { fixture.store.send(.automation(.event(.host($0)))) },
			authorizeResponse: { request, result in
				fixture.store.state.automationResponseValidation(request, result: result, snapshots: fixture.snapshots)
			}
		)
		defer { fixture.reply = nil }
		fixture.reply = { id, result in
			if revokeBeforeReply { host.revoke(UUID(80)) }
			host.respond(id, result: result)
		}
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: UUID(80),
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(81),
			payload: .hello
		)
		do {
			let hello = try await LocalAutomationSocket.exchange(path: path, envelope: envelope)
			guard case let .hello(epoch) = hello else { throw AutomationFailure.staleSession }
			envelope.epoch = epoch
			let request = try fixture.request()
			envelope.payload = .request(request.id, request.operation)
			let response = try await LocalAutomationSocket.exchange(path: path, envelope: envelope)
			if revokeBeforeReply {
				guard case .failure(.disconnected) = response else {
					Issue.record("Revoked close receipt reached the peer")
					throw AutomationFailure.invalidRequest
				}
			} else {
				guard case let .result(result) = response else { throw AutomationFailure.invalidRequest }
				expectNoDifference(result, .command(.init(
					operationID: UUID(83),
					status: .committed,
					targetID: fixture.tab.id.rawValue
				)))
			}
			#expect(!fixture.store.workspace.tabs.ids.contains(fixture.tab.id))
			#expect(fixture.store.automation.closeReceipts.isEmpty)
			await host.stop()
		} catch {
			await host.stop()
			throw error
		}
	}

	@MainActor
	private final class Fixture {
		internal let tab: BrowserCore.Tab
		internal var store: StoreOf<AppFeature>!
		internal var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
		internal var approvals: [BrowserCore.Tab.ID] = []
		internal var closed: [BrowserCore.Tab.ID] = []
		internal var responses: [AutomationResult] = []
		internal var responseFailures: [AutomationFailure?] = []
		internal var stateAtResponse: AppFeature.State?
		internal var permitted: Bool = true
		internal var nativeCloses: Bool = true
		internal var authorized: Bool = true
		internal var permission: (@MainActor () async -> Bool)?
		internal var reply: (@MainActor (UUID, AutomationResult) -> Void)?
		internal var afterDidClose: (@MainActor () -> Void)?

		internal init(
			kind: String = "ordinary",
			additional: Bool = false,
			supportsClose: Bool = true
		) {
			var organization = IntegrationFeatureTests().fixture()
			var tab = organization.tabs[0]
			tab.automationClientID = UUID(80)
			if kind != "ordinary" {
				tab.savedDestination = .init(title: "Saved", url: URL(string: "https://capturecontext.dev/saved")!)
				organization.spaces[0].unpinnedTabs.removeAll { $0 == tab.id }
				if kind == "favorite" {
					organization.profiles[0].favorites.append(tab.id)
				} else {
					organization.spaces[0].savedItems.append(.tab(tab.id))
				}
			}
			organization.tabs[0] = tab
			self.tab = tab
			self.snapshots = [tab.id: .init(navigation: .init(url: tab.restoration.url), revision: 2)]
			let location = AutomationAccess.location(of: tab.id, in: organization)!
			let client = AutomationClient(
				id: UUID(80),
				name: "Fixture",
				credentialDigest: AutomationSecurity.digest(Data(String(repeating: "0", count: 64).utf8)),
				scopes: [.tab(tab.id, profileID: tab.profileID, location: location)],
				allowsRead: true,
				allowsManagement: true,
				mutationGrantUntil: Date(timeIntervalSince1970: 200),
				grantRevision: UUID(82)
			)
			var state = AppFeature.State(
				main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
				automation: .init(isEnabled: true, clients: [client])
			)
			var owner = additional
			? MainFeature.State(organization: organization, spaceID: organization.spaces[0].id, id: UUID(72))
			: state.main
			owner.archive.profileID = tab.profileID
			owner.archive.isPresented = true
			owner.viewer.item = .init(tab: organization.tabs[1], generation: 3)
			owner.viewer.panes.append(.init(id: UUID(71), item: .init(tab: tab, generation: 7)))
			owner.viewer.presentations.append(.init(
				id: organization.spaces[1].id,
				panes: [.init(id: UUID(73), tabID: tab.id)],
				activePaneID: UUID(73)
			))
			if additional { state.windows.append(owner) } else { state.main = owner }
			state.automation.sessions[UUID(81)] = client.id
			self.store = Store(initialState: state) { AppFeature() } withDependencies: { [weak self] dependencies in
				dependencies.uuid = .incrementing
				dependencies.date.now = Date(timeIntervalSince1970: 100)
				dependencies.browserEngine.snapshot = { self?.snapshots[$0] }
				dependencies.browserEngine.open = { tab in
					self?.snapshots[tab.id] = .init(navigation: .init(url: tab.restoration.url), revision: 20)
				}
				dependencies.browserEngine.permitsClosing = { id in
					guard let self else { return false }
					self.approvals.append(id)
					if let permission = self.permission { return await permission() }
					return self.permitted
				}
				dependencies.browserEngine.close = { id in
					self?.closed.append(id)
					if self?.nativeCloses == true { self?.snapshots[id] = nil }
				}
				if supportsClose {
					dependencies.browserEngine.closeAuthorized = { id, revision, authorize, didClose in
						guard let self, authorize() else { throw AutomationFailure.denied }
						guard self.snapshots[id]?.revision == revision
						else { throw AutomationFailure.staleTarget }
						self.approvals.append(id)
						let permitted: Bool
						if let permission = self.permission {
							permitted = await permission()
						} else {
							permitted = self.permitted
						}
						try Task.checkCancellation()
						guard permitted else { return false }
						guard authorize() else { throw AutomationFailure.denied }
						guard self.snapshots[id]?.revision == revision
						else { throw AutomationFailure.staleTarget }
						guard self.nativeCloses else { throw AutomationFailure.engineFailed }

						self.closed.append(id)
						self.snapshots[id] = nil
						didClose()
						self.afterDidClose?()
						return true
					}
				}
				dependencies.automationControl.authorize = { id in
					guard let self, self.authorized else { return false }
					return self.store.state.automationCanExecute(id, snapshots: self.snapshots, now: Date(timeIntervalSince1970: 100))
				}
				dependencies.automationControl.respond = { id, result in
					guard let self else { return }
					self.responses.append(result)
					self.stateAtResponse = self.store.state
					if let request = self.store.automation.closeReceipts[id]?.request {
						self.responseFailures.append(self.store.state.automationResponseValidation(request, result: result, snapshots: self.snapshots))
					}
					self.reply?(id, result)
				}
			}
		}

		internal func request() throws -> AutomationRequest {
			let item = try #require(AutomationInventoryBuilder.items(
				client: store.automationPreferences.clients[0],
				organization: store.workspace,
				snapshots: snapshots
			).first { $0.id == tab.id.rawValue })
			return .init(
				id: UUID(84),
				clientID: UUID(80),
				sessionID: UUID(81),
				operation: .command(.init(operationID: UUID(83), action: .closeTab, targetID: item.id, expectedRevision: item.revision))
			)
		}
	}
}
