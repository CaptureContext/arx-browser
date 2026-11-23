import AgentToolsClient
import BrowserAutomationClient
import BrowserCore
import Foundation
import _MCP

/// Turns MCP tool calls into Arx requests. Every request still goes through Arx's own
/// authorization; this layer only composes calls to save the agent round trips.
internal struct AutomationCalls: Sendable {
	internal let gateway: AutomationGateway

	/// How long a batch approval lasts, as far as this helper relies on it when Arx doesn't say
	/// when it lapses: Arx's window less a margin, since the user approved before the helper
	/// heard of it (DEV-1072).
	internal let batchApprovalWindow: Duration

	/// Calls that returned waitingForUser, as first prepared, so the same call again acts on
	/// the same target even when "focused" now means another tab (DEV-1024).
	private let waiting: Waiting = .init()

	internal init(
		gateway: AutomationGateway,
		batchApprovalWindow: Duration = .seconds(AutomationBatchPlan.approvalWindow) - .seconds(10)
	) {
		self.gateway = gateway
		self.batchApprovalWindow = batchApprovalWindow
	}

	internal func call(
		_ name: String,
		arguments: [String: Value]
	) async throws -> CallTool.Result {
		let result: CallTool.Result = try await route(name, arguments: arguments)
		return await namingSiteSkill(in: result, tool: name, arguments: arguments)
	}

	private func route(
		_ name: String,
		arguments: [String: Value]
	) async throws -> CallTool.Result {
		switch name {
		case "browser_spaces", "browser_profiles", "browser_windows":
			guard arguments.isEmpty || arguments == ["action": .string("list")]
			else { return try await single(name, arguments: arguments) }

			return try await list(name)

		case "browser_archive", "browser_downloads":
			guard
				arguments["action"] == nil || arguments["action"] == .string("list"),
				let kind = AutomationTools.CommandTool(rawValue: name)?.dataKind
			else { return try await single(name, arguments: arguments) }

			let request: AutomationDataRequest
			do {
				request = try AutomationTools.dataRequest(kind, arguments: arguments)
			} catch {
				throw MCPError.invalidParams("Arguments do not match the tool schema")
			}
			return try BrowserMCPServer.toolResult(await gateway.perform(.data(request)))

		case "browser_batch":
			return try await batch(arguments)

		case "browser_pdf":
			return try await pdf(arguments)

		case _ where Self.pageReadingTools.contains(name):
			return try await read(name, arguments: arguments)

		default:
			return try await single(name, arguments: arguments)
		}
	}

	// MARK: - Site skills

	/// Adds `siteSkill` to the first answer about a page on a site Arx has a skill for, so the agent
	/// reads it before acting there. Each skill is named once per connection.
	internal func namingSiteSkill(
		in response: CallTool.Result,
		tool: String,
		arguments: [String: Value]
	) async -> CallTool.Result {
		let page: AutomationGateway.Page
		if Self.pageReadingTools.contains(tool) {
			page = .confirmed
		} else if tool == AutomationTools.CommandTool.tabs.rawValue {
			switch arguments["action"]?.stringValue {
			case "openTab", "navigate": page = .openedNow
			case "selectTab": page = .confirmed
			default: return response
			}
		} else {
			return response
		}

		guard
			response.isError != true,
			case let .object(fields)? = response.structuredContent,
			case let .object(result)? = fields["result"],
			let targetID = result["targetID"]?.stringValue.flatMap(UUID.init(uuidString:)),
			let skill = await gateway.unnamedSiteSkill(forTab: targetID, page: page),
			let named = try? BrowserMCPServer.adding(["siteSkill": Self.hint(skill)], to: response)
		else { return response }

		await gateway.markNamed(skill)
		return named
	}

	internal static func hint(_ skill: AgentSiteSkill) -> Value {
		.object([
			"name": .string(skill.name),
			"description": .string(skill.description),
			"resource": .string(AutomationResources.Address.skill(skill.name).uri),
		])
	}

