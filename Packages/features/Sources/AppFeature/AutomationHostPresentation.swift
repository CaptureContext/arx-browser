import BrowserCore
import BrowserEngineClient
import Foundation
import PeekFeature
import _ComposableArchitecture

extension BrowserAutomation {
	/// Runs an approved Peek or Little Arx operation through the existing presentation handlers,
	/// which keep sole ownership of the browsing session.
	internal func executeHost(
		_ id: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .command(command) = pending.request.operation,
			let context = pending.hostContext
		else { return finish(id, result: .failure(.staleTarget), state: &state) }

		let snapshots = liveSnapshots(state)
		let failure = state.automationValidation(pending, snapshots: snapshots, now: now)
		if let failure { return finish(id, result: .failure(failure), state: &state) }

		let currentContext = state.automationHostContext(for: pending, snapshots: snapshots, now: now)
		guard currentContext == context
		else { return finish(id, result: .failure(.staleTarget), state: &state) }

		state.automation.hostHandles = state.automation.hostHandles.filter {
			$0.value.expiresAt > now && state.automationHostIsCurrent($0.value)
		}
		state.automation.pending[id]?.executing = true

		switch command.action {
		case .openPeek:
			return openPeek(id, command: command, context: context, state: &state)

		case .openLittleArx:
			return openLittleArx(id, command: command, state: &state)

		default:
			return promote(id, command: command, context: context, state: &state)
		}
	}

	internal func hostProgress(
		_ id: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			pending.executing,
			case let .command(command) = pending.request.operation,
			let handle = pending.hostContext?.handle
		else { return .none }

		if let failure = state.automation.hostFailures.removeValue(forKey: id) {
			return finish(id, result: .failure(failure), state: &state)
		}

		let isCommitted = state.automation.hostCompletions.contains(id)
		let peekWasPromotedToLittleArx = isCommitted
		&& command.action == .promotePeekToLittleArx
		&& state.peeks[id: handle.hostID] == nil

		if peekWasPromotedToLittleArx {
			let little = state.littleWindows.first {
				$0.tab.id == handle.tabID && $0.tab.profileID == handle.profileID
			}
			if let little {
				state.automation.hostTransitions[handle.hostID] = nil
				state.automation.hostHandles[handle.id] = nil
				let next = makeHostHandle(
					pending,
					kind: .littleArx,
					hostID: little.id,
					tabID: handle.tabID,
					profileID: handle.profileID,
					source: nil,
					expiresAt: handle.expiresAt
				)
				state.automation.hostHandles[next.id] = next
				return finishHost(id, tabID: command.targetID, handle: next, state: &state)
			}
		}

		let hostIsGone = handle.kind == .peek
		? state.peeks[id: handle.hostID] == nil
		: state.littleWindows[id: handle.hostID] == nil

		if isCommitted, command.action != .promotePeekToLittleArx, hostIsGone {
			let tab = state.workspace.tabs.first {
				$0.id == handle.tabID && $0.profileID == handle.profileID
			}
			if let tab {
				state.automation.hostTransitions[handle.hostID] = nil
				state.automation.hostHandles[handle.id] = nil
				return finishHost(id, tabID: tab.id.rawValue, handle: nil, state: &state)
			}
		}

		let hasFailed: Bool
		switch handle.kind {
		case .peek:
			let peek = state.peeks[id: handle.hostID]
			hasFailed = peek == nil || (peek?.phase == .idle && peek?.error != nil)

		case .littleArx:
			let little = state.littleWindows[id: handle.hostID]
			hasFailed = little == nil || (little?.isPromoting == false && little?.error != nil)
		}

		let hasTimedOut = now.timeIntervalSince(pending.hostStartedAt ?? .distantPast) >= 10
		if hasFailed || hasTimedOut {
			// Leave an in-flight fence until its native/model commit callback refuses
			// the now-absent request. Expiry never closes content or promises rollback.
			let failure: AutomationFailure = hasFailed ? .staleTarget : .timedOut
			return finish(id, result: .failure(failure), state: &state)
		}

		return pollHost(id)
	}

	// MARK: - Operations

	private func openPeek(
		_ id: UUID,
		command: AutomationCommand,
		context: AutomationHostContext,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			let source = context.source
		else { return finish(id, result: .failure(.notReady), state: &state) }

		let previous = Set(state.peeks.map(\.id))
		let action: Action = if let url = command.url {
			.ui(.peekURLFromSource(url, source))
		} else {
			.ui(.peekTab(
				.init(rawValue: command.targetID),
				sourceWindowID: source.windowID,
				sourcePaneID: source.paneID
			))
		}
		let effect = PeekPresentation()._reduce(into: &state, action: action)

		guard let peek = state.peeks.first(where: { $0.source == source && !previous.contains($0.id) })
		else { return finish(id, result: .failure(.busy), state: &state) }

		if peek.isTemporary {
			state.peeks[id: peek.id]?.tab.automationClientID = pending.request.clientID
		}

		let handle = makeHostHandle(
			pending,
			kind: .peek,
			hostID: peek.id,
			tabID: peek.tab.id,
			profileID: peek.tab.profileID,
			source: source
		)
		state.automation.hostHandles[handle.id] = handle
		return .merge(effect, finishHost(id, tabID: command.targetID, handle: handle, state: &state))
	}

