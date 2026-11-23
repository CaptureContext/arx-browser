import BrowserCore
import CustomDump
import Foundation
import Testing
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct ViewerRetryTests {
	/// A page that moved on in its tab and then lost its renderer reloads where it was,
	/// not at the URL the tab was shown with or at a pinned tab's saved destination.
	@Test
	internal func retryReopensTheFailedPageNotTheShownURL() async throws {
		var tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		tab.savedDestination = .init(title: "Pinned", url: try #require(URL(string: "https://capturecontext.dev/pinned")))
		let current = try #require(URL(string: "http://localhost:8000/live.html"))
		let initial = ViewerItemFeature.State(
			tab: tab,
			navigation: .init(url: current, title: "Live", errorCode: BrowserNavigation.Failure.rendererStoppedCode),
			failure: "Renderer stopped",
			generation: 5
		)
		let events = LockIsolated<[String]>([])
		let store = TestStore(initialState: initial) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.close = { id in
				expectNoDifference(id, tab.id)
				events.withValue { $0.append("close") }
			}
			$0.browserEngine.open = { opened in
				expectNoDifference(opened.id, tab.id)
				events.withValue { $0.append("open \(opened.reopeningURL.absoluteString)") }
			}
			$0.browserEngine.events = { _ in AsyncStream { $0.finish() } }
		}

		await store.send(.ui(.retry))
		await store.receive(\.show) {
			$0.navigation = .init(url: tab.restoration.url, title: tab.restoration.title)
			$0.failure = nil
			$0.generation = 6
			$0.isObserving = true
		}
		await store.finish()
		expectNoDifference(events.value.prefix(2), ["close", "open \(current.absoluteString)"])
	}

	/// Without a usable URL the tab reopens as it was shown.
	@Test
	internal func retryWithoutAPageURLReopensTheShownTab() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let initial = ViewerItemFeature.State(
			tab: tab,
			navigation: .init(url: URL(string: "about:blank"), title: ""),
			generation: 5
		)
		let opened = LockIsolated<[URL]>([])
		let store = TestStore(initialState: initial) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.close = { _ in }
			$0.browserEngine.open = { tab in opened.withValue { $0.append(tab.reopeningURL) } }
			$0.browserEngine.events = { _ in AsyncStream { $0.finish() } }
		}

		await store.send(.ui(.retry))
		await store.receive(\.show) {
			$0.navigation = .init(url: tab.restoration.url, title: tab.restoration.title)
			$0.generation = 6
			$0.isObserving = true
		}
		await store.finish()
		expectNoDifference(opened.value.first, tab.restoration.url)
	}
}
