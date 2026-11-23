import BrowserCaptureClient
import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumCaptureAdapterTests {
	/// DEV-1172: Capture Page's whole page goes to the beyond-viewport capture with its own limits,
	/// and a page cut at them says so.
	@Test
	internal func aWholePageRequestUsesTheBeyondViewportCaptureWithItsLimits() async throws {
		let fixture = Fixture()
		var request = fixture.request
		request.mode = .fullDocument
		request.beyondViewport = true
		await #expect(throws: PageCaptureFailure.unavailable) { try await fixture.client.capture(request) }
		#expect(fixture.calls.isEmpty)

		fixture.wholePageAvailable = true
		let task = Task { try await fixture.client.capture(request) }
		await fixture.waitForCapture()
		#expect(fixture.wholePageLimits == .init(
			maximumDimension: 100,
			maximumPixels: 100,
			maximumEncodedBytes: 100,
			timeoutMilliseconds: 50
		))
		#expect(!fixture.documentCalled)
		fixture.completeWholePage(cut: true)
		let frame = try await task.value
		#expect(frame.isCut)
		#expect(frame.image.width == 4 && frame.image.height == 6)
		#expect(frame.documentGeometry?.documentRect == .init(x: 0, y: 0, width: 4, height: 6))
		#expect(frame.documentGeometry?.scrollY == 2)
	}

	/// DEV-1208: Capture Area scrolls a zoomed page in CSS pixels and reports the move in points.
	@Test
	internal func aScrollOnAZoomedPageTurnsPointsIntoCSSPixelsAndBack() async throws {
		let fixture = Fixture()
		fixture.zoom = 1.25
		fixture.scrollReply = .success(.json("[0,64]"))
		let moved = try await fixture.client.scrollAuthorized(fixture.request, .init(x: 0, y: 100), { true })

		#expect(moved == .init(x: 0, y: 80))
		let script = try #require(fixture.scripts.first)
		#expect(script.contains("left: 0.0000, top: 80.0000"))
		#expect(script.contains(#"behavior: "instant""#))
	}

	/// The page's own end stops a scroll short, and a reply that isn't two numbers is refused.
	@Test
	internal func aScrollReportsOnlyHowFarThePageMoved() async throws {
		let fixture = Fixture()
		fixture.scrollReply = .success(.json("[0,0]"))
		#expect(try await fixture.client.scrollAuthorized(fixture.request, .init(x: 0, y: 40), { true }) == .zero)

		// A reply that isn't two numbers came after the scroll may have run.
		fixture.scrollReply = .success(.json(#"{"x":1}"#))
		await #expect(throws: PageCaptureFailure.invalidImage) {
			try await fixture.client.scrollAuthorized(fixture.request, .init(x: 0, y: 40), { true })
		}
		fixture.scrollReply = .success(.undefined)
		await #expect(throws: PageCaptureFailure.invalidImage) {
			try await fixture.client.scrollAuthorized(fixture.request, .init(x: 0, y: 40), { true })
		}
		fixture.scrollReply = .failure(.busy)
		await #expect(throws: PageCaptureFailure.busy) {
			try await fixture.client.scrollAuthorized(fixture.request, .init(x: 0, y: 40), { true })
		}
	}

	/// A page magnified with a pinch isn't scrolled: the script checks before it scrolls, and the
	/// reply says the page didn't move.
	@Test
	internal func aPinchedPageIsntScrolled() async throws {
		let fixture = Fixture()
		fixture.scrollReply = .success(.json(ChromiumCaptureAdapter.pinchedReply))
		await #expect(throws: PageCaptureFailure.unavailable) {
			try await fixture.client.scrollAuthorized(fixture.request, .init(x: 0, y: 40), { true })
		}

		let script = try #require(fixture.scripts.first)
		let check = try #require(script.range(of: "visualViewport.scale - 1"))
		let scroll = try #require(script.range(of: "scrollBy("))
		#expect(check.lowerBound < scroll.lowerBound)
	}

	/// A script the engine refused up front, as on a `file:` page, never ran, so the page didn't move;
	/// a failure after it ran may have moved it.
	@Test(arguments: [
		(ChromiumDeveloperFailure.unsupportedDocument, PageCaptureFailure.unavailable),
		(.unavailable, .unavailable),
		(.invalidRequest, .unavailable),
		(.busy, .busy),
		(.timedOut, .timedOut),
		(.staleDocument, .staleDocument),
		(.failed, .invalidImage),
		(.limitExceeded, .invalidImage),
	])
	internal func aScrollSaysWhetherItRan(
		failure: ChromiumDeveloperFailure,
		expected: PageCaptureFailure
	) async throws {
		let fixture = Fixture()
		fixture.scrollReply = .failure(failure)
		await #expect(throws: expected) {
			try await fixture.client.scrollAuthorized(fixture.request, .init(x: 0, y: 40), { true })
		}
	}

	/// A scroll needs the page on screen and unchanged, as a capture does, and never runs for a
	/// hidden, changed or unauthorized page.
	@Test(arguments: ["unavailable", "hidden", "revision", "authorization", "zoom"])
	internal func aScrollChecksThePageFirst(change: String) async throws {
		let fixture = Fixture()
		var expected: PageCaptureFailure = .unavailable
		var authorized = true
		switch change {
		case "unavailable": fixture.scrollAvailable = false
		case "hidden": fixture.visible = false
		case "revision":
			fixture.revision = 9
			expected = .staleDocument
		case "authorization":
			authorized = false
			expected = .staleDocument
		default: fixture.zoom = nil
		}

		let allowed = authorized
		await #expect(throws: expected) {
			try await fixture.client.scrollAuthorized(fixture.request, .init(x: 0, y: 40), { allowed })
		}
		#expect(fixture.scripts.isEmpty)
	}

	/// One scroll moves a few screens at most, and nothing that isn't a number reaches the script.
	@Test
	internal func theScrollScriptIsBounded() throws {
		let script = try #require(ChromiumCaptureAdapter.scrollScript(.init(x: -1e9, y: 1e9), zoom: 2))
		#expect(script.contains("left: -2048.0000, top: 2048.0000"))
		#expect(ChromiumCaptureAdapter.scrollScript(.init(x: .nan, y: 0), zoom: 1) == nil)
		#expect(ChromiumCaptureAdapter.scrollScript(.init(x: 0, y: 1), zoom: 0) == nil)
	}

	/// MCP's recorded document never takes the beyond-viewport capture.
	@Test
	internal func aRecordedDocumentRequestKeepsTheDocumentCapture() async throws {
		let fixture = Fixture()
		fixture.wholePageAvailable = true
		var request = fixture.request
		request.mode = .fullDocument
		await #expect(throws: PageCaptureFailure.unavailable) { try await fixture.client.capture(request) }
		#expect(fixture.calls.isEmpty && fixture.wholePageLimits == nil)
	}

	@Test
	internal func documentAvailabilityIsCheckedBeforeAndAfterItsSeparateNativeClosure() async throws {
		let fixture = Fixture()
		var request = fixture.request
		request.mode = .fullDocument
		await #expect(throws: PageCaptureFailure.unavailable) { try await fixture.client.capture(request) }
		#expect(fixture.calls.isEmpty)
		fixture.documentAvailable = true
		let task = Task { try await fixture.client.capture(request) }
		await fixture.waitForCapture()
		#expect(fixture.documentCalled)
		fixture.documentAvailable = false
		fixture.complete()
		await #expect(throws: PageCaptureFailure.unavailable) { try await task.value }
	}

	@Test(arguments: ["epoch", "profile", "private"])
	internal func explicitOrdinaryDocumentScopeIsCheckedBeforeAndAfterCapture(change: String) async throws {
		let fixture = Fixture()
		var request = fixture.request
		request.documentRevision = 8
		request.ordinaryProfileID = fixture.profileID
		let task = Task { try await fixture.client.capture(request) }
		await fixture.waitForCapture()

		switch change {
		case "epoch": fixture.documentRevision = 9
		case "profile": fixture.profileID = .init(rawValue: UUID())
		default: fixture.profileID = nil
		}
		fixture.complete()
		await #expect(throws: PageCaptureFailure.staleDocument) { try await task.value }

		let callCount = fixture.calls.count
		await #expect(throws: PageCaptureFailure.staleDocument) {
			try await fixture.client.capture(request)
		}
		#expect(fixture.calls.count == callCount)
	}

	@Test
	internal func hiddenOrdinaryRequestFailsBeforeAndAfterNativeCapture() async throws {
		let fixture = Fixture()
		var request = fixture.request
		request.ordinaryProfileID = fixture.profileID
		let task = Task { try await fixture.client.capture(request) }
		await fixture.waitForCapture()
		fixture.visible = false
		fixture.complete()
		await #expect(throws: PageCaptureFailure.unavailable) { try await task.value }
		let count = fixture.calls.count
		await #expect(throws: PageCaptureFailure.unavailable) { try await fixture.client.capture(request) }
		#expect(fixture.calls.count == count)

		// Explicit user capture keeps its existing native availability behavior.
		let explicit = Task { try await fixture.client.capture(fixture.request) }
		await fixture.waitForCapture()
		fixture.complete()
		_ = try await explicit.value
	}

	@Test
	internal func deniedAndStaleRequestsNeverReachNativeCapture() async throws {
		let fixture = Fixture()
		fixture.authorized = false
		await #expect(throws: PageCaptureFailure.staleDocument) {
			try await fixture.client.captureAuthorized(fixture.request, { fixture.authorized })
		}
		fixture.authorized = true
		fixture.revision = 8
		await #expect(throws: PageCaptureFailure.staleDocument) {
			try await fixture.client.capture(fixture.request)
		}
		#expect(fixture.calls.isEmpty)
	}

	@Test(arguments: [true, false])
	internal func revocationOrNavigationWhileNativeWorkRunsDiscardsResult(revokeAuthorization: Bool) async throws {
		let fixture = Fixture()
		let task = Task {
			try await fixture.client.captureAuthorized(fixture.request, { fixture.authorized })
		}
		await fixture.waitForCapture()
		if revokeAuthorization { fixture.authorized = false }
		else { fixture.revision = nil }
		fixture.complete()
		await #expect(throws: PageCaptureFailure.staleDocument) { try await task.value }
	}

	@Test
	internal func capturedFrameKeepsRequestedTabLimitsAndProtectedMediaWarning() async throws {
		let fixture = Fixture()
		let task = Task { try await fixture.client.capture(fixture.request) }
		await fixture.waitForCapture()
		fixture.complete()
		let frame = try await task.value
		#expect(fixture.calls == [fixture.request.tabID])
		#expect(fixture.limits == .init(maximumDimension: 100, maximumPixels: 100, maximumEncodedBytes: 100, timeoutMilliseconds: 50))
		#expect(frame.request == fixture.request)
		#expect(frame.documentID == "native-document")
		#expect(frame.image.png == Data([1, 2]))
		#expect(frame.viewportWidth == 1 && frame.viewportHeight == 1)
		#expect(frame.image.width == 2 && frame.image.height == 2)
		#expect(frame.warnings == [.protectedMediaMayBeMissing])
	}

	@Test
	internal func nativeBusyRemainsActionable() async throws {
		let fixture = Fixture()
		let task = Task { try await fixture.client.capture(fixture.request) }
		await fixture.waitForCapture()
		fixture.continuation?.resume(throwing: ChromiumCaptureFailure.busy)
		fixture.continuation = nil
		await #expect(throws: PageCaptureFailure.busy) { try await task.value }
	}

	@Test
	internal func shutdownAfterNativeCompletionCannotReturnAnImage() async throws {
		let fixture = Fixture()
		let task = Task { try await fixture.client.capture(fixture.request) }
		await fixture.waitForCapture()
		fixture.available = false
		fixture.complete()
		await #expect(throws: PageCaptureFailure.unavailable) { try await task.value }
	}

	@Test
	internal func visiblePageWaitsForItsCompositorFrame() async throws {
		let fixture = Fixture()
		fixture.surfaceRetryDelays = [.zero, .zero]
		var request = fixture.request
		request.limits.timeoutMilliseconds = 10_000
		request.ordinaryProfileID = fixture.profileID
		let task = Task { try await fixture.client.capture(request) }
		await fixture.waitForCapture()
		fixture.fail(.unavailable)
		await fixture.waitForCapture()
		fixture.complete()
		let frame = try await task.value
		#expect(frame.request == request)
		#expect(fixture.calls == [request.tabID, request.tabID])
	}

	@Test
	internal func visiblePageStopsWaitingForItsCompositorFrame() async throws {
		let fixture = Fixture()
		fixture.surfaceRetryDelays = [.zero, .zero]
		var request = fixture.request
		request.limits.timeoutMilliseconds = 10_000
		let task = Task { try await fixture.client.capture(request) }
		for _ in 0 ..< 3 {
			await fixture.waitForCapture()
			fixture.fail(.unavailable)
		}
		await #expect(throws: PageCaptureFailure.unavailable) { try await task.value }
		#expect(fixture.calls.count == 3)
	}

	@Test
	internal func hiddenPageDoesNotWaitForACompositorFrame() async throws {
		let fixture = Fixture()
		fixture.surfaceRetryDelays = [.zero, .zero]
		fixture.visible = false
		let task = Task { try await fixture.client.capture(fixture.request) }
		await fixture.waitForCapture()
		fixture.fail(.unavailable)
		await #expect(throws: PageCaptureFailure.unavailable) { try await task.value }
		#expect(fixture.calls.count == 1)
	}

	@Test
	internal func waitingForACompositorFrameStaysWithinTheRequestTimeout() async throws {
		let fixture = Fixture()

		// Wide margins: the first 1 s wait fits a 3 s budget unless the first attempt
		// takes over 2 s, and the 2.5 s wait after it never fits what is left.
		fixture.surfaceRetryDelays = [.seconds(1), .milliseconds(2_500)]
		var request = fixture.request
		request.limits.timeoutMilliseconds = 3_000
		let task = Task { try await fixture.client.capture(request) }
		await fixture.waitForCapture()
		#expect(fixture.limits?.timeoutMilliseconds == 3_000)
		fixture.fail(.unavailable)
		await fixture.waitForCapture()
		let retried = try #require(fixture.limits?.timeoutMilliseconds)
		#expect(retried >= 1 && retried <= 2_000)
		fixture.fail(.unavailable)
		await #expect(throws: PageCaptureFailure.unavailable) { try await task.value }
		#expect(fixture.calls.count == 2)
	}

	@Test
	internal func navigationWhileWaitingForACompositorFrameIsStale() async throws {
		let fixture = Fixture()
		fixture.surfaceRetryDelays = [.milliseconds(20)]
		var request = fixture.request
		request.limits.timeoutMilliseconds = 10_000
		let task = Task { try await fixture.client.capture(request) }
		await fixture.waitForCapture()

		// The page navigates before native reports the missing frame, so the check
		// after the wait sees it whatever the scheduler does.
		fixture.revision = 8
		fixture.fail(.unavailable)
		await #expect(throws: PageCaptureFailure.staleDocument) { try await task.value }
		#expect(fixture.calls.count == 1)
	}

	@Test
	internal func cancellationAfterNativeSuccessCannotReturnAnImage() async throws {
		let fixture = Fixture()
		let task = Task { try await fixture.client.capture(fixture.request) }
		await fixture.waitForCapture()
		task.cancel()
		fixture.complete()
		await #expect(throws: CancellationError.self) { try await task.value }
	}

	/// DEV-971: a private page (no ordinary profile) is read as PDF only when the request
	/// allows it, as the app's own Print and Save as PDF do; MCP's requests never do.
	@Test
	internal func aPrivatePageIsReadAsPDFOnlyWhenTheRequestAllowsIt() async throws {
		let tabID: Tab.ID = .init(rawValue: UUID())
		let asked: PDFRequests = .init()
		let client = ChromiumCaptureAdapter.client(
			isAvailable: { true },
			revision: { $0 == tabID ? 7 : nil },
			documentRevision: { $0 == tabID ? 8 : nil },
			ordinaryProfileID: { _ in nil },
			pdfIsAvailable: { true },
			pdf: { id, _, _, allowsPrivate in
				asked.allowsPrivate.append(allowsPrivate)
				return .init(documentID: "document", data: Data("%PDF".utf8))
			},
			capture: { _, _ in throw ChromiumCaptureFailure.unavailable }
		)
		var request: PagePDFRequest = .init(
			tabID: tabID,
			revision: 7,
			documentRevision: 8,
			kind: .source,
			maximumBytes: 100
		)

		await #expect(throws: PageCaptureFailure.staleDocument) {
			try await client.pdfAuthorized(request, { true })
		}
		#expect(asked.allowsPrivate.isEmpty)

		request.allowsPrivate = true
		let pdf = try await client.pdfAuthorized(request, { true })
		#expect(pdf.data == Data("%PDF".utf8))
		#expect(asked.allowsPrivate == [true])
	}
}

