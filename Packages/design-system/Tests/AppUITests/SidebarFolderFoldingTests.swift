@testable import AppUI
import CustomDump
import Foundation
import Testing

/// DEV-1249: the sidebar's rows are a lazy stack, which lays out only the rows it lists. A row it
/// stops listing plays its removal where it last was while the rows below already close up over
/// it, so closing a folder showed the rows under it sliding over its tabs. A closing folder keeps
/// its rows listed, folded to no height, until its spring settles.
internal struct SidebarFolderFoldingTests {
	// Pinned above
	// Folder (collapsed)
	//   One
	//   Inner (expanded)
	//     Two
	//   Three
	// Pinned below
	private static let above: SidebarItem = .init(id: .tab(id(1)), title: "Pinned above")
	private static let one: SidebarItem = .init(id: .tab(id(3)), title: "One")
	private static let two: SidebarItem = .init(id: .tab(id(5)), title: "Two")
	private static let three: SidebarItem = .init(id: .tab(id(6)), title: "Three")
	private static let inner: SidebarItem = .init(id: .folder(id(4)), title: "Inner", children: [two], isExpanded: true)
	private static let folder: SidebarItem = .init(id: .folder(id(2)), title: "Folder", children: [one, inner, three])
	private static let below: SidebarItem = .init(id: .tab(id(7)), title: "Pinned below")

	private static func rows(
		revealing revealed: Set<SidebarItem.ID> = [],
		folding: Set<SidebarItem.ID>
	) -> [Row] {
		SidebarTreeRow.flatten([above, folder, below], revealing: revealed, folding: folding).map(Row.init)
	}

	@Test
	internal func aClosingFolderKeepsItsRowsFoldedInTheirPlaces() {
		expectNoDifference(Self.rows(folding: [Self.folder.id]), [
			.init(Self.above, depth: 0),
			.init(Self.folder, depth: 0),
			.init(Self.one, depth: 1, isFolded: true),
			.init(Self.inner, depth: 1, isFolded: true),
			.init(Self.two, depth: 2, isFolded: true),
			.init(Self.three, depth: 1, isFolded: true),
			.init(Self.below, depth: 0),
		])
	}

	/// The tab the folder goes on showing stays a row like any other, where it sat, one level in
	/// as it shows beneath the closed folder, so it moves up with the rows folding around it.
	@Test
	internal func itsSelectedTabStaysShownAmongTheFoldedRows() {
		expectNoDifference(Self.rows(revealing: [Self.two.id], folding: [Self.folder.id]), [
			.init(Self.above, depth: 0),
			.init(Self.folder, depth: 0, isPartlyRevealed: true),
			.init(Self.one, depth: 1, isFolded: true),
			.init(Self.inner, depth: 1, isFolded: true),
			.init(Self.two, depth: 1),
			.init(Self.three, depth: 1, isFolded: true),
			.init(Self.below, depth: 0),
		])
	}

	/// The rows that aren't folded are what a person sees once the folder has closed.
	@Test
	internal func withoutTheFoldedRowsItIsTheClosedFolder() {
		for revealed: Set<SidebarItem.ID> in [[], [Self.two.id], [Self.below.id]] {
			let folding = Self.rows(revealing: revealed, folding: [Self.folder.id]).filter { !$0.isFolded }
			expectNoDifference(folding, Self.rows(revealing: revealed, folding: []))
		}
	}

	/// Only a collapsed folder folds: an open one listed as folding shows its rows as usual.
	@Test
	internal func anOpenFolderIgnoresFolding() {
		var open = Self.folder
		open.isExpanded = true
		let items: [SidebarItem] = [open]
		expectNoDifference(
			SidebarTreeRow.flatten(items, folding: [open.id]).map(Row.init),
			SidebarTreeRow.flatten(items).map(Row.init)
		)
	}

	@Test
	internal func theOpenFoldersAreFoundAtEveryDepth() {
		var open = Self.folder
		open.isExpanded = true
		#expect(SidebarTreeRow.expandedFolderIDs(in: [Self.above, Self.folder, Self.below]) == [Self.inner.id])
		#expect(SidebarTreeRow.expandedFolderIDs(in: [open]) == [open.id, Self.inner.id])
	}

	@Test
	internal func foldedRowsStayListedUntilTheSpringSettles() {
		let settle: TimeInterval = 0.3 * 1.6
		#expect(SidebarRowMotion.progress(at: settle) > 0.99)
		#expect(SidebarRowMotion.foldDuration >= .milliseconds(Int(settle * 1_000)))
	}

	private struct Row: Equatable {
		let id: SidebarItem.ID
		let title: String
		let depth: Int
		let isPartlyRevealed: Bool
		let isFolded: Bool

		init(
			_ item: SidebarItem,
			depth: Int,
			isPartlyRevealed: Bool = false,
			isFolded: Bool = false
		) {
			self.id = item.id
			self.title = item.title
			self.depth = depth
			self.isPartlyRevealed = isPartlyRevealed
			self.isFolded = isFolded
		}

		init(_ row: SidebarTreeRow) {
			self.init(row.item, depth: row.depth, isPartlyRevealed: row.isPartlyRevealed, isFolded: row.isFolded)
		}
	}

	private static func id(_ value: UInt8) -> UUID {
		UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
	}
}
