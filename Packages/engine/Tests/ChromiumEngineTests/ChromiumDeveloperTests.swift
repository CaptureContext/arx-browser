import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumDeveloperTests {
	@Test
	internal func scriptValueComesBackAsJSONText() async throws {
		let fixture = DeveloperFixture()
		let task = Task { try await fixture.developers.evaluate(page: 7, source: "return 1", maximumBytes: 1024, timeoutMilliseconds: 500) }
		let request = await fixture.nextRequest()
		#expect(request.page == 7)
		#expect(request.source == "return 1")
		#expect(request.maximumBytes == 1024)
		#expect(request.timeout == 500)

		fixture.reply(request, status: ARX_DEVELOPER_OK, json: #"{"type":"json","value":"{\"a\":1}"}"#)
		#expect(try await task.value == .json(#"{"a":1}"#))
	}

	@Test(arguments: [
		(#"{"type":"undefined"}"#, ChromiumScriptValue.undefined),
		(#"{"type":"unserializable","description":"cyclic"}"#, ChromiumScriptValue.unserializable("cyclic")),
	])
	internal func otherValues(
		json: String,
		value: ChromiumScriptValue
	) async throws {
		let fixture = DeveloperFixture()
		let task = Task { try await fixture.developers.evaluate(page: 1, source: "x", maximumBytes: 1024, timeoutMilliseconds: 500) }
		fixture.reply(await fixture.nextRequest(), status: ARX_DEVELOPER_OK, json: json)
		#expect(try await task.value == value)
	}

	@Test
	internal func exceptionsAndSyntaxErrorsCarryTheirMessage() async throws {
		let fixture = DeveloperFixture()
		let thrown = Task { try await fixture.developers.evaluate(page: 1, source: "x", maximumBytes: 1024, timeoutMilliseconds: 500) }
		fixture.reply(await fixture.nextRequest(), status: ARX_DEVELOPER_EXCEPTION, json: #"{"name":"TypeError","message":"nope"}"#)
		await #expect(throws: ChromiumDeveloperFailure.exception(.init(name: "TypeError", message: "nope"))) {
			try await thrown.value
		}

		let syntax = Task { try await fixture.developers.evaluate(page: 1, source: "(", maximumBytes: 1024, timeoutMilliseconds: 500) }
		fixture.reply(
			await fixture.nextRequest(),
			status: ARX_DEVELOPER_SYNTAX,
			json: #"{"name":"SyntaxError","message":"Unexpected end of input","line":1}"#
		)
		await #expect(throws: ChromiumDeveloperFailure.syntax(.init(name: "SyntaxError", message: "Unexpected end of input", line: 1))) {
			try await syntax.value
		}
	}

	@Test(arguments: [
		(ARX_DEVELOPER_LIMIT, ChromiumDeveloperFailure.limitExceeded),
		(ARX_DEVELOPER_STALE, ChromiumDeveloperFailure.staleDocument),
		(ARX_DEVELOPER_TIMEOUT, ChromiumDeveloperFailure.timedOut),
		(ARX_DEVELOPER_BUSY, ChromiumDeveloperFailure.busy),
		(ARX_DEVELOPER_UNSUPPORTED, ChromiumDeveloperFailure.unsupportedDocument),
		(ARX_DEVELOPER_UNAVAILABLE, ChromiumDeveloperFailure.unavailable),
	])
	internal func failuresMapFromNativeStatus(
		status: ArxDeveloperStatus,
		failure: ChromiumDeveloperFailure
	) async throws {
		let fixture = DeveloperFixture()
		let task = Task { try await fixture.developers.evaluate(page: 1, source: "x", maximumBytes: 1024, timeoutMilliseconds: 500) }
		fixture.reply(await fixture.nextRequest(), status: status, json: nil)
		await #expect(throws: failure) { try await task.value }
	}

	@Test
	internal func aReplyForAnotherPageIsStale() async throws {
		let fixture = DeveloperFixture()
		let task = Task { try await fixture.developers.evaluate(page: 1, source: "x", maximumBytes: 1024, timeoutMilliseconds: 500) }
		let request = await fixture.nextRequest()
		fixture.developers.complete(request.id, page: 2, status: ARX_DEVELOPER_OK, json: nil, count: 0)
		await #expect(throws: ChromiumDeveloperFailure.staleDocument) { try await task.value }
	}

	@Test(arguments: [
		("", 1024, 500),
		("x", 0, 500),
		("x", 262_145, 500),
		("x", 1024, 0),
		("x", 1024, 30_001),
		("a\0b", 1024, 500),
	])
	internal func invalidRequestsNeverReachNative(
		source: String,
		maximumBytes: Int,
		timeout: Int
	) async throws {
		let fixture = DeveloperFixture()
		await #expect(throws: ChromiumDeveloperFailure.invalidRequest) {
			try await fixture.developers.evaluate(page: 1, source: source, maximumBytes: maximumBytes, timeoutMilliseconds: timeout)
		}
		#expect(DeveloperFixture.pending.isEmpty)
	}

	@Test
	internal func oversizedSourceIsRefused() async throws {
		let fixture = DeveloperFixture()
		let source = String(repeating: "a", count: 65_537)
		await #expect(throws: ChromiumDeveloperFailure.invalidRequest) {
			try await fixture.developers.evaluate(page: 1, source: source, maximumBytes: 1024, timeoutMilliseconds: 500)
		}
	}

	@Test
	internal func logReadsDecodeEntriesAndCursor() async throws {
		let fixture = DeveloperFixture()
		let task = Task { try await fixture.developers.read(page: 3, kind: .network, after: 4, limit: 2) }
		let request = await fixture.nextRequest()
		#expect(request.kind == ARX_DEVELOPER_LOG_NETWORK)
		#expect(request.after == 4)
		#expect(request.limit == 2)
		fixture.reply(request, status: ARX_DEVELOPER_OK, json: """
		{"capturing":true,"entries":[{"sequence":5,"method":"GET","url":"https://a.test/?token=redacted",\
		"status":200,"type":"script","cached":false,"bytes":10,"mainFrame":true,"time":1.5}],"next":5,"dropped":0}
		""")
		let log = try await task.value
		#expect(log.capturing)
		#expect(log.next == 5)
		#expect(log.entries.map(\.url) == ["https://a.test/?token=redacted"])
	}

	@Test
	internal func readLimitsAreChecked() async throws {
		let fixture = DeveloperFixture()
		for limit in [0, 201] {
			await #expect(throws: ChromiumDeveloperFailure.invalidRequest) {
				try await fixture.developers.read(page: 1, kind: .console, after: 0, limit: limit)
			}
		}
	}

	@Test
	internal func cancellationReachesNativeAndStopAnswersPendingRequests() async throws {
		let fixture = DeveloperFixture()
		let cancelled = Task { try await fixture.developers.evaluate(page: 1, source: "x", maximumBytes: 1024, timeoutMilliseconds: 500) }
		let request = await fixture.nextRequest()
		cancelled.cancel()
		await #expect(throws: CancellationError.self) { try await cancelled.value }
		while DeveloperFixture.cancelled.isEmpty { await Task.yield() }
		#expect(DeveloperFixture.cancelled == [request.id])

		let pending = Task { try await fixture.developers.read(page: 1, kind: .console, after: 0, limit: 10) }
		_ = await fixture.nextRequest()
		fixture.developers.stop()
		await #expect(throws: ChromiumDeveloperFailure.unavailable) { try await pending.value }
	}

	@Test
	internal func missingBridgeIsUnavailable() async throws {
		let developers = ChromiumDevelopers(api: ArxEngineAPI())
		#expect(!developers.isAvailable)
		await #expect(throws: ChromiumDeveloperFailure.unavailable) {
			try await developers.evaluate(page: 1, source: "x", maximumBytes: 1024, timeoutMilliseconds: 500)
		}
	}
}

