import BrowserCore
import CoreGraphics
import CustomDump
import PageCaptureFeature
import Testing

internal struct PageCaptureGeometryTests {
	private let viewport = PageCaptureRegion(x: 0, y: 0, width: 800, height: 600)

	@Test
	internal func candidatesDropInlineTextTinyAndUnboundedNodes() {
		let nodes: [PageInspectionNode] = [
			.init(index: 0, role: "rootWebArea", bounds: .init(x: 0, y: 0, width: 800, height: 2_000)),
			.init(index: 1, parent: 0, role: "paragraph", bounds: .init(x: 10, y: 10, width: 300, height: 60)),
			.init(index: 2, parent: 1, role: "staticText", bounds: .init(x: 10, y: 10, width: 300, height: 20)),
			.init(index: 3, parent: 1, role: "link", bounds: .init(x: 20, y: 30, width: 40, height: 16)),
			.init(index: 4, parent: 0, role: "image", bounds: .init(x: 400, y: 10, width: 4, height: 4)),
			.init(index: 5, parent: 0, role: "heading"),
		]

		let candidates = PageCaptureGeometry.candidates(from: nodes)

		expectNoDifference(candidates.map(\.index), [1])
	}

	@Test
	internal func targetsDropWhatCoversThePageOrIsOffScreen() {
		let candidates: [PageCaptureTarget] = [
			.init(index: 1, role: "main", bounds: .init(x: 0, y: 0, width: 800, height: 3_000)),
			.init(index: 2, role: "section", bounds: .init(x: 0, y: 0, width: 800, height: 300)),
			.init(index: 3, role: "paragraph", bounds: .init(x: 0, y: 900, width: 800, height: 40)),
		]

		let targets = PageCaptureGeometry.targets(from: candidates, viewport: viewport)

		expectNoDifference(targets.map(\.index), [2])
	}

	@Test
	internal func pointPicksTheInnermostBlock() {
		let targets: [PageCaptureTarget] = [
			.init(index: 1, role: "section", bounds: .init(x: 0, y: 0, width: 400, height: 400)),
			.init(index: 2, parent: 1, role: "paragraph", bounds: .init(x: 20, y: 20, width: 200, height: 50)),
			.init(index: 3, parent: 1, role: "image", bounds: .init(x: 20, y: 100, width: 100, height: 100)),
		]

		#expect(PageCaptureGeometry.target(at: .init(x: 30, y: 30), in: targets)?.index == 2)
		#expect(PageCaptureGeometry.target(at: .init(x: 50, y: 150), in: targets)?.index == 3)
		#expect(PageCaptureGeometry.target(at: .init(x: 300, y: 300), in: targets)?.index == 1)
		#expect(PageCaptureGeometry.target(at: .init(x: 500, y: 500), in: targets) == nil)
		// Right and bottom edges belong to the next block, not this one.
		#expect(PageCaptureGeometry.target(at: .init(x: 220, y: 30), in: targets)?.index == 1)
	}

	@Test
	internal func arrowKeysWalkSiblingsAndNesting() {
		let section = PageCaptureTarget(index: 1, role: "section", bounds: .init(x: 0, y: 0, width: 400, height: 400))
		let first = PageCaptureTarget(
			index: 2,
			parent: 1,
			role: "paragraph",
			bounds: .init(x: 20, y: 20, width: 200, height: 50)
		)
		let second = PageCaptureTarget(
			index: 4,
			parent: 1,
			role: "paragraph",
			bounds: .init(x: 20, y: 80, width: 200, height: 50)
		)
		let targets = [section, first, second]

		func move(
			_ movement: PageCaptureMovement,
			from current: PageCaptureTarget?
		) -> PageCaptureTarget? {
			PageCaptureGeometry.target(movement, from: current, in: targets, viewport: viewport)
		}

		#expect(move(.next, from: nil) == section)
		#expect(move(.previous, from: nil) == second)
		#expect(move(.next, from: first) == second)
		#expect(move(.next, from: second) == second)
		#expect(move(.previous, from: first) == section)
		#expect(move(.parent, from: second) == section)
		#expect(move(.parent, from: section) == section)
		#expect(move(.child, from: section) == first)
		#expect(move(.child, from: first) == first)
	}

