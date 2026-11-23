@testable import AppUI
import Foundation
import Testing

/// DEV-1235: which spaces the pager keeps mounted beside the ones the track shows, a step at a
/// time, so no frame builds or tears down more than one page.
@Suite
internal struct SidebarPagerMountPlanTests {
	private static let spaces: [UUID] = (0..<8).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", $0))! }

	private static func plan(_ order: [Int]) -> SidebarPagerMountPlan {
		.init(order: order.map { spaces[$0] }, capacity: 5)
	}

	private static func step(
		_ plan: SidebarPagerMountPlan,
		toward wanted: [Int],
		among existing: [Int] = Array(0..<8)
	) -> SidebarPagerMountPlan {
		plan.step(toward: wanted.map { spaces[$0] }, among: Set(existing.map { spaces[$0] }))
	}

	private static func order(_ plan: SidebarPagerMountPlan) -> [Int] {
		plan.order.map { spaces.firstIndex(of: $0)! }
	}

	@Test
	internal func eachStepKeepsOneMoreWantedSpace() {
		let first = Self.step(Self.plan([0, 1]), toward: [1, 2, 0])
		#expect(Set(Self.order(first)) == [0, 1, 2])
		#expect(first.hasMore)

		let second = Self.step(first, toward: [1, 2, 0])
		#expect(Set(Self.order(second)) == [0, 1, 2])
		#expect(!second.hasMore)
	}

	@Test
	internal func theMostWantedSpaceIsLetGoLast() {
		let plan = Self.step(Self.plan([0, 1, 2]), toward: [1, 2, 0])
		#expect(Self.order(plan) == [0, 2, 1])
	}

	@Test
	internal func pastItsCapacityTheSpaceWantedLongestAgoGoesOneAStep() {
		var plan = Self.plan([0, 1, 2, 3, 4, 5, 6])
		plan = Self.step(plan, toward: [5, 6, 4])
		#expect(Set(Self.order(plan)) == [1, 2, 3, 4, 5, 6])
		#expect(plan.hasMore)

		plan = Self.step(plan, toward: [5, 6, 4])
		#expect(Set(Self.order(plan)) == [2, 3, 4, 5, 6])
		#expect(!plan.hasMore)
	}

	@Test
	internal func aSpaceThatNoLongerExistsIsForgotten() {
		let plan = Self.step(Self.plan([0, 1, 2]), toward: [1, 2, 0], among: [1, 2, 3])
		#expect(Set(Self.order(plan)) == [1, 2])
	}
}
