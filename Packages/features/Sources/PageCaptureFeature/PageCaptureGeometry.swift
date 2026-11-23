import BrowserCore
import Foundation

/// A block of the page the pointer can pick, from the engine's node bounds.
public struct PageCaptureTarget: Equatable, Sendable {
	/// The node's position in the engine's projected tree.
	public var index: Int

	/// The nearest projected ancestor, when there is one.
	public var parent: Int?
	public var role: String

	/// Viewport points, top-left origin.
	public var bounds: PageCaptureRegion

	public init(
		index: Int,
		parent: Int? = nil,
		role: String,
		bounds: PageCaptureRegion
	) {
		self.index = index
		self.parent = parent
		self.role = role
		self.bounds = bounds
	}
}

/// Pure selection geometry for capturing on the page. Every rectangle is in
/// viewport points with a top-left origin, as the engine reports node bounds.
public enum PageCaptureGeometry {
	/// A drag shorter than this is a click.
	public static let dragThreshold: Double = 4

	/// A target smaller than this on either side is too small to pick on its own.
	public static let minimumTargetSide: Double = 8

	/// A target covering at least this share of the viewport is the page itself.
	public static let pageCoverage: Double = 0.9

	/// Roles that sit inside a line of text. Picking one picks the block around it.
	public static let inlineRoles: Set<String> = [
		"abbr",
		"emphasis",
		"inlineTextBox",
		"lineBreak",
		"link",
		"mark",
		"staticText",
		"strong",
		"subscript",
		"superscript",
		"time",
	]

	/// Roles that show media whose pixels the engine may leave blank.
	public static let mediaRoles: Set<String> = ["video", "audio", "embeddedObject", "pluginObject"]

	/// The nodes worth picking anywhere on the page: they have bounds, aren't inline
	/// text and aren't tiny. Order follows the engine's tree.
	public static func candidates(from nodes: [PageInspectionNode]) -> [PageCaptureTarget] {
		nodes.compactMap { node in
			guard
				let bounds = node.bounds,
				!inlineRoles.contains(node.role),
				node.role != "rootWebArea",
				bounds.width >= minimumTargetSide,
				bounds.height >= minimumTargetSide
			else { return nil }

			return .init(index: node.index, parent: node.parent, role: node.role, bounds: bounds)
		}
	}

	/// The candidates on screen that don't cover the whole viewport.
	public static func targets(
		from candidates: [PageCaptureTarget],
		viewport: PageCaptureRegion
	) -> [PageCaptureTarget] {
		let viewportArea = viewport.width * viewport.height
		return candidates.filter { candidate in
			guard let visible = intersection(candidate.bounds, viewport) else { return false }
			return visible.width * visible.height < viewportArea * pageCoverage
		}
	}

	/// The smallest target under the point, which is the innermost block.
	/// Ties keep the later node, which is deeper in the tree.
	public static func target(
		at point: CGPoint,
		in targets: [PageCaptureTarget]
	) -> PageCaptureTarget? {
		var best: PageCaptureTarget?
		for target in targets where contains(target.bounds, point) {
			guard let current = best else {
				best = target
				continue
			}

			if area(target.bounds) <= area(current.bounds) { best = target }
		}
		return best
	}

	/// The target the arrow keys move to from `current`.
	public static func target(
		_ movement: PageCaptureMovement,
		from current: PageCaptureTarget?,
		in targets: [PageCaptureTarget],
		viewport: PageCaptureRegion
	) -> PageCaptureTarget? {
		let visible = targets.filter { intersection($0.bounds, viewport) != nil }
		guard let current, let position = visible.firstIndex(of: current)
		else { return movement == .previous ? visible.last : visible.first }

		switch movement {
		case .next:
			return visible[safe: position + 1] ?? current

		case .previous:
			return visible[safe: position - 1] ?? current

		case .parent:
			// The nearest enclosing target, skipping ancestors that aren't targets.
			return visible.last { $0 != current && $0.index < current.index && encloses($0.bounds, current.bounds) }
			?? current

		case .child:
			return visible.first { $0.index > current.index && $0 != current && encloses(current.bounds, $0.bounds) }
			?? current
		}
	}

	/// The rectangle a drag from `start` to `end` draws, clamped to the viewport.
	public static func region(
		from start: CGPoint,
		to end: CGPoint,
		viewport: PageCaptureRegion
	) -> PageCaptureRegion? {
		let rect = PageCaptureRegion(
			x: min(start.x, end.x),
			y: min(start.y, end.y),
			width: abs(end.x - start.x),
			height: abs(end.y - start.y)
		)
		return intersection(rect, viewport)
	}

	// MARK: Beyond the viewport (DEV-1208)

	/// How far inside an edge the page starts scrolling while an area is drawn toward it, at most a
	/// quarter of the viewport.
	public static let autoscrollEdge: Double = 36

	/// How far past the edge zone's inner line the pointer goes before the page scrolls at its
	/// top speed.
	public static let autoscrollReach: Double = 160

	/// Points a second, just inside the edge zone and at full reach.
	public static let autoscrollMinimumSpeed: Double = 60
	public static let autoscrollMaximumSpeed: Double = 3_000

