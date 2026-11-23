import AppKit
import ChromiumBridge
import CustomDump
import Testing

@testable import ChromiumEngine

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumCaptureTests {
	@Test
	internal func fullDocumentUsesItsOwnCallbackAndPreservesSeparateGeometry() async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		defer { fixture.runtime.finish() }
		let task = Task { try await fixture.runtime.capture(page, fullDocument: true) }
		let request = await fixture.nextRequest()
		fixture.deliverDocument(request)
		let result = try await task.value
		#expect(result.width == 4 && result.height == 2)
		#expect(result.viewportWidth == 2 && result.viewportHeight == 1)
		#expect(result.deviceScale == 2 && result.documentGeometry?.rasterScale == 1)
		#expect(result.documentGeometry?.documentX == -1)
		#expect(result.documentGeometry?.scrollY == 0.5)
	}

	@Test
	internal func fullDocumentUnavailableFailsBeforeNativeSubmission() async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		defer { fixture.runtime.finish() }
		Fixture.documentAvailable = false
		await #expect(throws: ChromiumCaptureFailure.unavailable) {
			try await fixture.runtime.capture(page, fullDocument: true)
		}
		#expect(Fixture.pending.isEmpty)
	}

	@Test
	internal func fullDocumentCancellationIgnoresLateBorrowedPayload() async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		defer { fixture.runtime.finish() }
		let task = Task { try await fixture.runtime.capture(page, fullDocument: true) }
		let request = await fixture.nextRequest()
		task.cancel()
		await #expect(throws: CancellationError.self) { try await task.value }
		#expect(Fixture.cancelled == [request])
		fixture.deliverDocument(request)
	}

	@Test
	internal func copiesBytesAndDocumentBeforeNativeMemoryExpires() async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		defer { fixture.runtime.finish() }
		let task = Task { try await fixture.runtime.capture(page) }
		let request = await fixture.nextRequest()
		fixture.deliver(request, bytes: [1, 2, 3, 4])
		let result = try await task.value
		expectNoDifference(result.documentID, "document-a")
		expectNoDifference(result.png, Data([1, 2, 3, 4]))
		#expect(result.width == 4 && result.height == 2)
		#expect(result.viewportWidth == 2 && result.viewportHeight == 1)
		#expect(result.deviceScale == 2)
		#expect(result.wasLoading)
	}

	@Test
	internal func cancellationResumesPromptlyAndIgnoresLateCompletion() async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		defer { fixture.runtime.finish() }
		let task = Task { try await fixture.runtime.capture(page) }
		let request = await fixture.nextRequest()
		task.cancel()
		await #expect(throws: CancellationError.self) { try await task.value }
		#expect(Fixture.cancelled == [request])
		fixture.deliver(request)

		// A late callback cannot resume another request or release its continuation.
		let next = Task { try await fixture.runtime.capture(page) }
		let nextRequest = await fixture.nextRequest()
		fixture.deliver(request)
		fixture.deliver(nextRequest)
		#expect(try await next.value.documentID == "document-a")
	}

	@Test
	internal func cancellationBeforeSubmissionNeverCallsNative() async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		defer { fixture.runtime.finish() }
		let task = Task { try await fixture.runtime.capture(page) }
		task.cancel()
		await #expect(throws: CancellationError.self) { try await task.value }
		#expect(Fixture.pending.isEmpty)
		#expect(Fixture.cancelled.isEmpty)
	}

	@Test
	internal func closeResumesAsStaleAndCancelsNativeWorkOnce() async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		defer { fixture.runtime.finish() }
		let task = Task { try await fixture.runtime.capture(page) }
		let request = await fixture.nextRequest()
		page.close()
		page.close()
		await #expect(throws: ChromiumCaptureFailure.staleDocument) { try await task.value }
		#expect(Fixture.cancelled == [request])
		fixture.deliver(request)
	}

	@Test
	internal func shutdownDrainsContinuationsAndIgnoresLateCallback() async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		let task = Task { try await fixture.runtime.capture(page) }
		let request = await fixture.nextRequest()
		fixture.runtime.finish()
		await #expect(throws: ChromiumCaptureFailure.unavailable) { try await task.value }
		fixture.deliver(request)
		#expect(Fixture.cancelled.isEmpty)
	}

	@Test
	internal func rejectsInvalidLimitsBeforeNativeSubmission() async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		defer { fixture.runtime.finish() }
		await #expect(throws: ChromiumCaptureFailure.invalidImage) {
			try await fixture.runtime.capture(page, limits: .init(maximumPixels: .max))
		}
		#expect(Fixture.pending.isEmpty)
	}

	@Test
	internal func rejectsOversizedPayloadBeforeCopyingBytes() async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		defer { fixture.runtime.finish() }
		let task = Task { try await fixture.runtime.capture(page, limits: .init(maximumEncodedBytes: 2)) }
		let request = await fixture.nextRequest()
		fixture.deliver(request, bytes: [1, 2, 3])
		await #expect(throws: ChromiumCaptureFailure.limitExceeded) { try await task.value }
	}

	@Test
	internal func wrongPageCannotCompleteACapture() async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		defer { fixture.runtime.finish() }
		let task = Task { try await fixture.runtime.capture(page) }
		let request = await fixture.nextRequest()
		fixture.deliver(request, page: 99)
		await #expect(throws: ChromiumCaptureFailure.staleDocument) { try await task.value }
	}

	@Test(arguments: [ARX_CAPTURE_TIMEOUT, ARX_CAPTURE_STALE, ARX_CAPTURE_BUSY, ARX_CAPTURE_UNSUPPORTED])
	internal func preservesNativeFailures(_ status: ArxCaptureStatus) async throws {
		let fixture = Fixture()
		let page = try fixture.runtime.makePage()
		defer { fixture.runtime.finish() }
		let task = Task { try await fixture.runtime.capture(page) }
		let request = await fixture.nextRequest()
		fixture.runtime.completeCapture(request, page: 1, status: status, snapshot: nil)
		await #expect(throws: ChromiumCaptureFailure(status: status)) { try await task.value }
	}
}