	private func openLittleArx(
		_ id: UUID,
		command: AutomationCommand,
		state: inout State
	) -> Effect<Action> {
		guard let pending = state.automation.pending[id]
		else { return .none }

		let previous = Set(state.littleWindows.map(\.id))
		let effect = LittleArxWindows()._reduce(
			into: &state,
			action: .ui(.openLittleArx(.init(rawValue: command.targetID), command.url))
		)

		guard let little = state.littleWindows.first(where: { !previous.contains($0.id) })
		else { return finish(id, result: .failure(.busy), state: &state) }

		state.littleWindows[id: little.id]?.tab.automationClientID = pending.request.clientID
		let handle = makeHostHandle(
			pending,
			kind: .littleArx,
			hostID: little.id,
			tabID: little.tab.id,
			profileID: little.tab.profileID,
			source: nil
		)
		state.automation.hostHandles[handle.id] = handle
		return .merge(effect, finishHost(id, tabID: command.targetID, handle: handle, state: &state))
	}

	private func promote(
		_ id: UUID,
		command: AutomationCommand,
		context: AutomationHostContext,
		state: inout State
	) -> Effect<Action> {
		guard let handle = context.handle
		else { return finish(id, result: .failure(.staleTarget), state: &state) }

		state.automation.pending[id]?.hostResultTab = handle.tabID
		state.automation.pending[id]?.hostStartedAt = now

		// The fence lets only this request's own handler callbacks commit the handoff.
		state.automation.hostTransitions[handle.hostID] = id

		let action: Action = if command.action == .promoteLittleArx {
			.littleWindows(.element(
				id: handle.hostID,
				action: .ui(.promote(.init(rawValue: command.targetID), handle.profileID))
			))
		} else {
			.peeks(.element(
				id: handle.hostID,
				action: .ui(.promote(command.action == .promotePeekToTab ? .tab : .littleArx))
			))
		}
		return .concatenate(.send(action), pollHost(id))
	}

	// MARK: - Receipts

	private func makeHostHandle(
		_ pending: AutomationState.Pending,
		kind: AutomationPresentation.Kind,
		hostID: UUID,
		tabID: BrowserCore.Tab.ID,
		profileID: Profile.ID,
		source: PeekFeature.Source?,
		expiresAt: Date? = nil
	) -> AutomationHostHandle {
		guard case let .command(command) = pending.request.operation
		else { preconditionFailure("Host handles belong to commands") }

		return .init(
			id: uuid(),
			clientID: pending.request.clientID,
			sessionID: pending.request.sessionID,
			grantRevision: pending.grantRevision,
			expiresAt: expiresAt ?? now.addingTimeInterval(State.automationHostLifetime),
			kind: kind,
			hostID: hostID,
			tabID: tabID,
			profileID: profileID,
			targetID: command.targetID,
			source: source
		)
	}

	private func finishHost(
		_ id: UUID,
		tabID: UUID,
		handle: AutomationHostHandle?,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .command(command) = pending.request.operation
		else { return .none }

		let snapshots = liveSnapshots(state)
		let presentation = handle.flatMap { handle in
			state.automationPresentations(for: pending.request, snapshots: snapshots, now: now)
				.first { $0.id == handle.id }
		}
		guard handle == nil || presentation != nil
		else { return finish(id, result: .failure(.staleTarget), state: &state) }

		// Openings are accepted once the model publishes the host; promotions commit only
		// after durable tab membership exists.
		let response = AutomationCommandResult(
			operationID: command.operationID,
			status: handle == nil ? .committed : .acceptedLoading,
			targetID: tabID,
			presentation: presentation
		)
		state.automation.hostReceipts[id] = .init(
			request: pending.request,
			grantRevision: pending.grantRevision,
			response: response
		)
		return finish(id, result: .command(response), state: &state)
	}

	private func liveSnapshots(_ state: State) -> [BrowserCore.Tab.ID: BrowserSessionSnapshot] {
		let ids = state.automationSnapshotTabIDs
		return MainActor.assumeIsolated {
			Dictionary(
				uniqueKeysWithValues: ids.compactMap { id in
					engine.snapshot(id).map { (id, $0) }
				}
			)
		}
	}

	/// Host promotion settles over native callbacks; every poll runs the whole root reducer,
	/// so it checks at most ten times per second.
	private func pollHost(_ id: UUID) -> Effect<Action> {
		.run { send in
			try await Task.sleep(for: .milliseconds(100))
			try Task.checkCancellation()
			await send(.automation(.event(.hostProgress(id))))
		}
		.cancellable(id: id)
	}
}
