import BrowserCore
import BrowserPageWaitClient
import CustomDump
import Foundation
import Testing
import _Dependencies
import _TestSupport

@testable import ChromiumBrowserEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumWaitAdapterTests {
	@Test(arguments: [nil, -105, -3] as [Int?])
	internal func alreadyStoppedPreservesErrorWithoutSubscription(error: Int?) async throws {
		let fixture = WaitFixture()
		fixture.snapshot.navigation.isLoading = false
		fixture.snapshot.navigation.errorCode = error
		let result = try await fixture.client.waitAuthorized(fixture.request, fixture.target, { true })
		expectNoDifference(result.snapshot, fixture.snapshot)
		expectNoDifference(result.source, fixture.source)
		expectNoDifference(fixture.subscriptions, 0)
	}

	@Test
	internal func wakesOnEventsButReadsCurrentStateInsteadOfBufferedPayload() async throws {
		let fixture = WaitFixture()
		let client = fixture.client
		let task = Task { try await client.waitAuthorized(fixture.request, fixture.target, { true }) }
		try await fixture.waitForSubscription()
		fixture.snapshot.revision = 5
		fixture.snapshot.navigation.title = "Updated during loading"
		fixture.emit(.init(isLoading: false))
		await Task.yield()
		fixture.snapshot.revision = 6
		fixture.snapshot.navigation.isLoading = false
		fixture.emit(.init(isLoading: true))
		let result = try await task.value
		expectNoDifference(result.snapshot.revision, 6)
		expectNoDifference(result.snapshot.navigation.title, "Updated during loading")
		#expect(!result.snapshot.navigation.isLoading)
		expectNoDifference(fixture.cancellations, 1)
	}

	@Test
	internal func changedOwnerCannotSatisfyWait() async throws {
		let fixture = WaitFixture()
		let task = Task { try await fixture.client.waitAuthorized(fixture.request, fixture.target, { true }) }
		try await fixture.waitForSubscription()
		fixture.current = false
		fixture.snapshot.navigation.isLoading = false
		fixture.emit(.init(isLoading: false))
		await #expect(throws: AutomationFailure.staleTarget) { try await task.value }
		expectNoDifference(fixture.cancellations, 1)
	}

	@Test
	internal func timeoutUsesInjectedDeadlineAndCancelsSubscription() async throws {
		let fixture = WaitFixture()
		let task = Task { try await fixture.client.waitAuthorized(fixture.request, fixture.target, { true }) }
		try await fixture.waitForSubscription()
		await fixture.clock.advance(by: .milliseconds(2000))
		await #expect(throws: AutomationFailure.timedOut) { try await task.value }
		expectNoDifference(fixture.cancellations, 1)
	}

	@Test
	internal func cancellationAndRevocationDiscardLateStoppedEvents() async throws {
		for cancel in [true, false] {
			let fixture = WaitFixture()
			let task = Task { try await fixture.client.waitAuthorized(fixture.request, fixture.target, { fixture.authorized }) }
			try await fixture.waitForSubscription()
			if cancel {
			task.cancel()
		} else {
			fixture.authorized = false
		}
			fixture.snapshot.navigation.isLoading = false
			fixture.emit(.init(isLoading: false))
			do {
				_ = try await task.value
				Issue.record("Stopped observation escaped cancellation or revocation")
			} catch is CancellationError {
				#expect(cancel)
			} catch {
				expectNoDifference(error as? AutomationFailure, .denied)
			}
			expectNoDifference(fixture.cancellations, 1)
		}
	}

	@Test
	internal func pendingObservationBudgetIsReleasedByCancellation() async throws {
		let fixture = WaitFixture()
		let client = fixture.client
		let tasks = (0..<16).map { _ in
			Task { try await client.waitAuthorized(fixture.request, fixture.target, { true }) }
		}
		for _ in 0..<1000 {
			if fixture.subscriptions == 16 { break }
			await Task.yield()
		}
		expectNoDifference(fixture.subscriptions, 16)
		await #expect(throws: AutomationFailure.busy) {
			try await client.waitAuthorized(fixture.request, fixture.target, { true })
		}
		for task in tasks { task.cancel() }
		for task in tasks {
			await #expect(throws: CancellationError.self) { try await task.value }
		}
		expectNoDifference(fixture.cancellations, 16)
		fixture.snapshot.navigation.isLoading = false
		_ = try await client.waitAuthorized(fixture.request, fixture.target, { true })
	}

	@Test
	internal func initialDenialAndStalePublicationNeverSubscribe() async throws {
		let fixture = WaitFixture()
		let client = fixture.client
		await #expect(throws: AutomationFailure.denied) {
			try await client.waitAuthorized(fixture.request, fixture.target, { false })
		}
		fixture.captureFailure = .notReady
		await #expect(throws: AutomationFailure.notReady) {
			try await client.waitAuthorized(fixture.request, fixture.target, { true })
		}
		expectNoDifference(fixture.subscriptions, 0)
	}

	@Test
	internal func closedEventStreamFailsInsteadOfMatchingCachedState() async throws {
		let fixture = WaitFixture()
		let task = Task { try await fixture.client.waitAuthorized(fixture.request, fixture.target, { true }) }
		try await fixture.waitForSubscription()
		fixture.continuation?.finish()
		await #expect(throws: AutomationFailure.staleTarget) { try await task.value }
		expectNoDifference(fixture.cancellations, 1)
	}
}

@MainActor
private final class WaitFixture {
	fileprivate let clock: TestClock<Duration> = .init()
	fileprivate let target: PageWaitTarget = .init(
		tabID: .init(rawValue: UUID(1)),
		profileID: .init(rawValue: UUID(2)),
		sessionRevision: 4,
		documentRevision: 7
	)
	fileprivate var current: Bool = true
	fileprivate var authorized: Bool = true
	fileprivate var captureFailure: AutomationFailure?
	fileprivate var subscriptions: Int = 0
	fileprivate var cancellations: Int = 0
	fileprivate var continuation: AsyncStream<BrowserNavigation>.Continuation?
	fileprivate var snapshot: BrowserSessionSnapshot = .init(
		navigation: .init(url: URL(string: "https://example.test"), title: "Loading", isLoading: true),
		revision: 4,
		documentRevision: 7
	)

	fileprivate var source: PageWaitSource { .init(target: target, pageID: 10) }
	fileprivate var request: AutomationWaitRequest {
		.init(targetID: target.tabID.rawValue, expectedRevision: String(repeating: "a", count: 64))
	}

	fileprivate var client: BrowserPageWaitClient {
		ChromiumWaitAdapter.client(
			clock: AnyClock(clock),
			isAvailable: { true },
			capture: { [self] target in
				if let captureFailure { throw captureFailure }
				expectNoDifference(target, self.target)
				return .init(
					source: source,
					read: { [self] in
						guard current else { throw AutomationFailure.staleTarget }
						return snapshot
					},
					subscribe: { [self] in
						subscriptions += 1
						let (stream, continuation) = AsyncStream<BrowserNavigation>.makeStream(bufferingPolicy: .bufferingNewest(1))
						self.continuation = continuation
						return .init(events: stream, cancel: { [self] in
							cancellations += 1
							continuation.finish()
							self.continuation = nil
						})
					}
				)
			},
			sourceIsCurrent: { [self] in current && $0 == source }
		)
	}

	fileprivate func emit(_ navigation: BrowserNavigation) { continuation?.yield(navigation) }

	fileprivate func waitForSubscription() async throws {
		for _ in 0..<1000 {
			if continuation != nil { return }
			await Task.yield()
		}
		throw AutomationFailure.timedOut
	}
}
