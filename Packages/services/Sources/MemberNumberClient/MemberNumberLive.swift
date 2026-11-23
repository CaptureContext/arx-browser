import BrowserCore
import Foundation
import OSLog

extension MemberNumberClient {
	/// Info.plist's Services ID for Apple's web sign-in (`ARX_APPLE_SERVICES_ID` in
	/// `.xcodegen/macOS.yml`), empty until one exists.
	public static let appleServicesIDInfoKey: String = "ArxAppleServicesID"

	/// Apple in a private Little Arx window (`window`, DEV-1323), Arx's server through
	/// `URLSession`, and the number in `defaults`. Apple is the only sign-in: Google's was removed.
	public static func live(
		defaults: UserDefaults = .standard,
		session: URLSession = .shared,
		base: URL = ArxService.backendURL(),
		bundle: Bundle = .main,
		window: MemberSignInWindow = .liveValue
	) -> Self {
		let apple: MemberNumberRequests.Apple? = .init(
			servicesID: bundle.object(forInfoDictionaryKey: appleServicesIDInfoKey) as? String,
			base: base
		)

		// UserDefaults is thread-safe; the SDK doesn't mark it Sendable.
		nonisolated(unsafe) let defaults: UserDefaults = defaults

		return .init(
			availableProviders: {
				apple == nil ? [] : [.apple]
			},
			signIn: { provider throws(Failure) in
				switch provider {
				case .apple:
					guard let apple else { throw .unavailable }
					let state = MemberNumberRequests.randomValue()
					let nonce = MemberNumberRequests.randomValue()
					let callback: URL
					do throws(Failure) {
						callback = try await window.callback(
							from: apple.authorizationURL(state: state, nonce: nonce),
							scheme: MemberNumberRequests.Apple.callbackScheme
						)
					} catch {
						log.notice("Sign-in window ended without an answer: \(String(describing: error), privacy: .public)")
						throw error
					}
					// Names only: the values are tokens.
					let names: [String] = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
					log.notice("Sign-in window returned \(callback.path(), privacy: .public) with \(names.joined(separator: ","), privacy: .public)")
					return try apple.idToken(from: callback, state: state, nonce: nonce)
				}
			},
			claim: { provider, idToken, memberSince throws(Failure) in
				try await MemberNumberRequests.claim(
					base: base,
					provider: provider,
					idToken: idToken,
					memberSince: memberSince,
					send: { try await session.data(for: $0) }
				)
			},
			load: { MemberNumberRequests.load(from: defaults) },
			save: { MemberNumberRequests.save($0, to: defaults) }
		)
	}
}

private let log: Logger = .init(subsystem: "dev.capturecontext.arx", category: "member-sign-in")
