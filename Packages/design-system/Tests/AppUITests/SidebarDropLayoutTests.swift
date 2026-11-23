@testable import AppUI
import CoreGraphics
import Foundation
import Testing

/// DEV-937: the sidebar's rows are lazy, so only the rows on screen report frames, and New Tab
/// reports none while it's off screen. A drop still lands where the pointer is.
internal struct SidebarDropLayoutTests {
	private static let rowHeight: CGFloat = 30

	@Test
	internal func everyRowMeasuredPlacesAsBefore() {
		let layout = Self.layout(measuring: Self.savedIDs + Self.tabIDs, newTabMeasured: true)

		#expect(layout.placement(at: Self.point(betweenRow: 1, depth: 1))?.target == .before(Self.child(0)))
		#expect(layout.placement(at: Self.point(belowRow: Self.lastChildRow, depth: 0))?.target == .after(Self.folder))
		#expect(layout.placement(at: Self.point(onRow: Self.newTabRow))?.target == nil)
		#expect(layout.placement(at: Self.point(onRow: Self.newTabRow + 1))?.target == .split(Self.tab(0)))
	}

	/// The middle of a pinned tab's row, in a folder too, forms a split; its edges still reorder
	/// (DEV-1006).
	@Test
	internal func theMiddleOfAPinnedTabsRowFormsASplit() {
		let layout = Self.layout(measuring: Self.savedIDs + Self.tabIDs, newTabMeasured: true)

		let placement = layout.placement(at: Self.point(onRow: 2))
		#expect(placement?.target == .split(Self.child(1)))
		#expect(placement?.depth == 1)
		#expect(placement?.lineY == nil)
		#expect(layout.placement(at: Self.point(betweenRow: 2, depth: 1))?.target == .before(Self.child(1)))
	}

	/// A split segment's drag moves its whole row in the sidebar's lists, but the page and
	/// Favorites take only the tab dragged; a selection moves as it is everywhere (DEV-1006).
	@Test
	internal func aSegmentCarriesItsSplitOnlyIntoTheLists() {
		let segment = SidebarTransfer(id: Self.tab(1), group: [Self.tab(0), Self.tab(1)])
		#expect(SidebarTransfer.orderedIDs([segment]) == [Self.tab(0), Self.tab(1)])
		#expect(SidebarTransfer.itemIDs([segment]) == [Self.tab(1)])

		let selected = SidebarTransfer(id: Self.tab(1), selection: [Self.tab(1), Self.tab(3)], group: [Self.tab(0), Self.tab(1)])
		#expect(SidebarTransfer.orderedIDs([selected]) == [Self.tab(1), Self.tab(3)])
		#expect(SidebarTransfer.itemIDs([selected]) == [Self.tab(1), Self.tab(3)])
	}

	@Test
	internal func savedRowsTakeDropsWhileNewTabIsOffScreen() {
		// Only the folder's last children are on screen; New Tab is below them.
		let measured: [SidebarItem.ID] = (6..<Self.childCount).map(Self.child)
		let layout = Self.layout(measuring: measured, newTabMeasured: false)

		#expect(layout.placement(at: Self.point(betweenRow: 8, depth: 1))?.target == .before(Self.child(7)))
	}

	@Test
	internal func aDropLeftOfAFoldersLastChildLandsAfterTheFolderOffScreen() {
		// The folder's heading has scrolled away above its last children.
		let measured: [SidebarItem.ID] = (6..<Self.childCount).map(Self.child)
		let layout = Self.layout(measuring: measured, newTabMeasured: false)

		let placement = layout.placement(at: Self.point(belowRow: Self.lastChildRow, depth: 0))
		#expect(placement?.target == .after(Self.folder))
		#expect(placement?.depth == 0)
	}

	@Test
	internal func openTabsTakeDropsWhileNewTabIsOffScreen() {
		// Scrolled into the open tabs: New Tab and the saved rows are above the screen, and the
		// last tabs are below it.
		let measured: [SidebarItem.ID] = (2..<5).map(Self.tab)
		let layout = Self.layout(measuring: measured, newTabMeasured: false)

		#expect(layout.placement(at: Self.point(onRow: Self.newTabRow + 4))?.target == .split(Self.tab(3)))
		// Under the last tab on screen, more tabs follow: before the next one, not at the end.
		let below = layout.placement(at: Self.point(belowRow: Self.newTabRow + 5, depth: 0))
		#expect(below?.target == .before(Self.tab(5)))
	}