/// What the adapter asked native PDF for.
@MainActor
private final class PDFRequests {
	fileprivate var allowsPrivate: [Bool]

	fileprivate init() {
		self.allowsPrivate = []
	}
}

@MainActor
private final class Fixture {
	fileprivate var available: Bool = true
	fileprivate var documentAvailable: Bool = false
	fileprivate var documentCalled: Bool = false
	fileprivate var wholePageAvailable: Bool = false
	fileprivate var wholePageLimits: ChromiumWholePageLimits?
	fileprivate var visible: Bool = true
	fileprivate var authorized: Bool = true
	fileprivate var revision: UInt64? = 7
	fileprivate var documentRevision: UInt64? = 8
	fileprivate var profileID: Profile.ID? = .init(rawValue: UUID())
	fileprivate var calls: [Tab.ID] = []
	fileprivate var limits: ChromiumCaptureLimits?
	fileprivate var continuation: CheckedContinuation<ChromiumCapture, any Error>?
	fileprivate var surfaceRetryDelays: [Duration] = []
	fileprivate var scrollAvailable: Bool = true
	fileprivate var zoom: Double? = 1
	fileprivate var scripts: [String] = []
	fileprivate var scrollReply: Result<ChromiumScriptValue, ChromiumDeveloperFailure> = .success(.json("[0,0]"))
	fileprivate let request: PageCaptureRequest = .init(
		tabID: .init(rawValue: UUID()),
		revision: 7,
		limits: .init(maximumDimension: 100, maximumPixels: 100, maximumEncodedBytes: 100, timeoutMilliseconds: 50)
	)

