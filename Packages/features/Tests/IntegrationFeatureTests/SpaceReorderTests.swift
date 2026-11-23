import AppFeature
import AppUI
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// Dragging a space column by its handle in the Library.
@Suite(.dependencies)
@MainActor
internal struct SpaceReorderTests {
	private let order = (0..<5).map { UUID($0) }

	private func slot(_ x: CGFloat, count: Int = 5) -> Int {
		SidebarSpaceReorder.slot(at: x, count: count, columnWidth: 240, spacing: 24, leadingInset: 24)
	}

	@Test
	internal func theSlotIsTheColumnUnderThePointer() {
		// Columns start at 24 and repeat every 264 points; each gap belongs half to either side.
		expectNoDifference(slot(-100), 0)
		expectNoDifference(slot(24), 0)
		expectNoDifference(slot(263), 0)
		expectNoDifference(slot(277), 1)
		expectNoDifference(slot(24 + 264 * 2 + 120), 2)
		expectNoDifference(slot(10_000), 4)
		expectNoDifference(slot(500, count: 0), 0)
	}

	@Test
	internal func theDraggedSpaceSitsInTheSlotWhileTheOthersSlideAside() throws {
		var reorder = try #require(SidebarSpaceReorder(id: order[0], in: order))
		expectNoDifference(reorder.order(order), order)
		let moved = reorder.track(x: 24 + 264 * 2 + 10, count: 5, columnWidth: 240, spacing: 24, leadingInset: 24)
		#expect(moved)
		expectNoDifference(reorder.slot, 2)
		expectNoDifference(reorder.order(order), [order[1], order[2], order[0], order[3], order[4]])

		// Staying over the same column changes nothing.
		let movedAgain = reorder.track(x: 24 + 264 * 2 + 200, count: 5, columnWidth: 240, spacing: 24, leadingInset: 24)
		#expect(!movedAgain)
	}

	@Test
	internal func droppingNamesTheSpaceItLandsBefore() throws {
		var right = try #require(SidebarSpaceReorder(id: order[0], in: order))
		right.track(x: 24 + 264 * 2, count: 5, columnWidth: 240, spacing: 24, leadingInset: 24)
		expectNoDifference(right.destination(in: order), .some(order[3]))

		var last = try #require(SidebarSpaceReorder(id: order[1], in: order))
		last.track(x: 10_000, count: 5, columnWidth: 240, spacing: 24, leadingInset: 24)
		expectNoDifference(last.destination(in: order), .some(nil))

		var left = try #require(SidebarSpaceReorder(id: order[4], in: order))
		left.track(x: 24 + 264, count: 5, columnWidth: 240, spacing: 24, leadingInset: 24)
		expectNoDifference(left.destination(in: order), .some(order[1]))
	}

	@Test
	internal func droppingWhereItStartedLeavesTheRowAlone() throws {
		var reorder = try #require(SidebarSpaceReorder(id: order[2], in: order))
		reorder.track(x: 24, count: 5, columnWidth: 240, spacing: 24, leadingInset: 24)
		reorder.track(x: 24 + 264 * 2 + 5, count: 5, columnWidth: 240, spacing: 24, leadingInset: 24)
		expectNoDifference(reorder.destination(in: order), nil)
		#expect(SidebarSpaceReorder(id: UUID(99), in: order) == nil)
	}

	@Test
	internal func everyDropMatchesTheRowShownDuringTheDrag() throws {
		let spaces = order.map { Space(id: .init(rawValue: $0), profileID: .init(rawValue: UUID(50)), name: "\($0)") }
		let organization = BrowserOrganization(
			profiles: [.init(id: .init(rawValue: UUID(50)), name: "Default")],
			spaces: spaces,
			tabs: []
		)
		for dragged in order.indices {
			for slot in order.indices {
				var reorder = try #require(SidebarSpaceReorder(id: order[dragged], in: order))
				reorder.track(
					x: 24 + 264 * CGFloat(slot) + 1,
					count: 5,
					columnWidth: 240,
					spacing: 24,
					leadingInset: 24
				)
				let shown = reorder.order(order)
				guard let destination = reorder.destination(in: order) else {
					expectNoDifference(shown, order)
					continue
				}
				let moved = try organization.applying(
					.moveSpace(.init(rawValue: order[dragged]), before: destination.map { .init(rawValue: $0) }),
					uuid: UUID.init
				)
				expectNoDifference(moved.spaces.map(\.id.rawValue), shown)
			}
		}
	}

	@Test
	internal func aDroppedSpaceIsSavedInItsNewPlace() async {
		let organization = IntegrationFeatureTests().fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.ui(.changeOrganization(.moveSpace(organization.spaces[0].id, before: nil)))))
		await store.receive(\.delegate.save)
		await store.finish()
		let reordered = [organization.spaces[1].id, organization.spaces[0].id]
		expectNoDifference(store.state.workspace.spaces.map(\.id), reordered)
		expectNoDifference(store.state.main.sidebar.organization.spaces.map(\.id), reordered)
	}
}
