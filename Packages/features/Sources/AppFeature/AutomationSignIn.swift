import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import BrowserPageInspectionClient
import Foundation
import _ComposableArchitecture

/// Trusted user sign-in handoff.
///
/// A client may only ask; the user approves in Arx UI. Approval closes every
/// client's observation and action path before the page is focused for
/// sensitive input, and the lock stays closed until the user resumes, which
/// disconnects every client and revokes the grants the user didn't keep. Arx
/// never reports website authentication success.
@Reducer
internal struct AutomationSignIn {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.automationControl)
	private var control

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.browserPageInspection)
	private var inspection

	@Dependency(\.date.now)
	private var now

	@Dependency(\.uuid)
	private var uuid

	internal enum Monitor: Hashable {
		case operation(UUID)
	}

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.automation.signIn.ui.approve) { state, id in
			guard
				var record = state.automation.signIn.records[id],
				record.status == .approvalRequired,
				!state.automationPrivacyIsLocked
			else { return .none }

			let isCurrent = state.signInSourceIsCurrent(
				record,
				engine: engine,
				strictRevision: true,
				now: now
			)
			guard isCurrent else {
				state.automation.signIn.records[id]?.status = .cancelled
				return .cancel(id: Monitor.operation(id))
			}

			let lock = uuid()
			record.lockID = lock
			record.status = .securingPrivacy
			state.automation.signIn.records[id] = record
			state.automation.signIn.keptClientIDs = [record.clientID]
			state.automationPreferences.authenticationLockID = lock
			state.automationPreferences.authenticationTransitionID = lock

			// Withdraw everything already released or in flight. The host also
			// rechecks the lock before any captured reply leaves the app.
			let scopes = state.automation.inspectionScopes.values.map(\.id)
			state.automation.inspectionScopes.removeAll()
			state.automation.releasedInspections.removeAll()
			state.automation.batchApprovals.removeAll()
			var effects: [Effect<Action>] = []
			for request in Array(state.automation.pending.keys) {
				effects.append(BrowserAutomation().finish(
					request,
					result: .failure(.authenticationProtected),
					state: &state
				))
				effects.append(.cancel(id: request))
			}
			return .merge(effects + [
				.run { [inspection] _ in
					await MainActor.run {
						for scope in scopes { inspection.revokeScope(scope) }
					}
				},
				state.saveWorkspace(),
			])
		}

		Pullback(\.event.saveSucceeded) { state, value in
			let (organization, preferences) = value
			guard organization == state.workspace, preferences == state.persistedPreferences
			else { return .none }

			let resumeTransitionID = state.automation.signIn.resumeTransitionID
			let resumed = state.automation.signIn.resumingLockID != nil
			&& preferences.automation.authenticationLockID == nil
			&& preferences.automation.authenticationTransitionID == resumeTransitionID
			guard !resumed
			else { return finishResume(state: &state) }

			return readiness(state: &state)
		}

		Pullback(\.event.saveFailed) { state, _ in
			for (id, record) in state.automation.signIn.records where record.status == .securingPrivacy {
				state.automation.signIn.records[id]?.status = .cancelled
			}
			return .none
		}

		Pullback(\.automation.signIn.event.tick) { state, id in
			guard var record = state.automation.signIn.records[id], record.isActive
			else { return .none }

			if record.expiresAt <= now {
				record.status = .expired
			} else if !state.signInSourceIsCurrent(record, engine: engine, now: now) {
				record.status = .cancelled
			}
			state.automation.signIn.records[id] = record
			return record.isActive ? .none : .cancel(id: Monitor.operation(id))
		}

		Pullback(\.automation.signIn.ui.confirm) { state, id in
			guard
				var record = state.automation.signIn.records[id],
				record.status == .userActionRequired,
				state.signInSourceIsCurrent(record, engine: engine, now: now)
			else { return .none }

			record.status = .userConfirmed
			state.automation.signIn.records[id] = record
			return .cancel(id: Monitor.operation(id))
		}

		Pullback(\.automation.signIn.ui.cancel) { state, id in
			guard state.automation.signIn.records[id]?.isActive == true
			else { return .none }

			state.automation.signIn.records[id]?.status = .cancelled
			return .cancel(id: Monitor.operation(id))
		}

		Pullback(\.automation.signIn.ui.keepClient) { state, value in
			guard state.automationPrivacyIsLocked, state.automation.signIn.resumingLockID == nil
			else { return .none }

			let (id, keeps) = value
			if keeps {
				state.automation.signIn.keptClientIDs.insert(id)
			} else {
				state.automation.signIn.keptClientIDs.remove(id)
			}
			return .none
		}

		Pullback(\.automation.signIn.ui.resume) { state in
			guard
				state.automationPreferences.authenticationLockID != nil,
				state.automation.signIn.resumingLockID == nil,
				!state.automation.signIn.records.values.contains(where: \.isActive)
			else { return .none }

			return beginResume(state: &state)
		}
	}

	/// The host stays closed until the clear is durably written. A kept client
	/// keeps its credential, scope and expiry, and nothing more: every client is
	/// disconnected, and a new grant revision stops old references and delayed
	/// receipts from resuming with the clear's successful write.
	private func beginResume(state: inout State) -> Effect<Action> {
		let clients = state.automationPreferences.clients
		let kept = state.automation.signIn.keptClientIDs
		let transition = uuid()
		state.automation.signIn.resumingLockID = state.automationPreferences.authenticationLockID
		state.automation.signIn.resumeTransitionID = transition
		state.automationPreferences.authenticationTransitionID = transition
		state.automationPreferences.authenticationLockID = nil
		state.automationPreferences.clients = clients
			.filter { kept.contains($0.id) }
			.map { client in
				var client = client
				client.grantRevision = uuid()
				return client
			}
		state.automation.sessions.removeAll()
		state.automation.inspectionScopes.removeAll()
		state.automation.releasedInspections.removeAll()
		state.automation.batchApprovals.removeAll()
		state.automation.operationBindings.removeAll()
		state.automation.clickReceipts.removeAll()
		state.automation.formReceipts.removeAll()
		state.automation.scrollReceipts.removeAll()
		state.automation.closeReceipts.removeAll()
		return .merge(
			.run { [control] _ in
				for client in clients { await control.revoke(client.id) }
			},
			state.saveWorkspace()
		)
	}

	private func finishResume(state: inout State) -> Effect<Action> {
		state.automation.signIn.resumingLockID = nil
		state.automation.signIn.resumeTransitionID = nil
		state.automation.signIn.keptClientIDs = []
		state.automation.signIn.records.removeAll()
		return .none
	}

	/// Sensitive input becomes available only after the exact lock was stored,
	/// the bound document is unchanged and no earlier page action is uncertain.
	private func readiness(state: inout State) -> Effect<Action> {
		let lock = state.automationPreferences.authenticationLockID
		let transition = state.automationPreferences.authenticationTransitionID
		let securing = state.automation.signIn.records.first { _, record in
			record.status == .securingPrivacy
			&& record.lockID == lock
			&& record.lockID == transition
		}
		guard let (id, record) = securing else { return .none }

		let isCurrent = state.signInSourceIsCurrent(
			record,
			engine: engine,
			strictRevision: true,
			now: now
		)
		guard isCurrent else {
			state.automation.signIn.records[id]?.status = .cancelled
			return .cancel(id: Monitor.operation(id))
		}

		// Success is the normal callback after native physical-slot release.
		// An early cancellation or timeout on the bound document cannot acquire
		// sensitive-input readiness; other tabs and replaced documents do not count.
		let submissionsAreSettled = MainActor.assumeIsolated {
			engine.referenceSubmissionsAreSettled(record.tabID)
		}
		guard submissionsAreSettled else {
			state.automation.signIn.records[id]?.status = .blocked
			return .cancel(id: Monitor.operation(id))
		}

		state.automation.signIn.records[id]?.status = .userActionRequired
		guard let tab = state.workspace.tabs[id: record.tabID]
		else { return .none }

		return OrdinaryTabPresentation().focus(tab, state: &state)
	}
}

