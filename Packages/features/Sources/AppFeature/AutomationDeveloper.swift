import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import _ComposableArchitecture

// The opt-in developer tier (DEV-668). Scripts and log reads run against the
// engine; neither a script's value nor a log entry enters the store, and logs
// are kept natively and read on request.

extension AppFeature.State {
	/// A permitted, live tab of a granted profile, with developer mode on.
	internal func automationDeveloperValidation(
		targetID: UUID,
		expectedRevision: String?,
		required: Set<AutomationCapability>,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot],
		requiresLoadedPage: Bool
	) -> AutomationFailure? {
		guard client.allows(required) else { return .denied }
		guard settings.general.developerModeEnabled else { return .developerModeRequired }
		guard automationPermitsLiveTab(targetID, client: client) else { return .denied }

		let tabID = Tab.ID(rawValue: targetID)
		if let expectedRevision {
			let item = AutomationInventoryBuilder.item(
				targetID,
				client: client,
				organization: workspace,
				snapshots: snapshots
			)
			guard item?.revision == expectedRevision
			else { return .staleTarget }
		}
		guard requiresLoadedPage else { return nil }

		guard let snapshot = snapshots[tabID] else { return .notLoaded }

		// DEV-873: Arx unloaded its page to free memory; `load` brings it back.
		guard !snapshot.navigation.isUnloaded else { return .notLoaded }
		guard
			let url = snapshot.navigation.url,
			url.hasWebScheme,
			url.host != nil
		else { return .unsupported }
		guard !snapshot.navigation.requiresUserAction else { return .userActionRequired }
		guard snapshot.navigation.errorCode == nil else { return .notReady }

		return nil
	}

	internal func automationScriptValidation(
		_ request: AutomationScriptRequest,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}
		return automationDeveloperValidation(
			targetID: request.targetID,
			expectedRevision: request.expectedRevision,
			required: AutomationOperation.script(request).requiredCapabilities,
			client: client,
			snapshots: snapshots,
			requiresLoadedPage: true
		)
	}

	internal func automationLogValidation(
		_ request: AutomationLogRequest,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}
		if let failure = automationNetworkDetailsQuarantine(request, snapshots: snapshots) { return failure }
		return automationDeveloperValidation(
			targetID: request.targetID,
			expectedRevision: request.expectedRevision,
			required: AutomationOperation.logs(request).requiredCapabilities,
			client: client,
			snapshots: snapshots,
			// Stopping and reading never need the page loaded; a read of an unloaded tab is empty.
			requiresLoadedPage: request.action == .start
		)
	}

	/// A script's value is released only while the grant, developer mode and the
	/// tab still allow it. The script itself may have navigated the page, so
	/// its revision isn't rechecked.
	internal func automationScriptResponseValidation(
		_ request: AutomationScriptRequest,
		response: AutomationScriptResult,
		client: AutomationClient
	) -> AutomationFailure? {
		do {
			try request.validate()
			try response.validate()
		} catch {
			return error as? AutomationFailure ?? .invalidRequest
		}
		guard
			response.operationID == request.operationID,
			response.targetID == request.targetID
		else { return .invalidRequest }

		return automationDeveloperValidation(
			targetID: request.targetID,
			expectedRevision: nil,
			required: AutomationOperation.script(request).requiredCapabilities,
			client: client,
			snapshots: [:],
			requiresLoadedPage: false
		)
	}

	/// A document holding a filled password that didn't sign in may have sent it, so its request
	/// details stay closed until the tab shows another document (DEV-924). The capture itself was
	/// dropped when the password was filled.
	internal func automationNetworkDetailsQuarantine(
		_ request: AutomationLogRequest,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		let tabID = Tab.ID(rawValue: request.targetID)
		guard request.needsNetworkDetails else { return nil }

		// Not while Arx fills a saved password into the tab.
		let isSigningIn = automation.pending.values.contains { pending in
			guard case let .passwordSignIn(signIn) = pending.request.operation else { return false }
			return signIn.targetID == request.targetID
		}
		if isSigningIn { return .authenticationProtected }
		guard let quarantined = automation.passwordQuarantine[tabID] else { return nil }

		// An unknown document might still be the filled one.
		return (snapshots[tabID]?.documentRevision ?? quarantined) == quarantined ? .authenticationProtected : nil
	}

	internal func automationLogResponseValidation(
		_ request: AutomationLogRequest,
		response: AutomationLogResult,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [:]
	) -> AutomationFailure? {
		do {
			try request.validate()
			try response.validate()
		} catch {
			return error as? AutomationFailure ?? .invalidRequest
		}
		guard
			response.action == request.action,
			response.targetID == request.targetID,
			response.console.count + response.network.count + response.requests.count <= request.limit
		else { return .invalidRequest }
		if let failure = automationNetworkDetailsQuarantine(request, snapshots: snapshots) { return failure }

		return automationDeveloperValidation(
			targetID: request.targetID,
			expectedRevision: nil,
			required: AutomationOperation.logs(request).requiredCapabilities,
			client: client,
			snapshots: [:],
			requiresLoadedPage: false
		)
	}
}

