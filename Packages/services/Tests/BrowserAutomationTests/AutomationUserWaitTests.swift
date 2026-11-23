import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Synchronization
import Testing
import _Dependencies
import _MCP

@testable import BrowserMCPServer

/// A call that needs the user waits for them inside the call, says what Arx asks, and past
/// its limit returns while the request stays open for the same call to collect (DEV-1024).
internal struct AutomationUserWaitGatewayTests {
	@Test(.timeLimit(.minutes(1)))
	internal func aCallWaitsForTheUserAndSaysWhatArxAsks() async throws {
		let fake = FakeArx(answerAfterWaits: 2)
		let (gateway, socket) = try await fake.start()
		let heard = Locked<[String]>([])
		let wait = AutomationGateway.UserWait(limit: .seconds(30)) { message in
			heard.value.withLock { $0.append(message) }
		}
		let click = AutomationClickTests.request()
		let result = await AutomationGateway.$userWait.withValue(wait) {
			await gateway.perform(.click(click))
		}
		expectNoDifference(result, .click(.init(operationID: click.operationID, disposition: .dispatched)))
		let lines = heard.value.withLock { $0 }
		#expect(lines.count >= 2)
		#expect(lines.allSatisfy { $0 == "Waiting for the user to approve a click in Arx." })
		expectNoDifference(fake.requests, 1)
		await gateway.disconnect()
		await socket.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func pastItsLimitTheSameCallCollectsTheOpenRequest() async throws {
		let fake = FakeArx(answerAfterWaits: nil)
		let (gateway, socket) = try await fake.start()
		let click = AutomationClickTests.request()
		let wait = AutomationGateway.UserWait(limit: .milliseconds(300))
		let first = await AutomationGateway.$userWait.withValue(wait) {
			await gateway.perform(.click(click))
		}
		expectNoDifference(first, .failure(.waitingForUser))
		expectNoDifference(wait.note.wait.withLock { $0?.question }, "approve a click in Arx")

		// The result names what Arx asks and how to collect it.
		let response = try AutomationGateway.$userWait.withValue(wait) {
			try BrowserMCPServer.toolResult(first)
		}
		let encoded = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
		#expect(encoded.contains("waitingForUser"))
		#expect(encoded.contains("approve a click in Arx"))
		#expect(encoded.contains("same operationID"))

		// The user answers later: the same call collects it, and nothing is sent twice.
		fake.answer()
		let second = await AutomationGateway.$userWait.withValue(.init(limit: .seconds(30))) {
			await gateway.perform(.click(click))
		}
		expectNoDifference(second, .click(.init(operationID: click.operationID, disposition: .dispatched)))
		expectNoDifference(fake.requests, 1)

		// Another operation is another request.
		_ = await AutomationGateway.$userWait.withValue(.init(limit: .seconds(30))) {
			await gateway.perform(.click(AutomationClickTests.request()))
		}
		expectNoDifference(fake.requests, 2)
		await gateway.disconnect()
		await socket.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func theSameToolCallCollectsItEvenWhenParsingGeneratesFields() async throws {
		let fake = FakeArx(answerAfterWaits: nil)
		let (gateway, socket) = try await fake.start()
		let call = BrowserMCPServer.callIdentity("browser_batch", arguments: ["steps": .array([])])

		// Parsing the same arguments again made another operation (a new batch or rule ID).
		let first = await AutomationGateway.$userWait.withValue(.init(limit: .milliseconds(300), call: call)) {
			await gateway.perform(.click(AutomationClickTests.request()))
		}
		expectNoDifference(first, .failure(.waitingForUser))
		fake.answer()
		let second = await AutomationGateway.$userWait.withValue(.init(limit: .seconds(30), call: call)) {
			await gateway.perform(.click(AutomationClickTests.request()))
		}
		guard case let .click(receipt) = second else {
			Issue.record("The same call didn't collect the open request")
			return
		}
		expectNoDifference(receipt.disposition, .dispatched)
		expectNoDifference(fake.requests, 1)
		await gateway.disconnect()
		await socket.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aWaitThatEndsWithoutAnAnswerKeepsTheClickUncertain() async throws {
		let fake = FakeArx(answerAfterWaits: nil, waitFailure: .timedOut)
		let (gateway, socket) = try await fake.start()
		let click = AutomationClickTests.request()
		let result = await AutomationGateway.$userWait.withValue(.init(limit: .seconds(30))) {
			await gateway.perform(.click(click))
		}
		expectNoDifference(result, .click(.init(
			operationID: click.operationID,
			disposition: .possiblyDispatched,
			failure: .timedOut
		)))
		await gateway.disconnect()
		await socket.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func signInIsFollowedInsideTheCall() async throws {
		let fake = FakeArx(answerAfterWaits: nil, signInConfirmedAfter: 2)
		let (gateway, socket) = try await fake.start()
		let heard = Locked<[String]>([])
		let wait = AutomationGateway.UserWait(limit: .seconds(30)) { message in
			heard.value.withLock { $0.append(message) }
		}
		let operationID = UUID()
		let response = try await AutomationGateway.$userWait.withValue(wait) {
			try await AutomationCalls(gateway: gateway).call(
				"browser_sign_in",
				arguments: ["operationID": .string(operationID.uuidString), "action": .string("status")]
			)
		}
		let encoded = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
		#expect(encoded.contains("userConfirmed"))
		#expect(heard.value.withLock { $0 }.contains("Waiting for the user to sign in in Arx."))
		await gateway.disconnect()
		await socket.stop()
	}

	@Test(arguments: [
		("claude-code", true, Duration.seconds(600)),
		("claude-code", false, .seconds(15)),
		("codex-mcp-client", true, .seconds(15)),
		(nil, true, .seconds(15)),
	] as [(String?, Bool, Duration)])
	internal func onlyClientsThatShowProgressWaitLong(
		client: String?,
		hearsProgress: Bool,
		limit: Duration
	) {
		expectNoDifference(BrowserMCPServer.userWaitLimit(client: client, hearsProgress: hearsProgress), limit)
	}
}

/// Stands in for Arx: asks the user about every mutation, and answers once told to.
private final class FakeArx: Sendable {
	private let state: Mutex<State>
	private let waitFailure: AutomationFailure?

	private struct State {
		var requests: Int = 0
		var waits: Int = 0
		var answered: Bool = false
		var signInPolls: Int = 0
		var answerAfterWaits: Int?
		var signInConfirmedAfter: Int?
		var click: AutomationClickRequest?
	}

	internal init(
		answerAfterWaits: Int?,
		waitFailure: AutomationFailure? = nil,
		signInConfirmedAfter: Int? = nil
	) {
		self.state = .init(.init(answerAfterWaits: answerAfterWaits, signInConfirmedAfter: signInConfirmedAfter))
		self.waitFailure = waitFailure
	}

	internal var requests: Int { state.withLock { $0.requests } }

	internal func answer() {
		state.withLock { $0.answered = true }
	}

	internal func start() async throws -> (AutomationGateway, LocalAutomationSocket) {
		let socket = LocalAutomationSocket()
		let directory = URL(fileURLWithPath: "/tmp/arx-user-wait-" + UUID().uuidString.prefix(8))
		let path = try await socket.start(directory: directory) { [self] envelope in
			reply(envelope.payload)
		}
		let gateway = AutomationGateway(path: path, clientID: UUID(), credential: String(repeating: "0", count: 64))
		try await gateway.initialize()
		return (gateway, socket)
	}

	private func reply(_ payload: AutomationIPC.Payload) -> AutomationIPC.Reply {
		let asking = AutomationUserWait(kind: .approval, question: "approve a click in Arx")
		switch payload {
		case .hello:
			return .hello(UUID())

		case .grants:
			return .grants(.init())

		case let .request(_, .signIn(request)):
			return state.withLock { state in
				state.signInPolls += 1
				let confirmed = state.signInConfirmedAfter.map { state.signInPolls > $0 } ?? false
				return .result(.signIn(.init(
					operationID: request.operationID,
					status: confirmed ? .userConfirmed : .userActionRequired
				)))
			}

		case let .request(_, .click(click)):
			state.withLock {
				$0.requests += 1
				$0.click = click
			}
			return .waitingForUser(asking)

		case .wait:
			if let waitFailure { return .failure(waitFailure) }
			return state.withLock { state in
				state.waits += 1
				let answered = state.answered || state.answerAfterWaits.map { state.waits >= $0 } ?? false
				guard answered, let click = state.click else { return .waitingForUser(asking) }
				return .result(.click(.init(operationID: click.operationID, disposition: .dispatched)))
			}

		default:
			return .acknowledged
		}
	}
}

/// The app side: a waiting request outlives its call, and a later `wait` collects it (DEV-1024).
@MainActor
internal struct AutomationUserWaitHostTests {
	@Test(.timeLimit(.minutes(1)))
	internal func aWaitingRequestReturnsAtOnceAndAWaitCollectsItsResult() async throws {
		let fixture = try await WaitFixture()
		defer { fixture.finish() }
		let (requestID, request) = try await fixture.request()
		fixture.host.waitForUser(requestID, Self.asking)
		guard case let .waitingForUser(wait) = try await request.value else {
			Issue.record("A request waiting for the user still blocked its call")
			return
		}
		expectNoDifference(wait, Self.asking)

		// A wait that hears nothing in its time says the request still waits.
		let quiet = Task { try await fixture.exchange(.wait(requestID, seconds: 1)) }
		try await Task.sleep(for: .milliseconds(100))
		await fixture.clock.advance(by: .seconds(1))
		guard case .waitingForUser = try await quiet.value else {
			Issue.record("A quiet wait didn't return")
			return
		}

		// The user approves while a wait listens.
		let listening = Task { try await fixture.exchange(.wait(requestID, seconds: 10)) }
		try await Task.sleep(for: .milliseconds(100))
		fixture.host.respond(requestID, result: Self.result)
		guard case .result(Self.result) = try await listening.value else {
			Issue.record("The waiting call didn't get the result")
			return
		}
		guard case .failure(.timedOut) = try await fixture.exchange(.wait(requestID, seconds: 1)) else {
			Issue.record("A collected result was given out twice")
			return
		}
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aLateAnswerIsKeptForTheSameSessionAndGrant() async throws {
		let fixture = try await WaitFixture()
		defer { fixture.finish() }
		let (requestID, request) = try await fixture.request()
		fixture.host.waitForUser(requestID, Self.asking)
		_ = try await request.value

		// Nobody listens when the user approves: the result waits to be collected.
		fixture.host.respond(requestID, result: Self.result)
		var other = fixture.envelope
		other.sessionID = UUID()
		other.payload = .wait(requestID, seconds: 1)
		guard case .failure = try await LocalAutomationSocket.exchange(path: fixture.path, envelope: other) else {
			Issue.record("Another connection collected the result")
			return
		}
		guard case .result(Self.result) = try await fixture.exchange(.wait(requestID, seconds: 1)) else {
			Issue.record("The late result wasn't kept")
			return
		}
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aChangedGrantGetsNoKeptResult() async throws {
		let fixture = try await WaitFixture()
		defer { fixture.finish() }
		let (requestID, request) = try await fixture.request()
		fixture.host.waitForUser(requestID, Self.asking)
		_ = try await request.value
		fixture.host.respond(requestID, result: Self.result)
		fixture.authority.preferences.clients[0].grantRevision = UUID()
		guard case .failure(.denied) = try await fixture.exchange(.wait(requestID, seconds: 1)) else {
			Issue.record("A result outlived its grant")
			return
		}
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aKeptResultIsCheckedAgainBeforeItIsReleased() async throws {
		let fixture = try await WaitFixture()
		defer { fixture.finish() }
		let (requestID, request) = try await fixture.request()
		fixture.host.waitForUser(requestID, Self.asking)
		_ = try await request.value
		fixture.host.respond(requestID, result: Self.result)

		// Its tab left the grant, or developer mode went off, before anyone collected it.
		fixture.authority.failure = .denied
		guard case .failure(.denied) = try await fixture.exchange(.wait(requestID, seconds: 1)) else {
			Issue.record("A kept result skipped the live check")
			return
		}
	}

	@Test(.timeLimit(.minutes(1)))
	internal func overlappingWaitsAllHearTheResult() async throws {
		let fixture = try await WaitFixture()
		defer { fixture.finish() }
		let (requestID, request) = try await fixture.request()
		fixture.host.waitForUser(requestID, Self.asking)
		_ = try await request.value

		// The same call made twice at once: neither displaces the other.
		let first = Task { try await fixture.exchange(.wait(requestID, seconds: 10)) }
		let second = Task { try await fixture.exchange(.wait(requestID, seconds: 10)) }
		try await Task.sleep(for: .milliseconds(200))
		fixture.host.respond(requestID, result: Self.result)
		for listener in [first, second] {
			guard case .result(Self.result) = try await listener.value else {
				Issue.record("An overlapping wait didn't hear the result")
				return
			}
		}
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aLateCommandComesBackAsItsOutcomeOnly() async throws {
		let fixture = try await WaitFixture()
		defer { fixture.finish() }
		let (requestID, request) = try await fixture.request()
		fixture.host.waitForUser(requestID, Self.asking)
		_ = try await request.value
		let operationID = UUID()
		var command = AutomationCommandResult(operationID: operationID, status: .committed, targetID: UUID())
		command.route = .init(profileID: UUID(), spaceID: UUID(), mode: .mainBrowser, source: .rule, ruleID: UUID(), ruleName: "Work")
		fixture.host.respond(requestID, result: .command(command))
		guard case let .result(.command(receipt)) = try await fixture.exchange(.wait(requestID, seconds: 1)) else {
			Issue.record("The late command's outcome wasn't kept")
			return
		}
		expectNoDifference(receipt.operationID, operationID)
		#expect(receipt.route == nil && receipt.item == nil && receipt.presentation == nil)
	}

	@Test(.timeLimit(.minutes(1)))
	internal func aWaitingRequestEndsAfterTheLimit() async throws {
		let fixture = try await WaitFixture()
		defer { fixture.finish() }
		let (requestID, request) = try await fixture.request()
		fixture.host.waitForUser(requestID, Self.asking)
		_ = try await request.value

		// Its old 30-second limit no longer applies.
		await fixture.clock.advance(by: .seconds(31))
		let quiet = Task { try await fixture.exchange(.wait(requestID, seconds: 1)) }
		try await Task.sleep(for: .milliseconds(100))
		await fixture.clock.advance(by: .seconds(1))
		guard case .waitingForUser = try await quiet.value else {
			Issue.record("A waiting request ended at the ordinary limit")
			return
		}

		// Kept alive by its helper's heartbeat, it ends at the user-wait limit.
		for _ in 0..<31 {
			_ = try await fixture.exchange(.ping)
			await fixture.clock.advance(by: .seconds(30))
		}
		guard case .failure(.timedOut) = try await fixture.exchange(.wait(requestID, seconds: 1)) else {
			Issue.record("A waiting request outlived the user-wait limit")
			return
		}
		#expect(fixture.cancelled.value.withLock { $0 }.contains(requestID))
	}

	private static let asking: AutomationUserWait = .init(kind: .approval, question: "approve a click in Arx")
	private static let result: AutomationResult = .inventory(.init(items: []))
}

@MainActor
private final class WaitFixture {
	internal let clock: TestClock<Duration> = .init()
	internal let host: BrowserAutomationHost
	internal let authority: WaitAuthority
	internal let path: String
	internal var envelope: AutomationIPC.Envelope
	internal let cancelled: Locked<Set<UUID>> = .init([])
	private let directory: URL
	private let events: AsyncStream<AutomationHostEvent>
	private let listener: Task<Void, Never>

	internal init() async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-user-wait-host-" + UUID().uuidString.prefix(8))
		self.directory = directory
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		let authority = WaitAuthority(preferences: AutomationPreferences(isEnabled: true, clients: [client]))
		self.authority = authority
		let host = BrowserAutomationHost(directory: directory, clock: AnyClock(clock))
		self.host = host
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		let (requests, forward) = AsyncStream<AutomationHostEvent>.makeStream()
		self.events = requests
		host.configure(
			preferences: { authority.preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in authority.failure }
		)
		let cancelled = self.cancelled
		self.listener = Task {
			for await event in events {
				if case let .cancel(id) = event { cancelled.value.withLock { _ = $0.insert(id) } }
				forward.yield(event)
			}
		}
		self.path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope)
		else { throw AutomationFailure.staleSession }
		envelope.epoch = epoch
		self.envelope = envelope
	}

	/// Sends a request and waits until it reaches the app.
	internal func request() async throws -> (UUID, Task<AutomationIPC.Reply, any Error>) {
		let id = UUID()
		var envelope = self.envelope
		envelope.payload = .request(id, .inventory(cursor: nil, limit: 1))
		let sent = envelope
		let path = self.path
		let task = Task { try await LocalAutomationSocket.exchange(path: path, envelope: sent) }
		for await event in events {
			if case let .request(request) = event, request.id == id { break }
		}
		return (id, task)
	}

	internal func exchange(_ payload: AutomationIPC.Payload) async throws -> AutomationIPC.Reply {
		var envelope = self.envelope
		envelope.payload = payload
		return try await LocalAutomationSocket.exchange(path: path, envelope: envelope)
	}

	internal func finish() {
		listener.cancel()
		let host = self.host
		let directory = self.directory
		Task { @MainActor in
			await host.stop()
			try? FileManager.default.removeItem(at: directory)
		}
	}
}

private final class WaitAuthority {
	internal var preferences: AutomationPreferences

	/// What Arx's live check answers about a result.
	internal var failure: AutomationFailure?

	internal init(preferences: AutomationPreferences) {
		self.preferences = preferences
	}
}

/// A value shared with escaping closures across tasks.
private final class Locked<Value: Sendable>: Sendable {
	internal let value: Mutex<Value>

	internal init(_ value: Value) {
		self.value = .init(value)
	}
}