	/// The area a drag draws once the page has scrolled `scrolled` points since the drag began: from
	/// where it started, which moved with the page, to the pointer, held inside the viewport. In
	/// viewport points, so it reaches above, below or beside the viewport once the page has
	/// scrolled. Before any scroll it's the clamped rectangle `region(from:to:viewport:)` draws.
	public static func region(
		from start: CGPoint,
		to end: CGPoint,
		scrolled: PageCaptureOffset,
		viewport: PageCaptureRegion
	) -> PageCaptureRegion? {
		let anchorX = Double(start.x) - scrolled.x
		let anchorY = Double(start.y) - scrolled.y
		let pointerX = min(max(Double(end.x), viewport.x), viewport.x + viewport.width)
		let pointerY = min(max(Double(end.y), viewport.y), viewport.y + viewport.height)
		let rect = PageCaptureRegion(
			x: min(anchorX, pointerX),
			y: min(anchorY, pointerY),
			width: abs(pointerX - anchorX),
			height: abs(pointerY - anchorY)
		)
		guard
			rect.x.isFinite, rect.y.isFinite, rect.width.isFinite, rect.height.isFinite,
			rect.width >= 1, rect.height >= 1
		else { return nil }

		return rect
	}

	/// How fast the page scrolls while an area is drawn from `start` to `pointer`, in points a
	/// second on each axis: toward an edge the pointer is near and has moved toward, slowly just
	/// inside the edge and faster the deeper it goes, past the edge too. Zero away from the edges.
	public static func autoscrollVelocity(
		from start: CGPoint,
		to pointer: CGPoint,
		viewport: PageCaptureRegion
	) -> PageCaptureOffset {
		.init(
			x: autoscrollSpeed(
				Double(pointer.x),
				start: Double(start.x),
				lower: viewport.x,
				upper: viewport.x + viewport.width
			),
			y: autoscrollSpeed(
				Double(pointer.y),
				start: Double(start.y),
				lower: viewport.y,
				upper: viewport.y + viewport.height
			)
		)
	}

	/// The part of a whole page captured beyond the viewport that `region` covers. `region` is in
	/// viewport points at the capture's own scroll; the image starts at the document's top-left
	/// corner. Nil when the area isn't all in the image, as past where a long page was cut.
	public static func documentRegion(
		for region: PageCaptureRegion,
		in frame: PageCaptureFrame
	) -> PageCaptureRegion? {
		guard
			let geometry = frame.documentGeometry,
			frame.viewportWidth > 0,
			geometry.visibleRect.width > 0
		else { return nil }

		// Image pixels a point, as the capture measured them.
		let scale = geometry.visibleRect.width / frame.viewportWidth
		let rect = PageCaptureRegion(
			x: region.x * scale + geometry.scrollX,
			y: region.y * scale + geometry.scrollY,
			width: region.width * scale,
			height: region.height * scale
		)
		let document = geometry.documentRect
		guard let inside = intersection(rect, document) else { return nil }

		// A cut page holds only its top and left: an area reaching past the cut isn't all there.
		guard
			!frame.isCut
			|| (rect.x + rect.width <= document.x + document.width + scale
				&& rect.y + rect.height <= document.y + document.height + scale)
		else { return nil }

		return inside
	}

	/// Where the captured frame sits once a capture is taken (DEV-1208): over what was captured when
	/// it's all on screen, else that scaled down to fit the viewport, inset from its edges and
	/// centered, so the frame shows everything the image holds. `extent` is in viewport points.
	public static func capturedFrame(
		for extent: PageCaptureRegion,
		viewport: PageCaptureRegion,
		inset: Double = 24
	) -> PageCaptureRegion {
		guard
			!fits(extent, in: viewport),
			extent.width > 0,
			extent.height > 0,
			viewport.width > 0,
			viewport.height > 0
		else { return extent }

		let availableWidth = max(1, viewport.width - inset * 2)
		let availableHeight = max(1, viewport.height - inset * 2)
		let scale = min(1, availableWidth / extent.width, availableHeight / extent.height)
		let width = extent.width * scale
		let height = extent.height * scale
		return .init(
			x: viewport.x + (viewport.width - width) / 2,
			y: viewport.y + (viewport.height - height) / 2,
			width: width,
			height: height
		)
	}

	/// Whether `region` is all inside `viewport`, give or take half a point.
	public static func fits(
		_ region: PageCaptureRegion,
		in viewport: PageCaptureRegion
	) -> Bool {
		let tolerance = 0.5
		return region.x >= viewport.x - tolerance
		&& region.y >= viewport.y - tolerance
		&& region.x + region.width <= viewport.x + viewport.width + tolerance
		&& region.y + region.height <= viewport.y + viewport.height + tolerance
	}

