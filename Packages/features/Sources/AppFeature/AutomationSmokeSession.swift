#if DEBUG
import BrowserCore
import BrowserMCPServer
import Darwin
import Foundation
import _MCP

/// The SDK has no request deadline. Disconnect resumes its pending continuations.
internal enum AutomationSmokeDeadline {
	@MainActor
	internal static func run<Value: Sendable>(
		for duration: Duration,
		expire: @escaping @MainActor @Sendable () async -> Void,
		operation: @escaping @MainActor @Sendable () async throws -> Value
	) async throws -> Value {
		let state = State()
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withThrowingTaskGroup(of: Value.self) { group in
				group.addTask { try await invoke(operation) }
				group.addTask {
					try await Task.sleep(for: duration)
					await state.markExpired()
					await expire()
					throw AutomationSmokeFailure.timedOut
				}
				defer { group.cancelAll() }
				do {
					guard let value = try await group.next()
					else { throw AutomationSmokeFailure.helperFailed }

					guard !state.expired else { throw AutomationSmokeFailure.timedOut }
					try Task.checkCancellation()
					return value
				} catch {
					if state.expired { throw AutomationSmokeFailure.timedOut }
					throw error
				}
			}
		} onCancel: {
			Task { @MainActor in await expire() }
		}
	}

	@MainActor
	private static func invoke<Value: Sendable>(
		_ operation: @MainActor @Sendable () async throws -> Value
	) async throws -> Value {
		try Task.checkCancellation()
		return try await operation()
	}

	@MainActor
	private final class State {
		internal var expired: Bool

		internal init() {
			self.expired = false
		}

		internal func markExpired() { expired = true }
	}
}

@MainActor
internal final class AutomationSmokeSession {
	internal let clientID: UUID
	private let client: Client
	private let process: Process
	private let input: Pipe
	private let output: Pipe
	private var closed: Bool

	internal init(
		helper: URL,
		configuration: AutomationSmokeConfiguration
	) throws {
		self.clientID = configuration.clientID
		self.client = .init(
			name: "Disposable native smoke",
			version: "1.0",
			configuration: .strict
		)
		self.process = .init()
		self.input = .init()
		self.output = .init()
		self.closed = false

		guard FileManager.default.isExecutableFile(atPath: helper.path)
		else { throw AutomationSmokeFailure.helperFailed }

		process.executableURL = helper

		// Never inherit credentials, debugger flags or another app's environment.
		process.environment = configuration.environment
		process.standardInput = input
		process.standardOutput = output

		// No raw helper diagnostics enter application logs, including on authentication failure.
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
		} catch {
			throw AutomationSmokeFailure.helperFailed
		}

