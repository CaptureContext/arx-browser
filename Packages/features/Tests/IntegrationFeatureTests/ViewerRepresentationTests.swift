import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import ViewerFeature
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct ViewerRepresentationTests {
	@Test
	internal func representingTheSameTabInTheSamePaneObservesTheNewestGeneration() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		let restored = BrowserNavigation(url: tab.restoration.url, title: tab.restoration.title)
		let subscriptions = Subscriptions()
		let initialState = ViewerFeature.State(item: .init(tab: tab, navigation: restored))
		let store = TestStore(initialState: initialState) {
			ViewerFeature()
		} withDependencies: {
			$0.browserEngine.events = { _ in subscriptions.subscribe() }
			$0.browserEngine.open = { _ in }
		}

		await store.send(.resume)
		await store.receive(\.panes) {
			$0.item.generation = 1
			$0.item.isObserving = true
			$0.observationGeneration = 1
		}
		try await subscriptions.wait(count: 1)

		// The second presentation of the same tab replaces the first observation.
		await store.send(.resume)
		await store.receive(\.panes) {
			$0.item.generation = 2
			$0.observationGeneration = 2
		}
		try await subscriptions.wait(count: 2)
		try await subscriptions.waitUntilTerminated(0)

		let loaded = BrowserNavigation(
			url: URL(string: "https://capturecontext.dev/loaded"),
			title: "Loaded",
			canGoBack: true
		)
		subscriptions.yield(loaded, to: 1)
		await store.receive(\.panes) {
			$0.item.navigation = loaded
		}
		await store.receive(\.panes)

		await store.send(.suspend)
		await store.receive(\.panes) {
			$0.item.generation = 3
			$0.item.isObserving = false
			$0.observationGeneration = 3
		}
		await store.finish()
	}

	/// Back-to-back presentations race to register their observation effects off the main
	/// actor. The newest generation must receive navigation whichever effect registers first,
	/// and the superseded observation must not outlive its first stale event.
	@Test
	internal func backToBackPresentationsNeverLoseTheCurrentObservation() async throws {
		let tab = IntegrationFeatureTests().fixture().tabs[0]
		let loaded = BrowserNavigation(
			url: URL(string: "https://capturecontext.dev/loaded"),
			title: "Loaded",
			canGoBack: true
		)
		var lost = 0
		var leaked = 0

		for _ in 0..<200 {
			let subscriptions = Subscriptions(initial: loaded)
			let store = Store(initialState: ViewerItemFeature.State()) {
				ViewerItemFeature()
			} withDependencies: {
				$0.browserEngine.events = { _ in subscriptions.subscribe() }
				$0.browserEngine.open = { _ in }
			}
			store.send(.show(tab))
			store.send(.show(tab))

			if !(await eventually { store.navigation == loaded && store.generation == 2 }) { lost += 1 }
			if !(await eventually { subscriptions.count == 2 && subscriptions.live == 1 }) { leaked += 1 }
			store.send(.suspend)
		}

		#expect(lost == 0)
		#expect(leaked == 0)
	}

	private func eventually(_ condition: () -> Bool) async -> Bool {
		// Until a deadline rather than a fixed number of polls, which a busy Mac used up first.
		try? await waitWhile { !condition() }
		return condition()
	}
}

/// Mirrors the engine: every subscription receives the current page snapshot, if any.
private final class Subscriptions: Sendable {
	private let state: LockIsolated<(
		continuations: [AsyncStream<BrowserNavigation>.Continuation],
		terminated: Set<Int>
	)> = .init(([], []))

	private let initial: BrowserNavigation?

	init(initial: BrowserNavigation? = nil) {
		self.initial = initial
	}

	var count: Int { state.value.continuations.count }

	var live: Int { state.value.continuations.count - state.value.terminated.count }

	func subscribe() -> AsyncStream<BrowserNavigation> {
		let (stream, continuation) = AsyncStream<BrowserNavigation>.makeStream(
			bufferingPolicy: .bufferingNewest(1)
		)
		let index = state.withValue { state in
			state.continuations.append(continuation)
			return state.continuations.count - 1
		}
		continuation.onTermination = { [state] _ in
			state.withValue { _ = $0.terminated.insert(index) }
		}
		if let initial { continuation.yield(initial) }
		return stream
	}

	func yield(_ navigation: BrowserNavigation, to index: Int) {
		state.value.continuations[index].yield(navigation)
	}

	func wait(count: Int) async throws {
		for _ in 0..<1_000 where self.count < count {
			try await Task.sleep(for: .milliseconds(1))
		}
		try #require(self.count == count)
	}

	func waitUntilTerminated(_ index: Int) async throws {
		for _ in 0..<1_000 where !state.value.terminated.contains(index) {
			try await Task.sleep(for: .milliseconds(1))
		}
		try #require(state.value.terminated.contains(index))
	}
}