	private static func autoscrollSpeed(
		_ position: Double,
		start: Double,
		lower: Double,
		upper: Double
	) -> Double {
		let edge = min(autoscrollEdge, max(0, upper - lower) / 4)
		guard edge > 0, position.isFinite, start.isFinite else { return 0 }

		let depth: Double
		let direction: Double
		if position > upper - edge, position > start {
			depth = position - (upper - edge)
			direction = 1
		} else if position < lower + edge, position < start {
			depth = lower + edge - position
			direction = -1
		} else {
			return 0
		}

		let progress = min(1, depth / (edge + autoscrollReach))
		let speed = autoscrollMinimumSpeed + (autoscrollMaximumSpeed - autoscrollMinimumSpeed) * progress * progress
		return direction * speed
	}

	/// Whether a pointer that went down at `start` and is now at `end` is dragging.
	public static func isDrag(
		from start: CGPoint,
		to end: CGPoint
	) -> Bool {
		hypot(end.x - start.x, end.y - start.y) >= dragThreshold
	}

	/// The part of `rect` inside `bounds`, or nil when nothing of it is.
	public static func intersection(
		_ rect: PageCaptureRegion,
		_ bounds: PageCaptureRegion
	) -> PageCaptureRegion? {
		let x = max(rect.x, bounds.x)
		let y = max(rect.y, bounds.y)
		let right = min(rect.x + rect.width, bounds.x + bounds.width)
		let bottom = min(rect.y + rect.height, bounds.y + bounds.height)
		guard
			x.isFinite, y.isFinite, right.isFinite, bottom.isFinite,
			right - x >= 1, bottom - y >= 1
		else { return nil }

		return .init(x: x, y: y, width: right - x, height: bottom - y)
	}

	/// Where the menu goes beside a captured frame: to its right when there's room,
	/// else to its left, else below it, else above it, else inside its bottom-right
	/// corner. Always inside the viewport.
	public static func menuOrigin(
		for frame: PageCaptureRegion,
		menu: CGSize,
		viewport: PageCaptureRegion,
		spacing: Double = 10
	) -> CGPoint {
		let width = Double(menu.width)
		let height = Double(menu.height)
		let minimumX = viewport.x + spacing
		let maximumX = max(minimumX, viewport.x + viewport.width - spacing - width)
		let minimumY = viewport.y + spacing
		let maximumY = max(minimumY, viewport.y + viewport.height - spacing - height)
		let right = frame.x + frame.width + spacing
		let left = frame.x - spacing - width
		let below = frame.y + frame.height + spacing
		let above = frame.y - spacing - height

		// Below or above, the menu lines up with the frame's trailing edge.
		let trailing = frame.x + frame.width - width

		let origin: (x: Double, y: Double) = if right <= maximumX {
			(right, frame.y)
		} else if left >= minimumX {
			(left, frame.y)
		} else if below <= maximumY {
			(trailing, below)
		} else if above >= minimumY {
			(trailing, above)
		} else {
			(frame.x + frame.width - spacing - width, frame.y + spacing)
		}
		return .init(
			x: min(max(origin.x, minimumX), maximumX),
			y: min(max(origin.y, minimumY), maximumY)
		)
	}

	/// Whether a media node intersects the captured region, so blank pixels there
	/// may be protected content rather than the page's own colors.
	public static func mediaRegions(
		in region: PageCaptureRegion,
		targets: [PageCaptureTarget]
	) -> [PageCaptureRegion] {
		targets.compactMap { target in
			guard mediaRoles.contains(target.role) else { return nil }
			return intersection(target.bounds, region)
		}
	}

	/// The clear cut-out the dimming leaves. With nothing in focus it's an empty rect at
	/// the center of the last focus, or of the viewport, so the cut-out shrinks into a
	/// point and grows out of one instead of popping in and out.
	public static func cutout(
		for focus: PageCaptureRegion?,
		previous: PageCaptureRegion?,
		viewport: PageCaptureRegion
	) -> PageCaptureRegion {
		if let focus { return focus }
		let anchor = previous ?? viewport
		return .init(
			x: anchor.x + anchor.width / 2,
			y: anchor.y + anchor.height / 2,
			width: 0,
			height: 0
		)
	}

	/// A corner radius that fits `region`: never more than half its shorter side.
	public static func cornerRadius(
		for region: PageCaptureRegion,
		preferred: Double
	) -> Double {
		max(0, min(preferred, region.width / 2, region.height / 2))
	}

	public static func contains(
		_ rect: PageCaptureRegion,
		_ point: CGPoint
	) -> Bool {
		Double(point.x) >= rect.x
		&& Double(point.x) < rect.x + rect.width
		&& Double(point.y) >= rect.y
		&& Double(point.y) < rect.y + rect.height
	}

	public static func encloses(
		_ outer: PageCaptureRegion,
		_ inner: PageCaptureRegion
	) -> Bool {
		inner.x >= outer.x
		&& inner.y >= outer.y
		&& inner.x + inner.width <= outer.x + outer.width
		&& inner.y + inner.height <= outer.y + outer.height
		&& area(outer) > area(inner)
	}

	private static func area(_ rect: PageCaptureRegion) -> Double { rect.width * rect.height }
}

/// How the arrow keys move the highlight.
public enum PageCaptureMovement: Equatable, Sendable {
	case next
	case previous
	case parent
	case child
}

extension Array {
	fileprivate subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}