@MainActor
private struct DeveloperFixture {
	fileprivate struct Request {
		fileprivate var id: UInt64
		fileprivate var page: UInt64
		fileprivate var source: String?
		fileprivate var maximumBytes: UInt32 = 0
		fileprivate var timeout: UInt32 = 0
		fileprivate var kind: ArxDeveloperLogKind?
		fileprivate var after: UInt64 = 0
		fileprivate var limit: UInt32 = 0
	}

	fileprivate static var pending: [Request] = []
	fileprivate static var cancelled: [UInt64] = []
	fileprivate let developers: ChromiumDevelopers

	fileprivate init() {
		Self.pending = []
		Self.cancelled = []
		var api = ArxEngineAPI()
		api.evaluate_script = { page, request, source, maximumBytes, timeout in
			MainActor.assumeIsolated {
				DeveloperFixture.pending.append(.init(
					id: request,
					page: page,
					source: source.map { String(cString: $0) },
					maximumBytes: maximumBytes,
					timeout: timeout
				))
			}
		}
		api.set_developer_log = { _, _ in true }
		api.read_developer_log = { page, request, kind, after, limit in
			MainActor.assumeIsolated {
				DeveloperFixture.pending.append(.init(id: request, page: page, kind: kind, after: after, limit: limit))
			}
		}
		api.cancel_developer = { request in
			MainActor.assumeIsolated { DeveloperFixture.cancelled.append(request) }
		}
		self.developers = .init(api: api)
	}

	fileprivate func nextRequest() async -> Request {
		while Self.pending.isEmpty { await Task.yield() }
		return Self.pending.removeFirst()
	}

	fileprivate func reply(
		_ request: Request,
		status: ArxDeveloperStatus,
		json: String?
	) {
		guard let json else {
			developers.complete(request.id, page: request.page, status: status, json: nil, count: 0)
			return
		}
		let bytes = Array(json.utf8)
		bytes.withUnsafeBufferPointer { buffer in
			developers.complete(request.id, page: request.page, status: status, json: buffer.baseAddress, count: buffer.count)
		}
	}
}
