import AppUI
import CoreGraphics
import Testing

/// A drag from a floating window's header controls moves the window, and its release never
/// triggers the control (DEV-1247).
@Suite
internal struct WindowControlDragTests {
	@Test
	internal func aClickWithoutMovementReachesTheControl() {
		var drag = WindowControlDrag()

		#expect(drag.mouseDown(at: .init(x: 100, y: 100), onHeader: true) == .deliver)
		#expect(drag.mouseDragged(to: .init(x: 102, y: 101)) == .deliver)
		#expect(drag.mouseUp() == .deliver)
		#expect(!drag.isTracking)
	}

	@Test
	internal func aDragPastTheThresholdMovesTheWindowFromWhereThePressStarted() {
		var drag = WindowControlDrag()

		_ = drag.mouseDown(at: .init(x: 100, y: 100), onHeader: true)
		#expect(drag.mouseDragged(to: .init(x: 100 + WindowControlDrag.threshold, y: 100)) == .startDrag(from: .init(x: 100, y: 100)))
		// The rest of the drag and its release belong to the window.
		#expect(drag.mouseDragged(to: .init(x: 140, y: 120)) == .drop)
		#expect(drag.mouseUp() == .drop)
		#expect(!drag.isTracking)
	}

	@Test
	internal func theThresholdCountsDiagonalDistance() {
		var drag = WindowControlDrag()

		_ = drag.mouseDown(at: .zero, onHeader: true)
		#expect(drag.mouseDragged(to: .init(x: 2, y: 2)) == .deliver)
		#expect(drag.mouseDragged(to: .init(x: 3, y: 3)) == .startDrag(from: .zero))
	}

	@Test
	internal func aPressOffTheHeaderIsLeftAlone() {
		var drag = WindowControlDrag()

		_ = drag.mouseDown(at: .zero, onHeader: false)
		#expect(drag.mouseDragged(to: .init(x: 200, y: 0)) == .deliver)
		#expect(drag.mouseUp() == .deliver)
	}

	@Test
	internal func theNextPressAfterADragIsAClickAgain() {
		var drag = WindowControlDrag()

		_ = drag.mouseDown(at: .zero, onHeader: true)
		_ = drag.mouseDragged(to: .init(x: 20, y: 0))

		// The window's move loop took the release, so none arrives here.
		#expect(drag.mouseDown(at: .init(x: 50, y: 50), onHeader: true) == .deliver)
		#expect(drag.mouseUp() == .deliver)
	}

	@Test
	internal func aNewPressForgetsAnUnfinishedOne() {
		var drag = WindowControlDrag()

		_ = drag.mouseDown(at: .zero, onHeader: true)
		_ = drag.mouseDown(at: .init(x: 500, y: 500), onHeader: false)
		#expect(drag.mouseDragged(to: .init(x: 40, y: 0)) == .deliver)
		#expect(!drag.isTracking)
	}
}