	private func single(
		_ name: String,
		arguments: [String: Value]
	) async throws -> CallTool.Result {
		var arguments = arguments
		var returnsSnapshot: Bool = false
		if AutomationTools.returnSnapshotTools.contains(name), let value = arguments.removeValue(forKey: "returnSnapshot") {
			guard let flag = value.boolValue
			else { throw MCPError.invalidParams("Arguments do not match the tool schema") }

			returnsSnapshot = flag
		}

		let identity = AutomationGateway.userWait?.call?.identity
		let prepared: Prepared
		if let identity, case let .single(kept) = await waiting.kept(identity) {
			prepared = kept
		} else {
			switch try await prepare(name, arguments: arguments) {
			case let .operation(value): prepared = value
			case let .result(result): return try BrowserMCPServer.toolResult(result)
			}
		}

		var result = await gateway.perform(prepared.operation)

		// Kept until the call ends, so an overlapping retry acts on the same target too.
		if let identity {
			if result == .failure(.waitingForUser) {
				await waiting.keep(.single(prepared), for: identity)
			} else {
				await waiting.drop(identity)
			}
		}
		if case let .signIn(request) = prepared.operation, request.action != .cancel {
			result = await signInWait(request, result: result)
		}

		// Still waiting for the user: a fresh snapshot would replace the one the change acts on.
		guard
			returnsSnapshot,
			result != .failure(.waitingForUser),
			let target = Self.referenceTarget(prepared.operation)
		else { return try BrowserMCPServer.toolResult(result, focusedTab: prepared.focusedTab) }

		return try BrowserMCPServer.toolResult(
			result,
			focusedTab: prepared.focusedTab,
			extra: await observe(target)
		)
	}

	/// Follows a sign-in handoff inside the call, telling the client what the user is doing,
	/// until it ends or the call's wait limit passes (DEV-1024). Past the limit the latest status
	/// returns, and `status` with the same operationID goes on following it.
	private func signInWait(
		_ request: AutomationSignInRequest,
		result: AutomationResult
	) async -> AutomationResult {
		let wait = AutomationGateway.userWait ?? .init()
		let deadline = ContinuousClock.now.advanced(by: wait.limit)
		let status = AutomationSignInRequest(operationID: request.operationID, action: .status)
		var result = result
		while
			case let .signIn(value) = result,
			let doing = value.status.userDoing,
			ContinuousClock.now.advanced(by: Self.signInPoll) < deadline,
			!Task.isCancelled
		{
			await wait.progress("Waiting for the user to " + doing + ".")
			do {
				try await Task.sleep(for: Self.signInPoll)
			} catch {
				break
			}
			result = await gateway.perform(.signIn(status))
		}
		return result
	}

	private static let signInPoll: Duration = .seconds(2)

	/// A call as first prepared, kept while it waits for the user.
	private enum Kept: Sendable {
		case single(Prepared)

		/// A batch whose approval waits.
		case batch(steps: [BatchStep], plan: AutomationBatchPlan)

		/// An approved batch one of whose steps waits, or whose approval for the steps left
		/// waits (DEV-1072).
		case batchProgress(BatchProgress)
	}

	private struct BatchStep: Sendable {
		internal var tool: String
		internal var prepared: Prepared
	}

	/// How far an approved batch got, so the same call again goes on where it waited instead of
	/// asking for the batch again and repeating steps that ran (DEV-1072).
	private struct BatchProgress: Sendable {
		internal var steps: [BatchStep]
		internal var plan: AutomationBatchPlan

		/// The outcomes of the steps that ran, and their images.
		internal var outcomes: [Value]
		internal var images: [AutomationCaptureImage]

		/// The step to run next: the one that waits, once kept.
		internal var next: Int

		/// The number the call gave the request that waits, for the same call to reach it again.
		internal var position: Int

		/// When the user last approved steps of this batch, as the helper heard.
		internal var approvedAt: ContinuousClock.Instant

		/// When that approval lapses in Arx, which Arx says: the user may have approved long
		/// before the helper collected the answer. Nil from an older Arx.
		internal var expiresAt: Date?

		/// The steps left, sent for approval again once the first approval lapsed, while that waits.
		internal var pendingApproval: AutomationBatchPlan?

		/// The step at `next` already has a request open in Arx, so it asks for no approval again.
		internal var resumesOpenRequest: Bool = false
	}

	private actor Waiting {
		private var kept: [String: Kept] = [:]

		internal func keep(
			_ value: Kept,
			for identity: String
		) {
			if kept.count >= 16, kept[identity] == nil, let any = kept.keys.first { kept[any] = nil }
			kept[identity] = value
		}

		internal func kept(_ identity: String) -> Kept? {
			kept[identity]
		}

		internal func drop(_ identity: String) {
			kept[identity] = nil
		}
	}

	// MARK: - Preparation

	internal struct Prepared: Sendable {
		internal var operation: AutomationOperation
		internal var focusedTab: UUID?
	}

	internal enum Preparation: Sendable {
		case operation(Prepared)

		/// The call ends here with this result, without reaching Arx.
		case result(AutomationResult)
	}

