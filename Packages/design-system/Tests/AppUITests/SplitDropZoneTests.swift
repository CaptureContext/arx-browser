import AppUI
import CoreGraphics
import Testing

/// DEV-793: each edge takes the triangle between its two corners and the page's center.
internal struct SplitDropZoneTests {
	private static let size: CGSize = .init(width: 1000, height: 600)

	private static func edge(
		_ x: CGFloat,
		_ y: CGFloat,
		in size: CGSize = Self.size
	) -> SplitDropEdge {
		SplitDropEdge(point: .init(x: x, y: y), size: size)
	}

	@Test
	internal func eachTriangleTakesItsEdge() {
		// Halfway from the center to each edge's midpoint.
		#expect(Self.edge(250, 300) == .leading)
		#expect(Self.edge(750, 300) == .trailing)
		#expect(Self.edge(500, 150) == .top)
		#expect(Self.edge(500, 450) == .bottom)
	}

	@Test
	internal func theDiagonalsFollowThePageShape() {
		// On a wide page the top triangle reaches far to the sides near the top edge: a point a
		// quarter across and a little below the top is still above the diagonal.
		#expect(Self.edge(250, 100) == .top)
		#expect(Self.edge(750, 500) == .bottom)
		// Just inside the leading triangle, below the diagonal from the top-left corner.
		#expect(Self.edge(250, 160) == .leading)
		#expect(Self.edge(250, 140) == .top)
	}

	@Test
	internal func pointsOnADiagonalGoToTheSide() {
		// The diagonal from the top-left corner passes (250, 150) on a 1000×600 page.
		#expect(Self.edge(250, 150) == .leading)
		#expect(Self.edge(750, 150) == .trailing)
		#expect(Self.edge(250, 450) == .leading)
		#expect(Self.edge(750, 450) == .trailing)
		#expect(Self.edge(500, 300) == .trailing)
	}

	@Test
	internal func cornersGoToTheSide() {
		#expect(Self.edge(0, 0) == .leading)
		#expect(Self.edge(0, 600) == .leading)
		#expect(Self.edge(1000, 0) == .trailing)
		#expect(Self.edge(1000, 600) == .trailing)
		// One point in from a corner along the top edge is already top.
		#expect(Self.edge(2, 1) == .top)
		#expect(Self.edge(1, 2) == .leading)
	}

	@Test
	internal func everyPointPicksTheNearestEdgeInPageUnits() {
		for x in stride(from: CGFloat(0), through: 1000, by: 25) {
			for y in stride(from: CGFloat(0), through: 600, by: 25) {
				let u = x / 1000
				let v = y / 600
				let side = min(u, 1 - u)
				let topOrBottom = min(v, 1 - v)
				let expected: SplitDropEdge = topOrBottom < side
				? (v < 0.5 ? .top : .bottom)
				: (u < 0.5 ? .leading : .trailing)
				#expect(Self.edge(x, y) == expected)
			}
		}
	}

	@Test
	internal func pointsOffThePageCountFromTheNearestPointOnIt() {
		#expect(Self.edge(-5, 300) == .leading)
		#expect(Self.edge(500, 610) == .bottom)
		#expect(Self.edge(1200, 300) == .trailing)
		#expect(Self.edge(500, -40) == .top)
		#expect(Self.edge(10, 10, in: .zero) == .trailing)
	}
}

/// DEV-793: holding a tab at the sidebar's edge pages spaces only inside the sidebar's own strip.
internal struct SidebarDragEdgeTests {
	private static let width: CGFloat = 260
	private static let band: CGFloat = BrowserMetrics.Sidebar.dragEdgeWidth

	@Test
	internal func theOuterStripsAreTheEdges() {
		#expect(SidebarDragEdge(x: 0, width: Self.width) == .leading)
		#expect(SidebarDragEdge(x: Self.band, width: Self.width) == .leading)
		#expect(SidebarDragEdge(x: Self.width - Self.band, width: Self.width) == .trailing)
		#expect(SidebarDragEdge(x: Self.width, width: Self.width) == .trailing)
	}

	@Test
	internal func theMiddleIsNoEdge() {
		#expect(SidebarDragEdge(x: Self.band + 1, width: Self.width) == nil)
		#expect(SidebarDragEdge(x: Self.width / 2, width: Self.width) == nil)
		#expect(SidebarDragEdge(x: Self.width - Self.band - 1, width: Self.width) == nil)
	}

	@Test
	internal func pointsPastTheSidebarAreNoEdge() {
		// Over the page, or left of the window: the drop belongs to whatever is there.
		#expect(SidebarDragEdge(x: Self.width + 1, width: Self.width) == nil)
		#expect(SidebarDragEdge(x: Self.width + 300, width: Self.width) == nil)
		#expect(SidebarDragEdge(x: -1, width: Self.width) == nil)
	}

	@Test
	internal func anUnmeasuredSidebarHasNoEdges() {
		#expect(SidebarDragEdge(x: 0, width: 0) == nil)
		#expect(SidebarDragEdge(x: 8, width: 0) == nil)
	}
}
