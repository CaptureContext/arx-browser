import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumSavedPasswordsTests {
	@Test
	internal func listingsDecodeSitesAndUsernamesOnly() async throws {
		let fixture = SavedPasswordsFixture()
		let task = Task { try await fixture.passwords.list(profileKey: "") }
		let request = await fixture.nextRequest()
		#expect(request.kind == .list)
		#expect(request.profileKey == "")
		// A stray field in the reply never becomes part of the Swift value.
		fixture.reply(request, status: ARX_SAVED_PASSWORDS_OK, json: #"""
		{"listing":"ABC123","passwords":[{"id":1,"site":"example.com","origin":"https://example.com","username":"me","password":"never"}],
		"blocked":[{"id":2,"site":"blocked.test","origin":"https://blocked.test"}]}
		"""#)
		expectEqual(try await task.value, .init(
			listing: "ABC123",
			passwords: [.init(id: 1, site: "example.com", origin: "https://example.com", username: "me")],
			blocked: [.init(id: 2, site: "blocked.test", origin: "https://blocked.test")]
		))
	}

	@Test
	internal func savesLendTheFieldAndNeverItsValue() async throws {
		let fixture = SavedPasswordsFixture()
		let field = NSSecureTextField()
		field.stringValue = "probe"
		let task = Task {
			try await fixture.passwords.save(
				profileKey: "a",
				listing: "ABC123",
				credential: 4,
				url: nil,
				username: "me",
				passwordField: field
			)
		}
		let request = await fixture.nextRequest()
		#expect(request.kind == .save)
		#expect(request.listing == "ABC123")
		#expect(request.credential == 4)
		#expect(request.username == "me")
		#expect(request.field == Unmanaged.passUnretained(field).toOpaque())
		fixture.reply(request, status: ARX_SAVED_PASSWORDS_OK, json: #"{"listing":"DEF","passwords":[],"blocked":[]}"#)
		#expect(try await task.value.listing == "DEF")
	}

	@Test
	internal func additionsNeedASite() async throws {
		let fixture = SavedPasswordsFixture()
		await #expect(throws: ChromiumSavedPasswordFailure.invalid(reason: nil)) {
			try await fixture.passwords.save(profileKey: "", listing: nil, credential: 0, url: "", username: "", passwordField: nil)
		}
		await #expect(throws: ChromiumSavedPasswordFailure.invalid(reason: nil)) {
			try await fixture.passwords.save(profileKey: "", listing: "not a token", credential: 1, url: nil, username: "", passwordField: nil)
		}
		await #expect(throws: ChromiumSavedPasswordFailure.invalid(reason: nil)) {
			try await fixture.passwords.remove(profileKey: "", listing: "ABC", credential: 0)
		}
		await #expect(throws: ChromiumSavedPasswordFailure.invalid(reason: nil)) {
			try await fixture.passwords.reveal(profileKey: "", listing: "ABC", credential: 1, reason: "", mode: .copy)
		}
		await #expect(throws: ChromiumSavedPasswordFailure.invalid(reason: nil)) {
			try await fixture.passwords.importPasswords(profileKey: "", file: URL(string: "https://example.com/a.csv")!)
		}
		#expect(SavedPasswordsFixture.pending.isEmpty)
	}

	@Test(arguments: [
		(ARX_SAVED_PASSWORDS_INVALID, #"{"reason":"format"}"#, ChromiumSavedPasswordFailure.invalid(reason: "format")),
		(ARX_SAVED_PASSWORDS_STALE, "{}", .stale),
		(ARX_SAVED_PASSWORDS_NOT_FOUND, "{}", .notFound),
		(ARX_SAVED_PASSWORDS_EXISTS, "{}", .exists),
		(ARX_SAVED_PASSWORDS_DENIED, "{}", .denied),
		(ARX_SAVED_PASSWORDS_BUSY, "{}", .busy),
		(ARX_SAVED_PASSWORDS_FAILED, #"{"reason":"io"}"#, .failed(reason: "io")),
		(ARX_SAVED_PASSWORDS_UNAVAILABLE, "{}", .unavailable),
	])
	internal func failuresMapFromNativeStatuses(
		status: ArxSavedPasswordsStatus,
		json: String,
		failure: ChromiumSavedPasswordFailure
	) async throws {
		let fixture = SavedPasswordsFixture()
		let task = Task { try await fixture.passwords.remove(profileKey: "", listing: "ABC", credential: 1) }
		fixture.reply(await fixture.nextRequest(), status: status, json: json)
		await #expect(throws: failure) { try await task.value }
	}

	@Test
	internal func revealsShowIntoTheLentField() async throws {
		let fixture = SavedPasswordsFixture()
		let field = NSTextField()
		let task = Task {
			try await fixture.passwords.reveal(profileKey: "", listing: "ABC", credential: 3, reason: "Show", mode: .show(field))
		}
		let request = await fixture.nextRequest()
		#expect(request.kind == .reveal)
		#expect(request.mode == ARX_PASSWORD_REVEAL_SHOW)
		#expect(request.field == Unmanaged.passUnretained(field).toOpaque())
		#expect(request.reason == "Show")
		fixture.reply(request, status: ARX_SAVED_PASSWORDS_OK, json: "{}")
		try await task.value
	}

	@Test
	internal func importsReportCountsConflictsAndSkippedRows() async throws {
		let fixture = SavedPasswordsFixture()
		let file = URL(fileURLWithPath: "/tmp/passwords.csv")
		let task = Task { try await fixture.passwords.importPasswords(profileKey: "", file: file) }
		let request = await fixture.nextRequest()
		#expect(request.kind == .import)
		#expect(request.path == "/tmp/passwords.csv")
		fixture.reply(request, status: ARX_SAVED_PASSWORDS_OK, json: #"""
		{"imported":2,"conflicts":[{"site":"example.com","username":"me"}],"conflictCount":1,
		"skipped":[{"site":"","username":"x","reason":"missingURL"}],"skippedCount":1}
		"""#)
		expectEqual(try await task.value, .init(
			imported: 2,
			conflicts: [.init(site: "example.com", username: "me")],
			conflictCount: 1,
			skipped: [.init(site: "", username: "x", reason: "missingURL")],
			skippedCount: 1
		))
	}

	@Test
	internal func cancellationReachesNativeAndStopFailsPending() async throws {
		let fixture = SavedPasswordsFixture()
		let cancelled = Task { try await fixture.passwords.list(profileKey: "") }
		let first = await fixture.nextRequest()
		cancelled.cancel()
		await #expect(throws: (any Error).self) { try await cancelled.value }
		while SavedPasswordsFixture.cancelled.isEmpty { await Task.yield() }
		#expect(SavedPasswordsFixture.cancelled == [first.id])

		let stopped = Task { try await fixture.passwords.list(profileKey: "") }
		_ = await fixture.nextRequest()
		fixture.passwords.stop()
		await #expect(throws: ChromiumSavedPasswordFailure.unavailable) { try await stopped.value }
	}

	private func expectEqual<Value: Equatable>(_ actual: Value, _ expected: Value) {
		#expect(actual == expected)
	}
}

@MainActor
private struct SavedPasswordsFixture {
	fileprivate enum Kind: Equatable {
		case list
		case save
		case remove
		case reveal
		case `import`
	}

	fileprivate struct Request {
		fileprivate var id: UInt64
		fileprivate var kind: Kind
		fileprivate var profileKey: String
		fileprivate var listing: String? = nil
		fileprivate var credential: UInt32 = 0
		fileprivate var username: String? = nil
		fileprivate var field: UnsafeMutableRawPointer? = nil
		fileprivate var mode: ArxPasswordReveal? = nil
		fileprivate var reason: String? = nil
		fileprivate var path: String? = nil
	}

	fileprivate static var pending: [Request] = []
	fileprivate static var cancelled: [UInt64] = []
	fileprivate let passwords: ChromiumSavedPasswords

	fileprivate init() {
		Self.pending = []
		Self.cancelled = []
		var api = ArxEngineAPI()
		api.list_saved_passwords = { request, key in
			MainActor.assumeIsolated {
				SavedPasswordsFixture.pending.append(.init(id: request, kind: .list, profileKey: String(cString: key!)))
			}
		}
		api.save_saved_password = { request, key, listing, credential, _, username, field in
			MainActor.assumeIsolated {
				SavedPasswordsFixture.pending.append(.init(
					id: request,
					kind: .save,
					profileKey: String(cString: key!),
					listing: listing.map { String(cString: $0) },
					credential: credential,
					username: username.map { String(cString: $0) },
					field: field
				))
			}
		}
		api.remove_saved_password = { request, key, listing, credential in
			MainActor.assumeIsolated {
				SavedPasswordsFixture.pending.append(.init(
					id: request,
					kind: .remove,
					profileKey: String(cString: key!),
					listing: listing.map { String(cString: $0) },
					credential: credential
				))
			}
		}
		api.reveal_saved_password = { request, key, listing, credential, mode, reason, field in
			MainActor.assumeIsolated {
				SavedPasswordsFixture.pending.append(.init(
					id: request,
					kind: .reveal,
					profileKey: String(cString: key!),
					listing: listing.map { String(cString: $0) },
					credential: credential,
					field: field,
					mode: mode,
					reason: reason.map { String(cString: $0) }
				))
			}
		}
		api.import_saved_passwords = { request, key, path in
			MainActor.assumeIsolated {
				SavedPasswordsFixture.pending.append(.init(
					id: request,
					kind: .import,
					profileKey: String(cString: key!),
					path: path.map { String(cString: $0) }
				))
			}
		}
		api.cancel_saved_passwords = { request in
			MainActor.assumeIsolated { SavedPasswordsFixture.cancelled.append(request) }
		}
		self.passwords = .init(api: api)
	}

	fileprivate func nextRequest() async -> Request {
		while Self.pending.isEmpty { await Task.yield() }
		return Self.pending.removeFirst()
	}

	fileprivate func reply(
		_ request: Request,
		status: ArxSavedPasswordsStatus,
		json: String
	) {
		let bytes = Array(json.utf8)
		bytes.withUnsafeBufferPointer { buffer in
			passwords.complete(request.id, status: status, json: buffer.baseAddress, count: buffer.count)
		}
	}
}