extension BrowserAutomation {
	/// Runs an approved script. The final authorization is checked immediately
	/// before the engine starts it; its value never enters state.
	internal func evaluateScript(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .script(request) = pending.request.operation
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		state.automation.pending[requestID]?.executing = true
		let tabID = Tab.ID(rawValue: request.targetID)

		// Stop needs to find this document after the script returns (DEV-899).
		let clientID = pending.request.clientID

		// Closed tabs take their scripts with them; at most one entry per tab and client remains.
		let workspace = state.workspace
		state.automation.scriptDocuments.removeAll { document in
			workspace.tabs[id: document.tabID] == nil || (document.tabID == tabID && document.clientID == clientID)
		}
		state.automation.scriptDocuments.append(.init(tabID: tabID, clientID: clientID))
		return .run { [engine, control, clock] send in
			let result: AutomationResult
			do throws(BrowserDeveloperFailure) {
				guard await engine.developerTierIsAvailable() else { throw .unavailable }
				let outcome = try await BrowserEngineClient.evaluateWhenFree(clock: clock) { () throws(BrowserDeveloperFailure) in
					try await engine.evaluateScript(
						tabID,
						request.script,
						request.maximumResultBytes,
						request.timeoutMilliseconds
					) { control.authorize(requestID) }
				}
				result = .script(Self.scriptResult(outcome, request: request))
			} catch {
				result = .failure(Self.developerFailure(error))
			}
			await send(.automation(.event(.finished(requestID, result))))
		}
		.cancellable(id: requestID)
	}

	/// Starts, stops or reads a tab's logs. Reads go to the engine; entries are
	/// returned to the client without passing through state.
	internal func developerLogs(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .logs(request) = pending.request.operation
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		let tabID = Tab.ID(rawValue: request.targetID)
		switch request.action {
		case .start, .stop:
			let isStart = request.action == .start

			// Recorded before the engine answers, so a revocation in between still stops it.
			state.automation.developerLogs[tabID] = isStart ? pending.request.clientID : nil
			state.automation.pending[requestID]?.executing = true
			let details = request.details == true
			return .run { [engine, control] send in
				let result: AutomationResult
				if await !engine.developerTierIsAvailable() {
					result = .failure(.unsupported)
				} else if details, await !engine.networkDetailsAreAvailable() {
					result = .failure(.unsupported)
				} else if await engine.setDeveloperLog(tabID, isStart) {
					// Request details follow the logs: started with details, always stopped with them. They
					// start only if the request is still authorized at that moment, in the same main-actor
					// turn, so a saved-password fill that began meanwhile keeps them off.
					let detailed = await MainActor.run {
						guard isStart, details else { return engine.setNetworkCapture(tabID, false) }
						return control.authorize(requestID) && engine.setNetworkCapture(tabID, true)
					}
					result = isStart && details && !detailed
					? .failure(.notLoaded)
					: .logs(.init(action: request.action, targetID: request.targetID, capturing: isStart))
				} else {
					result = .failure(.notLoaded)
				}
				await send(.automation(.event(.finished(requestID, result))))
			}
			.cancellable(id: requestID)

		case .requests, .har:
			state.automation.pending[requestID]?.executing = true
			return .run { [engine] send in

				// Whole bodies, so credential fields are found before anything is cut.
				let data = await engine.readNetworkCapture(
					tabID,
					request.after,
					request.limit,
					AutomationDeveloper.maximumKeptBodyBytes
				)
				let result: AutomationResult = data.map { Self.networkDetails($0, request: request) }
				?? .logs(.init(action: request.action, targetID: request.targetID, capturing: false, next: request.after))
				await send(.automation(.event(.finished(requestID, result))))
			}
			.cancellable(id: requestID)

		case .console, .network:
			state.automation.pending[requestID]?.executing = true
			return .run { [engine] send in
				let result: AutomationResult
				do throws(BrowserDeveloperFailure) {
					let log = try await engine.readDeveloperLog(
						tabID,
						request.action == .console ? .console : .network,
						request.after,
						request.limit
					)
					result = .logs(.init(
						action: request.action,
						targetID: request.targetID,
						capturing: log.capturing,
						console: log.console,
						network: log.network,
						next: log.next,
						dropped: log.dropped
					))
				} catch {
					result = .failure(Self.developerFailure(error))
				}
				await send(.automation(.event(.finished(requestID, result))))
			}
			.cancellable(id: requestID)
		}
	}