	/// DEV-911: a tab group's row among the open tabs takes a drop into the group in its middle,
	/// where a tab's row would form a split.
	@Test
	internal func aTabGroupsRowTakesADropIntoTheGroup() {
		let group: SidebarItem.ID = .folder(uuid(300))
		let member: SidebarItem.ID = .tab(uuid(301))
		let rows: [SidebarItem] = [
			.init(id: group, title: "Group", children: [.init(id: member, title: "Member", isPinned: false)], isExpanded: true, isTabGroup: true),
			.init(id: member, title: "Member", isPinned: false),
		]
		let layout = SidebarDropLayout(
			savedRows: [],
			regularTabs: rows,
			frames: [group: Self.frame(ofRow: 1), member: Self.frame(ofRow: 2)],
			newTabFrame: Self.frame(ofRow: 0)
		)

		#expect(layout.placement(at: Self.point(onRow: 1))?.target == .inside(group))
		#expect(layout.placement(at: Self.point(betweenRow: 1, depth: 0))?.target == .before(group))
		#expect(layout.placement(at: Self.point(onRow: 2))?.target == .split(member))
	}

	@Test
	internal func nothingMeasuredTakesNoDrop() {
		let layout = Self.layout(measuring: [], newTabMeasured: false)

		#expect(layout.placement(at: .init(x: 100, y: 100)) == nil)
	}

	// MARK: - Fixture

	private static let childCount: Int = 10
	private static let tabCount: Int = 8
	private static let folder: SidebarItem.ID = .folder(uuid(1))
	private static let savedIDs: [SidebarItem.ID] = [folder] + (0..<childCount).map(child)
	private static let tabIDs: [SidebarItem.ID] = (0..<tabCount).map(tab)

	/// The folder is row 0 and its children rows 1 through `childCount`.
	private static let lastChildRow: Int = childCount
	private static let newTabRow: Int = childCount + 1

	private static func child(_ index: Int) -> SidebarItem.ID { .tab(uuid(100 + index)) }

	private static func tab(_ index: Int) -> SidebarItem.ID { .tab(uuid(200 + index)) }

	/// A folder with its children expanded, then New Tab, then the open tabs, one row each.
	private static func layout(
		measuring measured: [SidebarItem.ID],
		newTabMeasured: Bool
	) -> SidebarDropLayout {
		let children: [SidebarItem] = (0..<childCount).map { SidebarItem(id: child($0), title: "Child \($0)") }
		let folderItem = SidebarItem(id: folder, title: "Folder", children: children, isExpanded: true)
		let tabs: [SidebarItem] = (0..<tabCount).map { SidebarItem(id: tab($0), title: "Tab \($0)", isPinned: false) }
		let order: [SidebarItem.ID] = savedIDs + tabIDs
		var frames: [SidebarItem.ID: CGRect] = [:]
		for id in measured {
			guard let index = order.firstIndex(of: id) else { continue }

			// Open tabs sit one row further down, below New Tab.
			let row: Int = index < savedIDs.count ? index : index + 1
			frames[id] = frame(ofRow: row)
		}
		return .init(
			savedRows: SidebarTreeRow.flatten([folderItem]),
			regularTabs: tabs,
			frames: frames,
			newTabFrame: newTabMeasured ? frame(ofRow: newTabRow) : .zero
		)
	}

	private static func frame(ofRow row: Int) -> CGRect {
		.init(x: 0, y: CGFloat(row) * rowHeight, width: 240, height: rowHeight)
	}

	private static func point(onRow row: Int) -> CGPoint {
		.init(x: 120, y: frame(ofRow: row).midY)
	}

	/// Just above a row's middle, at an indentation that asks for `depth`.
	private static func point(
		betweenRow row: Int,
		depth: Int
	) -> CGPoint {
		.init(x: 16 + CGFloat(depth) * 17 + 2, y: frame(ofRow: row).minY + 2)
	}

	/// In the lower edge of a row, at an indentation that asks for `depth`.
	private static func point(
		belowRow row: Int,
		depth: Int
	) -> CGPoint {
		.init(x: 16 + CGFloat(depth) * 17 + 2, y: frame(ofRow: row).maxY - 2)
	}
}

private func uuid(_ value: Int) -> UUID {
	UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
}
