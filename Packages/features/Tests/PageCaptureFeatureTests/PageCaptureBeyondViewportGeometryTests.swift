import BrowserCore
import CoreGraphics
import CustomDump
import Foundation
import PageCaptureFeature
import Testing

/// DEV-1208: the area a drag draws once the page scrolls under it, how fast it scrolls, where the
/// area sits in a whole page captured beyond the viewport, and where the captured frame goes.
internal struct PageCaptureBeyondViewportGeometryTests {
	private let viewport = PageCaptureRegion(x: 0, y: 0, width: 800, height: 600)

	// MARK: Drawn area

	@Test
	internal func anAreaDrawnWhileThePageScrolledDownReachesAboveTheViewport() {
		let region = PageCaptureGeometry.region(
			from: .init(x: 100, y: 200),
			to: .init(x: 300, y: 590),
			scrolled: .init(x: 0, y: 500),
			viewport: viewport
		)

		// Where the drag began moved up with the page, 300 points above the viewport.
		expectNoDifference(region, .init(x: 100, y: -300, width: 200, height: 890))
	}

	@Test
	internal func anAreaDrawnWhileThePageScrolledUpAndLeftReachesBelowAndBeside() {
		let region = PageCaptureGeometry.region(
			from: .init(x: 700, y: 100),
			to: .init(x: -40, y: -50),
			scrolled: .init(x: -300, y: -400),
			viewport: viewport
		)

		// The pointer past the top-left corner holds at it.
		expectNoDifference(region, .init(x: 0, y: 0, width: 1_000, height: 500))
	}

	@Test
	internal func beforeAnyScrollTheAreaIsTheDragClampedToTheViewport() {
		let start = CGPoint(x: 100, y: 200)
		let end = CGPoint(x: 900, y: 700)

		expectNoDifference(
			PageCaptureGeometry.region(from: start, to: end, scrolled: .zero, viewport: viewport),
			PageCaptureGeometry.region(from: start, to: end, viewport: viewport)
		)
		#expect(PageCaptureGeometry.region(from: start, to: start, scrolled: .zero, viewport: viewport) == nil)
	}

	@Test
	internal func anAreaFitsWhenItsAllOnScreen() {
		#expect(PageCaptureGeometry.fits(.init(x: 0, y: 0, width: 800, height: 600), in: viewport))
		#expect(PageCaptureGeometry.fits(.init(x: -0.2, y: 10, width: 800, height: 590.3), in: viewport))
		#expect(!PageCaptureGeometry.fits(.init(x: 0, y: -10, width: 100, height: 100), in: viewport))
		#expect(!PageCaptureGeometry.fits(.init(x: 0, y: 550, width: 100, height: 100), in: viewport))
	}

	// MARK: Speed

	@Test
	internal func thePageScrollsOnlyNearAnEdgeThePointerMovedToward() {
		let start = CGPoint(x: 400, y: 300)
		let middle = PageCaptureGeometry.autoscrollVelocity(from: start, to: .init(x: 420, y: 500), viewport: viewport)
		let down = PageCaptureGeometry.autoscrollVelocity(from: start, to: .init(x: 400, y: 580), viewport: viewport)
		let up = PageCaptureGeometry.autoscrollVelocity(from: start, to: .init(x: 400, y: 20), viewport: viewport)
		let right = PageCaptureGeometry.autoscrollVelocity(from: start, to: .init(x: 790, y: 300), viewport: viewport)

		// A drag that began at the bottom edge and moves up doesn't scroll down.
		let away = PageCaptureGeometry.autoscrollVelocity(
			from: .init(x: 400, y: 598),
			to: .init(x: 400, y: 590),
			viewport: viewport
		)

		#expect(middle == .zero)
		#expect(down.x == 0 && down.y > 0)
		#expect(up.x == 0 && up.y < 0)
		#expect(right.x > 0 && right.y == 0)
		#expect(away == .zero)
	}

	@Test
	internal func thePageScrollsFasterCloserToTheEdgeAndPastIt() {
		let start = CGPoint(x: 400, y: 300)
		let speeds: [Double] = [565, 580, 599, 650, 760, 2_000].map { y in
			PageCaptureGeometry.autoscrollVelocity(from: start, to: .init(x: 400, y: y), viewport: viewport).y
		}

		#expect(speeds.first! >= PageCaptureGeometry.autoscrollMinimumSpeed)
		#expect(zip(speeds, speeds.dropFirst()).dropLast().allSatisfy { $0 < $1 })
		#expect(speeds[4] == PageCaptureGeometry.autoscrollMaximumSpeed)
		#expect(speeds[5] == PageCaptureGeometry.autoscrollMaximumSpeed)
	}

	@Test
	internal func aSmallViewportsEdgeZoneIsAQuarterOfIt() {
		let small = PageCaptureRegion(x: 0, y: 0, width: 40, height: 40)
		let start = CGPoint(x: 20, y: 5)

		#expect(PageCaptureGeometry.autoscrollVelocity(from: start, to: .init(x: 20, y: 29), viewport: small) == .zero)
		#expect(PageCaptureGeometry.autoscrollVelocity(from: start, to: .init(x: 20, y: 31), viewport: small).y > 0)
	}

