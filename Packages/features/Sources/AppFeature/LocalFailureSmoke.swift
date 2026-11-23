#if DEBUG
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import ViewerItemFeature
import _ComposableArchitecture

/// Runs only with `ARX_LOCAL_FAILURE_SMOKE` and a disposable `ARX_ENGINE_PROFILE`.
/// The launch URL is a loopback port nothing listens on; `ARX_LOCAL_FAILURE_TLS_URL`
/// names a loopback HTTPS server with an untrusted certificate, and `ARX_LOCAL_FAILURE_PLAIN_URL`
/// is an `https` URL for a loopback server that speaks plain HTTP and serves `ARX_LOCAL_FAILURE_PLAIN_TITLE`.
/// `ARX_LOCAL_FAILURE_UNRESOLVED_URL` is a name that never resolves (DEV-1226): the engine commits its
/// own error page, and Arx's generic card doesn't show on top of it.
internal enum LocalFailureSmoke {
	internal enum Failure: String, Error {
		case missingConfiguration
		case missingPage
		case notRefused
		case notCertificate
		case notPlainHTTP
		case plainHTTPNotOpened
		case cardOverEngineErrorPage
		case timedOut
	}

	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		environment: [String: String]
	) async throws {
		guard
			let refusedURL = environment["ARX_ENGINE_URL"].flatMap(URL.init(string:)),
			let refusedPort = refusedURL.port,
			let certificateURL = environment["ARX_LOCAL_FAILURE_TLS_URL"].flatMap(URL.init(string:)),
			let plainURL = environment["ARX_LOCAL_FAILURE_PLAIN_URL"].flatMap(URL.init(string:)),
			let plainHTTPURL = BrowserNavigation.Failure.plainHTTPURL(for: plainURL),
			let plainTitle = environment["ARX_LOCAL_FAILURE_PLAIN_TITLE"],
			let unresolvedURL = environment["ARX_LOCAL_FAILURE_UNRESOLVED_URL"].flatMap(URL.init(string:))
		else { throw Failure.missingConfiguration }

		try await wait { isSettledFailure(store) }
		guard let tab = store.main.viewer.item.tab else { throw Failure.missingPage }
		try check(store, .localServerUnreachable(port: refusedPort), or: .notRefused)
		print("ARX_LOCAL_FAILURE_PHASE_REFUSED")

		try await engine.client.command(tab.id, .navigate(certificateURL))
		try await wait { isSettledFailure(store) && store.main.viewer.item.navigation.url?.port == certificateURL.port }
		try check(store, .localCertificateRejected, or: .notCertificate)
		print("ARX_LOCAL_FAILURE_PHASE_CERTIFICATE")

		try await engine.client.command(tab.id, .navigate(plainURL))
		try await wait { isSettledFailure(store) && store.main.viewer.item.navigation.url?.port == plainURL.port }
		try check(store, .localServerExpectsHTTP(httpURL: plainHTTPURL), or: .notPlainHTTP)
		print("ARX_LOCAL_FAILURE_PHASE_PLAIN_HTTP")

		store.send(.main(.viewer(.item(.ui(.openPlainHTTP)))))
		do {
			try await wait {
				let navigation = store.main.viewer.item.navigation
				return !navigation.isLoading
					&& navigation.errorCode == nil
					&& navigation.url == plainHTTPURL
					&& navigation.title == plainTitle
			}
		} catch Failure.timedOut {
			throw Failure.plainHTTPNotOpened
		}
		print("ARX_LOCAL_FAILURE_PHASE_PLAIN_HTTP_OPENED")

		// DEV-1226: the engine commits its own error page for a name that never resolves, with its
		// own Reload button; Arx's card mustn't repeat it.
		try await engine.client.command(tab.id, .navigate(unresolvedURL))
		try await wait {
			isSettledFailure(store) && store.main.viewer.item.navigation.url?.host() == unresolvedURL.host()
		}
		let item = store.main.viewer.item
		print(
			"ARX_LOCAL_FAILURE_OBSERVED code=\(item.navigation.errorCode.map(String.init) ?? "none") "
			+ "document=\(item.navigation.document) engineErrorDocument=\(item.engineErrorDocument)"
		)
		guard
			item.failure == nil,
			item.engineErrorDocument != 0,
			item.engineErrorDocument == item.navigation.document
		else { throw Failure.cardOverEngineErrorPage }
		print("ARX_LOCAL_FAILURE_PHASE_ENGINE_ERROR_PAGE")
		print("ARX_LOCAL_FAILURE_SMOKE_SUCCESS")
	}

	@MainActor
	private static func isSettledFailure(_ store: StoreOf<AppFeature>) -> Bool {
		let item = store.main.viewer.item
		return !item.navigation.isLoading && item.navigation.errorCode != nil
	}

	@MainActor
	private static func check(
		_ store: StoreOf<AppFeature>,
		_ expected: BrowserNavigation.Failure,
		or failure: Failure
	) throws {
		let item = store.main.viewer.item
		let code = item.navigation.errorCode.map(String.init) ?? "none"
		print("ARX_LOCAL_FAILURE_OBSERVED code=\(code) url=\(item.navigation.url?.absoluteString ?? "none")")
		guard
			item.navigation.failure == expected,
			item.failure == ViewerItemFeature.message(for: expected)
		else { throw failure }
	}

	@MainActor
	private static func wait(_ condition: @MainActor () -> Bool) async throws {
		let end = ContinuousClock.now.advanced(by: .seconds(30))
		while !condition() {
			guard ContinuousClock.now < end else { throw Failure.timedOut }
			try await Task.sleep(for: .milliseconds(100))
		}
	}
}
#endif