	fileprivate var client: BrowserCaptureClient {
		ChromiumCaptureAdapter.client(
			fullDocumentIsAvailable: { [self] in documentAvailable },
			captureDocument: { [self] id, limits in
				documentCalled = true
				calls.append(id)
				self.limits = limits
				return try await withCheckedThrowingContinuation { continuation = $0 }
			},
			wholePageIsAvailable: { [self] in wholePageAvailable },
			captureWholePage: { [self] id, limits in
				calls.append(id)
				wholePageLimits = limits
				return try await withCheckedThrowingContinuation { continuation = $0 }
			},
			isAvailable: { [self] in available },
			revision: { [self] id in id == request.tabID ? revision : nil },
			documentRevision: { [self] id in id == request.tabID ? documentRevision : nil },
			isVisible: { [self] id in id == request.tabID && visible },
			ordinaryProfileID: { [self] id in id == request.tabID ? profileID : nil },
			scrollIsAvailable: { [self] in scrollAvailable },
			pageZoom: { [self] id in id == request.tabID ? zoom : nil },
			evaluateScroll: { [self] id, script in
				calls.append(id)
				scripts.append(script)
				return try scrollReply.get()
			},
			surfaceRetryDelays: surfaceRetryDelays,
			capture: { [self] id, limits in
				calls.append(id)
				self.limits = limits
				return try await withCheckedThrowingContinuation { continuation = $0 }
			}
		)
	}

