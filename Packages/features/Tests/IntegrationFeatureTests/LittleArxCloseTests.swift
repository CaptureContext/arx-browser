import BrowserCore
import ConcurrencyExtras
import Foundation
import LittleArxFeature
import Testing
import _ComposableArchitecture

/// Closing a Little Arx window asks its page first (DEV-855). A close that crosses the window
/// showing its tab again, as one does just after it opens, still closes it (DEV-965).
@MainActor
@Suite(.dependencies)
internal struct LittleArxCloseTests {
	@Test
	func aCloseThatCrossesTheTabShowingAgainAsksAgainAndCloses() async throws {
		let tab: BrowserCore.Tab = .init(
			id: .init(rawValue: UUID()),
			profileID: .init(rawValue: UUID()),
			restoration: .init(title: "Torn off", url: URL(string: "https://arx.example/")!)
		)
		let asked = LockIsolated(0)
		let (answers, answer) = AsyncStream<Bool>.makeStream()
		let store = TestStore(
			initialState: LittleArxFeature.State(id: UUID(), spaceID: .init(rawValue: UUID()), tab: tab)
		) {
			LittleArxFeature()
		} withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.permitsClosing = { _ in
				asked.withValue { $0 += 1 }
				var iterator = answers.makeAsyncIterator()
				return await iterator.next() ?? false
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.close))
		#expect(store.state.isClosing)
		let first = try #require(store.state.closeRequest)

		// The window moves on while its page is asked.
		await store.send(.viewer(.suspend))
		#expect(store.state.viewer.generation != first.generation)

		answer.yield(true)
		await store.receive(\.event.closeDecision)

		// Still closing, with a new request for what the window shows now.
		#expect(store.state.isClosing)
		let second = try #require(store.state.closeRequest)
		#expect(second != first)

		answer.yield(true)
		await store.receive(\.event.closeDecision)
		await store.receive(\.delegate.closeApproved)
		#expect(asked.value == 2)
		answer.finish()
		await store.skipInFlightEffects(strict: false)
	}

	@Test
	func aPageThatKeepsItOpenStaysOpen() async throws {
		let tab: BrowserCore.Tab = .init(
			id: .init(rawValue: UUID()),
			profileID: .init(rawValue: UUID()),
			restoration: .init(title: "Unsaved form", url: URL(string: "https://arx.example/")!)
		)
		let store = TestStore(
			initialState: LittleArxFeature.State(id: UUID(), spaceID: .init(rawValue: UUID()), tab: tab)
		) {
			LittleArxFeature()
		} withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.permitsClosing = { _ in false }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.close))
		await store.receive(\.event.closeDecision)
		#expect(!store.state.isClosing)
		#expect(store.state.closeRequest == nil)
	}
}
