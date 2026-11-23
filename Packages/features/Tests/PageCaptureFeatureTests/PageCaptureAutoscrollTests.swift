import AppUI
import BrowserCaptureClient
import BrowserCore
import CustomDump
import Foundation
import PageCaptureFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1208: drawing an area toward an edge scrolls the page, and an area larger than the viewport
/// is cut from the whole page in one image; Capture Page's frame shows the whole page it took.
@Suite(.dependencies)
@MainActor
internal struct PageCaptureAutoscrollTests {
	private typealias Fixtures = PageCaptureFixtures

	private let start = CGPoint(x: 10, y: 10)

	/// Near the 40-point viewport's bottom edge, which starts 10 points up.
	private let nearBottom = CGPoint(x: 30, y: 39)

	@Test
	internal func drawingTowardTheBottomScrollsAndTakesTheWholeAreaInOneImage() async throws {
		let clock = TestClock()
		var offsets: [PageCaptureOffset] = []
		let store = TestStore(initialState: drawingState()) { PageCaptureFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.browserCapture.scrollAuthorized = { request, offset, authorize in
				#expect(authorize() && request == Fixtures.request)
				offsets.append(offset)
				return .init(x: 0, y: 20)
			}
			$0.browserCapture.captureAuthorized = { request, authorize in
				#expect(authorize() && request.mode == .fullDocument && request.beyondViewport)
				return try Self.wholePage(request)
			}
		}

		await store.send(.ui(.dragChanged(from: start, to: nearBottom))) {
			$0.drawingGeneration = 1
			$0.drawing = .init(start: self.start, pointer: self.nearBottom, isTicking: true)
			$0.drag = .init(x: 10, y: 10, width: 20, height: 29)
		}
		await clock.advance(by: PageCaptureFeature.autoscrollInterval)
		await store.receive(\.event.autoscrollTick) { $0.drawing?.isScrolling = true }
		await store.receive(\.event.autoscrolled) {
			$0.drawing?.isScrolling = false
			$0.drawing?.scrolled = .init(x: 0, y: 20)
			$0.inspectionGeneration = 1

			// Where the drag began moved 10 points above the viewport; the cut-out shows the rest.
			$0.drag = .init(x: 10, y: 0, width: 20, height: 39)
		}
		let offset = try #require(offsets.first)
		let velocity = PageCaptureGeometry.autoscrollVelocity(from: start, to: nearBottom, viewport: Fixtures.state().viewport)
		#expect(offset.x == 0)
		#expect(abs(offset.y - velocity.y * 0.016) < 0.000_1)

		await store.send(.ui(.dragEnded(from: start, to: nearBottom))) {
			$0.drawing = nil
			$0.drag = nil
			$0.request?.mode = .fullDocument
			$0.request?.beyondViewport = true
			$0.request?.limits = .wholePage
		}
		let region = PageCaptureRegion(x: 10, y: -10, width: 20, height: 49)
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = region
		}
		let frame = try Self.wholePage(Self.wholePageRequest)