	/// Resolves the focused-tab alias and parses the arguments. Malformed arguments throw.
	internal func prepare(
		_ name: String,
		arguments: [String: Value]
	) async throws -> Preparation {
		var arguments = arguments
		var focusedTab: UUID?
		if
			AutomationTools.focusedTabTools.contains(name),
			arguments["targetID"] == .string(AutomationFocusedTab.alias)
		{
			switch await gateway.focusedTab() {
			case let .success(tab):
				arguments["targetID"] = .string(tab.tabID.uuidString)
				let revision = arguments["expectedRevision"]
				if revision == nil || revision == .string(AutomationFocusedTab.alias) {
					arguments["expectedRevision"] = .string(tab.revision)
				}
				focusedTab = tab.tabID

			case let .failure(failure):
				return .result(.failure(failure))
			}
		}

		do {
			let operation = try AutomationTools.operation(name: name, arguments: arguments)
			return .operation(.init(operation: operation, focusedTab: focusedTab))

		} catch AutomationFailure.unsupported where AutomationTools.isCommandTool(name) {
			// A well-formed but unavailable command, such as a background host opening, is an explicit result.
			return .result(.failure(.unsupported))

		} catch let failure as AutomationFailure where name == "browser_settings"
			&& [.protectedSetting, .invalidValue, .shortcutReserved].contains(failure) {
			// Schema-valid arguments the setting refuses get an explicit reason.
			return .result(.failure(failure))

		} catch {
			throw MCPError.invalidParams("Arguments do not match the tool schema")
		}
	}

	// MARK: - Act and observe

	private struct ReferenceTarget: Sendable {
		internal var targetID: UUID
		internal var snapshotID: String
	}

	private static func referenceTarget(_ operation: AutomationOperation) -> ReferenceTarget? {
		switch operation {
		case let .click(request): .init(targetID: request.targetID, snapshotID: request.snapshotID)
		case let .form(request): .init(targetID: request.target.targetID, snapshotID: request.target.snapshotID)
		case let .scroll(request): .init(targetID: request.target.targetID, snapshotID: request.target.snapshotID)
		default: nil
		}
	}

	/// A fresh snapshot of the document the action's snapshot came from, or why there is none.
	/// A navigation away from that document is reported, never papered over with the new page.
	private func observe(_ target: ReferenceTarget) async -> [String: Value] {
		func unavailable(_ reason: String) -> [String: Value] {
			["snapshot": .null, "snapshotUnavailable": .string(reason)]
		}

		guard let original = await gateway.deliveredDocument(snapshotID: target.snapshotID)
		else { return unavailable("unknownSnapshot") }

		let inventory: AutomationInventory
		switch await gateway.fullInventory() {
		case let .success(value): inventory = value
		case let .failure(failure): return unavailable(failure.rawValue)
		}
		guard let item = inventory.items.first(where: { $0.kind == .tab && $0.id == target.targetID })
		else { return unavailable(AutomationFailure.denied.rawValue) }

		let result = BrowserMCPServer.validated(await gateway.perform(.inspect(.init(
			targetID: target.targetID,
			expectedRevision: item.revision
		))))
		switch result {
		case let .inspection(inspection):
			guard inspection.snapshot.documentID == original.documentID
			else { return unavailable("documentChanged") }

			guard let payload = try? BrowserMCPServer.payload(result)
			else { return unavailable(AutomationFailure.invalidRequest.rawValue) }

			return ["snapshot": payload]

		case let .failure(failure):
			return unavailable(failure.rawValue)

		default:
			return unavailable(AutomationFailure.invalidRequest.rawValue)
		}
	}

	// MARK: - Lists

	private func list(_ name: String) async throws -> CallTool.Result {
		let inventory: AutomationInventory
		switch await gateway.fullInventory() {
		case let .success(value): inventory = value
		case let .failure(failure): return try BrowserMCPServer.toolResult(.failure(failure))
		}

		let result: Value
		switch name {
		case "browser_spaces":
			let global = inventory.chromeAppearance ?? .default
			let profiles = Dictionary(
				inventory.items.filter { $0.kind == .profile }.map { ($0.profileID, $0.appearance) }
					+ inventory.profiles.map { ($0.id, $0.appearance) },
				uniquingKeysWith: { first, _ in first }
			)
			result = .object([
				"kind": .string("spaces"),
				"items": .array(try inventory.items.filter { $0.kind == .space }.map { space in
					try Self.resolving(space, appearance: .init(
						global: global,
						profile: profiles[space.profileID] ?? nil,
						space: space.appearance
					))
				}),
			])

		case "browser_windows":
			result = .object([
				"kind": .string("windows"),
				"items": try Value(encoding: inventory.windows),
			])

		default:
			// Whole-profile grants also carry the profile items management commands target.
			let global = inventory.chromeAppearance ?? .default
			result = .object([
				"kind": .string("profiles"),
				"items": .array(try inventory.profiles.map { profile in
					try Self.resolving(profile, appearance: .init(global: global, profile: profile.appearance, space: nil))
				}),
				"targets": try Value(encoding: inventory.items.filter { $0.kind == .profile }),
			])
		}
		let response = try BrowserMCPServer.envelope(
			["untrustedData": .bool(true), "result": result],
			isError: false
		)
		guard BrowserMCPServer.fits(response)
		else { return try BrowserMCPServer.toolResult(.failure(.limitExceeded)) }
		return response
	}

