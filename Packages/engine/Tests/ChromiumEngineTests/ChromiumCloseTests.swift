import AppKit
import ChromiumBridge
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumCloseTests {
	@Test
	internal func documentRevisionReadsNativeEpochBeforeQueuedNavigationDelivery() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let page = try fixture.page()
		#expect(fixture.runtime.documentRevision(for: page) == 1)
		Fixture.generation = 2
		#expect(page.closeGeneration == 1)
		#expect(fixture.runtime.publishedDocumentRevision(for: page) == 1)
		#expect(fixture.runtime.documentRevision(for: page) == 2)
		page.close()
		#expect(fixture.runtime.documentRevision(for: page) == nil)
		#expect(fixture.runtime.publishedDocumentRevision(for: page) == nil)
	}

	@Test
	internal func missingCloseGenerationDoesNotInterruptNavigation() async throws {
		let fixture = Fixture(supportsCloseGeneration: false)
		defer { fixture.finish() }

		let page = try fixture.page()
		#expect(page.navigation.title == "Fixture")
		#expect(page.closeGeneration == 0)
		#expect(fixture.runtime.documentRevision(for: page) == nil)
		#expect(!fixture.runtime.supportsAuthorizedClosing)
		await #expect(throws: ChromiumCloseFailure.unavailable) {
			try await fixture.runtime.approveClose(page)
		}
		#expect(Fixture.request == nil)
	}

	@Test
	internal func generationQueryRejectsForeignClosedAndStoppedOwners() throws {
		let fixture = Fixture()
		let page = try fixture.page()
		let foreign = ChromiumPage(
			id: page.identifier,
			view: NSView(),
			runtime: fixture.runtime
		)

		#expect(fixture.runtime.closeGeneration(for: page) == 1)
		#expect(fixture.runtime.closeGeneration(for: foreign) == 0)
		page.close()
		#expect(fixture.runtime.closeGeneration(for: page) == 0)

		let remaining = try fixture.page()
		fixture.finish()
		#expect(fixture.runtime.closeGeneration(for: remaining) == 0)
	}

	@Test
	internal func publishedEpochCannotAuthorizeANewerUnpublishedDocument() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let page = try fixture.page()
		Fixture.generation = 2

		let task = Task { try await fixture.runtime.approveClose(page) }
		await fixture.waitForRequest()
		#expect(Fixture.request?.generation == 1)
		fixture.complete(status: ARX_CLOSE_STALE)
		await #expect(throws: ChromiumCloseFailure.staleDocument) { try await task.value }
		#expect(!page.isClosed)
		#expect(Fixture.consumed.isEmpty)
	}

	@Test
	internal func consumesOnceAndInvalidatesSwiftOwnershipWithoutDoubleDestroy() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let page = try fixture.page()
		let approval = try await fixture.approve(page)

		try fixture.runtime.consumeClose(approval, for: page)
		#expect(page.isClosed)
		#expect(Fixture.consumed == [page.identifier])
		#expect(Fixture.destroyed.isEmpty)
		#expect(throws: ChromiumCloseFailure.staleDocument) {
			try fixture.runtime.consumeClose(approval, for: page)
		}
		page.close()
		#expect(Fixture.destroyed.isEmpty)
	}

	@Test
	internal func otherPageCannotConsumeOrRevokeAnApproval() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let first = try fixture.page()
		let second = try fixture.page()
		let approval = try await fixture.approve(first)

		#expect(throws: ChromiumCloseFailure.staleDocument) {
			try fixture.runtime.consumeClose(approval, for: second)
		}
		#expect(Fixture.consumed.isEmpty)
		try fixture.runtime.consumeClose(approval, for: first)
		#expect(!second.isClosed)
	}

	@Test
	internal func nativeStaleConsumeLeavesPageAlive() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let page = try fixture.page()
		let approval = try await fixture.approve(page)
		Fixture.consumeStatus = ARX_CLOSE_STALE

		#expect(throws: ChromiumCloseFailure.staleDocument) {
			try fixture.runtime.consumeClose(approval, for: page)
		}
		#expect(!page.isClosed)
		#expect(Fixture.destroyed.isEmpty)
		#expect(throws: ChromiumCloseFailure.staleDocument) {
			try fixture.runtime.consumeClose(approval, for: page)
		}
		#expect(Fixture.consumed.count == 1)
	}

	@Test
	internal func cancelledAwaitRevokesNativeSlotAndLateSuccessCannotRestoreIt() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let page = try fixture.page()
		let task = Task { try await fixture.runtime.approveClose(page) }
		await fixture.waitForRequest()
		task.cancel()
		await #expect(throws: CancellationError.self) { try await task.value }
		#expect(Fixture.cancelled.count == 1)
		fixture.complete(status: ARX_CLOSE_SUCCESS)
		#expect(!page.isClosed)
		#expect(Fixture.consumed.isEmpty)
	}

	@Test
	internal func refusalReturnsNoApprovalAndShutdownDrainsPendingRequest() async throws {
		let fixture = Fixture()
		let page = try fixture.page()
		let refused = Task { try await fixture.runtime.approveClose(page) }
		await fixture.waitForRequest()
		fixture.complete(status: ARX_CLOSE_REFUSED)
		#expect(try await refused.value == nil)
		Fixture.request = nil

		let pending = Task { try await fixture.runtime.approveClose(page) }
		await fixture.waitForRequest()
		fixture.finish()
		await #expect(throws: ChromiumCloseFailure.unavailable) { try await pending.value }
		#expect(page.isClosed)
	}

	@Test
	internal func closingThePageDrainsPendingApprovalAndIgnoresLateSuccess() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let page = try fixture.page()
		let pending = Task { try await fixture.runtime.approveClose(page) }
		await fixture.waitForRequest()

		page.close()
		await #expect(throws: ChromiumCloseFailure.staleDocument) { try await pending.value }
		fixture.complete(status: ARX_CLOSE_SUCCESS)

		#expect(Fixture.cancelled.count == 1)
		#expect(Fixture.destroyed == [page.identifier])
		#expect(Fixture.consumed.isEmpty)
	}

	@Test
	internal func foreignCallbackPageCannotCreateAuthority() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let page = try fixture.page()
		let other = try fixture.page()
		let pending = Task { try await fixture.runtime.approveClose(page) }
		await fixture.waitForRequest()
		let request = try #require(Fixture.request)

		fixture.runtime.closeRequests.complete(
			request: request.id,
			page: other.identifier,
			status: ARX_CLOSE_SUCCESS,
			token: 100
		)
		await #expect(throws: ChromiumCloseFailure.staleDocument) { try await pending.value }
		#expect(Fixture.cancelled == [request.id])
		#expect(Fixture.consumed.isEmpty)
		#expect(!page.isClosed)
		#expect(!other.isClosed)
	}

	@Test
	internal func deadlineRevokesNativeRequestWithoutClosingPage() async throws {
		var api = ArxEngineAPI()
		api.request_authorized_close = { _, _, _ in }

		// The callback cannot capture local state; use the serialized fixture record.
		Fixture.cancelled = []
		api.cancel_authorized_close = { _, request in
			MainActor.assumeIsolated { Fixture.cancelled.append(request) }
		}
		let requests = ChromiumCloseRequests(api: api, timeout: .milliseconds(1))

		await #expect(throws: ChromiumCloseFailure.timedOut) {
			try await requests.request(page: 1, generation: 1)
		}
		let cancellations = Fixture.cancelled
		#expect(cancellations.count == 1)
		let request = try #require(cancellations.first)
		requests.complete(
			request: request,
			page: 1,
			status: ARX_CLOSE_SUCCESS,
			token: 100
		)
		requests.finish()
		#expect(Fixture.cancelled == cancellations)
	}

	@Test
	internal func cancelledApprovalCannotBeConsumed() async throws {
		let fixture = Fixture()
		defer { fixture.finish() }
		let page = try fixture.page()
		let approval = try await fixture.approve(page)
		fixture.runtime.cancelClose(approval)

		#expect(throws: ChromiumCloseFailure.staleDocument) {
			try fixture.runtime.consumeClose(approval, for: page)
		}
		#expect(Fixture.consumed.isEmpty)
		#expect(!page.isClosed)
	}
}