	/// Stops every log a client started. A grant change or revocation ends them;
	/// the agent starts them again under its new grant.
	internal func stopDeveloperLogs(
		of clientID: UUID,
		state: inout State
	) -> Effect<Action> {
		let tabs = state.automation.developerLogs.filter { $0.value == clientID }.map(\.key)
		guard !tabs.isEmpty else { return .none }

		for tab in tabs {
			state.automation.developerLogs[tab] = nil
		}
		return .run { [engine] _ in
			for tab in tabs {
				_ = await engine.setDeveloperLog(tab, false)
				_ = await engine.setNetworkCapture(tab, false)
			}
		}
	}

	/// The engine's request details as a `requests` or `har` result, credential fields redacted,
	/// and as many entries as fit in one reply; `next` continues after the last one included.
	internal static func networkDetails(
		_ data: Data,
		request: AutomationLogRequest
	) -> AutomationResult {
		struct Capture: Decodable {
			var capturing: Bool
			var entries: [AutomationRequestDetail]
			var next: UInt64
			var dropped: UInt64
		}
		guard let capture = try? JSONDecoder().decode(Capture.self, from: data)
		else { return .failure(.engineFailed) }

		let bodyBytes = request.bodyBytes ?? AutomationDeveloper.defaultDetailBodyBytes
		var entries = Array(capture.entries.prefix(request.limit)).map { $0.redactingCredentials(bodyBytes: bodyBytes) }
		func result() -> AutomationLogResult {
			let next = entries.last?.sequence ?? request.after
			return .init(
				action: request.action,
				targetID: request.targetID,
				capturing: capture.capturing,
				requests: request.action == .requests ? entries : [],
				har: request.action == .har ? AutomationHAR.text(entries) : nil,
				next: entries.count == capture.entries.count ? max(next, capture.next) : next,
				dropped: capture.dropped
			)
		}

		// The MCP reply carries the payload twice, as text and as structured content, escaped:
		// a third of the IPC limit leaves room for both.
		let budget = AutomationIPC.maximumResponseBytes / 3
		func size() -> Int {
			(try? JSONEncoder().encode(AutomationIPC.Reply.result(.logs(result()))).count) ?? .max
		}
		while entries.count > 1, size() > budget {
			entries.removeLast(max(1, entries.count / 4))
		}

		// One entry still too large loses its bodies, then its headers, so paging can go on.
		if size() > budget, var entry = entries.first {
			if entry.requestBody != nil { entry.requestBodyOmitted = true }
			if entry.responseBody != nil { entry.responseBodyOmitted = true }
			entry.requestBody = nil
			entry.responseBody = nil
			entries[0] = entry
			if size() > budget {
				entry.requestHeaders = [:]
				entry.responseHeaders = [:]
				entry.headersOmitted = true
				entries[0] = entry
			}
		}
		return .logs(result())
	}

	internal static func scriptResult(
		_ outcome: BrowserScriptOutcome,
		request: AutomationScriptRequest
	) -> AutomationScriptResult {
		switch outcome {
		case let .value(text):
			.init(operationID: request.operationID, targetID: request.targetID, outcome: .value, value: text)
		case .undefined:
			.init(operationID: request.operationID, targetID: request.targetID, outcome: .undefined)
		case let .unserializable(detail):
			.init(operationID: request.operationID, targetID: request.targetID, outcome: .unserializable, detail: detail)
		case let .exception(name, message):
			.init(
				operationID: request.operationID,
				targetID: request.targetID,
				outcome: .exception,
				error: .init(name: name, message: message)
			)
		case let .syntaxError(name, message, line):
			.init(
				operationID: request.operationID,
				targetID: request.targetID,
				outcome: .syntaxError,
				error: .init(name: name, message: message, line: line)
			)
		}
	}

	internal static func developerFailure(_ failure: BrowserDeveloperFailure) -> AutomationFailure {
		switch failure {
		case .unavailable, .unsupported: .unsupported
		case .stale: .staleTarget
		case .limitExceeded: .limitExceeded
		case .busy: .busy
		case .timedOut: .timedOut
		case .invalid: .invalidRequest
		case .failed: .engineFailed
		case .denied: .denied
		}
	}
}
