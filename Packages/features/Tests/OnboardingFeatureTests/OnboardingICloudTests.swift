import BrowserCore
import Foundation
@testable import OnboardingFeature
import Testing
import WorkspaceSync
import _ComposableArchitecture
import _TestSupport

/// "Sync with iCloud" (DEV-1215) over a fake `WorkspaceSyncClient`: iCloud is never reached.
@Suite(.dependencies)
@MainActor
internal struct OnboardingICloudTests {
	private static let lastUsedSpace: UUID = UUID(42)

	// MARK: - Flow

	@Test
	internal func theStepFollowsWelcomeOnlyWhenOffered() {
		#expect(OnboardingFlow.steps(offersICloud: true) == [.welcome, .iCloud] + OnboardingFlow.steps.dropFirst())
		#expect(!OnboardingFlow.steps(offersICloud: false).contains(.iCloud))
		#expect(!OnboardingFeature.State().steps.contains(.iCloud))
		#expect(OnboardingFeature.State(offersICloud: true).steps.contains(.iCloud))
		// Settings' single steps never hold Default back, so they never list it.
		#expect(!OnboardingFeature.Mode.flow.steps.contains(.iCloud))
	}

	@Test
	internal func withoutAnAccountThePageStepsAside() async {
		let sync: SyncDouble = .init(account: false)
		let store = makeStore(sync)

		await store.send(.page(.iCloud(.ui(.task))))
		await store.receive(\.page.iCloud.event.accountChecked) {
			$0.page = .iCloud(.init(phase: .finished(.unavailable)))
		}
		await store.receive(\.page.iCloud.delegate.resolved, .unavailable) {
			$0.iCloudResolution = .unavailable
			$0.index = 2
			$0.page = .tour(.init())
		}
		await store.receive(\.delegate.iCloudResolved, .unavailable)
		#expect(store.state.completedSteps == [.welcome])
		#expect(sync.joins.value == 0)
	}

	// MARK: - The three outcomes

	@Test
	internal func iCloudsWorkspaceIsAdoptedAndTheImportSaysSo() async throws {
		let sync: SyncDouble = .init(events: [
			.fetching(.organization),
			.fetching(.preferences),
			.finished(.init(hasWorkspace: true, lastUsedSpaceID: Self.lastUsedSpace)),
		])
		let store = makeStore(sync)
		try await ready(store)

		await store.send(.page(.iCloud(.ui(.sync)))) {
			$0.page = .iCloud(.init(phase: .syncing(nil)))
		}
		await store.receive(\.page.iCloud.event.sync) {
			$0.page = .iCloud(.init(phase: .syncing(.organization)))
		}
		await store.receive(\.page.iCloud.event.sync) {
			$0.page = .iCloud(.init(phase: .syncing(.preferences)))
		}
		let adopted: OnboardingICloud.Resolution = .adopted(lastUsedSpaceID: Self.lastUsedSpace)
		await store.receive(\.page.iCloud.event.sync) {
			$0.page = .iCloud(.init(phase: .finished(adopted)))
		}
		await store.receive(\.page.iCloud.delegate.resolved, adopted) {
			$0.iCloudResolution = adopted
			$0.completedSteps = [.welcome, .iCloud]
			$0.index = 2
			$0.page = .tour(.init())
		}
		await store.receive(\.delegate.stepCompleted, .iCloud)
		await store.receive(\.delegate.iCloudResolved, adopted)
		#expect(sync.joins.value == 1)
		#expect(store.state.workspaceCameFromICloud)

		// The import page offers only what iCloud doesn't sync.
		store.exhaustivity = .off
		while store.state.step != .migration {
			await store.send(.ui(.continueSetup))
		}
		let migration = try #require(store.state.page.migration)
		#expect(migration.workspaceCameFromICloud)

		// Back on the step it shows what happened, without asking again.
		await store.send(.ui(.back))
		while store.state.step != .iCloud {
			await store.send(.ui(.back))
		}
		#expect(store.state.page == .iCloud(.init(phase: .finished(adopted))))
		await store.send(.page(.iCloud(.ui(.task))))
		#expect(sync.accountChecks.value == 1)
	}

	@Test
	internal func anEmptyICloudKeepsDefaultAsTheStarter() async throws {
		let sync: SyncDouble = .init(events: [
			.fetching(.organization),
			.finished(.init(hasWorkspace: false)),
		])
		let store = makeStore(sync)
		store.exhaustivity = .off
		try await ready(store)

		await store.send(.page(.iCloud(.ui(.sync))))
		await store.receive(\.delegate.iCloudResolved, .empty)
		#expect(store.state.completedSteps == [.welcome, .iCloud])
		#expect(store.state.step == .tour)
		#expect(!store.state.workspaceCameFromICloud)
	}

