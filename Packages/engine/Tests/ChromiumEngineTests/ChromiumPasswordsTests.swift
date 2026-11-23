import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumPasswordsTests {
	@Test
	internal func credentialsDecodeWithoutAnyPassword() async throws {
		let fixture = PasswordsFixture()
		let task = Task { try await fixture.passwords.credentials(page: 7) }
		let request = await fixture.nextRequest()
		#expect(request.page == 7)
		fixture.reply(
			request,
			status: ARX_SIGN_IN_OK,
			json: #"{"document":"ABC123","origin":"https://example.com","credentials":[{"id":3,"username":"me","form":true}]}"#
		)
		expectEqual(try await task.value, .init(
			document: "ABC123",
			origin: "https://example.com",
			credentials: [.init(id: 3, username: "me", hasForm: true)]
		))
	}

	@Test(arguments: [
		(ARX_SIGN_IN_SIGNED_IN, ChromiumSignInResult.Outcome.signedIn),
		(ARX_SIGN_IN_NEEDS_USER, .needsUser),
		(ARX_SIGN_IN_FAILED, .failed),
	])
	internal func attemptsReportOutcomes(
		status: ArxSignInStatus,
		outcome: ChromiumSignInResult.Outcome
	) async throws {
		let fixture = PasswordsFixture()
		let task = Task {
			try await fixture.passwords.attempt(page: 1, document: "ABC123", frame: "F00D", credential: 3, timeoutMilliseconds: 5_000)
		}
		let request = await fixture.nextRequest()
		#expect(request.document == "ABC123")
		#expect(request.frame == "F00D")
		#expect(request.credential == 3)
		fixture.reply(request, status: status, json: #"{"reason":"x","filled":true,"passwordVisible":false}"#)
		expectEqual(try await task.value, .init(outcome: outcome, reason: "x", filled: true, passwordVisible: false))
	}

	@Test(arguments: [
		(ARX_SIGN_IN_STALE, ChromiumSignInFailure.staleDocument(filled: true)),
		(ARX_SIGN_IN_TIMEOUT, .timedOut(filled: true)),
		(ARX_SIGN_IN_BUSY, .busy),
		(ARX_SIGN_IN_INVALID, .invalidRequest),
		(ARX_SIGN_IN_UNAVAILABLE, .unavailable),
	])
	internal func failuresKeepWhetherAValueWentIn(
		status: ArxSignInStatus,
		failure: ChromiumSignInFailure
	) async throws {
		let fixture = PasswordsFixture()
		let task = Task {
			try await fixture.passwords.attempt(page: 1, document: "ABC", frame: nil, credential: 1, timeoutMilliseconds: 5_000)
		}
		fixture.reply(await fixture.nextRequest(), status: status, json: #"{"reason":"x","filled":true}"#)
		await #expect(throws: failure) { try await task.value }
	}

	@Test(arguments: [
		("", nil as String?, 5_000),
		("not a token", nil, 5_000),
		("ABC", "", 5_000),
		("ABC", "x-y", 5_000),
		("ABC", nil, 4_999),
		("ABC", nil, 60_001),
	])
	internal func invalidAttemptsNeverReachNative(
		document: String,
		frame: String?,
		timeout: Int
	) async throws {
		let fixture = PasswordsFixture()
		await #expect(throws: ChromiumSignInFailure.invalidRequest) {
			try await fixture.passwords.attempt(page: 1, document: document, frame: frame, credential: 1, timeoutMilliseconds: timeout)
		}
		#expect(PasswordsFixture.pending.isEmpty)
	}

	@Test
	internal func offersReachObserversAndCancellationReachesNative() async throws {
		let fixture = PasswordsFixture()
		var iterator = fixture.passwords.offers().makeAsyncIterator()
		let offer = ChromiumPasswordSaveOffer(page: 2, token: 9, origin: "https://example.com", username: "me", isUpdate: true)
		fixture.passwords.offered(offer)
		#expect(await iterator.next() == offer)

		let cancelled = Task { try await fixture.passwords.credentials(page: 1) }
		let request = await fixture.nextRequest()
		cancelled.cancel()
		await #expect(throws: CancellationError.self) { try await cancelled.value }
		while PasswordsFixture.cancelled.isEmpty { await Task.yield() }
		#expect(PasswordsFixture.cancelled == [request.id])
	}

	@Test
	internal func missingBridgeIsUnavailable() async {
		let passwords = ChromiumPasswords(api: ArxEngineAPI())
		#expect(!passwords.isAvailable)
		await #expect(throws: ChromiumSignInFailure.unavailable) { try await passwords.credentials(page: 1) }
	}

	private func expectEqual<Value: Equatable>(_ actual: Value, _ expected: Value) {
		#expect(actual == expected)
	}
}

@MainActor
private struct PasswordsFixture {
	fileprivate struct Request {
		fileprivate var id: UInt64
		fileprivate var page: UInt64
		fileprivate var document: String?
		fileprivate var frame: String?
		fileprivate var credential: UInt32 = 0
	}

	fileprivate static var pending: [Request] = []
	fileprivate static var cancelled: [UInt64] = []
	fileprivate let passwords: ChromiumPasswords

	fileprivate init() {
		Self.pending = []
		Self.cancelled = []
		var api = ArxEngineAPI()
		api.answer_password_save = { _, _, _ in true }
		api.sign_in_credentials = { page, request in
			MainActor.assumeIsolated { PasswordsFixture.pending.append(.init(id: request, page: page)) }
		}
		api.sign_in_attempt = { page, request, document, frame, credential, _ in
			MainActor.assumeIsolated {
				PasswordsFixture.pending.append(.init(
					id: request,
					page: page,
					document: document.map { String(cString: $0) },
					frame: frame.map { String(cString: $0) },
					credential: credential
				))
			}
		}
		api.cancel_sign_in = { request in
			MainActor.assumeIsolated { PasswordsFixture.cancelled.append(request) }
		}
		self.passwords = .init(api: api)
	}

	fileprivate func nextRequest() async -> Request {
		while Self.pending.isEmpty { await Task.yield() }
		return Self.pending.removeFirst()
	}

	fileprivate func reply(
		_ request: Request,
		status: ArxSignInStatus,
		json: String
	) {
		let bytes = Array(json.utf8)
		bytes.withUnsafeBufferPointer { buffer in
			passwords.complete(request.id, page: request.page, status: status, json: buffer.baseAddress, count: buffer.count)
		}
	}
}
