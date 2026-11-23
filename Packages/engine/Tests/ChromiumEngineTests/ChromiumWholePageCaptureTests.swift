import AppKit
import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-1172: the whole page beyond the viewport is an optional export outside the ABI table.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumWholePageCaptureTests {
	@Test
	internal func olderEnginesDoNotOfferIt() async throws {
		let fixture = WholePageFixture(exports: false)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		#expect(!fixture.runtime.supportsWholePageCapture)
		await #expect(throws: ChromiumCaptureFailure.unavailable) {
			try await fixture.runtime.captureWholePage(page)
		}
	}

	@Test
	internal func theLimitsReachTheEngineAndTheImageAndGeometryAreCopied() async throws {
		let fixture = WholePageFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()
		#expect(fixture.runtime.supportsWholePageCapture)

		let task = Task { try await fixture.runtime.captureWholePage(page) }
		let request = await fixture.nextRequest()
		let limits = try #require(WholePageFixture.limits.last)
		#expect(limits.maximum_dimension == 16_384)
		#expect(limits.maximum_pixels == 50_331_648)
		#expect(limits.timeout_ms == 15_000)
		#expect(WholePageFixture.pages == [page.id])

		fixture.deliver(request, cut: true)
		let capture = try await task.value
		expectNoDifference(capture.documentID, "document-a")
		expectNoDifference(capture.png, Data([1, 2, 3, 4]))
		#expect(capture.width == 4 && capture.height == 6)
		#expect(capture.isCut)
		#expect(capture.deviceScale == 2)
		let geometry = try #require(capture.documentGeometry)
		#expect(geometry.documentX == 0 && geometry.documentY == 0)
		#expect(geometry.documentWidth == 4 && geometry.documentHeight == 6)
		#expect(geometry.scrollX == 2 && geometry.scrollY == 4)
		#expect(geometry.visibleWidth == 4 && geometry.visibleHeight == 2)
		#expect(geometry.pageScale == 1 && geometry.rasterScale == 1)
	}

	@Test
	internal func anEngineThatRefusesTheRequestFailsAtOnce() async throws {
		let fixture = WholePageFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()
		WholePageFixture.accepts = false

		await #expect(throws: ChromiumCaptureFailure.unavailable) {
			try await fixture.runtime.captureWholePage(page)
		}
		#expect(fixture.runtime.wholePageCaptures.isEmpty)
	}

	@Test
	internal func invalidLimitsNeverReachTheEngine() async throws {
		let fixture = WholePageFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		await #expect(throws: ChromiumCaptureFailure.invalidImage) {
			try await fixture.runtime.captureWholePage(page, limits: .init(maximumDimension: 16_385))
		}
		#expect(WholePageFixture.pending.isEmpty)
	}

	@Test
	internal func anImageOverTheLimitsIsRefusedBeforeItsBytesAreCopied() async throws {
		let fixture = WholePageFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		let task = Task { try await fixture.runtime.captureWholePage(page, limits: .init(maximumDimension: 5)) }
		let request = await fixture.nextRequest()
		fixture.deliver(request, cut: false)
		await #expect(throws: ChromiumCaptureFailure.limitExceeded) { try await task.value }
	}

	@Test
	internal func cancelingTellsTheEngineAndIgnoresItsLateReply() async throws {
		let fixture = WholePageFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		let task = Task { try await fixture.runtime.captureWholePage(page) }
		let request = await fixture.nextRequest()
		task.cancel()
		await #expect(throws: CancellationError.self) { try await task.value }
		#expect(WholePageFixture.cancelled == [request])
		fixture.deliver(request, cut: false)
		fixture.runtime.completeWholePageCapture(request, status: ARX_CAPTURE_CANCELLED, snapshot: nil)
	}

	@Test
	internal func closingThePageEndsItsCaptureAsStale() async throws {
		let fixture = WholePageFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		let task = Task { try await fixture.runtime.captureWholePage(page) }
		let request = await fixture.nextRequest()
		page.close()
		await #expect(throws: ChromiumCaptureFailure.staleDocument) { try await task.value }
		#expect(WholePageFixture.cancelled == [request])
		fixture.deliver(request, cut: false)
	}

	@Test
	internal func shuttingDownEndsTheCapture() async throws {
		let fixture = WholePageFixture(exports: true)
		let page = try fixture.runtime.makePage()

		let task = Task { try await fixture.runtime.captureWholePage(page) }
		let request = await fixture.nextRequest()
		fixture.runtime.finish()
		await #expect(throws: ChromiumCaptureFailure.unavailable) { try await task.value }
		fixture.deliver(request, cut: false)
	}

	@Test(arguments: [ARX_CAPTURE_BUSY, ARX_CAPTURE_UNSUPPORTED, ARX_CAPTURE_LIMIT, ARX_CAPTURE_TIMEOUT])
	internal func theEnginesFailuresComeThrough(_ status: ArxCaptureStatus) async throws {
		let fixture = WholePageFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		let task = Task { try await fixture.runtime.captureWholePage(page) }
		let request = await fixture.nextRequest()
		fixture.runtime.completeWholePageCapture(request, status: status, snapshot: nil)
		await #expect(throws: ChromiumCaptureFailure(status: status)) { try await task.value }
	}
}

@MainActor
private final class WholePageFixture {
	private static var view: NSView = .init()
	fileprivate static var accepts: Bool = true
	fileprivate static var pending: [UInt64] = []
	fileprivate static var pages: [UInt64] = []
	fileprivate static var limits: [ArxPageCaptureLimits] = []
	fileprivate static var cancelled: [UInt64] = []
	fileprivate let runtime: ChromiumRuntime

	fileprivate init(exports: Bool) {
		Self.accepts = true
		Self.pending = []
		Self.pages = []
		Self.limits = []
		Self.cancelled = []
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { WholePageFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		self.runtime = .init(api: api)
		if exports {
			runtime.optionalExports.wholePageCapture = .init(
				capture: { page, request, limits, _, _ in
					MainActor.assumeIsolated {
						guard WholePageFixture.accepts else { return false }

						WholePageFixture.pending.append(request)
						WholePageFixture.pages.append(page)
						if let limits { WholePageFixture.limits.append(limits.pointee) }
						return true
					}
				},
				cancel: { request in
					MainActor.assumeIsolated { WholePageFixture.cancelled.append(request) }
				}
			)
		}
		runtime.didBecomeReady()
	}

	fileprivate func nextRequest() async -> UInt64 {
		while Self.pending.isEmpty { await Task.yield() }
		return Self.pending.removeFirst()
	}

	/// A 4 × 6 pixel page at 2×: 2 × 3 DIP captured, scrolled to (1, 2).
	fileprivate func deliver(
		_ request: UInt64,
		cut: Bool
	) {
		"document-a".withCString { document in
			[UInt8(1), 2, 3, 4].withUnsafeBufferPointer { bytes in
				runtime.completeWholePageCapture(
					request,
					status: ARX_CAPTURE_SUCCESS,
					snapshot: .init(
						document_id: document,
						png: bytes.baseAddress,
						png_size: bytes.count,
						width: 4,
						height: 6,
						document_width: 2,
						document_height: cut ? 10 : 3,
						captured_width: 2,
						captured_height: 3,
						scroll_x: 1,
						scroll_y: 2,
						viewport_width: 2,
						viewport_height: 1,
						device_scale: 2,
						zoom_level: 0,
						cut: cut,
						was_loading: false
					)
				)
			}
		}
	}
}
