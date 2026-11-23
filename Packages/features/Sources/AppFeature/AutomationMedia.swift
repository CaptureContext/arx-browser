import BrowserAutomationClient
import BrowserCore
import BrowserMediaClient
import Foundation
import MainFeature
import _ComposableArchitecture

extension AppFeature.State {
	/// Media sessions in the client's permitted ordinary tabs, read from the
	/// observed native snapshot at the time of the call.
	internal func automationMediaSessions(
		for client: AutomationClient,
		targetID: UUID?
	) -> [AutomationMediaSession] {
		media.visibleSources
			.filter { source in
				!source.isPrivate
				&& (targetID == nil || source.id.tabID.rawValue == targetID)
				&& workspace.profiles.ids.contains(source.id.profileID)
				&& workspace.tabs[id: source.id.tabID]?.profileID == source.id.profileID
				&& AutomationAccess.permitsTab(source.id.tabID, client: client, organization: workspace)
			}
			.prefix(AutomationMediaResult.maximumSessions)
			.map(AutomationMediaSession.init)
	}

	internal func automationMediaValidation(
		_ request: AutomationMediaRequest,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		guard client.allows([.read, .interact]) else { return .denied }
		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}
		guard media.isAvailable else { return .unsupported }

		guard let targetID = request.targetID else { return nil }

		let tabID = Tab.ID(rawValue: targetID)
		guard
			AutomationAccess.permitsTab(tabID, client: client, organization: workspace),
			let tab = workspace.tabs[id: tabID],
			workspace.profiles.ids.contains(tab.profileID)
		else { return .denied }

		if let expectedRevision = request.expectedRevision {
			let item = AutomationInventoryBuilder.item(
				targetID,
				client: client,
				organization: workspace,
				snapshots: snapshots
			)
			guard item?.revision == expectedRevision
			else { return .staleTarget }
		}
		guard request.isControl else { return nil }

		func isBusy(_ host: MainFeature.State) -> Bool {
			host.transferInProgress
			|| host.isClosing
			|| host.pendingTabCloses.contains(tabID)
		}
		guard
			!settings.isManagingOrganization,
			!isBusy(main),
			!windows.contains(where: isBusy),
			// ArxPiP's own control is in flight; the engine runs one at a time.
			media.pending == nil
		else { return .busy }

		return nil
	}

	internal func automationMediaResponseValidation(
		_ request: AutomationMediaRequest,
		response: AutomationMediaResult,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		if let failure = automationMediaValidation(request, client: client, snapshots: snapshots) {
			// A control already reached the engine; its outcome is reported even if
			// ArxPiP picked up another command since.
			guard request.isControl, failure == .busy else { return failure }
		}
		do {
			try response.validate()
		} catch {
			return error as? AutomationFailure ?? .invalidRequest
		}
		guard response.action == request.action, response.operationID == request.operationID
		else { return .invalidRequest }

		let permitted = Set(automationMediaSessions(for: client, targetID: request.targetID).map(\.targetID))
		guard response.sessions.allSatisfy({ permitted.contains($0.targetID) })
		else { return .staleTarget }

		// A position read answers only for the tab it named.
		guard response.position.map({ $0.targetID == request.targetID }) ?? true
		else { return .invalidRequest }

		return nil
	}
}

extension BrowserAutomation {
	/// Lists media sessions synchronously from the observed snapshot, or reads one
	/// tab's position from the engine once. Position never enters state.
	internal func readMedia(
		requestID: UUID,
		client: AutomationClient,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .media(request) = pending.request.operation
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		guard request.action == .position else {
			let result = AutomationMediaResult(
				action: .list,
				sessions: state.automationMediaSessions(for: client, targetID: request.targetID)
			)
			return finish(requestID, result: .media(result), state: &state)
		}
		guard let targetID = request.targetID
		else { return finish(requestID, result: .failure(.invalidRequest), state: &state) }

		@Dependency(\.browserMedia)
		var media

		let tabID = Tab.ID(rawValue: targetID)
		let sources = state.media.visibleSources.filter { $0.id.tabID == tabID && !$0.isPrivate }
		state.automation.pending[requestID]?.executing = true
		return .run { send in
			let result: AutomationResult
			if let value = await media.position(tabID) {
				// The token names the session only while the observed snapshot has it.
				let session = value.sourceID.flatMap { id in sources.first { $0.id == id } }
				let position = AutomationMediaPosition(
					targetID: targetID,
					token: session.map {
						AutomationMediaSession.Token(generation: $0.id.generation, revision: $0.revision).rawValue
					},
					isMuted: value.isMuted,
					position: session == nil ? nil : value.position,
					duration: session == nil ? nil : value.duration,
					playbackRate: session == nil ? nil : value.playbackRate
				)
				result = position.isValid
				? .media(.init(action: .position, position: position))
				: .failure(.engineFailed)
			} else {
				result = .failure(.unsupported)
			}
			await send(.automation(.event(.finished(requestID, result))))
		}
		.cancellable(id: requestID)
	}

