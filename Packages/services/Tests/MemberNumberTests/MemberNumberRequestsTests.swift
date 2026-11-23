import BrowserCore
import Foundation
import MemberNumberClient
import Testing
import _TestSupport

internal struct MemberNumberRequestsTests {
	private let base: URL = .init(string: "https://api.example.test")!

	// MARK: - Arx's server

	@Test
	internal func theRequestSendsOnlyTheProviderAndTheToken() throws {
		let request = MemberNumberRequests.accounts(base: base, provider: .apple, idToken: "token")

		#expect(request.url?.absoluteString == "https://api.example.test/v1/accounts")
		#expect(request.httpMethod == "POST")
		#expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
		let body = try #require(request.httpBody)
		let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
		#expect(object == ["provider": "apple", "idToken": "token"])
	}

	@Test
	internal func theRequestAddsOnlyTheInstallDayWhenThereIsOne() throws {
		let request = MemberNumberRequests.accounts(base: base, provider: .apple, idToken: "token", memberSince: "2026-11-11")
		let body = try #require(request.httpBody)
		let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
		#expect(object == ["provider": "apple", "idToken": "token", "memberSince": "2026-11-11"])
	}

	@Test
	internal func theAccountsDayComesBackWithTheNumber() throws {
		let number = try MemberNumberRequests.memberNumber(
			data: Data(#"{"idx":42,"registeredOn":"2026-11-18","memberSince":"2026-11-02"}"#.utf8),
			response: response(200),
			provider: .apple
		)
		#expect(number == .init(index: 42, registeredOn: "2026-11-18", provider: .apple, memberSince: "2026-11-02"))

		// A day that isn't one is dropped; the number still counts.
		let odd = try MemberNumberRequests.memberNumber(
			data: Data(#"{"idx":42,"registeredOn":"2026-11-18","memberSince":"soon"}"#.utf8),
			response: response(200),
			provider: .apple
		)
		#expect(odd == .init(index: 42, registeredOn: "2026-11-18", provider: .apple))
	}

	@Test
	internal func aNewServerAnswersTheFirstRequest() async throws {
		let sent: LockIsolated<[[String: String]]> = .init([])
		let number = try await MemberNumberRequests.claim(base: base, provider: .apple, idToken: "token", memberSince: "2026-11-11") { request in
			sent.withValue { $0.append(Self.body(request)) }
			return (Data(#"{"idx":42,"registeredOn":"2026-11-18","memberSince":"2026-11-02"}"#.utf8), self.response(200))
		}
		#expect(number.memberSince == "2026-11-02")
		#expect(sent.value == [["provider": "apple", "idToken": "token", "memberSince": "2026-11-11"]])
	}

	@Test
	internal func aServerFromBeforeTheDayGetsTheRequestAgainWithoutIt() async throws {
		let sent: LockIsolated<[[String: String]]> = .init([])
		let number = try await MemberNumberRequests.claim(base: base, provider: .apple, idToken: "token", memberSince: "2026-11-11") { request in
			let body = Self.body(request)
			sent.withValue { $0.append(body) }
			// The old server: exactly provider and idToken, or 400.
			guard body["memberSince"] == nil else {
				return (Data(#"{"ok":false,"message":"Expected {\"provider\", \"idToken\"}"}"#.utf8), self.response(400))
			}
			return (Data(#"{"idx":42,"registeredOn":"2026-11-18"}"#.utf8), self.response(200))
		}
		#expect(number == .init(index: 42, registeredOn: "2026-11-18", provider: .apple))
		#expect(sent.value.map { $0["memberSince"] } == ["2026-11-11", nil])
	}

	@Test
	internal func aRefusalWithoutTheDayIsNotRetried() async {
		let sent: LockIsolated<Int> = .init(0)
		await #expect(throws: MemberNumberClient.Failure.refused) {
			try await MemberNumberRequests.claim(base: base, provider: .apple, idToken: "token", memberSince: nil) { _ in
				sent.withValue { $0 += 1 }
				return (Data(), self.response(400))
			}
		}
		#expect(sent.value == 1)
	}

	private static func body(_ request: URLRequest) -> [String: String] {
		request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
	}

	@Test(arguments: [200, 201])
	internal func aNumberComesBackOnSuccess(status: Int) throws {
		let number = try MemberNumberRequests.memberNumber(
			data: Data(#"{"idx":42,"registeredOn":"2026-11-18"}"#.utf8),
			response: response(status),
			provider: .apple
		)

		#expect(number == .init(index: 42, registeredOn: "2026-11-18", provider: .apple))
	}

	@Test(arguments: [400, 401, 429, 503])
	internal func anyOtherAnswerIsRefused(status: Int) {
		#expect(throws: MemberNumberClient.Failure.refused) {
			try MemberNumberRequests.memberNumber(
				data: Data(#"{"ok":false,"message":"Token has expired"}"#.utf8),
				response: response(status),
				provider: .apple
			)
		}
	}

	@Test
	internal func aMalformedAnswerIsRefused() {
		#expect(throws: MemberNumberClient.Failure.refused) {
			try MemberNumberRequests.memberNumber(
				data: Data(#"{"idx":42,"registeredOn":"yesterday"}"#.utf8),
				response: response(200),
				provider: .apple
			)
		}
	}

	@Test
	internal func networkErrorsReadAsNoConnection() {
		#expect(MemberNumberRequests.failure(URLError(.notConnectedToInternet)) == .offline)
		#expect(MemberNumberRequests.failure(URLError(.timedOut)) == .offline)
		#expect(MemberNumberRequests.failure(URLError(.cannotFindHost)) == .offline)
		#expect(MemberNumberRequests.failure(URLError(.cancelled)) == .cancelled)
	}

	// MARK: - Google, removed (DEV-1323)

	@Test
	internal func aSavedGoogleNumberReadsAsNone() throws {
		let suite = "MemberNumberRequestsTests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.set(Data(#"{"idx":42,"registeredOn":"2026-11-18","provider":"google"}"#.utf8), forKey: MemberNumberRequests.storageKey)

		#expect(MemberNumberRequests.load(from: defaults) == nil)
		#expect(MemberSignInProvider.allCases == [.apple])
	}

	// MARK: - Apple

	private let servicesID: String = "dev.capturecontext.arx.auth"
	private let state: String = MemberNumberRequests.randomValue()
	private let nonce: String = MemberNumberRequests.randomValue()

	@Test
	internal func appleNeedsAServicesID() {
		#expect(MemberNumberRequests.Apple(servicesID: nil) == nil)
		#expect(MemberNumberRequests.Apple(servicesID: "") == nil)
		// An Info.plist value whose build setting was never set.
		#expect(MemberNumberRequests.Apple(servicesID: "$(ARX_APPLE_SERVICES_ID)") == nil)
		#expect(MemberNumberRequests.Apple(servicesID: "no-dots") == nil)

		let apple = MemberNumberRequests.Apple(servicesID: " dev.capturecontext.arx.auth ")
		#expect(apple?.servicesID == servicesID)
		#expect(apple?.redirectURI.absoluteString == "https://api.arxbrowser.net/v1/apple/callback")
		#expect(MemberNumberRequests.Apple.callbackScheme == "dev.capturecontext.arx.auth")
	}

	@Test
	internal func appleIsAskedForAnIDTokenWithNoScopeThroughArxsCallback() throws {
		let apple = try #require(MemberNumberRequests.Apple(servicesID: servicesID))
		let url = apple.authorizationURL(state: state, nonce: nonce)
		let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
		let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

		#expect(url.scheme == "https")
		#expect(url.host == "appleid.apple.com")
		#expect(url.path == "/auth/authorize")
		#expect(query == [
			"client_id": servicesID,
			"redirect_uri": "https://api.arxbrowser.net/v1/apple/callback",
			"response_type": "code id_token",
			"response_mode": "form_post",
			"state": state,
			"nonce": nonce,
		])
		#expect(query["scope"] == nil)
	}

	@Test
	internal func appleAnswersThroughTheBackendTheAppPointsAt() throws {
		let apple = try #require(MemberNumberRequests.Apple(servicesID: servicesID, base: base))
		#expect(apple.redirectURI.absoluteString == "https://api.example.test/v1/apple/callback")
	}

	@Test
	internal func appleHandsOnTheTokenOnlyWithThisSignInsStateAndNonce() throws {
		let apple = try #require(MemberNumberRequests.Apple(servicesID: servicesID))
		let token = idToken(claims: ["aud": servicesID, "sub": "someone", "nonce": nonce])

		#expect(try apple.idToken(from: handOff(["id_token": token, "state": state]), state: state, nonce: nonce) == token)

		let refused: [(String, URL)] = [
			("another state", handOff(["id_token": token, "state": MemberNumberRequests.randomValue()])),
			("no state", handOff(["id_token": token])),
			("no token", handOff(["state": state])),
			("another sign-in's nonce", handOff(["id_token": idToken(claims: ["nonce": MemberNumberRequests.randomValue()]), "state": state])),
			("no nonce", handOff(["id_token": idToken(claims: ["sub": "someone"]), "state": state])),
			("not a token", handOff(["id_token": "not-a-token", "state": state])),
			("another scheme", handOff(["id_token": token, "state": state], scheme: "arx")),
			("another path", handOff(["id_token": token, "state": state], path: "/google")),
			("Apple's error", handOff(["error": "failed", "state": state])),
		]
		for (reason, url) in refused {
			#expect(throws: MemberNumberClient.Failure.signInFailed, "\(reason)") {
				try apple.idToken(from: url, state: state, nonce: nonce)
			}
		}
	}

	@Test
	internal func cancellingApplesSignInSendsNothing() throws {
		let apple = try #require(MemberNumberRequests.Apple(servicesID: servicesID))
		#expect(throws: MemberNumberClient.Failure.cancelled) {
			try apple.idToken(from: handOff(["error": "cancelled", "state": state]), state: state, nonce: nonce)
		}
	}

	@Test
	internal func theNonceIsReadFromTheTokensPayload() {
		// A payload whose base64url needs padding and uses "-" and "_".
		#expect(MemberNumberRequests.Apple.nonce(in: idToken(claims: ["nonce": "a?b>c~"])) == "a?b>c~")
		#expect(MemberNumberRequests.Apple.nonce(in: "a.b") == nil)
		#expect(MemberNumberRequests.Apple.nonce(in: "a.%%%.c") == nil)
	}

	/// The server's hand-off, `dev.capturecontext.arx.auth:/apple?…`.
	private func handOff(
		_ items: [String: String],
		scheme: String = MemberNumberRequests.Apple.callbackScheme,
		path: String = "/apple"
	) -> URL {
		var components: URLComponents = .init()
		components.scheme = scheme
		components.path = path
		components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
		return components.url!
	}

	/// An unsigned stand-in for Apple's ID token: the app reads only its nonce.
	private func idToken(claims: [String: String]) -> String {
		let segment = { (object: [String: String]) in
			(try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
				.base64EncodedString()
				.replacingOccurrences(of: "+", with: "-")
				.replacingOccurrences(of: "/", with: "_")
				.replacingOccurrences(of: "=", with: "")
		}
		return segment(["alg": "RS256", "kid": "key"]) + "." + segment(claims) + ".signature"
	}

	// MARK: - Storage

	@Test
	internal func aSavedNumberIsThereForTheNextLaunch() throws {
		let suite = "MemberNumberTests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let number: MemberNumber = .init(index: 42, registeredOn: "2026-11-18", provider: .apple)

		MemberNumberClient.live(defaults: defaults).save(number)

		// A new client on the same defaults, as after a relaunch.
		#expect(MemberNumberClient.live(defaults: defaults).load() == number)

		MemberNumberClient.live(defaults: defaults).save(nil)
		#expect(MemberNumberClient.live(defaults: defaults).load() == nil)
	}

	// MARK: - The server's day

	@Test
	internal func onlyARealDayIsAccepted() {
		#expect(MemberNumber(index: 42, registeredOn: "2026-11-18", provider: .apple).registrationDate != nil)
		#expect(MemberNumber(index: 1, registeredOn: "2026-02-30", provider: .apple).registrationDate == nil)
	}

	private func response(_ status: Int) -> HTTPURLResponse {
		HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: nil)!
	}
}
