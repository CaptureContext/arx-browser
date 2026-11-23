import AppKit
@testable import AppUI
import CustomDump
import Foundation
import SwiftUI
import Testing

/// DEV-1110: a collapsed folder still shows its selected tab beneath it, one level in, and only
/// that tab. Its icon shows "•••" meanwhile.
internal struct SidebarFolderRevealTests {
	// Work (expanded)
	//   Docs
	//   Snowboarding (collapsed)
	//     Boards
	//     Jackets
	//     Old (collapsed)
	//       Receipts
	// Mail
	private static let docs: SidebarItem = .init(id: .tab(id(2)), title: "Docs")
	private static let boards: SidebarItem = .init(id: .tab(id(4)), title: "Boards")
	private static let jackets: SidebarItem = .init(id: .tab(id(5)), title: "Snow Jackets & Hoodies")
	private static let receipts: SidebarItem = .init(id: .tab(id(7)), title: "Receipts")
	private static let old: SidebarItem = .init(id: .folder(id(6)), title: "Old", children: [receipts])
	private static let snowboarding: SidebarItem = .init(
		id: .folder(id(3)),
		title: "Snowboarding",
		children: [boards, jackets, old]
	)
	private static let work: SidebarItem = .init(
		id: .folder(id(1)),
		title: "Work",
		children: [docs, snowboarding],
		isExpanded: true
	)
	private static let mail: SidebarItem = .init(id: .tab(id(8)), title: "Mail")

	private static func rows(
		_ items: [SidebarItem] = [work, mail],
		revealing revealed: Set<SidebarItem.ID>
	) -> [Row] {
		SidebarTreeRow.flatten(items, revealing: revealed).map(Row.init)
	}

	@Test
	internal func aCollapsedFolderShowsOnlyItsSelectedTabOneLevelIn() {
		expectNoDifference(Self.rows(revealing: [Self.jackets.id]), [
			.init(Self.work, depth: 0),
			.init(Self.docs, depth: 1),
			.init(Self.snowboarding, depth: 1, isPartlyRevealed: true),
			.init(Self.jackets, depth: 2),
			.init(Self.mail, depth: 0),
		])
	}

	@Test
	internal func aSelectionOutsideTheFolderHidesItsTabsAgain() {
		let collapsed: [Row] = [
			.init(Self.work, depth: 0),
			.init(Self.docs, depth: 1),
			.init(Self.snowboarding, depth: 1),
			.init(Self.mail, depth: 0),
		]
		expectNoDifference(Self.rows(revealing: [Self.mail.id]), collapsed)
		expectNoDifference(Self.rows(revealing: []), collapsed)
	}

	@Test
	internal func anExpandedFolderShowsAllItsTabsAsUsual() {
		var expanded = Self.snowboarding
		expanded.isExpanded = true
		expectNoDifference(Self.rows([expanded], revealing: [Self.jackets.id]), [
			.init(expanded, depth: 0),
			.init(Self.boards, depth: 1),
			.init(Self.jackets, depth: 1),
			.init(Self.old, depth: 1),
		])
	}

	/// The tab shows under the nearest folder still on screen, however many collapsed folders
	/// hold it, and an expanded folder between them doesn't change that.
	@Test
	internal func aNestedTabShowsUnderItsNearestVisibleCollapsedFolder() {
		expectNoDifference(Self.rows(revealing: [Self.receipts.id]), [
			.init(Self.work, depth: 0),
			.init(Self.docs, depth: 1),
			.init(Self.snowboarding, depth: 1, isPartlyRevealed: true),
			.init(Self.receipts, depth: 2),
			.init(Self.mail, depth: 0),
		])

		var openOld = Self.old
		openOld.isExpanded = true
		var collapsedWork = Self.work
		collapsedWork.isExpanded = false
		collapsedWork.children = [Self.docs, .init(id: Self.snowboarding.id, title: "Snowboarding", children: [openOld])]
		expectNoDifference(Self.rows([collapsedWork], revealing: [Self.receipts.id]), [
			.init(collapsedWork, depth: 0, isPartlyRevealed: true),
			.init(Self.receipts, depth: 1),
		])
	}