	@Test
	internal func aSlowFetchOffersContinueWithoutWaiting() async throws {
		let clock: TestClock<Duration> = .init()
		let sync: SyncDouble = .init(events: [.fetching(.organization)], staysOpen: true)
		let store = makeStore(sync) { $0.continuousClock = clock }
		try await ready(store)

		await store.send(.page(.iCloud(.ui(.sync)))) {
			$0.page = .iCloud(.init(phase: .syncing(nil)))
		}
		await store.receive(\.page.iCloud.event.sync) {
			$0.page = .iCloud(.init(phase: .syncing(.organization)))
		}

		// Nothing to press before it's slow.
		await store.send(.page(.iCloud(.ui(.continueWithoutWaiting))))
		await store.send(.page(.iCloud(.ui(.notNow))))

		await clock.advance(by: OnboardingICloud.patience)
		await store.receive(\.page.iCloud.event.becameSlow) {
			$0.page = .iCloud(.init(phase: .syncing(.organization), isSlow: true))
		}

		await store.send(.page(.iCloud(.ui(.continueWithoutWaiting)))) {
			$0.page = .iCloud(.init(phase: .finished(.continuedWithoutWaiting)))
		}
		await store.receive(\.page.iCloud.delegate.resolved, .continuedWithoutWaiting) {
			$0.iCloudResolution = .continuedWithoutWaiting
			$0.completedSteps = [.welcome, .iCloud]
			$0.index = 2
			$0.page = .tour(.init())
		}
		await store.receive(\.delegate.stepCompleted, .iCloud)
		await store.receive(\.delegate.iCloudResolved, .continuedWithoutWaiting)

		// Onboarding stopped waiting; the fetch it started was cancelled with the page.
		await store.finish()
		#expect(sync.cancellations.value == 1)
	}

	@Test
	internal func offlineOffersTryAgainAndContinueWithoutWaiting() async throws {
		let sync: SyncDouble = .init(events: [.unavailable])
		let store = makeStore(sync)
		try await ready(store)

		await store.send(.page(.iCloud(.ui(.sync)))) {
			$0.page = .iCloud(.init(phase: .syncing(nil)))
		}
		await store.receive(\.page.iCloud.event.sync, .unavailable) {
			$0.page = .iCloud(.init(phase: .failed(nil)))
		}
		#expect(store.state.page.iCloud?.offersContinueWithoutWaiting == true)

		// Try again runs the join again.
		sync.events = [.failed("The network connection was lost.")]
		await store.send(.page(.iCloud(.ui(.sync)))) {
			$0.page = .iCloud(.init(phase: .syncing(nil)))
		}
		await store.receive(\.page.iCloud.event.sync) {
			$0.page = .iCloud(.init(phase: .failed("The network connection was lost.")))
		}
		#expect(sync.joins.value == 2)

		store.exhaustivity = .off
		await store.send(.page(.iCloud(.ui(.continueWithoutWaiting))))
		await store.receive(\.delegate.iCloudResolved, .continuedWithoutWaiting)
		#expect(store.state.step == .tour)
	}

	@Test
	internal func aJoinStartedBeforeARelaunchResumesInsteadOfAskingAgain() async throws {
		// Sync with iCloud turned sync on, then Arx quit before the fetch ended.
		let sync: SyncDouble = .init(syncIsOn: true, events: [.finished(.init(hasWorkspace: false))])
		let store = makeStore(sync)
		store.exhaustivity = .off

		await store.send(.page(.iCloud(.ui(.task))))
		await store.receive(\.page.iCloud.event.accountChecked) {
			$0.page = .iCloud(.init(phase: .syncing(nil)))
		}
		await store.receive(\.delegate.iCloudResolved, .empty)
		#expect(sync.joins.value == 1)
	}

	// MARK: - Not now

	@Test
	internal func notNowMovesOnWithoutFinishingTheStep() async throws {
		let sync: SyncDouble = .init()
		let store = makeStore(sync)
		try await ready(store)

		await store.send(.page(.iCloud(.ui(.notNow)))) {
			$0.page = .iCloud(.init(phase: .finished(.notNow)))
		}
		await store.receive(\.page.iCloud.delegate.resolved, .notNow) {
			$0.iCloudResolution = .notNow
			$0.index = 2
			$0.page = .tour(.init())
		}
		await store.receive(\.delegate.iCloudResolved, .notNow)
		#expect(store.state.completedSteps == [.welcome])
		#expect(sync.joins.value == 0)
	}