	@Test
	internal func dragDrawsANormalizedRegionInsideTheViewport() {
		let region = PageCaptureGeometry.region(
			from: .init(x: 700, y: 500),
			to: .init(x: 900, y: 200),
			viewport: viewport
		)

		expectNoDifference(region, .init(x: 700, y: 200, width: 100, height: 300))
		#expect(PageCaptureGeometry.region(from: .init(x: 900, y: 10), to: .init(x: 950, y: 50), viewport: viewport) == nil)
	}

	@Test
	internal func shortMovementsAreClicks() {
		#expect(!PageCaptureGeometry.isDrag(from: .init(x: 10, y: 10), to: .init(x: 12, y: 12)))
		#expect(PageCaptureGeometry.isDrag(from: .init(x: 10, y: 10), to: .init(x: 14, y: 10)))
	}

	@Test
	internal func menuGoesRightLeftBelowAboveThenInside() {
		let menu = CGSize(width: 200, height: 150)

		let right = PageCaptureGeometry.menuOrigin(
			for: .init(x: 100, y: 100, width: 200, height: 100),
			menu: menu,
			viewport: viewport
		)
		#expect(right == .init(x: 310, y: 100))

		let left = PageCaptureGeometry.menuOrigin(
			for: .init(x: 500, y: 100, width: 250, height: 100),
			menu: menu,
			viewport: viewport
		)
		#expect(left == .init(x: 290, y: 100))

		let below = PageCaptureGeometry.menuOrigin(
			for: .init(x: 50, y: 100, width: 700, height: 100),
			menu: menu,
			viewport: viewport
		)
		#expect(below == .init(x: 550, y: 210))

		let above = PageCaptureGeometry.menuOrigin(
			for: .init(x: 50, y: 300, width: 700, height: 200),
			menu: menu,
			viewport: viewport
		)
		#expect(above == .init(x: 550, y: 140))

		let inside = PageCaptureGeometry.menuOrigin(
			for: viewport,
			menu: menu,
			viewport: viewport
		)
		#expect(inside == .init(x: 590, y: 10))

		// A frame near the bottom keeps the whole menu on screen.
		let low = PageCaptureGeometry.menuOrigin(
			for: .init(x: 100, y: 550, width: 100, height: 40),
			menu: menu,
			viewport: viewport
		)
		#expect(low == .init(x: 210, y: 440))
	}

	@Test
	internal func mediaRegionsAreTheVisiblePartsOfMediaInTheCapture() {
		let targets: [PageCaptureTarget] = [
			.init(index: 1, role: "video", bounds: .init(x: 0, y: 0, width: 300, height: 200)),
			.init(index: 2, role: "paragraph", bounds: .init(x: 0, y: 220, width: 300, height: 40)),
			.init(index: 3, role: "video", bounds: .init(x: 500, y: 0, width: 200, height: 100)),
		]

		let regions = PageCaptureGeometry.mediaRegions(
			in: .init(x: 100, y: 100, width: 300, height: 200),
			targets: targets
		)

		expectNoDifference(regions, [.init(x: 100, y: 100, width: 200, height: 100)])
	}

	@Test
	internal func cutoutIsTheFocusWhenThereIsOne() {
		let focus = PageCaptureRegion(x: 10, y: 20, width: 300, height: 40)

		let cutout = PageCaptureGeometry.cutout(
			for: focus,
			previous: .init(x: 0, y: 0, width: 50, height: 50),
			viewport: viewport
		)

		expectNoDifference(cutout, focus)
	}

	@Test
	internal func cutoutCollapsesIntoTheLastFocusThenTheViewportCenter() {
		let previous = PageCaptureRegion(x: 100, y: 200, width: 300, height: 40)

		expectNoDifference(
			PageCaptureGeometry.cutout(for: nil, previous: previous, viewport: viewport),
			.init(x: 250, y: 220, width: 0, height: 0)
		)
		expectNoDifference(
			PageCaptureGeometry.cutout(for: nil, previous: nil, viewport: viewport),
			.init(x: 400, y: 300, width: 0, height: 0)
		)
	}

	@Test
	internal func cornerRadiusFitsSmallAndEmptyRegions() {
		#expect(PageCaptureGeometry.cornerRadius(for: .init(x: 0, y: 0, width: 300, height: 40), preferred: 8) == 8)
		#expect(PageCaptureGeometry.cornerRadius(for: .init(x: 0, y: 0, width: 300, height: 10), preferred: 8) == 5)
		#expect(PageCaptureGeometry.cornerRadius(for: .init(x: 0, y: 0, width: 0, height: 0), preferred: 8) == 0)
	}
}
