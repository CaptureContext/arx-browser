import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumCredentialImportTests {
	@Test
	internal func anEngineWithoutABI46IsUnavailableAndNeverCalled() async throws {
		let credentials = ChromiumCredentialImport(api: ArxEngineAPI())
		#expect(!credentials.isAvailable)
		await #expect(throws: ChromiumCredentialImportFailure.unavailable) {
			try await credentials.importPasswords(profileKey: "", records: [Self.password])
		}
		await #expect(throws: ChromiumCredentialImportFailure.unavailable) {
			try await credentials.checkCookies(profileKey: "", keys: [])
		}
	}

	@Test
	internal func passwordsReachNativeForTheCallAndRepliesCarryKeysOnly() async throws {
		let fixture = CredentialImportFixture()
		#expect(fixture.credentials.isAvailable)
		let second: ChromiumImportedPassword = .init(
			url: "https://b.test/login",
			signonRealm: "https://b.test/",
			username: "",
			password: "pässwörd"
		)
		let task = Task { try await fixture.credentials.importPasswords(profileKey: "a", records: [Self.password, second]) }
		let request = await fixture.nextRequest()
		#expect(request.kind == .passwords)
		#expect(request.profileKey == "a")
		#expect(request.strings == [
			["https://a.test/", "https://a.test/", "ann", "throwaway"],
			["https://b.test/login", "https://b.test/", "", "pässwörd"],
		])

		// A stray value in the reply never becomes part of the Swift value.
		fixture.reply(request, status: ARX_CREDENTIAL_IMPORT_OK, json: #"""
		{"imported":[{"signonRealm":"https://a.test/","username":"ann","dateCreated":"13370000000000000","password":"never"}],
		"conflicts":1,"skipped":0}
		"""#)
		#expect(try await task.value == .init(
			imported: [.init(signonRealm: "https://a.test/", username: "ann", dateCreated: "13370000000000000")],
			conflicts: 1,
			skipped: 0
		))
	}

	@Test
	internal func cookiesCarryTheirWholeIdentity() async throws {
		let fixture = CredentialImportFixture()
		let cookie: ChromiumImportedCookie = .init(
			domain: ".a.test",
			name: "__Host-id",
			value: "throwaway",
			path: "/",
			topFrameSiteKey: "https://top.test",
			creationUTC: 1,
			expiresUTC: 2,
			lastAccessUTC: 3,
			isSecure: true,
			isHTTPOnly: true,
			hasCrossSiteAncestor: true,
			sameSite: 1,
			priority: 2,
			sourceScheme: 2,
			sourcePort: 8443
		)
		let task = Task { try await fixture.credentials.importCookies(profileKey: "", cookies: [cookie]) }
		let request = await fixture.nextRequest()
		#expect(request.kind == .cookies)
		#expect(request.strings == [[".a.test", "__Host-id", "throwaway", "/", "https://top.test"]])
		#expect(request.cookies.first == cookie)

		let key = #"{"domain":".a.test","name":"__Host-id","path":"/","topFrameSiteKey":"https://top.test","hasCrossSiteAncestor":true,"sourceScheme":2,"sourcePort":8443}"#
		fixture.reply(request, status: ARX_CREDENTIAL_IMPORT_OK, json: #"{"accepted":[\#(key)],"existing":[],"rejected":[]}"#)
		#expect(try await task.value == .init(accepted: [Self.key], existing: [], rejected: []))
	}

	@Test
	internal func checkAndUndoSendKeysAsJSON() async throws {
		let fixture = CredentialImportFixture()
		let check = Task { try await fixture.credentials.checkCookies(profileKey: "", keys: [Self.key]) }
		let checkRequest = await fixture.nextRequest()
		#expect(checkRequest.kind == .check)
		let sent = try JSONDecoder().decode([ChromiumCookieKey].self, from: Data(checkRequest.keys!.utf8))
		#expect(sent == [Self.key])
		fixture.reply(checkRequest, status: ARX_CREDENTIAL_IMPORT_OK, json: #"{"present":[]}"#)
		#expect(try await check.value.isEmpty)

		let password: ChromiumPasswordKey = .init(signonRealm: "https://a.test/", username: "ann", dateCreated: "1")
		let undo = Task { try await fixture.credentials.undo(profileKey: "", passwords: [password], cookies: [Self.key]) }
		let undoRequest = await fixture.nextRequest()
		#expect(undoRequest.kind == .undo)
		struct Keys: Decodable, Equatable {
			var passwords: [ChromiumPasswordKey]
			var cookies: [ChromiumCookieKey]
		}
		#expect(try JSONDecoder().decode(Keys.self, from: Data(undoRequest.keys!.utf8)) == .init(passwords: [password], cookies: [Self.key]))
		fixture.reply(undoRequest, status: ARX_CREDENTIAL_IMPORT_OK, json: #"{"removed":2}"#)
		#expect(try await undo.value == 2)
	}

	@Test(arguments: [
		(ARX_CREDENTIAL_IMPORT_INVALID, #"{"reason":"count"}"#, ChromiumCredentialImportFailure.invalid(reason: "count")),
		(ARX_CREDENTIAL_IMPORT_BUSY, #"{"reason":"profile"}"#, .busy),
		(ARX_CREDENTIAL_IMPORT_FAILED, #"{"reason":"timeout"}"#, .failed(reason: "timeout")),
		(ARX_CREDENTIAL_IMPORT_UNAVAILABLE, #"{"reason":"profile"}"#, .unavailable),
	])
	internal func failuresMapFromNativeStatuses(
		status: ArxCredentialImportStatus,
		json: String,
		failure: ChromiumCredentialImportFailure
	) async throws {
		let fixture = CredentialImportFixture()
		let task = Task { try await fixture.credentials.checkCookies(profileKey: "", keys: []) }
		fixture.reply(await fixture.nextRequest(), status: status, json: json)
		await #expect(throws: failure) { try await task.value }
	}

	@Test
	internal func valuesWithANULAreNeverCutShort() async throws {
		let fixture = CredentialImportFixture()
		let truncated: ChromiumImportedPassword = .init(
			url: "https://c.test/",
			signonRealm: "https://c.test/",
			username: "cy",
			password: "abc\u{0}def"
		)
		let passwords = Task { try await fixture.credentials.importPasswords(profileKey: "", records: [truncated, Self.password]) }
		let passwordRequest = await fixture.nextRequest()

		// Only the representable row reaches native; the other is reported skipped.
		#expect(passwordRequest.strings.map { $0[2] } == ["ann"])
		fixture.reply(passwordRequest, status: ARX_CREDENTIAL_IMPORT_OK, json: #"{"imported":[],"conflicts":0,"skipped":0}"#)
		#expect(try await passwords.value.skipped == 1)

		let cookie: ChromiumImportedCookie = .init(
			domain: "a.test", name: "id", value: "abc\u{0}def", path: "/", topFrameSiteKey: "",
			creationUTC: 1, expiresUTC: 2, lastAccessUTC: 1, isSecure: false, isHTTPOnly: false,
			hasCrossSiteAncestor: true, sameSite: -1, priority: 1, sourceScheme: 1, sourcePort: 80
		)
		let cookies = Task { try await fixture.credentials.importCookies(profileKey: "", cookies: [cookie]) }
		let cookieRequest = await fixture.nextRequest()
		#expect(cookieRequest.cookies.isEmpty)
		fixture.reply(cookieRequest, status: ARX_CREDENTIAL_IMPORT_OK, json: #"{"accepted":[],"existing":[],"rejected":[]}"#)
		#expect(try await cookies.value.rejected == [.init(
			domain: "a.test",
			name: "id",
			path: "/",
			topFrameSiteKey: "",
			hasCrossSiteAncestor: false,
			sourceScheme: 1,
			sourcePort: 80
		)])
	}

	@Test
	internal func unconfirmedKeysReachTheCaller() async throws {
		let fixture = CredentialImportFixture()
		let task = Task { try await fixture.credentials.importPasswords(profileKey: "", records: [Self.password]) }
		let request = await fixture.nextRequest()
		fixture.reply(request, status: ARX_CREDENTIAL_IMPORT_OK, json: #"""
		{"imported":[],"unconfirmed":[{"signonRealm":"https://a.test/","username":"ann","dateCreated":"9"}],"conflicts":0,"skipped":1}
		"""#)
		let result = try await task.value
		#expect(result.imported.isEmpty)
		#expect(result.unconfirmed == [.init(signonRealm: "https://a.test/", username: "ann", dateCreated: "9")])
	}

	@Test
	internal func aCancelledImportStillWaitsForNativesReply() async throws {
		let fixture = CredentialImportFixture()
		let task = Task { try await fixture.credentials.importPasswords(profileKey: "", records: [Self.password]) }
		let request = await fixture.nextRequest()
		task.cancel()
		for _ in 0..<20 { await Task.yield() }

		// Only the reply names what was written, so cancelling doesn't drop it.
		fixture.reply(request, status: ARX_CREDENTIAL_IMPORT_OK, json: #"""
		{"imported":[{"signonRealm":"https://a.test/","username":"ann","dateCreated":"9"}],"unconfirmed":[],"conflicts":0,"skipped":0}
		"""#)
		#expect(try await task.value.imported.count == 1)
	}

	@Test
	internal func overlongFieldsStayOnTheSwiftSide() async throws {
		let fixture = CredentialImportFixture()
		var long = Self.password
		long.username = String(repeating: "u", count: ChromiumCredentialImport.maximumFieldBytes + 1)
		let task = Task { try await fixture.credentials.importPasswords(profileKey: "", records: [long, Self.password]) }
		let request = await fixture.nextRequest()
		#expect(request.strings.map { $0[2] } == ["ann"])
		fixture.reply(request, status: ARX_CREDENTIAL_IMPORT_OK, json: #"{"imported":[],"conflicts":0,"skipped":0}"#)
		#expect(try await task.value.skipped == 1)
	}

	@Test
	internal func oversizedCallsNeverReachNative() async throws {
		let fixture = CredentialImportFixture()
		let records = Array(repeating: Self.password, count: ChromiumCredentialImport.maximumPasswords + 1)
		await #expect(throws: ChromiumCredentialImportFailure.invalid(reason: "count")) {
			try await fixture.credentials.importPasswords(profileKey: "", records: records)
		}
		#expect(CredentialImportFixture.pending.isEmpty)
	}

	@Test
	internal func cancellationAndStopEndPendingRequests() async throws {
		let fixture = CredentialImportFixture()
		let cancelled = Task { try await fixture.credentials.checkCookies(profileKey: "", keys: []) }
		let first = await fixture.nextRequest()
		cancelled.cancel()
		await #expect(throws: (any Error).self) { try await cancelled.value }

		// Native's late reply is dropped.
		fixture.reply(first, status: ARX_CREDENTIAL_IMPORT_OK, json: #"{"present":[]}"#)

		let stopped = Task { try await fixture.credentials.checkCookies(profileKey: "", keys: []) }
		_ = await fixture.nextRequest()
		fixture.credentials.stop()
		await #expect(throws: ChromiumCredentialImportFailure.unavailable) { try await stopped.value }
	}

	@Test
	internal func descriptionsNeverShowValues() {
		#expect(!String(describing: Self.password).contains("throwaway"))
		#expect(!String(reflecting: Self.password).contains("throwaway"))
		let cookie: ChromiumImportedCookie = .init(
			domain: "a.test", name: "id", value: "throwaway", path: "/", topFrameSiteKey: "",
			creationUTC: 0, expiresUTC: 0, lastAccessUTC: 0, isSecure: false, isHTTPOnly: false,
			hasCrossSiteAncestor: false, sameSite: -1, priority: 1, sourceScheme: 0, sourcePort: -1
		)
		#expect(!String(describing: cookie).contains("throwaway"))
	}

	@Test
	internal func arenasLendEveryStringNULTerminated() {
		let arena = Arena(strings: ["", "a", "pässwörd", "z"])
		#expect(arena.count == 4)
		arena.withPointers { pointers in
			#expect(pointers.map { String(cString: $0) } == ["", "a", "pässwörd", "z"])
		}
	}

	private static let password: ChromiumImportedPassword = .init(
		url: "https://a.test/",
		signonRealm: "https://a.test/",
		username: "ann",
		password: "throwaway"
	)

	private static let key: ChromiumCookieKey = .init(
		domain: ".a.test",
		name: "__Host-id",
		path: "/",
		topFrameSiteKey: "https://top.test",
		hasCrossSiteAncestor: true,
		sourceScheme: 2,
		sourcePort: 8443
	)
}

@MainActor
private struct CredentialImportFixture {
	fileprivate enum Kind: Equatable {
		case passwords
		case cookies
		case check
		case undo
	}

	fileprivate struct Request {
		fileprivate var id: UInt64
		fileprivate var kind: Kind
		fileprivate var profileKey: String

		/// Each record's strings, copied while native held them.
		fileprivate var strings: [[String]] = []
		fileprivate var cookies: [ChromiumImportedCookie] = []
		fileprivate var keys: String? = nil
	}

	fileprivate static var pending: [Request] = []
	fileprivate let credentials: ChromiumCredentialImport

	fileprivate init() {
		Self.pending = []
		var api = ArxEngineAPI()
		api.import_password_records = { request, key, records, count in
			let rows = UnsafeBufferPointer(start: records, count: count).map {
				[$0.url, $0.signon_realm, $0.username, $0.password].map { String(cString: $0!) }
			}
			MainActor.assumeIsolated {
				CredentialImportFixture.pending.append(.init(
					id: request,
					kind: .passwords,
					profileKey: String(cString: key!),
					strings: rows
				))
			}
		}
		api.import_cookies = { request, key, cookies, count in
			let natives = Array(UnsafeBufferPointer(start: cookies, count: count))
			let strings = natives.map {
				[$0.domain, $0.name, $0.value, $0.path, $0.top_frame_site_key].map { String(cString: $0!) }
			}
			let records = zip(natives, strings).map { native, strings in
				ChromiumImportedCookie(
					domain: strings[0],
					name: strings[1],
					value: strings[2],
					path: strings[3],
					topFrameSiteKey: strings[4],
					creationUTC: native.creation_utc,
					expiresUTC: native.expires_utc,
					lastAccessUTC: native.last_access_utc,
					isSecure: native.secure,
					isHTTPOnly: native.http_only,
					hasCrossSiteAncestor: native.has_cross_site_ancestor,
					sameSite: native.same_site,
					priority: native.priority,
					sourceScheme: native.source_scheme,
					sourcePort: native.source_port
				)
			}
			MainActor.assumeIsolated {
				CredentialImportFixture.pending.append(.init(
					id: request,
					kind: .cookies,
					profileKey: String(cString: key!),
					strings: strings,
					cookies: records
				))
			}
		}
		api.check_cookies = { request, key, keys in
			MainActor.assumeIsolated {
				CredentialImportFixture.pending.append(.init(
					id: request,
					kind: .check,
					profileKey: String(cString: key!),
					keys: keys.map { String(cString: $0) }
				))
			}
		}
		api.undo_credential_import = { request, key, keys in
			MainActor.assumeIsolated {
				CredentialImportFixture.pending.append(.init(
					id: request,
					kind: .undo,
					profileKey: String(cString: key!),
					keys: keys.map { String(cString: $0) }
				))
			}
		}
		self.credentials = .init(api: api)
	}

	fileprivate func nextRequest() async -> Request {
		while Self.pending.isEmpty { await Task.yield() }
		return Self.pending.removeFirst()
	}

	fileprivate func reply(
		_ request: Request,
		status: ArxCredentialImportStatus,
		json: String
	) {
		let bytes = Array(json.utf8)
		bytes.withUnsafeBufferPointer { buffer in
			credentials.complete(request.id, status: status, json: buffer.baseAddress, count: buffer.count)
		}
	}
}
