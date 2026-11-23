import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Synchronization
import Testing
import _MCP

@testable import BrowserMCPServer

/// `browser_run` (DEV-1012): a script whose steps are the tool calls of the same name, each
/// through the same grant, approval and operationID checks as a direct call.
internal struct AutomationRunTests {
	@Test(.timeLimit(.minutes(1)))
	internal func aLoopOverSearchResultsCallsAToolPerResult() async throws {
		let fake = RunArx()
		let (run, finish) = try await fake.start()
		defer { finish() }
		let result = try await run.run(["code": .string("""
		const page = history({ query: 'arx' });
		const cleaned = page.result.items.map(item => links({ kind: 'clean', url: item.url }).result.url);
		console.log(cleaned.length + ' links');
		return cleaned;
		""")])
		let fields = try Self.fields(result)
		expectNoDifference(result.isError, false)
		expectNoDifference(fields["value"], .array([
			.string("https://a.example/"), .string("https://b.example/"), .string("https://c.example/"),
		]))
		expectNoDifference(fields["output"], .string("3 links"))
		expectNoDifference(fields["steps"], .int(4))
		expectNoDifference(fake.requests, ["data", "link", "link", "link"])
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aStepThatNeedsApprovalWaitsInsideTheRun() async throws {
		let fake = RunArx(approvalDelay: .milliseconds(400))
		let (run, finish) = try await fake.start()
		defer { finish() }
		let result = try await run.run(["code": .string("""
		const done = click({ operationID: uuid(), targetID: '\(UUID())', expectedRevision: '\(String(repeating: "a", count: 64))',
			snapshotID: 'snapshot', reference: 'send' });
		return done.result.disposition;
		""")])
		expectNoDifference(result.isError, false)
		let fields = try Self.fields(result)
		expectNoDifference(fields["value"], .string("dispatched"))

		// The log keeps the click's receipt, in case a later step fails.
		guard
			case let .array(log)? = fields["log"],
			case let .object(step)? = log.first,
			case let .object(receipt)? = step["result"]
		else {
			Issue.record("The click's receipt is missing from the log.")
			return
		}
		expectNoDifference(receipt["disposition"], .string("dispatched"))
	}

	/// A step waits for the user with the run's caller's wait: its limit and its progress lines,
	/// although the step runs on the script's own queue.
	@Test(.timeLimit(.minutes(1)))
	internal func aStepWaitsForTheUserWithTheRunsWait() async throws {
		let fake = RunArx(neverAnswers: true)
		let (run, finish) = try await fake.start()
		defer { finish() }
		let lines = Lines()
		let wait = AutomationGateway.UserWait(limit: .milliseconds(300), call: "browser_run {}") { line in
			lines.value.withLock { $0.append(line) }
		}
		let started = ContinuousClock.now
		let result = try await AutomationGateway.$userWait.withValue(wait) {
			try await run.run(["code": .string("""
			try {
			  click({ operationID: uuid(), targetID: '\(UUID())', expectedRevision: '\(String(repeating: "a", count: 64))',
			    snapshotID: 'snapshot', reference: 'send' });
			  return 'dispatched';
			} catch (error) {
			  return error.code;
			}
			""")])
		}
		expectNoDifference(try Self.fields(result)["value"], .string("waitingForUser"))

		// The run's 300 ms, not the 15 s a call with no wait of its own gets.
		#expect(ContinuousClock.now - started < .seconds(10))
		expectNoDifference(lines.value.withLock { $0.first }, "Waiting for the user to approve a click in Arx.")
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aStepTheGrantRefusesThrowsWithItsCode() async throws {
		let fake = RunArx(refuseClicks: true)
		let (run, finish) = try await fake.start()
		defer { finish() }
		let click = """
		click({ operationID: uuid(), targetID: '\(UUID())', expectedRevision: '\(String(repeating: "a", count: 64))',
			snapshotID: 'snapshot', reference: 'send' })
		"""
		let caught = try await run.run(["code": .string("try { \(click); return 'ran'; } catch (e) { return e.code; }")])
		expectNoDifference(try Self.fields(caught)["value"], .string("denied"))

		let uncaught = try await run.run(["code": .string("\(click); return 'ran';")])
		expectNoDifference(uncaught.isError, true)
		let fields = try Self.fields(uncaught)
		#expect(fields["error"]?.stringValue?.hasPrefix("denied") == true)
		// The log keeps the refused click's receipt, so its operationID and disposition survive.
		guard case let .array(log)? = fields["log"], case let .object(step)? = log.first, log.count == 1 else {
			Issue.record("The log should have the one click.")
			return
		}
		expectNoDifference(step["error"], .string("denied"))
		guard case let .object(receipt)? = step["result"] else {
			Issue.record("The click's receipt is missing.")
			return
		}
		expectNoDifference(receipt["disposition"], .string("notDispatched"))
		#expect(receipt["operationID"] != nil)
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aSecondRunIsRefusedWhileOneIsRunning() async throws {
		let fake = RunArx()
		let (run, finish) = try await fake.start()
		defer { finish() }
		let first = Task {
			try await run.run(["code": .string("sleep(1500); return 'first';")])
		}
		try await Task.sleep(for: .milliseconds(300))
		let second = try await run.run(["code": .string("return 'second';")])
		expectNoDifference(second.isError, true)
		#expect(try Self.fields(second)["error"]?.stringValue?.hasPrefix("busy") == true)
		let firstResult = try await first.value
		expectNoDifference(try Self.fields(firstResult)["value"], .string("first"))

		let third = try await run.run(["code": .string("return 'third';")])
		expectNoDifference(try Self.fields(third)["value"], .string("third"))
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aRunStopsAtItsStepLimit() async throws {
		let fake = RunArx()
		let (run, finish) = try await fake.start()
		defer { finish() }
		let result = try await run.run(["code": .string("""
		for (let i = 0; i < 201; i++) links({ kind: 'clean', url: 'https://a.example/' });
		""")])
		expectNoDifference(result.isError, true)
		let fields = try Self.fields(result)
		expectNoDifference(fields["steps"], .int(AutomationRun.maximumSteps))
		#expect(fields["error"]?.stringValue?.hasPrefix("limitExceeded") == true)
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aScriptThatNeverEndsStopsAtItsTimeLimit() async throws {
		let fake = RunArx()
		let (run, finish) = try await fake.start()
		defer { finish() }
		let started = ContinuousClock.now
		let result = try await run.run(["code": .string("while (true) {}"), "timeoutSeconds": .int(1)])
		expectNoDifference(result.isError, true)
		#expect(ContinuousClock.now - started < .seconds(10))
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aStepStillRunningAtTheDeadlineEndsTheRun() async throws {
		let fake = RunArx(approvalDelay: .seconds(20))
		let (run, finish) = try await fake.start()
		defer { finish() }
		let started = ContinuousClock.now
		let result = try await run.run([
			"code": .string("""
			try {
				click({ operationID: uuid(), targetID: '\(UUID())', expectedRevision: '\(String(repeating: "a", count: 64))',
					snapshotID: 'snapshot', reference: 'send' });
			} catch (e) {
				return e.code;
			}
			return 'ran';
			"""),
			"timeoutSeconds": .int(1),
		])
		#expect(ContinuousClock.now - started < .seconds(10))
		expectNoDifference(result.isError, true)
		let fields = try Self.fields(result)
		#expect(fields["error"]?.stringValue?.hasPrefix("timedOut") == true)
		// The log keeps what is known about the cut-off click: its receipt, or that it never answered.
		guard case let .array(log)? = fields["log"], case let .object(step)? = log.first, log.count == 1 else {
			Issue.record("The log should have the one click.")
			return
		}
		expectNoDifference(step["tool"], .string("browser_click"))
		expectNoDifference(step["error"], .string("timedOut"))
		#expect(step["unfinished"] == .bool(true) || step["result"] != nil)
	}

	@Test(.timeLimit(.minutes(1)), arguments: ["while (true) {}", "while (true) sleep(20000);"])
	internal func cancellingARunStopsABusyOrSleepingScript(_ code: String) async throws {
		let fake = RunArx()
		let (run, finish) = try await fake.start()
		defer { finish() }
		let started = ContinuousClock.now
		let busy = Task {
			try await run.run(["code": .string(code), "timeoutSeconds": .int(600)])
		}
		try await Task.sleep(for: .milliseconds(300))
		busy.cancel()
		let cancelled = try await busy.value
		#expect(ContinuousClock.now - started < .seconds(10))
		expectNoDifference(cancelled.isError, true)

		let next = try await run.run(["code": .string("return 1;")])
		expectNoDifference(try Self.fields(next)["value"], .int(1))
	}

	@Test(.timeLimit(.minutes(1)))
	internal func outputAndValueAreBoundedInBytes() async throws {
		let fake = RunArx()
		let (run, finish) = try await fake.start()
		defer { finish() }
		let result = try await run.run(["code": .string("""
		const marks = '\\u0301'.repeat(1600000);
		console.log('a' + marks);
		return 'b' + marks;
		""")])
		#expect(BrowserMCPServer.fits(result))
		let fields = try Self.fields(result)
		expectNoDifference(fields["truncated"], .bool(true))
		#expect((fields["output"]?.stringValue?.utf8.count ?? .max) <= 8_000)
		#expect((fields["value"]?.stringValue?.utf8.count ?? .max) <= 8_000)
	}

	@Test
	internal func stepImagesComeAfterTheResultNewestFirstWhenTheyDontAllFit() throws {
		let image: (String) -> Tool.Content = { tag in
			.image(data: tag + String(repeating: "A", count: 4_000_000), mimeType: "image/png", annotations: nil, _meta: nil)
		}
		let outcome = AutomationRun.Outcome(
			value: "1",
			printed: "",
			truncated: false,
			log: [],
			failure: nil,
			outputLimit: 8_000,
			attachments: [image("old"), image("new")]
		)
		let result = try outcome.toolResult()
		#expect(BrowserMCPServer.fits(result))
		expectNoDifference(result.content.count, 2)
		guard case let .image(data, _, _, _) = result.content.last else {
			Issue.record("The newest image is missing.")
			return
		}
		#expect(data.hasPrefix("new"))
		expectNoDifference(try Self.fields(result)["attachmentsLeftOut"], .int(1))
	}

	@Test(.timeLimit(.minutes(1)))
	internal func keepLastsBetweenRunsAndRunsDontNest() async throws {
		let fake = RunArx()
		let (run, finish) = try await fake.start()
		defer { finish() }
		_ = try await run.run(["code": .string("keep.seen = (keep.seen || 0) + 1;")])
		let second = try await run.run(["code": .string("keep.seen += 1; return keep.seen;")])
		expectNoDifference(try Self.fields(second)["value"], .int(2))

		let nested = try await run.run(["code": .string("try { call('browser_run', { code: '1' }); } catch (e) { return e.code; }")])
		expectNoDifference(try Self.fields(nested)["value"], .string("unknownTool"))
	}

	@Test
	internal func runIsListedWithTheReadClass() {
		let listed = AutomationTools.definitions(for: .init(capabilities: [.read])).map(\.name)
		#expect(listed.contains("browser_run"))
		#expect(!AutomationTools.definitions(for: .init()).map(\.name).contains("browser_run"))
	}

	private static func fields(_ result: CallTool.Result) throws -> [String: Value] {
		guard
			case let .object(envelope)? = result.structuredContent,
			case let .object(fields)? = envelope["result"]
		else { throw AutomationFailure.invalidRequest }
		return fields
	}
}

/// The progress lines a run's caller hears.
private final class Lines: Sendable {
	let value: Mutex<[String]> = .init([])
}

/// Stands in for Arx: answers history, link and click requests.
private final class RunArx: Sendable {
	private static let asking: AutomationUserWait = .init(kind: .approval, question: "approve a click in Arx")
	private let approvalDelay: Duration?
	private let refuseClicks: Bool

	/// Arx asks the user about every click and never hears back.
	private let neverAnswers: Bool
	private let seen: Mutex<[String]> = .init([])

	internal init(
		approvalDelay: Duration? = nil,
		refuseClicks: Bool = false,
		neverAnswers: Bool = false
	) {
		self.approvalDelay = approvalDelay
		self.refuseClicks = refuseClicks
		self.neverAnswers = neverAnswers
	}

	internal var requests: [String] { seen.withLock { $0 } }

	internal func start() async throws -> (AutomationRun, @Sendable () -> Void) {
		let socket = LocalAutomationSocket()
		let directory = URL(fileURLWithPath: "/tmp/arx-run-" + UUID().uuidString.prefix(8))
		let path = try await socket.start(directory: directory) { [self] envelope in
			await reply(envelope.payload)
		}
		let gateway = AutomationGateway(path: path, clientID: UUID(), credential: String(repeating: "0", count: 64))
		try await gateway.initialize()
		let run = AutomationRun(calls: AutomationCalls(gateway: gateway))
		return (run, {
			Task {
				await gateway.disconnect()
				await socket.stop()
				try? FileManager.default.removeItem(at: directory)
			}
		})
	}

	private func reply(_ payload: AutomationIPC.Payload) async -> AutomationIPC.Reply {
		switch payload {
		case .hello:
			return .hello(UUID())

		case .grants:
			return .grants(.init(capabilities: [.read, .pageContent, .interact, .history]))

		case let .request(_, .data(request)):
			seen.withLock { $0.append("data") }
			let items = ["a", "b", "c"].map { host in
				AutomationDataItem(
					id: UUID(),
					kind: .history,
					title: host,
					url: "https://\(host).example/?utm_source=x",
					profileID: UUID(),
					date: Date(timeIntervalSince1970: 0),
					revision: String(repeating: "b", count: 64)
				)
			}
			return .result(.data(.init(request: request, items: items)))

		case let .request(_, .link(request)):
			seen.withLock { $0.append("link") }
			let url = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
			var clean = url
			clean?.query = nil
			return .result(.link(.init(request: request, url: clean?.string ?? "", outcome: "cleaned")))

		case let .request(_, .click(click)):
			seen.withLock { $0.append("click") }
			if refuseClicks {
				return .result(.click(.init(operationID: click.operationID, disposition: .notDispatched, failure: .denied)))
			}
			if neverAnswers { return .waitingForUser(Self.asking) }

			// Arx holds the request while the user decides.
			if let approvalDelay { try? await Task.sleep(for: approvalDelay) }
			return .result(.click(.init(operationID: click.operationID, disposition: .dispatched)))

		case .wait where neverAnswers:
			return .waitingForUser(Self.asking)

		default:
			return .acknowledged
		}
	}
}
