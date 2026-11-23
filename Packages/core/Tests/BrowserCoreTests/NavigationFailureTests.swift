import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct NavigationFailureTests {
	private typealias Failure = BrowserNavigation.Failure

	@Test(arguments: [
		"localhost", "LocalHost", "localhost.", "app.localhost", "a.b.localhost",
		"127.0.0.1", "127.255.255.254", "127.1.2.3", "::1", "[::1]", "0:0:0:0:0:0:0:1", "0000::0001",
	])
	internal func loopbackHostsAreRecognized(host: String) {
		#expect(Failure.isLoopback(host: host))
	}

	@Test(arguments: [
		"", "capturecontext.dev", "localhost.capturecontext.dev", "notlocalhost", "mylocalhost",
		"128.0.0.1", "126.0.0.1", "10.0.0.1", "192.168.1.10", "0.0.0.0", "127.0.0", "127.0.0.1.5",
		"127.0.0.256", "127.0.0.-1", "::", "::2", "fe80::1", "::ffff:127.0.0.1", "[2001:db8::1]",
	])
	internal func otherHostsAreNotLoopback(host: String) {
		#expect(!Failure.isLoopback(host: host))
	}

	@Test
	internal func localDevelopmentPortUsesExplicitOrSchemeDefaultPort() throws {
		func port(_ string: String) throws -> Int? {
			Failure.localDevelopmentPort(of: try #require(URL(string: string)))
		}
		expectNoDifference(try port("http://localhost:3000/app"), 3000)
		expectNoDifference(try port("http://127.0.0.1"), 80)
		expectNoDifference(try port("https://api.localhost"), 443)
		expectNoDifference(try port("https://[::1]:8443/"), 8443)
		expectNoDifference(try port("file:///localhost"), nil)
		expectNoDifference(try port("ws://localhost:3000"), nil)
		expectNoDifference(try port("https://capturecontext.dev:3000"), nil)
	}

	@Test
	internal func loopbackConnectionRefusedNamesThePort() throws {
		expectNoDifference(
			Failure(errorCode: -102, url: URL(string: "http://127.0.0.1:5173/")),
			.localServerUnreachable(port: 5173)
		)
		expectNoDifference(
			Failure(errorCode: -102, url: URL(string: "http://[::1]:8080")),
			.localServerUnreachable(port: 8080)
		)
		expectNoDifference(
			Failure(errorCode: -102, url: URL(string: "http://web.localhost")),
			.localServerUnreachable(port: 80)
		)
	}

	@Test(arguments: [-200, -201, -202, -207, -213, -219])
	internal func loopbackCertificateErrorsExplainTrust(code: Int) {
		expectNoDifference(
			Failure(errorCode: code, url: URL(string: "https://localhost:8443")),
			.localCertificateRejected
		)
	}

	@Test
	internal func loopbackSSLProtocolErrorSuggestsPlainHTTP() throws {
		expectNoDifference(
			Failure(errorCode: -107, url: URL(string: "https://localhost:3000/app?q=1#top")),
			.localServerExpectsHTTP(httpURL: try #require(URL(string: "http://localhost:3000/app?q=1#top")))
		)
		expectNoDifference(
			Failure(errorCode: -107, url: URL(string: "https://[::1]:5173/")),
			.localServerExpectsHTTP(httpURL: try #require(URL(string: "http://[::1]:5173/")))
		)
		expectNoDifference(
			Failure(errorCode: -107, url: URL(string: "https://127.0.0.1/")),
			.localServerExpectsHTTP(httpURL: try #require(URL(string: "http://127.0.0.1:443/")))
		)
		expectNoDifference(
			Failure(errorCode: -107, url: URL(string: "https://app.localhost:8080")),
			.localServerExpectsHTTP(httpURL: try #require(URL(string: "http://app.localhost:8080")))
		)
	}

	@Test
	internal func sslProtocolErrorStaysGenericOffLoopbackHTTPS() {
		expectNoDifference(Failure(errorCode: -107, url: URL(string: "https://capturecontext.dev:3000/")), .other(-107))
		expectNoDifference(Failure(errorCode: -107, url: URL(string: "https://192.168.1.10:3000/")), .other(-107))
		expectNoDifference(Failure(errorCode: -107, url: URL(string: "http://localhost:3000/")), .other(-107))
		expectNoDifference(Failure(errorCode: -107, url: nil), .other(-107))
		expectNoDifference(Failure(errorCode: -113, url: URL(string: "https://localhost:3000/")), .other(-113))
		expectNoDifference(Failure(errorCode: -106, url: URL(string: "https://localhost:3000/")), .other(-106))
	}

	@Test
	internal func plainHTTPURLKeepsTheEffectivePortPathAndQuery() throws {
		func plain(_ string: String) throws -> URL? {
			Failure.plainHTTPURL(for: try #require(URL(string: string)))
		}
		expectNoDifference(try plain("https://localhost:3000/a/b?x=1&y=2"), URL(string: "http://localhost:3000/a/b?x=1&y=2"))
		expectNoDifference(try plain("HTTPS://LocalHost:8443"), URL(string: "http://LocalHost:8443"))
		expectNoDifference(try plain("https://127.0.0.1"), URL(string: "http://127.0.0.1:443"))
		expectNoDifference(try plain("http://localhost:3000"), nil)
		expectNoDifference(try plain("https://capturecontext.dev:3000"), nil)
		expectNoDifference(try plain("wss://localhost:3000"), nil)
	}

	@Test
	internal func otherFailuresStayGeneric() {
		let local = URL(string: "https://localhost:8443")
		expectNoDifference(Failure(errorCode: -105, url: local), .other(-105))
		expectNoDifference(Failure(errorCode: -107, url: URL(string: "http://localhost:3000")), .other(-107))
		expectNoDifference(Failure(errorCode: -199, url: local), .other(-199))
		expectNoDifference(Failure(errorCode: -220, url: local), .other(-220))
		expectNoDifference(Failure(errorCode: -102, url: URL(string: "https://capturecontext.dev")), .other(-102))
		expectNoDifference(Failure(errorCode: -202, url: URL(string: "https://capturecontext.dev")), .other(-202))
		expectNoDifference(Failure(errorCode: -102, url: URL(string: "http://192.168.1.10:3000")), .other(-102))
		expectNoDifference(Failure(errorCode: -102, url: nil), .other(-102))
		expectNoDifference(Failure(errorCode: -10000, url: local), .rendererStopped)
	}

	@Test
	internal func navigationExposesItsClassifiedFailure() {
		#expect(BrowserNavigation(url: URL(string: "http://localhost:3000")).failure == nil)
		expectNoDifference(
			BrowserNavigation(url: URL(string: "http://localhost:3000"), errorCode: -102).failure,
			.localServerUnreachable(port: 3000)
		)
	}

	/// DEV-1226: a failed navigation that committed a new main-frame document is the engine's own
	/// error page: DNS failures (-105), refused connections (-102) and no network (-106) alike.
	@Test(arguments: [-105, -102, -106])
	internal func aFailureThatCommittedADocumentIsTheEnginesErrorPage(code: Int) throws {
		let url = try #require(URL(string: "https://unreachable.example/"))
		let failed = BrowserNavigation(
			url: url,
			errorCode: code,
			history: [.init(id: 4, url: url, title: "", isCurrent: true)],
			document: 8
		)
		#expect(failed.committedErrorPage(after: 7))
		// The same failure with no new document committed nothing: the tab is blank, or the page
		// before it still shows.
		#expect(!failed.committedErrorPage(after: 8))
	}

	/// DEV-1226: a stopped renderer has no error page, nor does an engine that doesn't count
	/// documents, nor a navigation that succeeded.
	@Test
	internal func aStoppedRendererOrAnUncountedPageHasNoEngineErrorPage() throws {
		let url = try #require(URL(string: "https://capturecontext.dev/"))
		let stopped = BrowserNavigation(url: url, errorCode: Failure.rendererStoppedCode, document: 8)
		#expect(!stopped.committedErrorPage(after: 7))
		let uncounted = BrowserNavigation(url: url, errorCode: -105, document: 0)
		#expect(!uncounted.committedErrorPage(after: 7))
		let loaded = BrowserNavigation(url: url, document: 8)
		#expect(!loaded.committedErrorPage(after: 7))
	}

	/// DEV-1226: seeing the tab for the first time, with no document before it, its error page is
	/// committed when its current history entry is the failed address; the page before it, or none,
	/// isn't.
	@Test
	internal func aTabSeenFirstWithAFailureReadsItsCurrentEntry() throws {
		let url = try #require(URL(string: "https://unreachable.example/"))
		let before = try #require(URL(string: "https://capturecontext.dev/"))
		let committed = BrowserNavigation(
			url: url,
			errorCode: -105,
			history: [.init(id: 1, url: before, title: "", isCurrent: false), .init(id: 2, url: url, title: "", isCurrent: true)],
			document: 2
		)
		#expect(committed.committedErrorPage(after: 0))
		let stale = BrowserNavigation(
			url: url,
			errorCode: -105,
			history: [.init(id: 1, url: before, title: "", isCurrent: true)],
			document: 1
		)
		#expect(!stale.committedErrorPage(after: 0))
		let blank = BrowserNavigation(url: url, errorCode: -105, document: 1)
		#expect(!blank.committedErrorPage(after: 0))
	}

	/// DEV-1226: only the generic card repeats the engine's error page.
	@Test
	internal func onlyTheGenericFailureRepeatsTheEnginesErrorPage() throws {
		let http = try #require(URL(string: "http://localhost:3000/"))
		#expect(!Failure.other(-105).addsToEngineErrorPage)
		#expect(Failure.rendererStopped.addsToEngineErrorPage)
		#expect(Failure.localServerUnreachable(port: 3000).addsToEngineErrorPage)
		#expect(Failure.localCertificateRejected.addsToEngineErrorPage)
		#expect(Failure.localServerExpectsHTTP(httpURL: http).addsToEngineErrorPage)
	}
}
