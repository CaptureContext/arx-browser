import BrowserAutomationClient
import BrowserCore
import Darwin
import Foundation
import JavaScriptCore
import Synchronization
import _MCP

extension AutomationTools {
	/// The longest script `browser_run` takes, in bytes.
	internal static let runMaximumCodeBytes: Int = 32_768

	internal static var runDefinition: Tool {
		.init(
			name: "browser_run",
			title: "Run several browser steps as a script",
			description: """
			Runs JavaScript here, in the Arx helper, that calls the browser tools as functions: loops over search \
			results or pages, a form filled from what an earlier step read, a list read until a row turns up. \
			Each step is the tool call of the same name with the same arguments and goes through the same checks: \
			the grant, approval (a step that needs it waits inside the run) and its own operationID. \
			call("browser_click", {...}) calls any tool; every tool also has a function named without its \
			browser_ prefix, as click({...}), read({...}), find_in_page({...}). A step returns the tool's result \
			object; a failed step throws an Error with code and result. uuid() makes an operationID; \
			sleep(ms) waits up to 20 seconds; console.log prints; keep is an object that lasts between runs. \
			Steps are synchronous: no fetch, timers or DOM; the page is only reachable through tools. \
			At most \(AutomationRun.maximumSteps) steps and timeoutSeconds (1-600, default 60) a run, one run at a time. \
			The result has the returned value, what was printed (outputLimit bytes, 256-32000, default 8000) \
			and a compact step log; images and PDFs the steps return come after it, newest first when they don't \
			all fit. Use single calls for one or two steps and browser_batch for fixed steps under one approval.
			""",
			inputSchema: schema(
				properties: [
					"code": string(maximum: runMaximumCodeBytes),
					"outputLimit": .object([
						"type": .string("integer"),
						"minimum": .int(256),
						"maximum": .int(32_000),
					]),
					"timeoutSeconds": .object([
						"type": .string("integer"),
						"minimum": .int(1),
						"maximum": .int(600),
					]),
				],
				required: ["code"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: true,
				idempotentHint: false,
				openWorldHint: true
			)
		)
	}
}

/// `browser_run` (DEV-1012): a script that calls the browser tools as functions.
///
/// The script runs in a JavaScriptCore context in this helper, never in a page. Each step is
/// the tool call of the same name through `AutomationCalls`, so it keeps its own grant check,
/// approval and operationID in Arx; the script itself can only compute. One context lasts for
/// the connection, so `keep` carries values from run to run.
///
/// JavaScriptCore calls back synchronously, so the context lives on its own serial queue,
/// never on a Swift concurrency thread, and a step waits there for its async tool call.
internal final class AutomationRun: @unchecked Sendable {
	internal static let maximumSteps: Int = 200

	private let calls: AutomationCalls
	private let queue: DispatchQueue = .init(label: "dev.capturecontext.arx.mcp.run")

	/// One run at a time: a second one is refused rather than left waiting past its own limits.
	private let running: Mutex<Bool> = .init(false)

	/// Confined to `queue`.
	private var context: JSContext?
	private var current: Script?

	internal init(calls: AutomationCalls) {
		self.calls = calls
	}