	/// The item with `resolvedAppearance`: what its chrome shows once inherited settings are filled in.
	private static func resolving(
		_ item: some Codable,
		appearance: AutomationResolvedAppearance
	) throws -> Value {
		guard case var .object(fields) = try Value(encoding: item)
		else { return try Value(encoding: item) }
		fields["resolvedAppearance"] = try Value(encoding: appearance)
		return .object(fields)
	}

	// MARK: - Batches

	private func batch(_ arguments: [String: Value]) async throws -> CallTool.Result {
		guard
			Set(arguments.keys) == ["steps"],
			case let .array(rawSteps) = arguments["steps"],
			(1...AutomationBatchPlan.maximumSteps).contains(rawSteps.count)
		else { throw MCPError.invalidParams("Arguments do not match the tool schema") }

		let identity = AutomationGateway.userWait?.call?.identity
		var steps: [BatchStep] = []
		var kept: AutomationBatchPlan?
		var keptCall: Kept?
		if let identity { keptCall = await waiting.kept(identity) }
		switch keptCall {
		case let .batch(keptSteps, plan):
			steps = keptSteps
			kept = plan

		case let .batchProgress(progress):
			// The same call again after a step waited: on from that step, approval kept.
			AutomationGateway.userWait?.call?.resume(at: progress.position)
			return try await run(progress, identity: identity)

		case .single, nil:
			break
		}

		// Parsed only the first time: a kept plan already holds its resolved steps.
		for rawStep in rawSteps where kept == nil {
			guard
				case let .object(step) = rawStep,
				Set(step.keys) == ["tool", "arguments"],
				let tool = step["tool"]?.stringValue,
				AutomationTools.batchStepTools.contains(tool),
				case let .object(stepArguments) = step["arguments"]
			else { throw MCPError.invalidParams("Arguments do not match the tool schema") }

			switch try await prepare(tool, arguments: stepArguments) {
			case let .operation(prepared): steps.append(.init(tool: tool, prepared: prepared))
			case let .result(result): return try BrowserMCPServer.toolResult(result)
			}
		}

		// The same call again after waitingForUser goes on with the plan as first prepared.
		let plan = kept ?? AutomationBatchPlan(batchID: UUID(), steps: steps.map(\.prepared.operation))
		do {
			try plan.validate()
		} catch {
			throw MCPError.invalidParams("Batch steps must be distinct operations without sign-in or nested batches")
		}

		var expiresAt: Date?
		switch await gateway.perform(.batch(plan)) {
		case let .batch(approval):
			if let identity { await waiting.drop(identity) }
			expiresAt = approval.expiresAt

		case .failure(.waitingForUser):
			if let identity { await waiting.keep(.batch(steps: steps, plan: plan), for: identity) }
			return try BrowserMCPServer.toolResult(.failure(.waitingForUser))

		case let failure:
			if let identity { await waiting.drop(identity) }
			return try BrowserMCPServer.toolResult(failure)
		}

		let progress: BatchProgress = .init(
			steps: steps,
			plan: plan,
			outcomes: [],
			images: [],
			next: 0,
			position: 0,
			approvedAt: .now,
			expiresAt: expiresAt
		)
		return try await run(progress, identity: identity)
	}

