import BrowserCore
import Foundation

/// The requests and answers of a claim, without the network or any window, so tests cover them.
public enum MemberNumberRequests {
	// MARK: Arx's server

	/// `POST /v1/accounts` with exactly `{"provider", "idToken"}`, and `memberSince` when given
	/// (DEV-1323): the `yyyy-MM-dd` day Arx was installed on this Mac. The server refuses
	/// anything more.
	public static func accounts(
		base: URL = ArxService.backend,
		provider: MemberSignInProvider,
		idToken: String,
		memberSince: String? = nil
	) -> URLRequest {
		var request: URLRequest = .init(url: base.appending(path: "v1/accounts"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.timeoutInterval = 30
		var body: [String: String] = ["provider": provider.rawValue, "idToken": idToken]
		if let memberSince { body["memberSince"] = memberSince }
		request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
		return request
	}

	/// The number from the server's answer: `201` the first time, `200` after.
	public static func memberNumber(
		data: Data,
		response: URLResponse,
		provider: MemberSignInProvider
	) throws(MemberNumberClient.Failure) -> MemberNumber {
		guard
			let http = response as? HTTPURLResponse,
			http.statusCode == 200 || http.statusCode == 201
		else { throw .refused }

		struct Answer: Decodable {
			var idx: Int
			var registeredOn: String
			/// Missing from a server before DEV-1323.
			var memberSince: String?
		}

		guard
			let answer = try? JSONDecoder().decode(Answer.self, from: data),
			answer.idx > 0
		else { throw .refused }

		var number: MemberNumber = .init(
			index: answer.idx,
			registeredOn: answer.registeredOn,
			provider: provider,
			memberSince: answer.memberSince
		)
		guard number.registrationDate != nil else { throw .refused }
		// Only shown, so a day that isn't one is dropped rather than refusing the number.
		if number.memberSinceDate == nil { number.memberSince = nil }
		return number
	}

	/// Claims the number: sends the token with this Mac's install day and reads the answer. A
	/// server from before DEV-1323 refuses the extra field with `400`, so then it sends once more
	/// without it, the same token to the same server, and the card keeps this Mac's own date.
	public static func claim(
		base: URL,
		provider: MemberSignInProvider,
		idToken: String,
		memberSince: String?,
		send: (URLRequest) async throws -> (Data, URLResponse)
	) async throws(MemberNumberClient.Failure) -> MemberNumber {
		var memberSince: String? = memberSince
		while true {
			let data: Data
			let response: URLResponse
			do {
				(data, response) = try await send(accounts(base: base, provider: provider, idToken: idToken, memberSince: memberSince))
			} catch {
				throw failure(error)
			}
			if memberSince != nil, (response as? HTTPURLResponse)?.statusCode == 400 {
				memberSince = nil
				continue
			}
			return try memberNumber(data: data, response: response, provider: provider)
		}
	}

	/// A network error as the card words it: anything that kept the request from an answer
	/// is "no connection".
	public static func failure(_ error: any Error) -> MemberNumberClient.Failure {
		if let failure = error as? MemberNumberClient.Failure { return failure }
		if let error = error as? URLError, error.code == .cancelled { return .cancelled }
		return .offline
	}

	// MARK: Apple

	/// Apple's web sign-in (DEV-1313) with a Services ID as the client: `code id_token`, posted
	/// to Arx's server, which hands it to `callbackScheme`. No scope: no name, no email.
	///
	/// The native sheet needs an entitlement Apple gives only to App Store apps, and Arx ships
	/// with Developer ID, so Apple signs in on the web.
	public struct Apple: Equatable, Sendable {
		/// The Services ID, grouped in the portal with the primary App ID `dev.capturecontext.arx`.
		public var servicesID: String

		/// Arx's server's callback, the Services ID's return URL. Apple posts its answer there.
		public var redirectURI: URL

		public init?(
			servicesID: String?,
			base: URL = ArxService.backend
		) {
			guard
				let servicesID = servicesID?.trimmingCharacters(in: .whitespaces),
				servicesID.contains("."),
				servicesID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
			else { return nil }

			self.servicesID = servicesID
			self.redirectURI = base.appending(path: "v1/apple/callback")
		}

		/// The scheme Arx's server redirects to with Apple's answer. The server's is the same
		/// constant (`APP_CALLBACK_SCHEME` in `arx-browser-backend`'s `src/apple.ts`).
		public static let callbackScheme: String = "dev.capturecontext.arx.auth"

		public func authorizationURL(
			state: String,
			nonce: String
		) -> URL {
			var components: URLComponents = .init(string: "https://appleid.apple.com/auth/authorize")!
			components.queryItems = [
				.init(name: "client_id", value: servicesID),
				.init(name: "redirect_uri", value: redirectURI.absoluteString),
				// Apple doesn't accept `id_token` alone. The code is never swapped, so Arx needs
				// no client secret; the server drops it.
				.init(name: "response_type", value: "code id_token"),
				.init(name: "response_mode", value: "form_post"),
				.init(name: "state", value: state),
				.init(name: "nonce", value: nonce),
			]
			return components.url!
		}

		/// The ID token from the server's hand-off, after checking the state and the token's nonce.
		public func idToken(
			from callback: URL,
			state: String,
			nonce: String
		) throws(MemberNumberClient.Failure) -> String {
			let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
			let value = { (name: String) in items.first { $0.name == name }?.value }
			guard
				callback.scheme == Self.callbackScheme,
				callback.path == "/apple"
			else { throw .signInFailed }

			if let error = value("error") {
				throw error == "cancelled" ? .cancelled : .signInFailed
			}
			guard
				value("state") == state,
				let token = value("id_token"),
				Self.nonce(in: token) == nonce
			else { throw .signInFailed }

			return token
		}

		/// The `nonce` claim of an ID token, unverified: Arx's server verifies the token's
		/// signature, and this only ties the token to this sign-in.
		public static func nonce(in token: String) -> String? {
			let segments = token.split(separator: ".", omittingEmptySubsequences: false)
			guard segments.count == 3 else { return nil }

			var payload = segments[1]
				.replacingOccurrences(of: "-", with: "+")
				.replacingOccurrences(of: "_", with: "/")
			payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
			guard
				let data = Data(base64Encoded: payload),
				let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
			else { return nil }

			return claims["nonce"] as? String
		}
	}

	// MARK: Random values

	/// 48 random bytes, base64url (64 characters): a PKCE verifier, a state or a nonce.
	public static func randomValue() -> String {
		var generator: SystemRandomNumberGenerator = .init()
		let bytes: [UInt8] = (0..<48).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
		return base64URL(Data(bytes))
	}

	fileprivate static func base64URL(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	// MARK: Storage

	/// The UserDefaults key that keeps this Mac's number.
	public static let storageKey: String = "MemberNumber"

	public static func load(from defaults: UserDefaults) -> MemberNumber? {
		defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(MemberNumber.self, from: $0) }
	}

	public static func save(
		_ number: MemberNumber?,
		to defaults: UserDefaults
	) {
		guard let number, let data = try? JSONEncoder().encode(number) else {
			defaults.removeObject(forKey: storageKey)
			return
		}
		defaults.set(data, forKey: storageKey)
	}
}