	/// Plays, pauses, seeks or moves an approved session into or out of ArxPiP, by
	/// the same availability rules ArxPiP's own controls use, or mutes or unmutes
	/// the tab.
	internal func controlMedia(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .media(request) = pending.request.operation,
			let operationID = request.operationID,
			let targetID = request.targetID
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		func outcome(_ failure: AutomationFailure) -> Effect<Action> {
			let result = AutomationMediaResult(action: request.action, operationID: operationID, failure: failure)
			return finish(requestID, result: .media(result), state: &state)
		}

		@Dependency(\.browserMedia)
		var media

		guard let action = request.action.mediaAction else {
			guard request.action == .mute || request.action == .unmute
			else { return outcome(.invalidRequest) }

			state.automation.pending[requestID]?.executing = true
			let isMuted = request.action == .mute
			return .run { [control] send in
				let result: AutomationMediaResult
				do {
					try Task.checkCancellation()
					guard await control.authorize(requestID) else { throw AutomationFailure.denied }

					try await media.setMuted(.init(rawValue: targetID), isMuted)
					result = .init(action: request.action, operationID: operationID, performed: true)

					// The tab's speaker in the sidebar follows (DEV-800).
					await send(.event(.mediaMuteChanged(.init(rawValue: targetID), isMuted)))

				} catch is CancellationError {
					await send(.automation(.event(.finished(requestID, .failure(.cancelled)))))
					return

				} catch {
					result = .init(action: request.action, operationID: operationID, failure: Self.mediaFailure(error))
				}
				await send(.automation(.event(.finished(requestID, .media(result)))))
			}
			.cancellable(id: requestID)
		}

		let token = request.token.flatMap(AutomationMediaSession.Token.init(rawValue:))
		guard
			let token,
			let source = state.media.visibleSources.first(where: {
				$0.id.tabID.rawValue == targetID
				&& $0.id.generation == token.generation
				&& $0.revision == token.revision
				&& !$0.isPrivate
			})
		else { return outcome(.staleTarget) }

		guard source.supports(action) else { return outcome(.unsupported) }

		state.automation.pending[requestID]?.executing = true
		let mediaRequest: BrowserMediaRequest = if action == .seek, let seconds = request.seconds {
			.init(source: source, seekingTo: seconds)
		} else {
			.init(source: source, action: action)
		}
		return .run { [control] send in
			let result: AutomationMediaResult
			do {
				try Task.checkCancellation()
				guard await control.authorize(requestID) else { throw AutomationFailure.denied }

				try await media.perform(mediaRequest)
				result = .init(action: request.action, operationID: operationID, performed: true)

			} catch is CancellationError {
				await send(.automation(.event(.finished(requestID, .failure(.cancelled)))))
				return

			} catch {
				result = .init(action: request.action, operationID: operationID, failure: Self.mediaFailure(error))
			}
			await send(.automation(.event(.finished(requestID, .media(result)))))
		}
		.cancellable(id: requestID)
	}

	private static func mediaFailure(_ error: any Error) -> AutomationFailure {
		if let failure = error as? AutomationFailure { return failure }
		guard let failure = error as? BrowserMediaClient.Failure else { return .engineFailed }
		switch failure {
		case .unavailable, .unsupportedAction: return .unsupported
		case .staleSource: return .staleTarget
		case .timedOut: return .timedOut
		case .requestFailed: return .engineFailed
		}
	}
}