	/// Runs one script and answers with its value, output and step log.
	internal func run(_ arguments: [String: Value]) async throws -> CallTool.Result {
		guard
			Set(arguments.keys).isSubset(of: ["code", "outputLimit", "timeoutSeconds"]),
			let code = arguments["code"]?.stringValue,
			!code.isEmpty,
			code.utf8.count <= AutomationTools.runMaximumCodeBytes
		else { throw MCPError.invalidParams("Arguments do not match the tool schema") }

		let outputLimit: Int
		let timeout: Int
		do {
			outputLimit = try AutomationTools.integer("outputLimit", in: arguments, default: 8_000)
			timeout = try AutomationTools.integer("timeoutSeconds", in: arguments, default: 60)
		} catch {
			throw MCPError.invalidParams("Arguments do not match the tool schema")
		}
		guard (256...32_000).contains(outputLimit), (1...600).contains(timeout)
		else { throw MCPError.invalidParams("Arguments do not match the tool schema") }

		let script = Script(
			outputLimit: outputLimit,
			deadline: ContinuousClock.now.advanced(by: .seconds(timeout)),
			// The steps run off this task, on the script's queue, so they take the run's wait
			// for the user with them: its limit and progress lines.
			userWait: AutomationGateway.userWait
		)
		let started = running.withLock { running in
			defer { running = true }
			return !running
		}
		guard started else {
			script.fail("busy: Another browser_run is still running; wait for its result, then run this one.")
			return try script.outcome.toolResult()
		}
		defer { running.withLock { $0 = false } }
		let outcome = await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				queue.async {
					continuation.resume(returning: self.evaluate(code, script: script))
				}
			}
		} onCancel: {
			script.cancel()
		}
		return try outcome.toolResult()
	}

	// MARK: - The context

	/// Confined to `queue`.
	private func evaluate(
		_ code: String,
		script: Script
	) -> Outcome {
		script.expireIfDue()
		guard !script.isOver else { return script.outcome }

		let context = self.context ?? makeContext()
		self.context = context
		current = script
		defer {
			current = nil
			context.exceptionHandler = nil
		}
		let watch = Watchdog.watch(context, while: script)
		defer { watch.end() }

		let finished = Shared(false)
		context.exceptionHandler = { _, exception in
			script.fail(exception?.toString() ?? "The script failed.")
		}
		let complete: @convention(block) (JSValue) -> Void = { value in
			script.finish(value.isUndefined ? nil : value.toString())
			finished.value.withLock { $0 = true }
		}
		let fail: @convention(block) (String) -> Void = { message in
			script.fail(message)
			finished.value.withLock { $0 = true }
		}
		context.setObject(complete, forKeyedSubscript: "__complete" as NSString)
		context.setObject(fail, forKeyedSubscript: "__fail" as NSString)

		// Await is allowed and does nothing: steps are synchronous.
		context.evaluateScript("""
		(async () => {
		\(code)
		})().then(
			v => __complete(v === undefined ? undefined : (typeof v === 'string' ? JSON.stringify(v) : JSON.stringify(v) ?? 'null')),
			e => __fail(e && e.message ? (e.code ? e.code + ': ' + e.message : e.message) : String(e))
		);
		""")
		context.setObject(nil, forKeyedSubscript: "__complete" as NSString)
		context.setObject(nil, forKeyedSubscript: "__fail" as NSString)

		script.expireIfDue()
		if !finished.value.withLock({ $0 }) {
			script.fail("The script left a promise pending. Nothing runs between calls, so keep was reset.")
		}

		// A script cut off by its limit may have left the context half way: start the next one fresh.
		if script.isOver { self.context = nil }
		return script.outcome
	}

	/// Confined to `queue`.
	private func makeContext() -> JSContext {
		let context = JSContext()!
		let step: @convention(block) (String, String) -> String = { [weak self] name, json in
			self?.step(name, json: json) ?? #"{"error":{"code":"cancelled","message":"The run ended."}}"#
		}
		let log: @convention(block) (String) -> Void = { [weak self] line in
			self?.current?.print(line)
		}
		let uuid: @convention(block) () -> String = { UUID().uuidString }
		let sleep: @convention(block) (Double) -> Void = { [weak self] milliseconds in
			self?.current?.sleep(milliseconds: milliseconds)
		}
		context.setObject(step, forKeyedSubscript: "__step" as NSString)
		context.setObject(log, forKeyedSubscript: "__log" as NSString)
		context.setObject(uuid, forKeyedSubscript: "uuid" as NSString)
		context.setObject(sleep, forKeyedSubscript: "sleep" as NSString)
		context.evaluateScript(Self.prelude)
		return context
	}

	/// One tool call from the script, made through the same dispatch as a direct call.
	/// Confined to `queue`; it waits there for the async call.
	private func step(
		_ name: String,
		json: String
	) -> String {
		guard let script = current else { return Self.error("cancelled", "The run ended.") }
		if let refusal = script.beginStep(name) { return refusal }
		guard name != "browser_run", AutomationTools.requiredCapabilities(forTool: name) != nil else {
			script.endStep(name, error: "unknownTool")
			return Self.error("unknownTool", "No tool named \(name). call() takes a browser_ tool's name.")
		}
		guard
			let data = json.data(using: .utf8),
			case let .object(arguments)? = try? JSONDecoder().decode(Value.self, from: data)
		else {
			script.endStep(name, error: "invalidRequest")
			return Self.error("invalidRequest", "A step's arguments must be an object.")
		}

		let answer = Shared<CallTool.Result?>(nil)
		let failure = Shared<String?>(nil)
		let done = DispatchSemaphore(value: 0)
		let calls = self.calls

		// Each step waits for the user as a call of its own would, with the run's limit and
		// progress. Its identity names the run and the step, so the same run again reaches the
		// request this step left waiting (DEV-1024, DEV-1072).
		let wait = script.userWait.map { run in
			AutomationGateway.UserWait(
				limit: run.limit,
				call: BrowserMCPServer.callIdentity(name, arguments: arguments).map {
					(run.call?.identity ?? "browser_run") + " step \(script.stepNumber) " + $0
				},
				progress: run.progress
			)
		}
		let task = Task {
			do {
				let result = try await AutomationGateway.$userWait.withValue(wait) {
					try await calls.call(name, arguments: arguments)
				}
				answer.value.withLock { $0 = result }
			} catch {
				failure.value.withLock { $0 = (error as? any LocalizedError)?.errorDescription ?? String(describing: error) }
			}
			done.signal()
		}
		script.track(task)
		var unfinished = false
		while done.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
			guard script.isOver else { continue }

			// Past the deadline or cancelled: stop the call and give it a moment to say what it did.
			script.expireIfDue()
			task.cancel()
			unfinished = done.wait(timeout: .now() + .seconds(5)) == .timedOut
			break
		}
		script.track(nil)

		let result = answer.value.withLock { $0 }

		// A step's site-skill hint marks the skill named for the connection, so the run's own answer
		// carries it, whatever the script keeps of the step's result (DEV-1025).
		script.noteSiteSkill(in: result)
		if script.isOver {
			script.expireIfDue()
			let code = script.isCancelled ? "cancelled" : "timedOut"

			// The run's own log keeps what is known about this step, so a caller whose script
			// didn't catch the error can still tell whether repeating it could act twice.
			var entry: [String: Value] = [:]
			if unfinished { entry["unfinished"] = .bool(true) }
			if let structured = result?.structuredContent { entry["result"] = structured }
			script.endStep(name, error: code, details: entry)
			var error: [String: Value] = [
				"code": .string(code),
				"message": .string(unfinished
				? "The run ended while this step was still running, so what it did is unknown. "
					+ "Check the page before repeating it with the same operationID."
				: "The run ended during this step."),
			]
			if let structured = result?.structuredContent { error["result"] = structured }
			return Self.encode(.object(["error": .object(error)]))
		}
		script.attach(result?.content ?? [])
		if let message = failure.value.withLock({ $0 }) {
			script.endStep(name, error: "invalidRequest")
			return Self.error("invalidRequest", message)
		}
		let structured = result?.structuredContent ?? .null
		if result?.isError == true {
			let code = Self.code(in: structured) ?? "failed"
			script.endStep(name, error: code, details: Self.receipt(in: structured).map { ["result": $0] } ?? [:])
			return Self.encode(.object(["error": .object([
				"code": .string(code),
				"message": .string(Self.message(in: structured) ?? code),
				"result": structured,
			])]))
		}
		script.endStep(name, error: nil, details: Self.receipt(in: structured).map { ["result": $0] } ?? [:])
		return Self.encode(.object(["value": structured]))
	}

	// MARK: - Script state

	/// One run's limits, output and step log. Read and written on `queue`, cancelled from anywhere.
	fileprivate final class Script: Sendable {
		private let outputLimit: Int
		private let deadline: ContinuousClock.Instant

		/// The run's own wait for the user, which the task-local doesn't carry onto the queue.
		let userWait: AutomationGateway.UserWait?
		private let state: Mutex<State> = .init(.init())

		private struct State {
			var printed: String = ""
			var truncated: Bool = false
			var steps: Int = 0
			var log: [Value] = []
			var value: String?
			var failure: String?
			var cancelled: Bool = false
			var task: Task<Void, Never>?
			var attachments: [(content: Tool.Content, bytes: Int)] = []
			var attachmentsLeftOut: Int = 0
			var siteSkills: [Value] = []
		}

		init(
			outputLimit: Int,
			deadline: ContinuousClock.Instant,
			userWait: AutomationGateway.UserWait?
		) {
			self.outputLimit = outputLimit
			self.deadline = deadline
			self.userWait = userWait
		}

		/// The number of the step running now, from 1.
		var stepNumber: Int {
			state.withLock { $0.steps }
		}

		/// Past the time limit, cancelled or failed: the next step refuses to start.
		var isOver: Bool {
			state.withLock { $0.cancelled || $0.failure != nil } || ContinuousClock.now >= deadline
		}

		var isCancelled: Bool {
			state.withLock { $0.cancelled }
		}

		/// Marks the run failed once it is past its deadline.
		func expireIfDue() {
			guard ContinuousClock.now >= deadline else { return }
			fail("timedOut: The run reached its time limit; run again for the rest.")
		}

		/// Keeps the site-skill hint a step's answer carried, for the run's result.
		func noteSiteSkill(in result: CallTool.Result?) {
			guard
				case let .object(fields)? = result?.structuredContent,
				let hint = fields["siteSkill"]
			else { return }

			state.withLock { $0.siteSkills.append(hint) }
		}

		/// Keeps the images and PDFs a step returned, for the run's result.
		func attach(_ content: [Tool.Content]) {
			let kept = content.filter { content in
				switch content {
				case .image, .resource: true
				default: false
				}
			}
			let sized = kept.map { ($0, (try? JSONEncoder().encode($0).count) ?? .max) }
			state.withLock { state in
				state.attachments += sized

				// Only the newest that fit one response can come back; let the rest go now.
				var total = state.attachments.reduce(0) { $0 &+ $1.bytes }
				while total > AutomationIPC.maximumImageResponseBytes, let oldest = state.attachments.first {
					total -= oldest.bytes
					state.attachments.removeFirst()
					state.attachmentsLeftOut += 1
				}
			}
		}

		func cancel() {
			let task = state.withLock { state in
				state.cancelled = true
				return state.task
			}
			task?.cancel()
		}

		func track(_ task: Task<Void, Never>?) {
			let cancelled = state.withLock { state in
				state.task = task
				return state.cancelled
			}
			if cancelled { task?.cancel() }
		}

		/// Nil when the step may run, or the error the script gets instead.
		func beginStep(_ name: String) -> String? {
			if state.withLock({ $0.cancelled }) { return AutomationRun.error("cancelled", "The run was cancelled.") }
			if ContinuousClock.now >= deadline {
				expireIfDue()
				return AutomationRun.error("timedOut", "The run reached its time limit; run again for the rest.")
			}
			return state.withLock { state in
				guard state.steps < AutomationRun.maximumSteps else {
					return AutomationRun.error(
						"limitExceeded",
						"More than \(AutomationRun.maximumSteps) steps in one run; stop here and run again for the rest."
					)
				}
				state.steps += 1
				return nil
			}
		}

		func endStep(
			_ name: String,
			error: String?,
			details: [String: Value] = [:]
		) {
			state.withLock { state in
				var entry: [String: Value] = details
				entry["tool"] = .string(name)
				if let error { entry["error"] = .string(error) }
				state.log.append(.object(entry))
			}
		}

		func print(_ line: String) {
			state.withLock { state in
				let separator = state.printed.isEmpty ? "" : "\n"
				let room = max(0, outputLimit - state.printed.utf8.count)
				let text = separator + line
				if text.utf8.count > room { state.truncated = true }
				state.printed += text.prefix(bytes: room)
			}
		}

		/// Sleeps in short naps, so a cancelled or expired run wakes within one.
		func sleep(milliseconds: Double) {
			let wanted = Duration.milliseconds(max(0, min(milliseconds, 20_000)))
			let end = min(ContinuousClock.now.advanced(by: wanted), deadline)
			while !isOver, ContinuousClock.now < end {
				let nap = min(.milliseconds(100), ContinuousClock.now.duration(to: end))
				usleep(useconds_t(max(0, nap.components.seconds * 1_000_000 + nap.components.attoseconds / 1_000_000_000_000)))
			}
		}

		func finish(_ value: String?) {
			state.withLock { $0.value = value }
		}

		func fail(_ message: String) {
			state.withLock { state in
				if state.failure == nil { state.failure = message }
			}
		}

		var outcome: Outcome {
			state.withLock { state in
				var failure = state.failure
				if failure == nil, state.cancelled { failure = "The run was cancelled." }
				return Outcome(
					value: state.value,
					printed: state.printed,
					truncated: state.truncated,
					log: state.log,
					failure: failure,
					outputLimit: outputLimit,
					attachments: state.attachments.map(\.content),
					attachmentsLeftOut: state.attachmentsLeftOut,
					siteSkills: state.siteSkills
				)
			}
		}
	}

	/// What a run answers.
	internal struct Outcome: Sendable {
		var value: String?
		var printed: String
		var truncated: Bool
		var log: [Value]
		var failure: String?
		var outputLimit: Int
		var attachments: [Tool.Content] = []

		/// Attachments already let go because newer ones filled the response.
		var attachmentsLeftOut: Int = 0

		/// The site-skill hints the steps' answers carried, in order. Each is named once per
		/// connection, so a run whose script drops a step's answer must pass them on.
		var siteSkills: [Value] = []

		/// The result, within the transport's limit: the oldest attachments go first, then the
		/// value and output.
		func toolResult() throws -> CallTool.Result {
			var fields: [String: Value] = [
				"kind": .string("run"),
				"steps": .int(log.count),
				"log": .array(log),
				"output": .string(printed),
				"truncated": .bool(truncated),
			]
			if let value {
				if
					value.utf8.count <= outputLimit,
					let data = value.data(using: .utf8),
					let decoded = try? JSONDecoder().decode(Value.self, from: data)
				{
					fields["value"] = decoded
				} else {
					fields["value"] = .string(String(value.prefix(bytes: outputLimit)))
					fields["truncated"] = .bool(true)
				}
			}
			if let failure {
				fields["error"] = .string(String(failure.prefix(bytes: outputLimit)))
			}

			var attached = attachments
			while true {
				let leftOut = attachmentsLeftOut + attachments.count - attached.count
				if leftOut > 0 { fields["attachmentsLeftOut"] = .int(leftOut) }
				var top: [String: Value] = ["untrustedData": .bool(true), "result": .object(fields)]
				if !siteSkills.isEmpty { top["siteSkills"] = .array(siteSkills) }
				let envelope = try BrowserMCPServer.envelope(top, isError: failure != nil)
				let response = CallTool.Result(
					content: envelope.content + attached,
					structuredContent: envelope.structuredContent,
					isError: envelope.isError
				)
				if BrowserMCPServer.fits(response) { return response }

				if !attached.isEmpty {
					attached.removeFirst()
				} else if fields["value"] != nil {
					fields["value"] = nil
					fields["truncated"] = .bool(true)
				} else if fields["output"] != .string("") {
					fields["output"] = .string("")
					fields["truncated"] = .bool(true)
				} else {
					return try BrowserMCPServer.toolResult(.failure(.limitExceeded))
				}
			}
		}
	}

	// MARK: - Helpers

	fileprivate static func error(
		_ code: String,
		_ message: String
	) -> String {
		encode(.object(["error": .object(["code": .string(code), "message": .string(message)])]))
	}

	private static func encode(_ value: Value) -> String {
		(try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
	}

	private static func code(in structured: Value) -> String? {
		guard case let .object(fields) = structured, case let .object(result)? = fields["result"] else { return nil }
		return result["code"]?.stringValue ?? result["failure"]?.stringValue
	}

	/// A mutation's receipt (its operationID and whether it acted), which the run's log keeps,
	/// so a run that fails later still says which steps acted.
	private static func receipt(in structured: Value) -> Value? {
		guard
			case let .object(fields) = structured,
			case let .object(result)? = fields["result"],
			result["operationID"] != nil || result["disposition"] != nil
		else { return nil }
		return .object(result)
	}

	private static func message(in structured: Value) -> String? {
		guard case let .object(fields) = structured, case let .object(result)? = fields["result"] else { return nil }
		return result["message"]?.stringValue
	}

	/// What every script sees: `call`, a function per tool, `console`, `keep`.
	private static var prelude: String {
		let tools = AutomationTools.definitions
			.map(\.name)
			.filter { $0 != "browser_run" && $0.hasPrefix("browser_") }
		let names = tools.map { "'" + $0 + "'" }.joined(separator: ", ")
		return """
		var keep = {};
		var console = { log: (...a) => __log(a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')) };
		console.error = console.warn = console.info = console.log;
		function call(tool, args) {
			const got = JSON.parse(__step(String(tool), JSON.stringify(args === undefined ? {} : args)));
			if (got.error !== undefined) {
				const e = new Error(got.error.message);
				e.code = got.error.code;
				e.result = got.error.result;
				throw e;
			}
			return got.value;
		}
		for (const tool of [\(names)]) {
			globalThis[tool.slice('browser_'.length)] = args => call(tool, args);
		}
		"""
	}
}

