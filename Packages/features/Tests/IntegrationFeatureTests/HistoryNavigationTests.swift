import BrowserCore
import CustomDump
import Foundation
import Testing
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct HistoryNavigationTests {
	@Test
	internal func selectionNavigatesDirectlyOnceAgainstTheNativeRevision() async throws {
		let initial = try fixture()
		let id = try #require(initial.tab?.id)
		let invocations = LockIsolated<[Int]>([])
		let store = TestStore(initialState: initial) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.snapshot = { requestedID in
				expectNoDifference(requestedID, id)
				return .init(navigation: initial.navigation, revision: 81)
			}
			$0.browserEngine.commandAuthorized = { requestedID, revision, command, authorize in
				expectNoDifference(requestedID, id)
				expectNoDifference(revision, 81)
				#expect(authorize())
				expectNoDifference(command, .historyEntry(0))
				invocations.withValue { $0.append(0) }
			}
		}
		await store.send(.ui(.selectHistory(tabID: id, generation: initial.generation, history: initial.navigation.history, entryID: 0))) {
			$0.historySelection = 1
		}
		await store.receive(\.event.historySelectionStarted)
		await store.finish()
		expectNoDifference(invocations.value, [0])
	}

	/// A newer selection cancels an older one that is already running, in reducer order.
	@Test
	internal func newerSelectionCancelsARunningSelection() async throws {
		let initial = try fixture()
		let id = try #require(initial.tab?.id)
		let calls = LockIsolated(0)
		let invocations = LockIsolated<[Int]>([])
		let store = TestStore(initialState: initial) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in .init(navigation: initial.navigation, revision: 81) }
			$0.browserEngine.commandAuthorized = { _, _, command, authorize in

				// Hold the first selection inside the engine until the second one cancels it.
				let isFirst = calls.withValue { count in
					count += 1
					return count == 1
				}

				// Only cancellation ends this wait early; the test fails long before it times out.
				if isFirst { try? await Task.sleep(for: .seconds(60)) }
				guard authorize(), case let .historyEntry(entryID) = command else { return }
				invocations.withValue { $0.append(entryID) }
			}
		}
		await store.send(.ui(.selectHistory(tabID: id, generation: initial.generation, history: initial.navigation.history, entryID: 0))) {
			$0.historySelection = 1
		}
		await store.receive(\.event.historySelectionStarted)
		await store.send(.ui(.selectHistory(tabID: id, generation: initial.generation, history: initial.navigation.history, entryID: 1))) {
			$0.historySelection = 2
		}
		await store.receive(\.event.historySelectionStarted)
		await store.finish()
		expectNoDifference(invocations.value, [1])
	}

	/// Back-to-back selections race to register their effects off the main actor. Only the
	/// newest selection may navigate, whichever effect registers first.
	@Test
	internal func backToBackSelectionsNavigateOnlyToTheNewestEntry() async throws {
		let initial = try fixture()
		let id = try #require(initial.tab?.id)
		var inverted = 0

		for _ in 0..<200 {
			let invocations = LockIsolated<[Int]>([])
			let store = Store(initialState: initial) { ViewerItemFeature() } withDependencies: {
				$0.browserEngine.snapshot = { _ in .init(navigation: initial.navigation, revision: 81) }
				$0.browserEngine.commandAuthorized = { _, _, command, authorize in
					guard authorize(), case let .historyEntry(entryID) = command else { return }
					invocations.withValue { $0.append(entryID) }
				}
			}
			let older = store.send(.ui(.selectHistory(
				tabID: id,
				generation: initial.generation,
				history: initial.navigation.history,
				entryID: 0
			)))
			let newer = store.send(.ui(.selectHistory(
				tabID: id,
				generation: initial.generation,
				history: initial.navigation.history,
				entryID: 1
			)))
			await older.finish()
			await newer.finish()

			if invocations.value != [1] { inverted += 1 }
		}

		#expect(inverted == 0)
	}

	@Test
	internal func rejectsChangedTabGenerationHistoryAndInvalidEntries() async throws {
		let initial = try fixture()
		let id = try #require(initial.tab?.id)
		let store = TestStore(initialState: initial) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in
				Issue.record("Stale UI selection must not reach the engine")
				return nil
			}
		}
		await store.send(.ui(.selectHistory(
			tabID: .init(rawValue: UUID(99)),
			generation: initial.generation,
			history: initial.navigation.history,
			entryID: 0
		)))
		await store.send(.ui(.selectHistory(
			tabID: id,
			generation: initial.generation - 1,
			history: initial.navigation.history,
			entryID: 0
		)))
		await store.send(.ui(.selectHistory(tabID: id, generation: initial.generation, history: [], entryID: 0)))
		for entryID in [2, 99] {
			await store.send(.ui(.selectHistory(
				tabID: id,
				generation: initial.generation,
				history: initial.navigation.history,
				entryID: entryID
			)))
		}
		await store.finish()
	}

	@Test
	internal func nativeHistoryChangeAfterMenuSelectionCancelsWithoutNavigation() async throws {
		let initial = try fixture()
		let id = try #require(initial.tab?.id)
		let store = TestStore(initialState: initial) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 82) }
			$0.browserEngine.commandAuthorized = { _, _, _, _ in Issue.record("Changed history must not navigate") }
		}
		await store.send(.ui(.selectHistory(tabID: id, generation: initial.generation, history: initial.navigation.history, entryID: 0))) {
			$0.historySelection = 1
		}
		await store.receive(\.event.historySelectionStarted)
		await store.finish()
	}

	@Test
	internal func failedNavigationIsReportedButStaleRevisionIsQuiet() async throws {
		let initial = try fixture()
		let id = try #require(initial.tab?.id)
		let stale = LockIsolated(true)
		let store = TestStore(initialState: initial) { ViewerItemFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in .init(navigation: initial.navigation, revision: 81) }
			$0.browserEngine.commandAuthorized = { _, _, _, _ in
				if stale.value { throw AutomationFailure.staleTarget }
				throw HistoryFailure.failed
			}
		}
		await store.send(.ui(.selectHistory(tabID: id, generation: initial.generation, history: initial.navigation.history, entryID: 0))) {
			$0.historySelection = 1
		}
		await store.receive(\.event.historySelectionStarted)
		await store.finish()
		stale.setValue(false)
		await store.send(.ui(.selectHistory(tabID: id, generation: initial.generation, history: initial.navigation.history, entryID: 0))) {
			$0.historySelection = 2
		}
		await store.receive(\.event.historySelectionStarted)
		await store.receive(\.event.failed) { $0.failure = "failed" }
		await store.finish()
	}

	private func fixture() throws -> ViewerItemFeature.State {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		return .init(
			tab: tab,
			navigation: .init(history: try (0..<4).map {
				.init(id: $0, url: try #require(URL(string: "https://capturecontext.dev/\($0)")), title: "Entry \($0)", isCurrent: $0 == 2)
			}),
			generation: 5
		)
	}

	private enum HistoryFailure: Error { case failed }
}