	/// Runs an approved batch's steps from `progress.next`. A step that waits for the user past
	/// the call's limit keeps the progress for the same call to go on with.
	private func run(
		_ progress: BatchProgress,
		identity: String?
	) async throws -> CallTool.Result {
		var progress = progress
		let call = AutomationGateway.userWait?.call
		var stoppedAt: Int?
		var waitsForUser: Bool = false
		while progress.next < progress.steps.count {
			let index = progress.next
			let step = progress.steps[index]

			// The approval lapsed while a step waited: ask once for the steps left, not each of them.
			if !progress.resumesOpenRequest, let rest = approvalAgain(progress) {
				progress.pendingApproval = rest
				progress.position = call?.position ?? 0
				switch await gateway.perform(.batch(rest)) {
				case let .batch(approval):
					progress.pendingApproval = nil
					progress.approvedAt = .now
					progress.expiresAt = approval.expiresAt

				case .failure(.waitingForUser):
					// Kept as it is, approval pending; the call still returns what the steps so far did.
					if let identity {
						await waiting.keep(.batchProgress(progress), for: identity)
						waitsForUser = true
					}
					progress.outcomes.append(try outcome(index, step: step, result: .failure(.waitingForUser)))
					stoppedAt = index

				case let failure:
					progress.outcomes.append(try outcome(index, step: step, result: failure))
					stoppedAt = index
				}
				if stoppedAt != nil { break }
			}

			progress.position = call?.position ?? 0
			let result = BrowserMCPServer.validated(await gateway.perform(step.prepared.operation))
			progress.resumesOpenRequest = false
			if case .failure(.waitingForUser) = result, let identity {
				// Kept without this step's outcome: the same call again collects its open request.
				var kept = progress
				kept.resumesOpenRequest = true
				await waiting.keep(.batchProgress(kept), for: identity)
				waitsForUser = true
			}
			if case let .capture(capture) = result {
				progress.images.append(capture.image)
			}
			progress.outcomes.append(try outcome(index, step: step, result: result))
			if BrowserMCPServer.isFailure(result) {
				stoppedAt = index
				break
			}
			progress.next += 1
		}
		if let identity, !waitsForUser {
			await waiting.drop(identity)
		}

		let plan = progress.plan
		let steps = progress.steps
		func response(
			_ outcomes: [Value],
			images: [AutomationCaptureImage]
		) throws -> CallTool.Result {
			try BrowserMCPServer.envelope(
				[
					"untrustedData": .bool(true),
					"result": .object([
						"kind": .string("batch"),
						"batchID": .string(plan.batchID.uuidString),
						"completed": .int(stoppedAt ?? steps.count),
						"stoppedAt": stoppedAt.map(Value.int) ?? .null,
						"steps": .array(outcomes),
					]),
				],
				images: images,
				isError: stoppedAt != nil
			)
		}

		let full = try response(progress.outcomes, images: progress.images)
		if BrowserMCPServer.fits(full) { return full }

		// Every receipt must survive; page content and images give way first.
		let receipts: [Value] = progress.outcomes.map { outcome in
			guard
				case var .object(fields) = outcome,
				case let .object(result) = fields["result"],
				case let .string(kind) = result["kind"],
				["inspection", "capture", "inventory"].contains(kind)
			else { return outcome }

			fields["result"] = .object(["kind": .string("omitted"), "reason": .string("limitExceeded")])
			return .object(fields)
		}
		return try response(receipts, images: [])
	}

	/// The steps left, to ask the user for again: the plan already waiting for approval, or a new
	/// one when the batch approval has lapsed and a step left needs one.
	private func approvalAgain(_ progress: BatchProgress) -> AutomationBatchPlan? {
		if let pending = progress.pendingApproval { return pending }
		if let expiresAt = progress.expiresAt {
			guard Date() >= expiresAt.addingTimeInterval(-Self.approvalMargin) else { return nil }
		} else {
			guard progress.approvedAt.duration(to: .now) >= batchApprovalWindow else { return nil }
		}

		let rest = progress.steps[progress.next...].map(\.prepared.operation)
		guard rest.contains(where: { AutomationSecurity.mutationBinding($0) != nil }) else { return nil }

		return .init(batchID: UUID(), steps: Array(rest))
	}

	/// How long before Arx's expiry the helper treats a batch approval as lapsed: the steps
	/// still have to reach Arx.
	private static let approvalMargin: TimeInterval = 10

	private func outcome(
		_ index: Int,
		step: BatchStep,
		result: AutomationResult
	) throws -> Value {
		var outcome: [String: Value] = [
			"index": .int(index),
			"tool": .string(step.tool),
			"result": try BrowserMCPServer.payload(result),
		]
		if let focused = step.prepared.focusedTab {
			outcome["focusedTab"] = .string(focused.uuidString)
		}
		return .object(outcome)
	}
}

extension AutomationTools {
	internal static func isCommandTool(_ name: String) -> Bool {
		name == "browser_command" || CommandTool(rawValue: name) != nil
	}
}

extension AutomationSignInResult.Status {
	/// What the user is doing in Arx while the handoff waits on them, or nil once it ended.
	fileprivate var userDoing: String? {
		switch self {
		case .approvalRequired: "approve the sign-in handoff in Arx"
		case .securingPrivacy, .userActionRequired: "sign in in Arx"
		case .userConfirmed, .cancelled, .expired, .blocked: nil
		}
	}
}