@MainActor
private final class Fixture {
	fileprivate static var generation: UInt64 = 1
	fileprivate static var nextPage: UInt64 = 1
	fileprivate static var request: (page: UInt64, id: UInt64, generation: UInt64)?
	fileprivate static var cancelled: [UInt64] = []
	fileprivate static var consumed: [UInt64] = []
	fileprivate static var destroyed: [UInt64] = []
	fileprivate static var consumeStatus: ArxCloseStatus = ARX_CLOSE_SUCCESS
	fileprivate static let view: NSView = .init()
	fileprivate let runtime: ChromiumRuntime

	fileprivate init(supportsCloseGeneration: Bool = true) {
		Self.generation = 1
		Self.nextPage = 1
		Self.request = nil
		Self.cancelled = []
		Self.consumed = []
		Self.destroyed = []
		Self.consumeStatus = ARX_CLOSE_SUCCESS
		var api = ArxEngineAPI()
		api.create_page = { _, _ in
			MainActor.assumeIsolated {
				defer { Fixture.nextPage += 1 }
				return Fixture.nextPage
			}
		}
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { Fixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.history_count = { _ in 0 }
		api.page_close_generation = { _ in MainActor.assumeIsolated { Fixture.generation } }
		api.request_authorized_close = { page, request, generation in
			MainActor.assumeIsolated { Fixture.request = (page, request, generation) }
		}
		api.consume_authorized_close = { page, _, _ in
			MainActor.assumeIsolated {
				Fixture.consumed.append(page)
				return Fixture.consumeStatus
			}
		}
		api.cancel_authorized_close = { _, request in
			MainActor.assumeIsolated { Fixture.cancelled.append(request) }
		}
		api.destroy_page = { page in
			MainActor.assumeIsolated { Fixture.destroyed.append(page) }
		}
		if !supportsCloseGeneration { api.page_close_generation = nil }
		runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
	}

	fileprivate func page() throws -> ChromiumPage {
		let page = try runtime.makePage()
		page.receive(.init(
			url: URL(string: "https://capturecontext.dev"),
			title: "Fixture",
			isLoading: false,
			canGoBack: false,
			canGoForward: false,
			errorCode: nil
		))
		return page
	}

	fileprivate func approve(_ page: ChromiumPage) async throws -> ChromiumCloseApproval {
		let task = Task { try await runtime.approveClose(page) }
		await waitForRequest()
		complete(status: ARX_CLOSE_SUCCESS)
		return try #require(await task.value)
	}

	fileprivate func waitForRequest() async {
		while Self.request == nil { await Task.yield() }
	}

	fileprivate func complete(status: ArxCloseStatus) {
		guard let request = Self.request else { return }
		runtime.closeRequests.complete(
			request: request.id,
			page: request.page,
			status: status,
			token: 100
		)
	}

	fileprivate func finish() { runtime.finish() }
}