	/// Every tab of the shown split stays visible, and a Split View row shows whole when any of
	/// its members is shown.
	@Test
	internal func aSplitShowsWhole() {
		expectNoDifference(Self.rows(revealing: [Self.jackets.id, Self.boards.id]), [
			.init(Self.work, depth: 0),
			.init(Self.docs, depth: 1),
			.init(Self.snowboarding, depth: 1, isPartlyRevealed: true),
			.init(Self.boards, depth: 2),
			.init(Self.jackets, depth: 2),
			.init(Self.mail, depth: 0),
		])

		let splitRow = SidebarItem(
			id: Self.boards.id,
			title: "Boards",
			split: .init(id: Self.id(20), members: [Self.boards, Self.jackets])
		)
		let folder = SidebarItem(id: .folder(Self.id(21)), title: "Gear", children: [Self.docs, splitRow])
		expectNoDifference(Self.rows([folder], revealing: [Self.jackets.id]), [
			.init(folder, depth: 0, isPartlyRevealed: true),
			.init(splitRow, depth: 1),
		])
	}

	/// ← from the shown tab goes to its folder, and → on the folder still expands it.
	@Test
	internal func theArrowKeysTreatTheShownTabAsTheFoldersChild() {
		let rows = SidebarTreeRow.flatten([Self.work, Self.mail], revealing: [Self.jackets.id])
		#expect(SidebarKeyboardNavigation.outcome(of: .left, from: Self.jackets.id, in: rows) == .focus(Self.snowboarding.id))
		#expect(SidebarKeyboardNavigation.outcome(of: .down, from: Self.snowboarding.id, in: rows) == .focus(Self.jackets.id))
		#expect(SidebarKeyboardNavigation.outcome(of: .right, from: Self.snowboarding.id, in: rows) == .toggle(Self.snowboarding.id))
	}

	/// A drop between the folder and its shown tab lands in the folder, before that tab.
	@Test
	internal func aDropAboveTheShownTabLandsBeforeItInTheFolder() {
		let rows = SidebarTreeRow.flatten([Self.snowboarding, Self.mail], revealing: [Self.jackets.id])
		var frames: [SidebarItem.ID: CGRect] = [:]
		for (index, row) in rows.enumerated() {
			frames[row.id] = .init(x: 0, y: CGFloat(index) * 30, width: 240, height: 30)
		}
		let layout = SidebarDropLayout(savedRows: rows, regularTabs: [], frames: frames, newTabFrame: .zero)
		let placement = layout.placement(at: .init(x: 40, y: 31))
		#expect(placement?.target == .before(Self.jackets.id))
		#expect(placement?.depth == 1)
	}

	/// A tab shown from a folder deeper in takes drops beside it into the folder it shows under,
	/// not into the hidden folder that holds it.
	@Test
	internal func aDropBesideATabFromADeeperFolderLandsInTheShownFolder() {
		let rows = SidebarTreeRow.flatten([Self.snowboarding, Self.mail], revealing: [Self.receipts.id])
		expectNoDifference(rows.map(\.shownParentID), [nil, Self.snowboarding.id, nil])
		var frames: [SidebarItem.ID: CGRect] = [:]
		for (index, row) in rows.enumerated() {
			frames[row.id] = .init(x: 0, y: CGFloat(index) * 30, width: 240, height: 30)
		}
		let layout = SidebarDropLayout(savedRows: rows, regularTabs: [], frames: frames, newTabFrame: .zero)

		// Above the shown tab, and below it at its indentation.
		#expect(layout.placement(at: .init(x: 40, y: 31))?.target == .inside(Self.snowboarding.id))
		#expect(layout.placement(at: .init(x: 40, y: 59))?.target == .inside(Self.snowboarding.id))
		// Below it at the folder's own level, after the folder.
		#expect(layout.placement(at: .init(x: 4, y: 59))?.target == .before(Self.mail.id))
	}

