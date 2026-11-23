import BrowserCore
import CustomDump
import Foundation
import Testing
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

/// DEV-1226: when the engine commits its own error page for a failed navigation ("This site can't
/// be reached", with its own Reload button), Arx's generic "This page could not load" card doesn't
/// show on top of it. It still shows when the failure leaves the tab blank or the page before it
/// showing, and for a stopped renderer.
@Suite(.dependencies)
@MainActor
internal struct EngineErrorPageTests {
	private static let failed = URL(string: "https://unreachable.example/")!
	private static let before = URL(string: "https://capturecontext.dev/")!

	private static func loaded(document: UInt64) -> BrowserNavigation {
		.init(url: before, title: "CaptureContext", history: [.init(id: 1, url: before, title: "", isCurrent: true)], document: document)
	}

	private static func errorPage(
		code: Int,
		document: UInt64,
		title: String = ""
	) -> BrowserNavigation {
		.init(
			url: failed,
			title: title,
			errorCode: code,
			canGoBack: true,
			history: [
				.init(id: 1, url: before, title: "", isCurrent: false),
				.init(id: 2, url: failed, title: "", isCurrent: true),
			],
			document: document
		)
	}

	private func store() throws -> TestStoreOf<ViewerItemFeature> {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		return TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 1)) {
			ViewerItemFeature()
		}
	}

	/// A DNS failure, a refused connection and no network each commit the engine's error page:
	/// only it shows, through later events on it (its title) too.
	@Test(arguments: [-105, -102, -106])
	internal func aCommittedEngineErrorPageShowsAlone(code: Int) async throws {
		let store = try store()
		store.exhaustivity = .off
		let tab = try #require(store.state.tab)
		await store.send(.event(.navigation(tab.id, 1, Self.loaded(document: 3))))
		await store.send(.event(.navigation(tab.id, 1, Self.errorPage(code: code, document: 4)))) {
			$0.failure = nil
			$0.engineErrorDocument = 4
		}
		await store.send(.event(.navigation(tab.id, 1, Self.errorPage(code: code, document: 4, title: "unreachable.example")))) {
			$0.failure = nil
			$0.engineErrorDocument = 4
		}

		// Loading it again commits another error page.
		await store.send(.event(.navigation(tab.id, 1, Self.errorPage(code: code, document: 5)))) {
			$0.failure = nil
			$0.engineErrorDocument = 5
		}
	}

	/// A failure that commits nothing leaves the page before it showing, or a blank tab: Arx's card
	/// says it failed.
	@Test
	internal func aFailureThatCommitsNothingGetsTheCard() async throws {
		let store = try store()
		store.exhaustivity = .off
		let tab = try #require(store.state.tab)
		await store.send(.event(.navigation(tab.id, 1, Self.loaded(document: 3))))
		var stale = Self.loaded(document: 3)
		stale.url = Self.failed
		stale.errorCode = -105
		await store.send(.event(.navigation(tab.id, 1, stale))) {
			$0.failure = String.localized(.appUI.viewer.navigationFailed(-105))
			$0.engineErrorDocument = 0
		}

		let blank = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 1)) { ViewerItemFeature() }
		blank.exhaustivity = .off
		await blank.send(.event(.navigation(tab.id, 1, .init(url: Self.failed, errorCode: -105, document: 1)))) {
			$0.failure = String.localized(.appUI.viewer.navigationFailed(-105))
		}
	}

	/// A stopped renderer has no error page: its card shows, on the engine's error page too.
	@Test
	internal func aStoppedRendererGetsTheCard() async throws {
		let store = try store()
		store.exhaustivity = .off
		let tab = try #require(store.state.tab)
		await store.send(.event(.navigation(tab.id, 1, Self.loaded(document: 3))))
		await store.send(.event(.navigation(tab.id, 1, Self.errorPage(code: -105, document: 4))))
		await store.send(.event(.navigation(tab.id, 1, Self.errorPage(code: BrowserNavigation.Failure.rendererStoppedCode, document: 4)))) {
			$0.failure = String.localized(.appUI.viewer.rendererFailed)
			$0.engineErrorDocument = 0
		}
	}

	/// The local development explanations name the fix, which the engine's page doesn't: they show
	/// over it.
	@Test
	internal func aLocalDevelopmentExplanationShowsOverTheEnginesErrorPage() async throws {
		let store = try store()
		store.exhaustivity = .off
		let tab = try #require(store.state.tab)
		let local = try #require(URL(string: "http://127.0.0.1:5173/"))
		await store.send(.event(.navigation(tab.id, 1, Self.loaded(document: 3))))
		let refused = BrowserNavigation(
			url: local,
			errorCode: -102,
			history: [.init(id: 2, url: local, title: "", isCurrent: true)],
			document: 4
		)
		await store.send(.event(.navigation(tab.id, 1, refused))) {
			$0.failure = String.localized(.appUI.viewer.localServerUnreachable(5173))
			$0.engineErrorDocument = 4
		}
	}

	/// The same tab shown again keeps its error page's document, so its first event there brings
	/// no card back.
	@Test
	internal func theTabShownAgainKeepsItsEngineErrorPageQuiet() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 1)) {
			ViewerItemFeature()
		} withDependencies: {
			$0.browserEngine.events = { _ in AsyncStream { $0.finish() } }
		}
		store.exhaustivity = .off
		await store.send(.event(.navigation(tab.id, 1, Self.loaded(document: 3))))
		await store.send(.event(.navigation(tab.id, 1, Self.errorPage(code: -105, document: 4))))
		await store.send(.show(tab))
		let generation = store.state.generation
		await store.send(.event(.navigation(tab.id, generation, Self.errorPage(code: -105, document: 4)))) {
			$0.failure = nil
			$0.engineErrorDocument = 4
		}
	}

	/// A tab seen first on its error page, with no document before it: its current history entry
	/// is the failed address, so it's the engine's page.
	@Test
	internal func aTabSeenFirstOnItsErrorPageShowsItAlone() async throws {
		let store = try store()
		store.exhaustivity = .off
		let tab = try #require(store.state.tab)
		await store.send(.event(.navigation(tab.id, 1, Self.errorPage(code: -105, document: 2)))) {
			$0.failure = nil
			$0.engineErrorDocument = 2
		}
	}
}
