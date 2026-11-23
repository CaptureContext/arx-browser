import BrowserCaptureClient
import BrowserCore
import CustomDump
import Foundation
import PageCaptureFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct PageCaptureFeatureTests {
	private typealias Fixtures = PageCaptureFixtures

	private let paragraph = PageCaptureTarget(index: 1, parent: 0, role: "paragraph", bounds: .init(x: 0, y: 0, width: 20, height: 20))
	private let image = PageCaptureTarget(index: 2, parent: 0, role: "image", bounds: .init(x: 20, y: 20, width: 20, height: 20))

	@Test
	internal func areaReadsNodeBoundsInWindowsThenHoverAndClickCaptureTheBlock() async throws {
		let frame = try Fixtures.frame()
		var windows: [Int] = []
		var revoked: [UUID] = []
		let store = TestStore(initialState: Fixtures.state()) { PageCaptureFeature() } withDependencies: {
			$0.pageCaptureInspection.isAvailable = { true }
			$0.pageCaptureInspection.inspectAuthorized = { request, source, authorize in
				#expect(authorize() && request.includesBounds && source == Fixtures.inspection)
				windows.append(request.windowStart)
				return request.windowStart == 0
				? Fixtures.snapshot([Fixtures.node(0, role: "rootWebArea", 0, 0, 40, 40), Fixtures.node(1, parent: 0, 0, 0, 20, 20)], total: 3)
				: Fixtures.snapshot([Fixtures.node(2, parent: 0, role: "image", 20, 20, 20, 20)], windowStart: 2, total: 3)
			}
			$0.pageCaptureInspection.revokeScope = { revoked.append($0) }
			$0.browserCapture.captureAuthorized = { request, authorize in
				#expect(authorize() && request == Fixtures.request)
				return frame
			}
		}

		await store.send(.prepared) { $0.phase = .selecting }
		await store.receive(\.inspect) { $0.inspectionGeneration = 1 }
		await store.receive(\.event.inspected) {
			$0.candidates = [self.paragraph, self.image]
			$0.targets = [self.paragraph, self.image]
		}
		expectNoDifference(windows, [0, 2])
		expectNoDifference(revoked, [Fixtures.inspection.scopeID])

		await store.send(.ui(.pointerMoved(.init(x: 25, y: 30)))) { $0.highlighted = self.image }
		await store.send(.ui(.pointerMoved(.init(x: 26, y: 31))))
		await store.send(.ui(.clicked(.init(x: 25, y: 30))))
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = self.image.bounds
		}
		let cropped = try PageCaptureCodec.crop(frame, to: image.bounds)
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = cropped
			$0.highlighted = nil
		}

		// Retina: 20 points of a 2× capture are 40 pixels, all from the bottom-right quadrant.
		#expect(cropped.width == 40 && cropped.height == 40)
		#expect(try Fixtures.color(of: cropped, x: 0, y: 0) == Fixtures.quadrants[3])
		#expect(try Fixtures.color(of: cropped, x: 39, y: 39) == Fixtures.quadrants[3])
		await store.finish()
	}

	@Test
	internal func dragCapturesTheDrawnAreaAtRetinaScale() async throws {
		let frame = try Fixtures.frame()
		var state = Fixtures.state(phase: .selecting)
		state.highlighted = paragraph
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.captureAuthorized = { _, _ in frame }
		}

		await store.send(.ui(.dragChanged(from: .init(x: 30, y: 30), to: .init(x: 10, y: 5)))) {
			$0.highlighted = nil
			$0.drag = .init(x: 10, y: 5, width: 20, height: 25)
		}
		await store.send(.ui(.dragEnded(from: .init(x: 30, y: 30), to: .init(x: 10, y: 5)))) { $0.drag = nil }
		let region = PageCaptureRegion(x: 10, y: 5, width: 20, height: 25)
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

		let image = try #require(store.state.image)
		#expect(image.width == 40 && image.height == 50)
		// The area spans all four quadrants; its corners show each one.
		#expect(try Fixtures.color(of: image, x: 0, y: 0) == Fixtures.quadrants[0])
		#expect(try Fixtures.color(of: image, x: 39, y: 0) == Fixtures.quadrants[1])
		#expect(try Fixtures.color(of: image, x: 0, y: 49) == Fixtures.quadrants[2])
		#expect(try Fixtures.color(of: image, x: 39, y: 49) == Fixtures.quadrants[3])
	}

	@Test
	internal func visibleAreaCapturesStraightAwayAroundTheViewport() async throws {
		let frame = try Fixtures.frame()
		var state = Fixtures.state(mode: .visible)
		state.inspection = nil
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.captureAuthorized = { _, _ in frame }
		}

		await store.send(.prepared)
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = $0.viewport
		}
		await store.receive(\.inspect) { $0.inspectionGeneration = 1 }
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = frame.image
		}
	}

	@Test
	internal func aCaptureFromTheChatGoesStraightToIt() async throws {
		let frame = try Fixtures.frame()
		var state = Fixtures.state(mode: .visible)
		state.inspection = nil
		state.allowsSendingToChat = true
		state.destination = .chat
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.captureAuthorized = { _, _ in frame }
		}

		await store.send(.prepared)
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = $0.viewport
		}
		await store.receive(\.inspect) { $0.inspectionGeneration = 1 }
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = frame.image
		}
		await store.receive(\.ui.sendToChat) { $0.isWorking = true }
		await store.receive(\.delegate.sendToChat)
		await store.receive(\.delegate.dismiss)
	}

	@Test
	internal func sendToChatNeedsTheHostsAllowance() async throws {
		let frame = try Fixtures.frame()
		var captured = Fixtures.state(phase: .captured)
		captured.frame = frame
		captured.image = frame.image
		let store = TestStore(initialState: captured) { PageCaptureFeature() }

		// A private window's page, or one in Little Arx, has no chat to send to.
		await store.send(.ui(.sendToChat))

		await store.send(.ui(.cancel)) {
			$0.generation = 1
			$0.inspectionGeneration = 1
		}
		await store.receive(\.delegate.dismiss)
	}

	@Test
	internal func copyEditAndSaveFinishTheCapture() async throws {
		let frame = try Fixtures.frame()
		var captured = Fixtures.state(phase: .captured)
		captured.frame = frame
		captured.image = frame.image
		captured.selection = captured.viewport
		var copied: [PageCaptureImage] = []
		var edited: [String] = []
		var saved: [PageCaptureFormat] = []
		let destination = URL(filePath: "/tmp/page.png")

		let store = TestStore(initialState: captured) { PageCaptureFeature() } withDependencies: {
			$0.pageCaptureExport.copy = { copied.append($0) }
			$0.pageCaptureExport.edit = { _, title in edited.append(title) }
			$0.pageCaptureExport.save = { _, format, _ in
				saved.append(format)
				return destination
			}
		}

		await store.send(.ui(.copy)) { $0.isWorking = true }
		await store.receive(\.event.finished) { $0.isWorking = false }
		await store.receive(\.delegate.dismiss)

		await store.send(.ui(.edit)) { $0.isWorking = true }
		await store.receive(\.event.finished) { $0.isWorking = false }
		await store.receive(\.delegate.dismiss)

		await store.send(.ui(.save)) { $0.isWorking = true }
		await store.receive(\.event.saved) { $0.isWorking = false }
		await store.receive(\.delegate.dismiss)

		expectNoDifference(copied, [frame.image])
		expectNoDifference(edited, ["Page"])
		expectNoDifference(saved, [.png])
	}

	@Test
	internal func cancelingTheSavePanelKeepsTheFrameAndMenu() async throws {
		let frame = try Fixtures.frame()
		var captured = Fixtures.state(phase: .captured)
		captured.image = frame.image
		captured.selection = captured.viewport
		let store = TestStore(initialState: captured) { PageCaptureFeature() } withDependencies: {
			$0.pageCaptureExport.save = { _, _, _ in nil }
		}

		await store.send(.ui(.save)) { $0.isWorking = true }
		await store.receive(\.event.saved) { $0.isWorking = false }
		#expect(store.state.phase == .captured)
	}

	@Test
	internal func retakeAsksForAFreshRevisionToPickAnArea() async throws {
		var captured = Fixtures.state(mode: .visible, phase: .captured)
		captured.image = try Fixtures.frame().image
		let store = TestStore(initialState: captured) { PageCaptureFeature() }

		await store.send(.ui(.retake)) { $0.mode = .area }
		await store.receive(\.delegate.retake)
	}

	@Test
	internal func escapeCancelsAtAnyPoint() async throws {
		let store = TestStore(initialState: Fixtures.state(phase: .selecting)) { PageCaptureFeature() }

		await store.send(.ui(.cancel)) {
			$0.generation = 1
			$0.inspectionGeneration = 1
		}
		await store.receive(\.delegate.dismiss)
	}

	@Test
	internal func clickingAwayFromTheFrameEndsTheCapture() async throws {
		var captured = Fixtures.state(phase: .captured)
		captured.selection = .init(x: 0, y: 0, width: 20, height: 20)
		let store = TestStore(initialState: captured) { PageCaptureFeature() }

		await store.send(.ui(.clicked(.init(x: 10, y: 10))))
		await store.send(.ui(.clicked(.init(x: 30, y: 30))))
		await store.receive(\.ui.cancel) {
			$0.generation = 1
			$0.inspectionGeneration = 1
		}
		await store.receive(\.delegate.dismiss)
	}

	@Test
	internal func arrowKeysMoveTheHighlightAndReturnCapturesIt() async throws {
		let frame = try Fixtures.frame()
		var state = Fixtures.state(phase: .selecting)
		let section = PageCaptureTarget(index: 0, role: "section", bounds: .init(x: 0, y: 0, width: 30, height: 30))
		state.targets = [section, paragraph]
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.captureAuthorized = { _, _ in frame }
		}

		await store.send(.ui(.move(.next))) { $0.highlighted = section }
		await store.send(.ui(.move(.child))) { $0.highlighted = self.paragraph }
		await store.send(.ui(.move(.parent))) { $0.highlighted = section }
		await store.send(.ui(.commit))
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = section.bounds
		}
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = try PageCaptureCodec.crop(frame, to: section.bounds)
			$0.highlighted = nil
		}
	}

	@Test
	internal func scrollingDropsStaleBoundsAndReadsThemOnceItSettles() async throws {
		let clock = TestClock()
		var state = Fixtures.state(phase: .selecting)
		state.candidates = [paragraph]
		state.targets = [paragraph]
		state.highlighted = paragraph
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageCaptureInspection.isAvailable = { true }
			$0.pageCaptureInspection.inspectAuthorized = { _, _, _ in
				Fixtures.snapshot([Fixtures.node(0, role: "image", 20, 20, 20, 20)], total: 1)
			}
		}

		await store.send(.ui(.scrolled)) {
			$0.highlighted = nil
			$0.candidates = []
			$0.targets = []
			$0.inspectionGeneration = 1
		}
		await store.send(.ui(.scrolled)) { $0.inspectionGeneration = 2 }
		await clock.advance(by: PageCaptureFeature.scrollSettleDelay)
		await store.receive(\.inspect) { $0.inspectionGeneration = 3 }
		let moved = PageCaptureTarget(index: 0, role: "image", bounds: .init(x: 20, y: 20, width: 20, height: 20))
		await store.receive(\.event.inspected) {
			$0.candidates = [moved]
			$0.targets = [moved]
		}
	}

	@Test
	internal func withoutNodeBoundsDrawingStillWorks() async throws {
		let store = TestStore(initialState: Fixtures.state()) { PageCaptureFeature() } withDependencies: {
			$0.pageCaptureInspection.isAvailable = { false }
		}

		await store.send(.prepared) { $0.phase = .selecting }
		await store.receive(\.inspect) { $0.inspectionGeneration = 1 }
		await store.receive(\.event.inspectionFailed)
		#expect(store.state.targets.isEmpty && store.state.phase == .selecting)
	}

	@Test
	internal func aPageThatChangedGetsAFreshRevisionTwiceAtMost() async throws {
		let store = TestStore(initialState: Fixtures.state(phase: .selecting)) { PageCaptureFeature() } withDependencies: {
			$0.pageCaptureAuthorization.authorize = { _, _ in false }
		}
		store.exhaustivity = .off

		for attempt in 1...3 {
			await store.send(.capture(.init(x: 0, y: 0, width: 10, height: 10)))
			await store.receive(\.event.failed)
			if attempt <= 2 { await store.receive(\.delegate.retake) }
			#expect(store.state.staleRetries == min(attempt, 2))
			#expect(store.state.phase == .selecting && store.state.message != nil)
		}
	}

	@Test
	internal func protectedMediaNoteAppearsOnlyWhenMediaCameOutBlank() async throws {
		let video = PageCaptureTarget(index: 3, role: "video", bounds: .init(x: 0, y: 0, width: 20, height: 20))

		// The top-left quadrant, where the video sits, is black in one capture and red in the other.
		for isBlank in [true, false] {
			let frame = try Fixtures.frame(warnings: [.protectedMediaMayBeMissing]) { x, y in
				x < 40 && y < 40 ? (isBlank ? [0, 0, 0] : [255, 0, 0]) : [255, 255, 255]
			}
			var state = Fixtures.state(phase: .selecting)
			state.candidates = [video]
			let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
				$0.browserCapture.captureAuthorized = { _, _ in frame }
			}
			store.exhaustivity = .off

			await store.send(.capture(nil))
			await store.receive(\.event.captured)
			await store.receive(\.event.mediaChecked)
			#expect(store.state.showsProtectedMediaNote == isBlank)
		}
	}

	@Test
	internal func fullPageReplacesTheImageAndKeepsTheFrameOnTheViewport() async throws {
		let viewport = try Fixtures.frame()
		let document = try Fixtures.frame(mode: .fullDocument)
		var captured = Fixtures.state(mode: .visible, phase: .captured)
		captured.frame = viewport
		captured.image = viewport.image
		captured.selection = captured.viewport
		captured.fullPageAvailable = true
		let store = TestStore(initialState: captured) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.captureAuthorized = { request, _ in
				#expect(request.mode == .fullDocument)
				return document
			}
		}

		await store.send(.ui(.captureFullPage)) {
			$0.isFullPage = true
			$0.request?.mode = .fullDocument
		}
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
		}
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = document
			$0.image = document.image
		}
		#expect(store.state.image?.height == 80)
	}

	@Test
	internal func fullPageNeedsTheEngineToCaptureDocuments() async throws {
		var state = Fixtures.state(mode: .visible)
		state.inspection = nil
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.fullDocumentIsAvailable = { false }
			$0.browserCapture.captureAuthorized = { _, _ in try Fixtures.frame() }
		}
		store.exhaustivity = .off

		await store.send(.prepared)
		await store.receive(\.event.captured)
		#expect(!store.state.fullPageAvailable)
		await store.send(.ui(.captureFullPage))
		#expect(!store.state.isFullPage && store.state.request?.mode == .viewport)
	}

	/// DEV-1172: an engine that renders whole pages beyond the viewport takes Capture Page, with its
	/// own limits; a page cut at them says where.
	@Test
	internal func capturePagePrefersTheWholePageBeyondTheViewport() async throws {
		var document = try Fixtures.frame(mode: .fullDocument)
		document.isCut = true
		var state = Fixtures.state(mode: .page)
		state.inspection = nil
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.wholePageIsAvailable = { true }
			$0.browserCapture.fullDocumentIsAvailable = { false }
			$0.browserCapture.captureAuthorized = { request, _ in
				#expect(request.mode == .fullDocument && request.beyondViewport)
				#expect(request.limits == .wholePage)
				var frame = document
				frame.request = request
				return frame
			}
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
		var expected = document
		expected.request.mode = .fullDocument
		expected.request.beyondViewport = true
		expected.request.limits = .wholePage
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = expected
			$0.image = document.image
		}

		// 80 pixels at 2× are 40 points.
		expectNoDifference(store.state.cutPoints, 40)
		expectNoDifference(store.state.menuMessage, "Too long to capture whole. Cut at 40 points.")
	}

	/// DEV-1172: a whole page the engine can't render, with DevTools open say, falls back to
	/// ABI16's recorded document before the visible area.
	@Test
	internal func aWholePageThatFailsFallsBackToTheRecordedDocument() async throws {
		let document = try Fixtures.frame(mode: .fullDocument)
		var state = Fixtures.state(mode: .page)
		state.inspection = nil
		let requests = LockIsolated<[PageCaptureRequest]>([])
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.wholePageIsAvailable = { true }
			$0.browserCapture.fullDocumentIsAvailable = { true }
			$0.browserCapture.captureAuthorized = { request, _ in
				requests.withValue { $0.append(request) }
				guard !request.beyondViewport
				else { throw PageCaptureFailure.unsupportedRendering }

				var frame = document
				frame.request = request
				return frame
			}
		}
		store.exhaustivity = .off

		await store.send(.prepared)
		await store.receive(\.event.wholePageFailed)
		await store.receive(\.event.captured)
		expectNoDifference(requests.value.map(\.beyondViewport), [true, false])
		expectNoDifference(requests.value.map(\.mode), [.fullDocument, .fullDocument])
		expectNoDifference(requests.value.last?.limits, PageCaptureLimits())
		#expect(store.state.isFullPage && store.state.fullPageAvailable)
		#expect(!store.state.wholePageAvailable && store.state.visibleAreaReason == nil)
	}

	/// A failed whole page goes back to the viewport's request, so a pick isn't the whole page.
	@Test
	internal func aFailedWholePageGoesBackToTheViewportRequest() async throws {
		var state = Fixtures.state(mode: .page)
		state.inspection = nil
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.wholePageIsAvailable = { true }
			$0.browserCapture.captureAuthorized = { _, _ in throw PageCaptureFailure.busy }
		}
		store.exhaustivity = .off

		await store.send(.prepared)
		await store.receive(\.event.failed)
		#expect(store.state.request == Fixtures.request)
		#expect(!store.state.isFullPage && store.state.phase == .selecting)
	}

	@Test
	internal func capturePageTakesTheWholePageStraightAway() async throws {
		let document = try Fixtures.frame(mode: .fullDocument)
		var state = Fixtures.state(mode: .page)
		state.inspection = nil
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.fullDocumentIsAvailable = { true }
			$0.browserCapture.captureAuthorized = { request, _ in
				#expect(request.mode == .fullDocument)
				return document
			}
		}

		await store.send(.prepared) {
			$0.fullPageAvailable = true
			$0.documentAvailable = true
			$0.isFullPage = true
			$0.request?.mode = .fullDocument
		}
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = $0.viewport
		}
		await store.receive(\.inspect) { $0.inspectionGeneration = 1 }
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = document
			$0.image = document.image
		}

		// The image is the document's whole height: 80 points, twice the 40-point viewport.
		#expect(store.state.frame?.imagePointHeight == 80)
		#expect(store.state.message == nil)
	}

	@Test(arguments: [
		(PageCaptureFailure.limitExceeded, "Too long to capture whole. Captured the visible area."),
		(.unsupportedRendering, "Can't capture this page whole. Captured the visible area."),
		(.invalidImage, "Can't capture this page whole. Captured the visible area."),
	])
	internal func aPageTheEngineCantCaptureWholeGetsItsVisibleAreaAndSaysWhy(
		failure: PageCaptureFailure,
		note: String
	) async throws {
		let viewport = try Fixtures.frame()
		var requested: [PageCaptureMode] = []
		var state = Fixtures.state(mode: .page)
		state.inspection = nil
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.fullDocumentIsAvailable = { true }
			$0.browserCapture.captureAuthorized = { request, _ in
				requested.append(request.mode)
				guard request.mode == .viewport else { throw failure }
				return viewport
			}
		}

		await store.send(.prepared) {
			$0.fullPageAvailable = true
			$0.documentAvailable = true
			$0.isFullPage = true
			$0.request?.mode = .fullDocument
		}
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = $0.viewport
		}
		await store.receive(\.inspect) { $0.inspectionGeneration = 1 }
		await store.receive(\.event.wholePageFailed) {
			$0.isFullPage = false
			$0.fullPageAvailable = false
			$0.visibleAreaReason = failure
			$0.request?.mode = .viewport
		}
		await store.receive(\.capture) { $0.generation = 2 }
		await store.receive(\.inspect) { $0.inspectionGeneration = 2 }
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = viewport
			$0.image = viewport.image
		}
		expectNoDifference(requested, [.fullDocument, .viewport])
		expectNoDifference(store.state.menuMessage, note)
	}

	/// The note on a visible-area frame outlasts a canceled Save, which clears the last failure.
	@Test
	internal func theVisibleAreaNoteOutlastsACanceledSave() async throws {
		let viewport = try Fixtures.frame()
		var captured = Fixtures.state(mode: .page, phase: .captured)
		captured.frame = viewport
		captured.image = viewport.image
		captured.selection = captured.viewport
		captured.visibleAreaReason = .limitExceeded
		captured.message = "A previous capture is still finishing. Try again in a moment."
		let store = TestStore(initialState: captured) { PageCaptureFeature() } withDependencies: {
			$0.pageCaptureExport.save = { _, _, _ in nil }
		}

		await store.send(.ui(.save)) {
			$0.isWorking = true
			$0.message = nil
		}
		await store.receive(\.event.saved) { $0.isWorking = false }
		expectNoDifference(store.state.menuMessage, "Too long to capture whole. Captured the visible area.")
	}

	@Test
	internal func capturePageTakesTheVisibleAreaWhenTheEngineCantCaptureDocuments() async throws {
		let viewport = try Fixtures.frame()
		var state = Fixtures.state(mode: .page)
		state.inspection = nil
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.fullDocumentIsAvailable = { false }
			$0.browserCapture.captureAuthorized = { request, _ in
				#expect(request.mode == .viewport)
				return viewport
			}
		}

		await store.send(.prepared)
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = $0.viewport
		}
		await store.receive(\.inspect) { $0.inspectionGeneration = 1 }
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = viewport
			$0.image = viewport.image
		}
	}

	/// A busy slot, or a timed-out document capture that holds the slot until its work drains,
	/// would fail the visible area too, so it's reported, not retried smaller. A block or an area
	/// picked next is cut from the viewport.
	@Test(arguments: [
		(PageCaptureFailure.busy, "A previous capture is still finishing. Try again in a moment."),
		(.timedOut, "The page did not finish capturing. Try again."),
	])
	internal func aBusyOrTimedOutCaptureDoesNotFallBackToTheVisibleArea(
		failure: PageCaptureFailure,
		message: String
	) async throws {
		var requested: [PageCaptureMode] = []
		var state = Fixtures.state(mode: .page)
		state.inspection = nil
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.fullDocumentIsAvailable = { true }
			$0.browserCapture.captureAuthorized = { request, _ in
				requested.append(request.mode)
				throw failure
			}
		}
		store.exhaustivity = .off

		await store.send(.prepared)
		await store.receive(\.event.failed)
		expectNoDifference(requested, [.fullDocument])
		#expect(store.state.visibleAreaReason == nil && store.state.image == nil)
		#expect(store.state.phase == .selecting && !store.state.isFullPage)
		#expect(store.state.request?.mode == .viewport)
		#expect(store.state.message == message)
	}

	@Test
	internal func resizingWhileSelectingReadsTheBlocksAgain() async throws {
		let clock = TestClock()
		var state = Fixtures.state(phase: .selecting)
		state.candidates = [paragraph]
		state.targets = [paragraph]
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.continuousClock = clock
		}
		store.exhaustivity = .off

		await store.send(.ui(.viewportChanged(.init(width: 60, height: 40))))
		await store.receive(\.ui.scrolled)
		#expect(store.state.targets.isEmpty && store.state.viewport.width == 60)
		await clock.advance(by: PageCaptureFeature.scrollSettleDelay)
		await store.receive(\.inspect)
	}

	@Test
	internal func boundsArrivingAfterAVisibleCaptureStillCheckProtectedMedia() async throws {
		let frame = try Fixtures.frame(warnings: [.protectedMediaMayBeMissing]) { x, y in
			x < 40 && y < 40 ? [0, 0, 0] : [255, 255, 255]
		}
		var captured = Fixtures.state(mode: .visible, phase: .captured)
		captured.frame = frame
		captured.image = frame.image
		captured.selection = captured.viewport
		captured.inspectionGeneration = 1
		let store = TestStore(initialState: captured) { PageCaptureFeature() }
		store.exhaustivity = .off

		let video = PageCaptureTarget(index: 3, role: "video", bounds: .init(x: 0, y: 0, width: 20, height: 20))
		await store.send(.event(.inspected(1, [video])))
		await store.receive(\.event.mediaChecked)
		#expect(store.state.showsProtectedMediaNote)
	}

	/// Back-to-back captures race to register their effects off the main actor. The newest
	/// capture must deliver its frame whichever effect registers first.
	@Test
	internal func backToBackCapturesDeliverTheNewestFrame() async throws {
		let frame = try Fixtures.frame()
		var lost = 0

		for _ in 0..<100 {
			let store = Store(initialState: Fixtures.state(phase: .selecting)) {
				PageCaptureFeature()
			} withDependencies: {
				$0.browserCapture.captureAuthorized = { _, _ in frame }
			}
			let older = store.send(.capture(nil))
			let newer = store.send(.capture(.init(x: 0, y: 0, width: 20, height: 20)))
			await older.finish()
			await newer.finish()

			if store.generation != 2 || store.phase != .captured || store.image?.width != 40 { lost += 1 }
		}

		#expect(lost == 0)
	}
}

