@testable import AppUI
import CustomDump
import Foundation
import Testing

internal struct SidebarDropLayoutTests {
	@Test
	func folderEdgesInsertWhileCenterNests() async throws {
		let layout = fixture
		expectNoDifference(
			layout.placement(at: .init(x: 18, y: 75))?.target,
			.before(folder(4).id)
		)
		expectNoDifference(
			layout.placement(at: .init(x: 80, y: 90))?.target,
			.inside(folder(4).id)
		)
		expectNoDifference(
			layout.placement(at: .init(x: 80, y: 106))?.target,
			.after(folder(4).id)
		)
		#expect(layout.placement(at: .init(x: 18, y: 75))?.lineY != nil)
		#expect(layout.placement(at: .init(x: 80, y: 90))?.lineY == nil)
	}

	@Test
	func gapBetweenCollapsedFoldersAlwaysInsertsAtRoot() async throws {
		let layout = SidebarDropLayout(
			savedRows: SidebarTreeRow.flatten([folder(1), folder(4)]),
			regularTabs: [],
			frames: [folder(1).id: frame(0), folder(4).id: frame(37)],
			newTabFrame: frame(110)
		)
		for x in [18.0, 80, 250] {
			let placement = layout.placement(at: .init(x: x, y: 35))
			expectNoDifference(placement?.target, .before(folder(4).id))
			expectNoDifference(placement?.depth, 0)
			#expect(placement?.lineY != nil)
		}
	}

	@Test
	func lowerEdgeOfExpandedFolderRespectsIndentation() async throws {
		let inside = fixture.placement(at: .init(x: 80, y: 72))
		let outside = fixture.placement(at: .init(x: 18, y: 72))
		expectNoDifference(inside?.target, .after(tab(2).id))
		expectNoDifference(inside?.depth, 1)
		expectNoDifference(outside?.target, .before(folder(4).id))
		expectNoDifference(outside?.depth, 0)
		expectNoDifference(inside?.lineY, outside?.lineY)
	}

	@Test
	func endOfSavedTreeCanRemainInsideLastFolder() async throws {
		let layout = SidebarDropLayout(
			savedRows: SidebarTreeRow.flatten([folder(1, children: [tab(2)], expanded: true)]),
			regularTabs: [],
			frames: fixture.frames,
			newTabFrame: fixture.newTabFrame
		)
		expectNoDifference(
			layout.placement(at: .init(x: 80, y: 80))?.target,
			.after(tab(2).id)
		)
		expectNoDifference(
			layout.placement(at: .init(x: 18, y: 80))?.target,
			.after(folder(1).id)
		)
	}

	@Test
	func nestedFolderBoundaryAllowsEachAncestorLevel() async throws {
		let tree = [
			folder(
				1,
				children: [folder(3, children: [tab(2)], expanded: true)],
				expanded: true
			),
		]
		let layout = SidebarDropLayout(
			savedRows: SidebarTreeRow.flatten(tree),
			regularTabs: [],
			frames: [
				folder(1).id: frame(0),
				folder(3).id: frame(37),
				tab(2).id: frame(74),
			],
			newTabFrame: frame(140)
		)
		expectNoDifference(
			layout.placement(at: .init(x: 70, y: 110))?.target,
			.after(tab(2).id)
		)
		expectNoDifference(
			layout.placement(at: .init(x: 35, y: 110))?.target,
			.after(folder(3).id)
		)
		expectNoDifference(
			layout.placement(at: .init(x: 18, y: 110))?.target,
			.after(folder(1).id)
		)
	}

	@Test
	func emptyExpandedFolderAcceptsIndentedEndInsertion() async throws {
		let layout = SidebarDropLayout(
			savedRows: SidebarTreeRow.flatten([folder(1, expanded: true), folder(4)]),
			regularTabs: [],
			frames: [folder(1).id: frame(0), folder(4).id: frame(37)],
			newTabFrame: frame(110)
		)
		expectNoDifference(
			layout.placement(at: .init(x: 80, y: 35))?.target,
			.inside(folder(1).id)
		)
		expectNoDifference(
			layout.placement(at: .init(x: 18, y: 35))?.target,
			.before(folder(4).id)
		)
	}

	@Test
	func regularRowsOfferBeginningMiddleAndEndInsertion() async throws {
		expectNoDifference(
			fixture.placement(at: .init(x: 80, y: 156))?.target,
			.before(tab(5).id)
		)
		expectNoDifference(
			fixture.placement(at: .init(x: 80, y: 191))?.target,
			.before(tab(6).id)
		)
		expectNoDifference(
			fixture.placement(at: .init(x: 80, y: 229))?.target,
			.unpinnedRoot
		)
	}

	@Test
	func blankBottomAreaAppendsRegularTabs() async throws {
		let placement = fixture.placement(at: .init(x: 80, y: 600))
		expectNoDifference(placement?.target, .unpinnedRoot)
		expectNoDifference(placement?.lineY, 230.5)
		expectNoDifference(placement?.depth, 0)
	}

	@Test
	func emptyRegularSectionAcceptsBottomDrop() async throws {
		let layout = SidebarDropLayout(
			savedRows: fixture.savedRows,
			regularTabs: [],
			frames: fixture.frames,
			newTabFrame: fixture.newTabFrame
		)
		expectNoDifference(
			layout.placement(at: .init(x: 80, y: 400))?.target,
			.unpinnedRoot
		)
		expectNoDifference(
			layout.placement(at: .init(x: 80, y: 400))?.lineY,
			158
		)
	}

	@Test
	func newTabButtonIsNeverADropDestination() async throws {
		for x in [0.0, 80, 285] {
			for y in [120.0, 137, 154] {
				#expect(fixture.placement(at: .init(x: x, y: y)) == nil)
			}
		}
	}

	private var fixture: SidebarDropLayout {
		.init(
			savedRows: SidebarTreeRow.flatten([
				folder(1, children: [tab(2)], expanded: true),
				folder(4),
			]),
			regularTabs: [tab(5), tab(6)],
			frames: [
				folder(1).id: frame(0),
				tab(2).id: frame(37),
				folder(4).id: frame(74),
				tab(5).id: frame(158),
				tab(6).id: frame(195)
			],
			newTabFrame: frame(120)
		)
	}

	private func frame(_ y: CGFloat) -> CGRect {
		.init(
			x: 7,
			y: y,
			width: 272,
			height: 34
		)
	}

	private func tab(_ value: UInt8) -> SidebarItem {
		.init(
			id: .tab(id(value)),
			title: "Tab \(value)"
		)
	}

	private func folder(
		_ value: UInt8,
		children: [SidebarItem] = [],
		expanded: Bool = false
	) -> SidebarItem {
		.init(
			id: .folder(id(value)),
			title: "Folder \(value)",
			children: children,
			isExpanded: expanded
		)
	}

	private func id(_ value: UInt8) -> UUID {
		.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
	}
}