/// Stops a script that runs between steps once its run is over: past its deadline or cancelled.
/// JavaScriptCore asks after each slice of CPU time; the call isn't public API, so it is
/// looked up at run time, and without it the run ends at its next step only.
private enum Watchdog {
	private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
	private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
	private typealias ClearLimit = @convention(c) (JSContextGroupRef?) -> Void

	private static let slice: Double = 0.25

	private static let setLimit: SetLimit? = symbol("JSContextGroupSetExecutionTimeLimit")
	private static let clearLimit: ClearLimit? = symbol("JSContextGroupClearExecutionTimeLimit")

	/// Ends when `end()` is called, after the script has returned.
	fileprivate struct Watch {
		fileprivate let end: () -> Void
	}

	fileprivate static func watch(
		_ context: JSContext,
		while script: AutomationRun.Script
	) -> Watch {
		guard let setLimit, let clearLimit, let global = context.jsGlobalContextRef
		else { return .init(end: {}) }

		let group = JSContextGetGroup(global)
		let retained = Unmanaged.passRetained(script)
		setLimit(group, slice, check, retained.toOpaque())
		return .init(end: {
			clearLimit(group)
			retained.release()
		})
	}

	/// Ends the script once its run is over. JavaScriptCore doesn't start another slice after
	/// the callback says to go on, so the callback starts it.
	private static let check: ShouldTerminate = { context, info in
		guard let info, let setLimit else { return true }
		if Unmanaged<AutomationRun.Script>.fromOpaque(info).takeUnretainedValue().isOver { return true }
		setLimit(JSContextGetGroup(context), slice, check, info)
		return false
	}

	private static func symbol<Function>(_ name: String) -> Function? {
		guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
		return unsafeBitCast(symbol, to: Function.self)
	}
}

/// A value shared with escaping closures across threads.
private final class Shared<Value: Sendable>: Sendable {
	internal let value: Mutex<Value>

	internal init(_ value: Value) {
		self.value = .init(value)
	}
}

extension String {
	/// The longest prefix of at most `bytes` UTF-8 bytes that ends on a scalar boundary.
	fileprivate func prefix(bytes: Int) -> String {
		guard utf8.count > bytes else { return self }
		var end = utf8.index(utf8.startIndex, offsetBy: max(0, bytes))
		while end.samePosition(in: unicodeScalars) == nil {
			end = utf8.index(before: end)
		}
		return String(String.UnicodeScalarView(unicodeScalars[..<end]))
	}
}