	/// Waits for the adapter to call into native. A call that never comes fails the
	/// test after a few seconds instead of hanging the whole run.
	fileprivate func waitForCapture(sourceLocation: SourceLocation = #_sourceLocation) async {
		let clock = ContinuousClock()
		let deadline = clock.now + .seconds(10)
		while continuation == nil {
			guard clock.now < deadline else {
				Issue.record("The adapter never called native capture", sourceLocation: sourceLocation)
				return
			}
			await Task.yield()
		}
	}

	fileprivate func fail(_ failure: ChromiumCaptureFailure) {
		continuation?.resume(throwing: failure)
		continuation = nil
	}

	/// A 4 × 6 pixel whole page at 2×, scrolled to 1 CSS pixel down.
	fileprivate func completeWholePage(cut: Bool) {
		do {
			let frame = try "native-document".withCString { document in
				try [UInt8](repeating: 1, count: 8).withUnsafeBufferPointer { bytes in
					try ChromiumCapture(
						native: .init(
							document_id: document,
							png: bytes.baseAddress,
							png_size: bytes.count,
							width: 4,
							height: 6,
							document_width: 2,
							document_height: cut ? 5 : 3,
							captured_width: 2,
							captured_height: 3,
							scroll_x: 0,
							scroll_y: 1,
							viewport_width: 2,
							viewport_height: 1,
							device_scale: 2,
							zoom_level: 0,
							cut: cut,
							was_loading: false
						),
						limits: ChromiumWholePageLimits()
					)
				}
			}
			continuation?.resume(returning: frame)
		} catch {
			continuation?.resume(throwing: error)
		}
		continuation = nil
	}

	fileprivate func complete() {
		do {
			let frame = try "native-document".withCString { document in
				try [UInt8(1), 2].withUnsafeBufferPointer { bytes in
					try ChromiumCapture(native: .init(
						document_id: document,
						png: bytes.baseAddress,
						png_size: bytes.count,
						width: 2,
						height: 2,
						viewport_width: 1,
						viewport_height: 1,
						device_scale: 2,
						was_loading: false
					), limits: .init())
				}
			}
			continuation?.resume(returning: frame)
		} catch {
			continuation?.resume(throwing: error)
		}
		continuation = nil
	}
}