/// DEV-757: the developer header's device capture frames the image it captures.
@MainActor
internal struct PageCaptureDeviceFramingTests {
	private typealias Fixtures = PageCaptureFixtures

	@Test
	internal func aDeviceCaptureFramesTheVisibleArea() async throws {
		let frame = try Fixtures.frame()
		let framed = PageCaptureImage(png: Data("framed".utf8), width: 120, height: 90)
		let style = DeviceCaptureStyle(isPortrait: false, gradient: 0.4, isDark: true)
		let framedWith = LockIsolated<[DeviceCaptureStyle]>([])
		var state = Fixtures.state(mode: .visible)
		state.inspection = nil
		state.framing = style
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.captureAuthorized = { _, _ in frame }
			$0.browserCapture.frame = { image, style in
				#expect(image == frame.image)
				framedWith.withValue { $0.append(style) }
				return framed
			}
		}

		await store.send(.prepared)
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = $0.viewport
		}
		await store.receive(\.inspect) { $0.inspectionGeneration = 1 }
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = framed
		}
		expectNoDifference(framedWith.value, [style])
	}

	@Test
	internal func portraitModeFramesAPhoneShapedSliceOfThePage() async throws {
		let frame = try Fixtures.frame()
		let viewport = PageCaptureRegion(x: 0, y: 0, width: 40, height: 40)

		// The capture keeps the part of the slice inside the viewport, as for any area.
		let slice = try #require(PageCaptureGeometry.intersection(DeviceCaptureStyle.portraitRegion(in: viewport), viewport))
		let expected = try PageCaptureCodec.crop(frame, to: slice)
		let framed = PageCaptureImage(png: Data("phone".utf8), width: 60, height: 120)
		var state = Fixtures.state(mode: .visible)
		state.inspection = nil
		state.framing = .init(isPortrait: true)
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.captureAuthorized = { _, _ in frame }
			$0.browserCapture.frame = { image, style in
				#expect(image == expected)
				#expect(image.width < image.height)
				#expect(style.isPortrait)
				return framed
			}
		}

		await store.send(.prepared)
		await store.receive(\.capture) {
			$0.phase = .capturing
			$0.generation = 1
			$0.selection = $0.viewport
		}
		await store.receive(\.inspect) { $0.inspectionGeneration = 1 }
		await store.receive(\.event.captured) {
			$0.phase = .captured
			$0.frame = frame
			$0.image = framed
			$0.selection = slice
		}
	}

	@Test
	internal func aWholePageIsFramedAsAWindowEvenInPortraitMode() async throws {
		let frame = try Fixtures.frame(mode: .fullDocument)
		let framedWith = LockIsolated<[DeviceCaptureStyle]>([])
		var state = Fixtures.state(mode: .visible, phase: .captured)
		state.inspection = nil
		state.image = try Fixtures.frame().image
		state.fullPageAvailable = true
		state.framing = .init(isPortrait: true, gradient: 0.1)
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.captureAuthorized = { _, _ in frame }
			$0.browserCapture.frame = { image, style in
				framedWith.withValue { $0.append(style) }
				return image
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.captureFullPage))
		await store.receive(\.event.captured)
		expectNoDifference(framedWith.value, [.init(isPortrait: false, gradient: 0.1)])
	}

	@Test
	internal func anOrdinaryCaptureIsNeverFramed() async throws {
		let frame = try Fixtures.frame()
		var state = Fixtures.state(mode: .visible)
		state.inspection = nil
		let store = TestStore(initialState: state) { PageCaptureFeature() } withDependencies: {
			$0.browserCapture.captureAuthorized = { _, _ in frame }
			$0.browserCapture.frame = { image, _ in
				Issue.record("Only a device capture is framed")
				return image
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.prepared)
		await store.receive(\.event.captured) { $0.image = frame.image }
	}
}