extension BrowserAutomation {
	/// Five minutes from begin, including consent and sensitive interaction.
	internal static let signInLifetime: TimeInterval = 300

	internal func signIn(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .signIn(request) = pending.request.operation
		else { return .none }

		switch request.action {
		case .status, .cancel:
			return signInStatus(
				request,
				pending: pending,
				requestID: requestID,
				state: &state
			)

		case .begin:
			return beginSignIn(
				request,
				pending: pending,
				requestID: requestID,
				state: &state
			)
		}
	}

	private func signInStatus(
		_ request: AutomationSignInRequest,
		pending: AutomationState.Pending,
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			var record = state.automation.signIn.records[request.operationID],
			record.clientID == pending.request.clientID,
			record.sessionID == pending.request.sessionID,
			record.grantRevision == pending.grantRevision
		else { return finish(requestID, result: .failure(.denied), state: &state) }

		if request.action == .cancel, record.isActive {
			record.status = .cancelled
		} else if record.isActive, record.expiresAt <= now {
			record.status = .expired
		} else if record.isActive, !state.signInSourceIsCurrent(record, engine: engine, now: now) {
			record.status = .cancelled
		}
		state.automation.signIn.records[request.operationID] = record
		let result: AutomationResult = .signIn(.init(
			operationID: request.operationID,
			status: record.status
		))
		let finished = finish(requestID, result: result, state: &state)
		guard !record.isActive
		else { return finished }

		return .merge(finished, .cancel(id: AutomationSignIn.Monitor.operation(request.operationID)))
	}