	/// Selecting a row below a shown tab doesn't move that row up under the pointer before a
	/// double-click's second click: the tab lingers while the pointer is in the sidebar.
	@Test
	internal func aTabTheSelectionLeavesLingersOnlyUnderThePointer() {
		let jackets: Set<SidebarItem.ID> = [Self.jackets.id]
		let mail: Set<SidebarItem.ID> = [Self.mail.id]
		#expect(SidebarFolderReveal.lingering(after: jackets, now: mail, pointerInSidebar: true) == jackets)
		#expect(SidebarFolderReveal.lingering(after: jackets, now: mail, pointerInSidebar: false).isEmpty)
		#expect(SidebarFolderReveal.lingering(after: jackets, now: jackets.union(mail), pointerInSidebar: true).isEmpty)
		expectNoDifference(
			Self.rows(revealing: jackets.union(mail)).map(\.id),
			[Self.work, Self.docs, Self.snowboarding, Self.jackets, Self.mail].map(\.id)
		)
	}

	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() {
		#expect(SidebarFolderReveal.isOn(read: { _ in nil }))
		#expect(SidebarFolderReveal.isOn(read: { _ in "1" }))
		for value in ["0", "false", "NO", "off"] {
			#expect(!SidebarFolderReveal.isOn(read: { $0 == "ARX_COLLAPSED_FOLDER_SHOWS_SELECTION" ? value : nil }), "\(value)")
		}
	}

	private static func id(_ value: UInt8) -> UUID {
		UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
	}

	/// What a row shows, compared whole.
	private struct Row: Equatable {
		let id: SidebarItem.ID
		let title: String
		let depth: Int
		let isPartlyRevealed: Bool

		init(
			_ item: SidebarItem,
			depth: Int,
			isPartlyRevealed: Bool = false
		) {
			self.id = item.id
			self.title = item.title
			self.depth = depth
			self.isPartlyRevealed = isPartlyRevealed
		}

		init(_ row: SidebarTreeRow) {
			self.init(row.item, depth: row.depth, isPartlyRevealed: row.isPartlyRevealed)
		}
	}
}

/// Writes offscreen PNGs of a collapsed folder showing its selected tab, next to plain collapsed
/// folders, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory (DEV-1110).
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct SidebarFolderRevealSnapshotTests {
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func partlyRevealedFolder(_ appearance: NSAppearance.Name) throws {
		let jackets = SidebarItem(id: .tab(Self.id(5)), title: "Snow Jackets & Hoodies", symbol: "figure.snowboarding")
		let items: [SidebarItem] = [
			.init(id: .folder(Self.id(1)), title: "Clothes", children: [.init(id: .tab(Self.id(11)), title: "Shirts")]),
			.init(id: .folder(Self.id(2)), title: "Photography", children: [.init(id: .tab(Self.id(12)), title: "Lenses")]),
			.init(id: .folder(Self.id(3)), title: "Snowboarding", children: [
				.init(id: .tab(Self.id(4)), title: "Boards"),
				jackets,
				.init(id: .tab(Self.id(6)), title: "Bindings"),
			]),
			.init(id: .folder(Self.id(7)), title: "Pull Requests", children: [.init(id: .tab(Self.id(13)), title: "Arx")]),
			.init(id: .tab(Self.id(8)), title: "Online Editing Courses", symbol: "square.fill"),
		]
		let rows = SidebarTreeRow.flatten(items, revealing: [jackets.id])
		let view = VStack(spacing: BrowserMetrics.Row.spacing) {
			ForEach(rows) { row in
				SidebarRow(
					item: row.item,
					depth: row.depth,
					isPartlyRevealed: row.isPartlyRevealed,
					selected: row.id == jackets.id,
					onAction: { _ in }
				)
			}
		}
		.padding(BrowserMetrics.Sidebar.horizontalPadding)
		.frame(width: 260, alignment: .top)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		try SidebarChromeSnapshot.write(
			view,
			size: .init(width: 260, height: 260),
			appearance: appearance,
			name: "folder-partly-revealed"
		)
	}

	private static func id(_ value: UInt8) -> UUID {
		UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
	}
}
