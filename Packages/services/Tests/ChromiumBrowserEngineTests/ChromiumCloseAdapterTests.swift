import BrowserCore
import BrowserEngineClient
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumCloseAdapterTests {
	@Test
	internal func missingCapabilityFailsClosed() {
		#expect(BrowserEngineClient.liveValue.closeAuthorized == nil)
	}

	@Test
	internal func storedClientComposedBeforeStartupRetainsCapability() async throws {
		var api = ArxEngineAPI()
		api.page_close_generation = { _ in 1 }
		api.request_authorized_close = { _, _, _ in }
		api.consume_authorized_close = { _, _, _ in ARX_CLOSE_STALE }
		api.cancel_authorized_close = { _, _ in }
		let runtime = ChromiumRuntime(api: api)
		let engine = ChromiumBrowserEngine(
			runtime: runtime,
			profileID: .init(rawValue: UUID()),
			enableAuthorizedClosing: true
		)
		let client = engine.client
		let close = try #require(client.closeAuthorized)
		let tabID = Tab.ID(rawValue: UUID())
		var publications = 0

		await #expect(throws: AutomationFailure.unsupported) {
			try await close(tabID, nil, { true }) { publications += 1 }
		}

		runtime.didBecomeReady()
		defer { runtime.finish() }

		let closed = try await close(tabID, nil, { true }) {
			#expect(client.snapshot(tabID) == nil)
			publications += 1
		}
		#expect(closed)
		#expect(publications == 1)
	}

	@Test
	internal func explicitEnablementWithoutNativeFunctionsStillHasNoCapability() {
		let runtime = ChromiumRuntime(api: ArxEngineAPI())
		let engine = ChromiumBrowserEngine(
			runtime: runtime,
			profileID: .init(rawValue: UUID()),
			enableAuthorizedClosing: true
		)
		#expect(engine.client.closeAuthorized == nil)
	}

	@Test(arguments: [true, false])
	internal func initialDenialOrStaleSessionDoesNotAskNative(denied: Bool) async {
		let fixture = Fixture()
		fixture.authorized = !denied
		fixture.current = denied

		await #expect(throws: denied ? AutomationFailure.denied : .staleTarget) {
			try await fixture.close()
		}
		#expect(fixture.continuation == nil)
		#expect(fixture.events.isEmpty)
	}

	@Test(arguments: [true, false])
	internal func revocationOrReplacementAfterApprovalCannotConsume(denied: Bool) async {
		let fixture = Fixture()
		let task = Task { try await fixture.close() }
		await fixture.wait()
		fixture.authorized = !denied
		fixture.current = denied
		fixture.complete(1)

		await #expect(throws: denied ? AutomationFailure.denied : .staleTarget) { try await task.value }
		#expect(fixture.events == ["cancel"])
	}

	@Test
	internal func cancellationAfterApprovalRevokesWithoutPublication() async {
		let fixture = Fixture()
		let task = Task { try await fixture.close() }
		await fixture.wait()
		task.cancel()
		fixture.complete(1)

		await #expect(throws: CancellationError.self) { try await task.value }
		#expect(fixture.events == ["cancel"])
	}

	@Test
	internal func nativeStaleDocumentDoesNotPublishSuccess() async {
		let fixture = Fixture()
		fixture.consumeFailure = .staleDocument
		let task = Task { try await fixture.close() }
		await fixture.wait()
		fixture.complete(1)

		await #expect(throws: AutomationFailure.staleTarget) { try await task.value }
		#expect(fixture.events == ["consume", "cancel"])
		#expect(fixture.current)
	}

	@Test
	internal func successDisposesBeforeSynchronousPublication() async throws {
		let fixture = Fixture()
		let task = Task { try await fixture.close() }
		await fixture.wait()
		fixture.complete(1)

		#expect(try await task.value)
		#expect(fixture.events == ["consume", "dispose", "didClose", "cancel"])
	}

	@Test
	internal func refusalLeavesDocumentAndMetadataUntouched() async throws {
		let fixture = Fixture()
		let task = Task { try await fixture.close() }
		await fixture.wait()
		fixture.complete(nil)

		#expect(try await !task.value)
		#expect(fixture.events.isEmpty)
		#expect(fixture.current)
	}
}

@MainActor
private final class Fixture {
	fileprivate var authorized: Bool = true
	fileprivate var current: Bool = true
	fileprivate var events: [String] = []
	fileprivate var continuation: CheckedContinuation<Int?, any Error>?
	fileprivate var consumeFailure: ChromiumCloseFailure?

	fileprivate func close() async throws -> Bool {
		try await ChromiumCloseAdapter.perform(
			authorize: { [self] in authorized },
			isCurrent: { [self] in current },
			approve: { [self] in try await withCheckedThrowingContinuation { continuation = $0 } },
			consume: { [self] _ in
				events.append("consume")
				if let consumeFailure { throw consumeFailure }
				current = false
				events.append("dispose")
			},
			cancel: { [self] _ in events.append("cancel") },
			didClose: { [self] in
				#expect(!current)
				events.append("didClose")
			}
		)
	}

	fileprivate func wait() async {
		while continuation == nil { await Task.yield() }
	}

	fileprivate func complete(_ approval: Int?) {
		continuation?.resume(returning: approval)
		continuation = nil
	}
}