	private func beginSignIn(
		_ request: AutomationSignInRequest,
		pending: AutomationState.Pending,
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		// Nobody can approve an unattended run; never wait for consent there.
		guard !state.automation.isUnattended
		else { return finish(requestID, result: .failure(.userActionRequired), state: &state) }

		// Terminal records answer status queries until their own deadline, then
		// free their slot. Pruning never revives authority: every begin needs
		// fresh trusted consent, and only active records can grant it.
		state.automation.signIn.records = state.automation.signIn.records.filter { _, record in
			record.isActive || record.expiresAt > now
		}
		guard
			state.automation.signIn.records.count < 16,
			state.automation.signIn.records[request.operationID] == nil,
			!state.automation.signIn.records.values.contains(where: \.isActive),
			let target = request.targetID,
			let tab = state.workspace.tabs.first(where: { $0.id.rawValue == target }),
			let snapshot = pending.snapshots[tab.id],
			let nativePageID = snapshot.nativePageID,
			let document = snapshot.documentRevision
		else { return finish(requestID, result: .failure(.busy), state: &state) }

		state.automation.signIn.records[request.operationID] = .init(
			request: request,
			clientID: pending.request.clientID,
			sessionID: pending.request.sessionID,
			grantRevision: pending.grantRevision,
			profileID: tab.profileID,
			tabID: tab.id,
			nativePageID: nativePageID,
			documentRevision: document,
			sessionRevision: snapshot.revision,
			status: .approvalRequired,
			expiresAt: now.addingTimeInterval(Self.signInLifetime)
		)

		@Dependency(\.continuousClock)
		var clock

		let operationID = request.operationID
		let ticks = Int(Self.signInLifetime * 10)
		let approvalRequired: AutomationResult = .signIn(.init(
			operationID: operationID,
			status: .approvalRequired
		))
		return .merge(
			finish(requestID, result: approvalRequired, state: &state),
			.run { send in
				for _ in 0..<ticks {
					try await clock.sleep(for: .milliseconds(100))
					await send(.automation(.signIn(.event(.tick(operationID)))))
				}
				await send(.automation(.signIn(.event(.tick(operationID)))))
			}
			.cancellable(id: AutomationSignIn.Monitor.operation(operationID))
		)
	}
}

extension AppFeature.State {
	internal func automationSignInValidation(
		_ request: AutomationSignInRequest,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		guard client.allowsSignIn
		else { return .denied }

		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}

		guard request.action == .begin
		else { return nil }

		guard
			automationWorkspaceIsSynchronized,
			!settings.isManagingOrganization,
			!main.transferInProgress,
			!main.isClosing,
			!windows.contains(where: { $0.transferInProgress || $0.isClosing }),
			peeks.isEmpty,
			littleWindows.isEmpty
		else { return .busy }

		guard
			let target = request.targetID,
			let tab = workspace.tabs.first(where: { $0.id.rawValue == target }),
			AutomationAccess.permitsTab(tab.id, client: client, organization: workspace),
			workspace.profiles.ids.contains(tab.profileID)
		else { return .denied }

		guard
			let snapshot = snapshots[tab.id],
			snapshot.nativeProfileID == tab.profileID,
			(snapshot.nativePageID ?? 0) > 0,
			(snapshot.documentRevision ?? 0) > 0,
			!snapshot.navigation.isLoading,
			snapshot.navigation.errorCode == nil
		else { return .notReady }

		let revision = AutomationInventoryBuilder
			.items(client: client, organization: workspace, snapshots: snapshots)
			.first(where: { $0.id == target })?.revision
		guard
			revision == request.expectedRevision,
			Self.signInOrigin(snapshot.navigation.url) == request.origin
		else { return .staleTarget }

		return nil
	}

	/// The exact client, connection, grant, profile, native page, document and
	/// top-level origin bound at begin. Any swap cancels the operation.
	internal func signInSourceIsCurrent(
		_ record: AutomationSignInState.Record,
		engine: BrowserEngineClient,
		strictRevision: Bool = false,
		now: Date
	) -> Bool {
		let clients = automationPreferences.clients
		guard
			automationWorkspaceIsSynchronized,
			record.expiresAt > now,
			automationPreferences.isEnabled,
			!shouldQuit,
			!checkingQuit,
			automation.sessions[record.sessionID] == record.clientID,
			let client = clients.first(where: { $0.id == record.clientID }),
			client.allowsRead,
			client.allowsSignIn,
			client.grantRevision == record.grantRevision,
			workspace.tabs[id: record.tabID]?.profileID == record.profileID,
			AutomationAccess.permitsTab(record.tabID, client: client, organization: workspace),
			let current = MainActor.assumeIsolated({ engine.snapshot(record.tabID) }),
			current.nativeProfileID == record.profileID,
			current.nativePageID == record.nativePageID,
			current.documentRevision == record.documentRevision,
			!strictRevision || current.revision == record.sessionRevision,
			Self.signInOrigin(current.navigation.url) == record.request.origin
		else { return false }

		return true
	}

	internal static func signInOrigin(_ url: URL?) -> String? {
		guard
			let url,
			var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
		else { return nil }

		parts.path = ""
		parts.query = nil
		parts.fragment = nil
		return parts.string.flatMap(AutomationSignInRequest.canonicalOrigin)
	}
}