@MainActor
private final class Fixture {
	private static var view: NSView = .init()
	fileprivate static var documentAvailable: Bool = true
	fileprivate static var pending: [UInt64] = []
	fileprivate static var cancelled: [UInt64] = []
	fileprivate let runtime: ChromiumRuntime

	fileprivate init() {
		Self.documentAvailable = true
		Self.pending = []
		Self.cancelled = []
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { Fixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		api.capture_viewport = { _, request, _ in MainActor.assumeIsolated { Fixture.pending.append(request) } }
		api.cancel_capture = { request in MainActor.assumeIsolated { Fixture.cancelled.append(request) } }
		api.document_capture_available = { MainActor.assumeIsolated { Fixture.documentAvailable } }
		api.capture_document = { _, request, _ in MainActor.assumeIsolated { Fixture.pending.append(request) } }
		api.cancel_document_capture = { request in MainActor.assumeIsolated { Fixture.cancelled.append(request) } }
		self.runtime = .init(api: api)
		runtime.didBecomeReady()
	}

	fileprivate func nextRequest() async -> UInt64 {
		while Self.pending.isEmpty { await Task.yield() }
		return Self.pending.removeFirst()
	}

	fileprivate func deliverDocument(_ request: UInt64) {
		"document-a".withCString { document in
			[UInt8(1), 2].withUnsafeBufferPointer { bytes in
				let snapshot = ArxDocumentCaptureSnapshot(
					document_id: document,
					png: bytes.baseAddress,
					png_size: bytes.count,
					width: 4,
					height: 2,
					document_x: -1,
					document_y: 0,
					document_width: 4,
					document_height: 2,
					visible_x: 0,
					visible_y: 0,
					visible_width: 2,
					visible_height: 1,
					scroll_x: 0,
					scroll_y: 0.5,
					zoom_level: 0,
					page_scale: 1,
					viewport_width: 2,
					viewport_height: 1,
					device_scale: 2,
					raster_scale: 1,
					was_loading: false
				)
				runtime.completeDocumentCapture(request, page: 1, status: ARX_CAPTURE_SUCCESS, snapshot: snapshot)
			}
		}
	}

	fileprivate func deliver(
		_ request: UInt64,
		page: UInt64 = 1,
		bytes: [UInt8] = [1]
	) {
		"document-a".withCString { document in
			bytes.withUnsafeBufferPointer { bytes in
				let snapshot = ArxCaptureSnapshot(
					document_id: document,
					png: bytes.baseAddress,
					png_size: bytes.count,
					width: 4,
					height: 2,
					viewport_width: 2,
					viewport_height: 1,
					device_scale: 2,
					was_loading: true
				)
				runtime.completeCapture(request, page: page, status: ARX_CAPTURE_SUCCESS, snapshot: snapshot)
			}
		}
	}
}