	@Test
	internal func leavingTheUndecidedPageIsNotNow() async throws {
		let sync: SyncDouble = .init()
		let store = makeStore(sync)
		try await ready(store)

		await store.send(.ui(.back)) {
			$0.iCloudResolution = .notNow
			$0.index = 0
			$0.direction = .backward
			$0.page = .welcome(.init())
		}
		await store.receive(\.delegate.iCloudResolved, .notNow)
		#expect(store.state.completedSteps == [.welcome])
	}

	@Test
	internal func leavingWhileSyncingGoesOnWithoutWaiting() async throws {
		let sync: SyncDouble = .init(events: [.fetching(.organization)], staysOpen: true)
		let store = makeStore(sync) { $0.continuousClock = TestClock<Duration>() }
		store.exhaustivity = .off
		try await ready(store)

		await store.send(.page(.iCloud(.ui(.sync))))
		await store.receive(\.page.iCloud.event.sync)
		await store.send(.ui(.skip))
		await store.receive(\.delegate.iCloudResolved, .continuedWithoutWaiting)
		#expect(store.state.completedSteps == [.welcome, .iCloud])
		await store.finish()
		#expect(sync.cancellations.value == 1)
	}

	// MARK: - Helpers

	/// The flow after the welcome page, on "Sync with iCloud".
	private func makeStore(
		_ sync: SyncDouble,
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> TestStoreOf<OnboardingFeature> {
		TestStore(initialState: OnboardingFeature.State(completedSteps: [.welcome], offersICloud: true)) {
			OnboardingFeature()
		} withDependencies: {
			$0.workspaceSync = sync.client

			// Never advanced unless a test says so: the fetch is never slow by itself.
			$0.continuousClock = TestClock<Duration>()
			dependencies(&$0)
		}
	}

	/// Appears, and finds an account.
	private func ready(_ store: TestStoreOf<OnboardingFeature>) async throws {
		#expect(store.state.step == .iCloud)
		#expect(store.state.page == .iCloud(.init()))
		await store.send(.page(.iCloud(.ui(.task))))
		await store.receive(\.page.iCloud.event.accountChecked) {
			$0.page = .iCloud(.init(phase: .ready))
		}
	}
}

/// A `WorkspaceSyncClient` whose onboarding join plays back `events`.
private final class SyncDouble: @unchecked Sendable {
	let account: Bool

	/// Sync is on already, as after a relaunch partway through the step's join.
	let syncIsOn: Bool
	var events: [OnboardingSyncEvent]

	/// The join stream stays open after `events`, as a fetch still running.
	let staysOpen: Bool
	let joins: LockIsolated<Int> = .init(0)
	let accountChecks: LockIsolated<Int> = .init(0)
	let cancellations: LockIsolated<Int> = .init(0)

	init(
		account: Bool = true,
		syncIsOn: Bool = false,
		events: [OnboardingSyncEvent] = [],
		staysOpen: Bool = false
	) {
		self.account = account
		self.syncIsOn = syncIsOn
		self.events = events
		self.staysOpen = staysOpen
	}

	var client: WorkspaceSyncClient {
		var client: WorkspaceSyncClient = .unavailable
		client.isAvailable = { true }
		client.statusUpdates = { [syncIsOn] in
			AsyncStream { continuation in
				continuation.yield(WorkspaceSyncStatus(isEnabled: syncIsOn))
				continuation.finish()
			}
		}
		client.accountIsAvailable = { [self] in
			accountChecks.withValue { $0 += 1 }
			return account
		}
		client.joinFromOnboarding = { [self] turningSyncOn in

			// The page always turns sync on; only AppFeature's background wait doesn't.
			#expect(turningSyncOn)
			joins.withValue { $0 += 1 }
			let events: [OnboardingSyncEvent] = events
			let staysOpen: Bool = staysOpen
			return AsyncStream { continuation in
				for event in events {
					continuation.yield(event)
				}
				continuation.onTermination = { [self] termination in
					if case .cancelled = termination {
						cancellations.withValue { $0 += 1 }
					}
				}
				if !staysOpen {
					continuation.finish()
				}
			}
		}
		return client
	}
}