		// 20 points down a page scrolled 20 points at 2×: pixels 20 to 118 of the whole page.
		let cropped = try PageCaptureCodec.crop(frame, to: .init(x: 20, y: 20, width: 40, height: 98))
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = cropped
			$0.selection = PageCaptureGeometry.capturedFrame(for: region, viewport: $0.viewport)
		}
		#expect(cropped.width == 40 && cropped.height == 98)
		// The page's top band is red and its next one blue: the area starts above the viewport.
		#expect(try Fixtures.color(of: cropped, x: 0, y: 0) == Fixtures.quadrants[0])
		#expect(try Fixtures.color(of: cropped, x: 39, y: 97) == Fixtures.quadrants[2])

		await clock.advance(by: PageCaptureFeature.scrollSettleDelay)
		await store.receive(\.inspect) { $0.inspectionGeneration = 2 }
	}

	@Test
	internal func letGoWhileAScrollIsOutTakesTheAreaOnceItsBack() async throws {
		let clock = TestClock()
		var state = drawingState()
		state.targets = [.init(index: 1, role: "paragraph", bounds: .init(x: 0, y: 0, width: 20, height: 20))]
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.browserCapture.scrollAuthorized = { _, _, _ in
				try await clock.sleep(for: .milliseconds(5))
				return .init(x: 0, y: 20)
			}
			$0.browserCapture.captureAuthorized = { request, _ in try Self.wholePage(request) }
		}

		await store.send(.ui(.dragChanged(from: start, to: nearBottom))) {
			$0.drawingGeneration = 1
			$0.drawing = .init(start: self.start, pointer: self.nearBottom, isTicking: true)
			$0.drag = .init(x: 10, y: 10, width: 20, height: 29)
		}
		await clock.advance(by: PageCaptureFeature.autoscrollInterval)
		await store.receive(\.event.autoscrollTick) { $0.drawing?.isScrolling = true }
		await store.send(.ui(.dragEnded(from: start, to: nearBottom))) {
			$0.drawing?.end = self.nearBottom
			$0.drawing?.isTicking = false
		}

		// Another drag, or a click on a block, before the scroll is back changes nothing.
		await store.send(.ui(.dragChanged(from: .init(x: 2, y: 2), to: .init(x: 20, y: 20))))
		await store.send(.ui(.dragEnded(from: .init(x: 2, y: 2), to: .init(x: 20, y: 20))))
		await store.send(.ui(.clicked(.init(x: 5, y: 5))))
		await clock.advance(by: .milliseconds(5))
		await store.receive(\.event.autoscrolled) {
			$0.inspectionGeneration = 1
			$0.targets = []
			$0.drawing = nil
			$0.drag = nil
			$0.request?.mode = .fullDocument
			$0.request?.beyondViewport = true
			$0.request?.limits = .wholePage
		}
		let region = PageCaptureRegion(x: 10, y: -10, width: 20, height: 49)
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = region
		}
		let frame = try Self.wholePage(Self.wholePageRequest)
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = try PageCaptureCodec.crop(frame, to: .init(x: 20, y: 20, width: 40, height: 98))
			$0.selection = PageCaptureGeometry.capturedFrame(for: region, viewport: $0.viewport)
		}
		await clock.advance(by: PageCaptureFeature.scrollSettleDelay)
		await store.receive(\.inspect) { $0.inspectionGeneration = 2 }
	}

	@Test
	internal func atThePagesEndTheScrollStopsAndAnAreaOnScreenComesFromTheViewport() async throws {
		let clock = TestClock()
		let frame = try Fixtures.frame()
		let store = TestStore(initialState: drawingState()) { PageCaptureFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.browserCapture.scrollAuthorized = { _, _, _ in .zero }
			$0.browserCapture.captureAuthorized = { request, _ in
				#expect(request == Fixtures.request)
				return frame
			}
		}

		await store.send(.ui(.dragChanged(from: start, to: nearBottom))) {
			$0.drawingGeneration = 1
			$0.drawing = .init(start: self.start, pointer: self.nearBottom, isTicking: true)
			$0.drag = .init(x: 10, y: 10, width: 20, height: 29)
		}
		await clock.advance(by: PageCaptureFeature.autoscrollInterval)
		await store.receive(\.event.autoscrollTick) { $0.drawing?.isScrolling = true }
		await store.receive(\.event.autoscrolled) {
			$0.drawing?.isScrolling = false
			$0.drawing?.isTicking = false
		}

		// Nothing ticks until the pointer moves again.
		await clock.advance(by: .milliseconds(100))

		await store.send(.ui(.dragEnded(from: start, to: nearBottom))) {
			$0.drawing = nil
			$0.drag = nil
		}
		let region = PageCaptureRegion(x: 10, y: 10, width: 20, height: 29)
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = region
		}
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = try PageCaptureCodec.crop(frame, to: region)
		}
	}

	/// A scroll that never ran, refused as busy, on a pinched page or on a `file:` page the engine
	/// runs no scripts in, keeps the drag: it draws on within the viewport and is taken from it.
	@Test(arguments: [PageCaptureFailure.busy, .unavailable])
	internal func aScrollThatNeverRanKeepsDrawingWithinTheViewport(failure: PageCaptureFailure) async throws {
		let clock = TestClock()
		let frame = try Fixtures.frame()
		let store = TestStore(initialState: drawingState()) { PageCaptureFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.browserCapture.scrollAuthorized = { _, _, _ in throw failure }
			$0.browserCapture.captureAuthorized = { _, _ in frame }
		}

		await store.send(.ui(.dragChanged(from: start, to: nearBottom))) {
			$0.drawingGeneration = 1
			$0.drawing = .init(start: self.start, pointer: self.nearBottom, isTicking: true)
			$0.drag = .init(x: 10, y: 10, width: 20, height: 29)
		}
		await clock.advance(by: PageCaptureFeature.autoscrollInterval)
		await store.receive(\.event.autoscrollTick) { $0.drawing?.isScrolling = true }
		await store.receive(\.event.autoscrollFailed) {
			$0.autoscrollAvailable = false
			$0.drawing?.isScrolling = false
			$0.drawing?.isTicking = false
		}
		await store.send(.ui(.dragChanged(from: start, to: .init(x: 30, y: 38)))) {
			$0.drawing?.pointer = .init(x: 30, y: 38)
			$0.drag = .init(x: 10, y: 10, width: 20, height: 28)
		}
		await store.send(.ui(.dragEnded(from: start, to: .init(x: 30, y: 38)))) {
			$0.drawing = nil
			$0.drag = nil
		}
		let region = PageCaptureRegion(x: 10, y: 10, width: 20, height: 28)
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = region
		}
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = try PageCaptureCodec.crop(frame, to: region)
		}
	}

	/// A scroll that timed out may have moved the page anyway, so the area drawn so far is dropped.
	@Test
	internal func aScrollThatMayHaveMovedDropsTheAreaAndSaysSo() async throws {
		let clock = TestClock()
		let store = TestStore(initialState: drawingState()) { PageCaptureFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.browserCapture.scrollAuthorized = { _, _, _ in throw PageCaptureFailure.timedOut }
		}

		await store.send(.ui(.dragChanged(from: start, to: nearBottom))) {
			$0.drawingGeneration = 1
			$0.drawing = .init(start: self.start, pointer: self.nearBottom, isTicking: true)
			$0.drag = .init(x: 10, y: 10, width: 20, height: 29)
		}
		await clock.advance(by: PageCaptureFeature.autoscrollInterval)
		await store.receive(\.event.autoscrollTick) { $0.drawing?.isScrolling = true }
		await store.receive(\.event.autoscrollFailed) {
			$0.autoscrollAvailable = false
			$0.drawing = nil
			$0.drag = nil
			$0.droppedDragStart = self.start
			$0.message = String.localized(.appUI.capture.scrollLost)

			// The blocks may have moved with the page, so they're read again.
			$0.inspectionGeneration = 1
		}

		// The rest of that drag draws and takes nothing.
		await store.send(.ui(.dragChanged(from: start, to: .init(x: 30, y: 30))))
		await store.send(.ui(.dragEnded(from: start, to: .init(x: 30, y: 30)))) { $0.droppedDragStart = nil }

		// The next drag draws within the viewport, without scrolling.
		await store.send(.ui(.dragChanged(from: .init(x: 5, y: 5), to: .init(x: 30, y: 30)))) {
			$0.drag = .init(x: 5, y: 5, width: 25, height: 25)
		}
		await clock.advance(by: PageCaptureFeature.scrollSettleDelay)
		await store.receive(\.inspect) { $0.inspectionGeneration = 2 }
	}

	/// A drag let go while its scroll was out, whose scroll then failed, leaves nothing behind:
	/// the next drag from the same point draws and takes its area.
	@Test
	internal func aLostScrollAfterReleaseDoesntSwallowTheNextDrag() async throws {
		let clock = TestClock()
		let frame = try Fixtures.frame()
		let store = TestStore(initialState: drawingState()) { PageCaptureFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.browserCapture.scrollAuthorized = { _, _, _ in
				try await clock.sleep(for: .milliseconds(5))
				throw PageCaptureFailure.timedOut
			}
			$0.browserCapture.captureAuthorized = { _, _ in frame }
		}

		await store.send(.ui(.dragChanged(from: start, to: nearBottom))) {
			$0.drawingGeneration = 1
			$0.drawing = .init(start: self.start, pointer: self.nearBottom, isTicking: true)
			$0.drag = .init(x: 10, y: 10, width: 20, height: 29)
		}
		await clock.advance(by: PageCaptureFeature.autoscrollInterval)
		await store.receive(\.event.autoscrollTick) { $0.drawing?.isScrolling = true }
		await store.send(.ui(.dragEnded(from: start, to: nearBottom))) {
			$0.drawing?.end = self.nearBottom
			$0.drawing?.isTicking = false
		}
		await clock.advance(by: .milliseconds(5))
		await store.receive(\.event.autoscrollFailed) {
			$0.autoscrollAvailable = false
			$0.drawing = nil
			$0.drag = nil
			$0.message = String.localized(.appUI.capture.scrollLost)
			$0.inspectionGeneration = 1
		}

		let next = CGPoint(x: 30, y: 30)
		await store.send(.ui(.dragChanged(from: start, to: next))) {
			$0.drag = .init(x: 10, y: 10, width: 20, height: 20)
		}
		await store.send(.ui(.dragEnded(from: start, to: next))) { $0.drag = nil }
		let region = PageCaptureRegion(x: 10, y: 10, width: 20, height: 20)
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = region
			$0.message = nil
		}
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = try PageCaptureCodec.crop(frame, to: region)
		}
		await clock.advance(by: PageCaptureFeature.scrollSettleDelay)
		await store.receive(\.inspect) { $0.inspectionGeneration = 2 }
	}

	/// A page that changed mid-drag is prepared again, and the drawing and its scrolling stop.
	@Test
	internal func aStalePageMidDragStopsTheScrolling() async throws {
		let clock = TestClock()
		let store = TestStore(initialState: drawingState()) { PageCaptureFeature() } withDependencies: {
			$0.continuousClock = clock
		}

		await store.send(.ui(.dragChanged(from: start, to: nearBottom))) {
			$0.drawingGeneration = 1
			$0.drawing = .init(start: self.start, pointer: self.nearBottom, isTicking: true)
			$0.drag = .init(x: 10, y: 10, width: 20, height: 29)
		}
		await store.send(.event(.inspectionFailed(0, isStale: true))) {
			$0.staleRetries = 1
			$0.drawing = nil
			$0.drag = nil
		}
		await store.receive(\.delegate.retake)

		// No tick comes.
		await clock.advance(by: .milliseconds(200))
	}

	/// Return doesn't take a block while an area is being drawn.
	@Test
	internal func returnWaitsForTheDrawing() async throws {
		let clock = TestClock()
		let paragraph = PageCaptureTarget(index: 1, role: "paragraph", bounds: .init(x: 0, y: 0, width: 20, height: 20))
		var state = drawingState()
		state.targets = [paragraph]
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.continuousClock = clock
		}

		await store.send(.ui(.dragChanged(from: start, to: nearBottom))) {
			$0.drawingGeneration = 1
			$0.drawing = .init(start: self.start, pointer: self.nearBottom, isTicking: true)
			$0.drag = .init(x: 10, y: 10, width: 20, height: 29)
		}

		// The arrow keys can still highlight a block mid-drag.
		await store.send(.ui(.move(.next))) { $0.highlighted = paragraph }
		await store.send(.ui(.commit))
		await store.send(.ui(.cancel)) {
			$0.generation = 1
			$0.inspectionGeneration = 1
		}
		await store.receive(\.delegate.dismiss)
	}

	@Test
	internal func escapeWhileDrawingStopsTheScroll() async throws {
		let clock = TestClock()
		let store = TestStore(initialState: drawingState()) { PageCaptureFeature() } withDependencies: {
			$0.continuousClock = clock
		}

		await store.send(.ui(.dragChanged(from: start, to: nearBottom))) {
			$0.drawingGeneration = 1
			$0.drawing = .init(start: self.start, pointer: self.nearBottom, isTicking: true)
			$0.drag = .init(x: 10, y: 10, width: 20, height: 29)
		}
		await store.send(.ui(.cancel)) {
			$0.generation = 1
			$0.inspectionGeneration = 1
		}
		await store.receive(\.delegate.dismiss)
		await clock.advance(by: .seconds(1))
	}

	@Test(arguments: ["all", "no flag", "no whole page", "no scrolling"])
	internal func drawingScrollsOnlyWithTheFlagTheWholePageAndScrolling(missing: String) async {
		let flag = missing != "no flag"
		let wholePage = missing != "no whole page"
		let scroll = missing != "no scrolling"
		var state = Fixtures.state()
		state.inspection = nil
		state.capturesBeyondViewport = flag
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.wholePageIsAvailable = { wholePage }
			$0.browserCapture.scrollIsAvailable = { scroll }
		}

		await store.send(.prepared) {
			$0.phase = .selecting
			$0.wholePageAvailable = wholePage
			$0.fullPageAvailable = wholePage
			$0.autoscrollAvailable = flag && wholePage && scroll
		}
		await store.receive(\.inspect) { $0.inspectionGeneration = 1 }
	}

	@Test
	internal func capturePagesFrameShowsTheWholePageScaledToFit() async throws {
		var state = Fixtures.state(mode: .page)
		state.inspection = nil
		state.capturesBeyondViewport = true
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.wholePageIsAvailable = { true }
			$0.browserCapture.captureAuthorized = { request, _ in try Self.wholePage(request) }
		}

		await store.send(.prepared) {
			$0.wholePageAvailable = true
			$0.fullPageAvailable = true
			$0.isFullPage = true
			$0.request?.mode = .fullDocument
			$0.request?.beyondViewport = true
			$0.request?.limits = .wholePage
		}
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = $0.viewport
		}
		await store.receive(\.inspect) { $0.inspectionGeneration = 1 }
		let frame = try Self.wholePage(Self.wholePageRequest)
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = frame.image

			// The 40 × 100 point page, not the 40 × 40 viewport it was taken from.
			$0.selection = PageCaptureGeometry.capturedFrame(
				for: .init(x: 0, y: 0, width: 40, height: 100),
				viewport: $0.viewport
			)
		}
		let selection = try #require(store.state.selection)
		#expect(selection.height / selection.width == 2.5)
	}

	private static var wholePageRequest: PageCaptureRequest {
		var request = Fixtures.request
		request.mode = .fullDocument
		request.beyondViewport = true
		request.limits = .wholePage
		return request
	}

	private func drawingState() -> PageCaptureFeature.State {
		var state = Fixtures.state(phase: .selecting)
		state.inspection = nil
		state.capturesBeyondViewport = true
		state.autoscrollAvailable = true
		state.wholePageAvailable = true
		return state
	}

	/// A whole 40 × 100 point page at 2×, scrolled 20 points down: red for its first 50 points,
	/// blue below.
	private static func wholePage(_ request: PageCaptureRequest) throws -> PageCaptureFrame {
		let image = try Fixtures.png(width: 80, height: 200) { _, y in
			y < 100 ? Fixtures.quadrants[0] : Fixtures.quadrants[2]
		}
		return .init(
			request: request,
			documentID: "document-1",
			image: image,
			viewportWidth: 40,
			viewportHeight: 40,
			deviceScale: 2,
			wasLoading: false,
			documentGeometry: .init(
				documentRect: .init(x: 0, y: 0, width: 80, height: 200),
				visibleRect: .init(x: 0, y: 40, width: 80, height: 80),
				scrollX: 0,
				scrollY: 40,
				zoomLevel: 0,
				pageScale: 1,
				rasterScale: 1
			)
		)
	}
}