	// MARK: Whole page

	@Test
	internal func anAreaSitsInTheWholePageAtTheCapturesScroll() throws {
		// 400 × 300 points at 2×, scrolled 300 points down a 1000-point page.
		let frame = try wholePage(scale: 2, scrollY: 300, height: 1_000)
		let region = PageCaptureRegion(x: 10, y: -100, width: 200, height: 500)

		expectNoDifference(
			PageCaptureGeometry.documentRegion(for: region, in: frame),
			.init(x: 20, y: 400, width: 400, height: 1_000)
		)
	}

	@Test
	internal func anAreaSitsInTheWholePageAtOneTimesToo() throws {
		let frame = try wholePage(scale: 1, scrollY: 50, height: 1_000)

		expectNoDifference(
			PageCaptureGeometry.documentRegion(for: .init(x: 0, y: -50, width: 400, height: 700), in: frame),
			.init(x: 0, y: 0, width: 400, height: 700)
		)
	}

	/// The capture's own scroll places the area, at any zoom: its sizes are already in points.
	@Test
	internal func anAreaUsesTheScaleTheCaptureMeasured() throws {
		// A zoomed page on a 1.5× display: 1.5 pixels a point.
		let frame = try wholePage(scale: 1.5, scrollY: 200, height: 1_000)

		expectNoDifference(
			PageCaptureGeometry.documentRegion(for: .init(x: 20, y: -40, width: 100, height: 400), in: frame),
			.init(x: 30, y: 240, width: 150, height: 600)
		)
	}

	@Test
	internal func anAreaPastWhereALongPageWasCutIsntAllThere() throws {
		var frame = try wholePage(scale: 2, scrollY: 300, height: 400)
		frame.isCut = true
		let inside = PageCaptureRegion(x: 0, y: -300, width: 100, height: 350)
		let past = PageCaptureRegion(x: 0, y: -100, width: 100, height: 400)

		expectNoDifference(
			PageCaptureGeometry.documentRegion(for: inside, in: frame),
			.init(x: 0, y: 0, width: 200, height: 700)
		)
		#expect(PageCaptureGeometry.documentRegion(for: past, in: frame) == nil)
		#expect(PageCaptureGeometry.documentRegion(for: .init(x: 0, y: 200, width: 10, height: 10), in: frame) == nil)
	}

	// MARK: Captured frame

	@Test
	internal func aCaptureOnScreenKeepsItsPlace() {
		let area = PageCaptureRegion(x: 40, y: 60, width: 200, height: 100)

		expectNoDifference(PageCaptureGeometry.capturedFrame(for: area, viewport: viewport), area)
		expectNoDifference(PageCaptureGeometry.capturedFrame(for: viewport, viewport: viewport), viewport)
	}

	@Test
	internal func aTallPageIsScaledDownToFitAndCentered() {
		let page = PageCaptureRegion(x: 0, y: 0, width: 800, height: 4_000)
		let frame = PageCaptureGeometry.capturedFrame(for: page, viewport: viewport)

		// 552 of 4000 points high leaves 110.4 points across.
		#expect(abs(frame.height - 552) < 0.001)
		#expect(abs(frame.width - 110.4) < 0.001)
		#expect(abs(frame.x - 344.8) < 0.001)
		#expect(abs(frame.y - 24) < 0.001)
	}

	@Test
	internal func aWideAreaIsScaledDownToFitItsWidth() {
		let area = PageCaptureRegion(x: -100, y: 100, width: 1_000, height: 200)
		let frame = PageCaptureGeometry.capturedFrame(for: area, viewport: viewport)

		#expect(abs(frame.width - 752) < 0.001)
		#expect(abs(frame.height - 150.4) < 0.001)
		#expect(abs(frame.x - 24) < 0.001)
		#expect(abs(frame.y - 224.8) < 0.001)
	}

	/// A whole page of a 400 × 300 point viewport, `height` points tall, scrolled `scrollY` points.
	private func wholePage(
		scale: Double,
		scrollY: Double,
		height: Double
	) throws -> PageCaptureFrame {
		var request = PageCaptureRequest(tabID: .init(rawValue: UUID()), revision: 1)
		request.mode = .fullDocument
		request.beyondViewport = true
		request.limits = .wholePage
		let width = Int(400 * scale)
		let pixels = Int(height * scale)
		return .init(
			request: request,
			documentID: "document",
			image: .init(png: Data([1]), width: width, height: pixels),
			viewportWidth: 400,
			viewportHeight: 300,
			deviceScale: scale,
			wasLoading: false,
			documentGeometry: .init(
				documentRect: .init(x: 0, y: 0, width: Double(width), height: Double(pixels)),
				visibleRect: .init(x: 0, y: scrollY * scale, width: 400 * scale, height: 300 * scale),
				scrollX: 0,
				scrollY: scrollY * scale,
				zoomLevel: 0,
				pageScale: 1,
				rasterScale: 1
			)
		)
	}
}