		// These ends belong to the spawned child; the parent's duplicates are unused.
		try? input.fileHandleForReading.close()
		try? output.fileHandleForWriting.close()
	}

	/// Connects and checks that the served tool list matches the grant `preferences` hold for this client.
	internal func connect(grantedBy preferences: AutomationPreferences) async throws {
		guard let grantee = preferences.clients.first(where: { $0.id == clientID })
		else { throw AutomationSmokeFailure.authorizationFailed }

		let expected = AutomationTools.definitions(for: AutomationGrantSummary(grantee))
		let names = expected.map(\.name)

		// Served schemas arrive through JSON, which turns whole doubles into integers; compare like for like.
		let schemas = try expected.map { tool in
			try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(tool.inputSchema))
		}
		try await request { [client, input, output, names, schemas] in
			let initialized = try await client.connect(transport: StdioTransport(
				input: .init(rawValue: output.fileHandleForReading.fileDescriptor),
				output: .init(rawValue: input.fileHandleForWriting.fileDescriptor)
			))
			guard initialized.protocolVersion == "2025-11-25"
			else { throw AutomationSmokeFailure.invalidResponse }

			// Arx lists only the tools the client's current grant covers (DEV-659). The served
			// names and input schemas must match the same filtering, so tool changes need no edit here.
			let tools = try await client.listTools()
			guard
				tools.tools.map(\.name) == names,
				tools.tools.map(\.inputSchema) == schemas
			else { throw AutomationSmokeFailure.invalidResponse }
		}
	}

	internal func verifyCredentialRejected() async throws {
		try await request { [client, input, output] in
			do {
				try await client.connect(transport: StdioTransport(
					input: .init(rawValue: output.fileHandleForReading.fileDescriptor),
					output: .init(rawValue: input.fileHandleForWriting.fileDescriptor)
				))
			} catch let MCPError.internalError(message) {
				guard message == "Arx connection failed: invalidCredential"
				else { throw AutomationSmokeFailure.authorizationFailed }
				return
			}
			throw AutomationSmokeFailure.authorizationFailed
		}
	}

	internal func inventory() async throws -> AutomationResult {
		try await call("browser_inventory", arguments: ["limit": .int(100)])
	}

	internal func command(
		id: UUID = UUID(),
		target: UUID,
		revision: String,
		url: URL
	) async throws -> AutomationResult {
		try await command(.init(
			operationID: id,
			action: .navigate,
			targetID: target,
			expectedRevision: revision,
			url: url
		))
	}

	/// - Parameters:
	///   - validatesLocally: `false` sends a request the helper must refuse itself.
	internal func command(
		_ command: AutomationCommand,
		validatesLocally: Bool = true
	) async throws -> AutomationResult {
		if validatesLocally { try command.validate() }
		var arguments: [String: Value] = [
			"operationID": .string(command.operationID.uuidString),
			"action": .string(command.action.rawValue),
			"targetID": .string(command.targetID.uuidString),
			"expectedRevision": .string(command.expectedRevision),
		]
		if let destination = command.destinationID {
			arguments["destinationID"] = .string(destination.uuidString)
		}
		if let revision = command.destinationRevision { arguments["destinationRevision"] = .string(revision) }
		if let url = command.url { arguments["url"] = .string(url.absoluteString) }
		if let name = command.name { arguments["name"] = .string(name) }
		if command.focus { arguments["focus"] = .bool(true) }
		if let source = command.sourceTabID { arguments["sourceTabID"] = .string(source.uuidString) }
		if let revision = command.sourceRevision { arguments["sourceRevision"] = .string(revision) }
		if let presentation = command.presentationID {
			arguments["presentationID"] = .string(presentation.uuidString)
		}
		if let revision = command.presentationRevision {
			arguments["presentationRevision"] = .string(revision)
		}
		return try await call("browser_command", arguments: arguments)
	}

	internal func capture(_ capture: AutomationCaptureRequest) async throws -> AutomationCaptureSmoke.Reply {
		try capture.validate()
		var arguments: [String: Value] = [
			"targetID": .string(capture.targetID.uuidString),
			"expectedRevision": .string(capture.expectedRevision),
			"mode": .string(capture.mode.rawValue),
		]
		if let region = capture.region {
			arguments["region"] = try Value(region)
		}
		let values = arguments
		return try await request { [client] in
			let context: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_capture",
				arguments: values
			)
			return try AutomationCaptureSmoke.decode(await context.value)
		}
	}

	internal func inspect(_ inspection: AutomationInspectionRequest) async throws -> AutomationInspectionSmoke.Reply {
		try inspection.validate()
		return try await request { [client] in
			let context: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_inspect",
				arguments: [
					"targetID": .string(inspection.targetID.uuidString),
					"expectedRevision": .string(inspection.expectedRevision),
					"maximumNodes": .int(inspection.maximumNodes),
					"maximumTextBytes": .int(inspection.maximumTextBytes),
				]
			)
			return try AutomationInspectionSmoke.decode(await context.value)
		}
	}

	internal func click(_ click: AutomationClickRequest) async throws -> AutomationClickResult {
		try click.validate()
		return try await request { [client] in
			let context: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_click",
				arguments: [
					"operationID": .string(click.operationID.uuidString),
					"targetID": .string(click.targetID.uuidString),
					"expectedRevision": .string(click.expectedRevision),
					"snapshotID": .string(click.snapshotID),
					"reference": .string(click.reference),
				]
			)
			return try AutomationClickSmoke.decode(await context.value, operationID: click.operationID)
		}
	}

	internal func waitPage(_ wait: AutomationWaitRequest) async throws -> AutomationWaitSmoke.Reply {
		try wait.validate()

		return try await request { [client] in
			let context: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_wait",
				arguments: [
					"targetID": .string(wait.targetID.uuidString),
					"expectedRevision": .string(wait.expectedRevision),
					"condition": .string(wait.condition.rawValue),
					"timeoutMilliseconds": .int(wait.timeoutMilliseconds),
				]
			)
			return try AutomationWaitSmoke.decode(await context.value)
		}
	}

	private static func pointerArguments(
		_ pointer: AutomationPointer,
		kind: AutomationFormRequest.Kind
	) -> [String: Value] {
		var arguments: [String: Value] = [:]
		if let point = pointer.point {
			arguments["x"] = .double(point.x)
			arguments["y"] = .double(point.y)
		}
		if let destination = pointer.destinationReference { arguments["toReference"] = .string(destination) }
		if let destination = pointer.destinationPoint {
			arguments["toX"] = .double(destination.x)
			arguments["toY"] = .double(destination.y)
		}
		if kind == .pointerClick { arguments["clickCount"] = .int(pointer.clickCount) }
		if kind == .drag { arguments["steps"] = .int(pointer.steps) }
		if !pointer.modifiers.isEmpty { arguments["modifiers"] = .array(pointer.modifiers.map { .string($0.rawValue) }) }
		return arguments
	}

	internal func form(_ form: AutomationFormRequest) async throws -> AutomationFormResult {
		try form.validate()
		let name: String = switch form.kind {
		case .replaceText: "browser_replace_text"
		case .selectValue: "browser_select_value"
		case .keyPress: "browser_keypress"
		case .hover: "browser_hover"
		case .pointerClick: "browser_click"
		case .drag: "browser_drag"
		case .typeText: "browser_type"
		case .keyChord: "browser_keypress"
		case .selectValues: "browser_select_value"
		case .setChecked: "browser_set_checked"
		case .upload: "browser_upload"
		}
		var arguments: [String: Value] = [
			"operationID": .string(form.operationID.uuidString),
			"targetID": .string(form.target.targetID.uuidString),
			"expectedRevision": .string(form.target.expectedRevision),
			"snapshotID": .string(form.target.snapshotID),
		]
		if let pointer = form.pointer {
			arguments.merge(Self.pointerArguments(pointer, kind: form.kind)) { $1 }
			if !form.targetsViewport { arguments["reference"] = .string(form.target.reference) }
		} else {
			arguments["reference"] = .string(form.target.reference)
			let key: String = switch form.kind {
			case .keyPress, .keyChord: "key"
			case .typeText: "text"
			case .replaceText, .selectValue, .hover, .pointerClick, .drag, .selectValues, .setChecked, .upload: "value"
			}
			if form.kind == .upload {
				arguments["paths"] = .array((form.values ?? []).map(Value.string))
			} else if let values = form.values {
				arguments["values"] = .array(values.map(Value.string))
			} else if let checked = form.checked {
				arguments["checked"] = .bool(checked)
			} else {
				arguments[key] = .string(form.value)
			}
			if let modifiers = form.keyModifiers {
				arguments["modifiers"] = .array(modifiers.map { .string($0.rawValue) })
			}
		}
		return try await request { [client, arguments] in
			let context: RequestContext<CallTool.Result> = try await client.callTool(
				name: name,
				arguments: arguments
			)
			return try AutomationFormSmoke.decode(await context.value, operationID: form.operationID)
		}
	}

	internal func scroll(_ scroll: AutomationScrollRequest) async throws -> AutomationScrollResult {
		try scroll.validate()
		return try await request { [client] in
			let context: RequestContext<CallTool.Result> = try await client.callTool(
				name: "browser_scroll",
				arguments: [
					"operationID": .string(scroll.operationID.uuidString),
					"targetID": .string(scroll.target.targetID.uuidString),
					"expectedRevision": .string(scroll.target.expectedRevision),
					"snapshotID": .string(scroll.target.snapshotID),
					"reference": .string(scroll.target.reference),
					"axis": .string(scroll.axis.rawValue),
					"deltaCSSPixels": .double(scroll.canonicalDelta),
				]
			)
			return try AutomationScrollSmoke.decode(await context.value, operationID: scroll.operationID)
		}
	}

	internal func close() async -> Bool {
		guard !closed else { return !process.isRunning }
		closed = true
		await client.disconnect()

		// The transport does not own these descriptors. EOF also stops the server cleanly.
		try? input.fileHandleForWriting.close()
		try? output.fileHandleForReading.close()
		for _ in 0..<50 {
			if !process.isRunning { return process.terminationStatus == 0 }
			try? await Task.sleep(for: .milliseconds(20))
		}
		if process.isRunning { process.terminate() }
		for _ in 0..<25 {
			if !process.isRunning { return false }
			try? await Task.sleep(for: .milliseconds(20))
		}

		// Process retains ownership of its child until reaping; never inspect or signal other apps.
		if process.isRunning { kill(process.processIdentifier, SIGKILL) }
		return false
	}

	/// The undecoded reply, for fixtures that audit every returned byte.
	internal func rawCall(
		_ name: String,
		arguments: [String: Value]
	) async throws -> CallTool.Result {
		try await request { [client] in
			let context: RequestContext<CallTool.Result> = try await client.callTool(
				name: name,
				arguments: arguments
			)
			return try await context.value
		}
	}

	private func call(
		_ name: String,
		arguments: [String: Value]
	) async throws -> AutomationResult {
		try await request { [client] in
			let context: RequestContext<CallTool.Result> = try await client.callTool(
				name: name,
				arguments: arguments
			)
			return try AutomationSmokeResponse.decode(await context.value)
		}
	}

	private func request<Value: Sendable>(
		caller: StaticString = #function,
		_ operation: @escaping @MainActor @Sendable () async throws -> Value
	) async throws -> Value {
		guard !closed else { throw AutomationSmokeFailure.helperFailed }
		let start = ContinuousClock.now
		do {
			return try await AutomationSmokeDeadline.run(
				for: .seconds(8),
				expire: { [self] in
					_ = await close()
				},
				operation: { [self] in
					guard !closed else { throw AutomationSmokeFailure.helperFailed }
					try Task.checkCancellation()
					return try await operation()
				}
			)
		} catch AutomationSmokeFailure.timedOut {
			throw SmokeDiagnostics.timeout(
				site: "AutomationSmokeSession.\(caller)",
				since: start,
				state: "no MCP reply within 8s; helper disconnected"
			)
		} catch {
			throw error as? AutomationSmokeFailure ?? .helperFailed
		}
	}
}
#endif
