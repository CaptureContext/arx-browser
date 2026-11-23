@testable import AppUI
import Foundation
import Testing

/// DEV-836: the search in a folder's hover preview stays open once engaged, moves its selection
/// with the arrows and the pointer, and opens the selected tab on Return.
internal struct SidebarFolderSearchTests {
	private let results: [UUID] = [UUID(1), UUID(2), UUID(3)]

	// MARK: - Open and close

	@Test
	internal func pointerLeavingClosesUntilTheSearchIsEngaged() {
		var search = SidebarFolderSearch()
		#expect(search.reduce(.pointerLeft) == .dismiss)

		search = .init()
		#expect(search.reduce(.focused) == .none)
		#expect(search.isEngaged)
		#expect(search.reduce(.pointerLeft) == .none)
	}

	@Test
	internal func typingKeepsThePreviewOpenEvenWithNoResults() {
		var search = SidebarFolderSearch()
		#expect(search.reduce(.queryChanged("zzz")) == .none)
		#expect(search.isEngaged)
		#expect(search.selection(in: []) == nil)
		#expect(search.reduce(.pointerLeft) == .none)
		#expect(search.reduce(.submitted(results: [])) == .none)
	}

	@Test
	internal func clearingTheQueryStaysEngaged() {
		var search = SidebarFolderSearch()
		_ = search.reduce(.queryChanged("a"))
		_ = search.reduce(.queryChanged(""))
		#expect(search.isEngaged)
		#expect(search.reduce(.pointerLeft) == .none)
	}

	@Test
	internal func anUnchangedQueryDoesNotEngage() {
		var search = SidebarFolderSearch()
		_ = search.reduce(.queryChanged(""))
		#expect(!search.isEngaged)
	}

	@Test
	internal func clickingElsewhereOrEscapeCloses() {
		var search = SidebarFolderSearch(query: "a", isEngaged: true)
		#expect(search.reduce(.clickedElsewhere) == .dismiss)
		search = .init(query: "a", isEngaged: true)
		#expect(search.reduce(.escape) == .dismiss)
	}

	@Test
	internal func pickingATabOpensIt() {
		var search = SidebarFolderSearch(query: "a", isEngaged: true)
		#expect(search.reduce(.rowClicked(UUID(2))) == .open(UUID(2)))
	}

	// MARK: - Selection

	@Test
	internal func theFirstResultIsSelectedWhileThereIsAQuery() {
		var search = SidebarFolderSearch()
		#expect(search.selection(in: results) == nil)
		_ = search.reduce(.queryChanged("a"))
		#expect(search.selection(in: results) == UUID(1))
		#expect(search.reduce(.submitted(results: results)) == .open(UUID(1)))
	}

	@Test
	internal func arrowsMoveTheSelectionAndStopAtTheEnds() {
		var search = SidebarFolderSearch(query: "a", isEngaged: true)
		_ = search.reduce(.moved(.down, results: results))
		#expect(search.selection(in: results) == UUID(2))
		_ = search.reduce(.moved(.down, results: results))
		_ = search.reduce(.moved(.down, results: results))
		#expect(search.selection(in: results) == UUID(3))
		_ = search.reduce(.moved(.up, results: results))
		_ = search.reduce(.moved(.up, results: results))
		_ = search.reduce(.moved(.up, results: results))
		#expect(search.selection(in: results) == UUID(1))
		#expect(search.reduce(.submitted(results: results)) == .open(UUID(1)))
	}

	@Test
	internal func arrowsWithoutAQueryStartAtEitherEnd() {
		var search = SidebarFolderSearch(isEngaged: true)
		_ = search.reduce(.moved(.down, results: results))
		#expect(search.selection(in: results) == UUID(1))

		search = .init(isEngaged: true)
		_ = search.reduce(.moved(.up, results: results))
		#expect(search.selection(in: results) == UUID(3))

		search = .init(isEngaged: true)
		_ = search.reduce(.moved(.down, results: []))
		#expect(search.selection == nil)
	}

	@Test
	internal func pointerAndArrowsShareOneSelection() {
		var search = SidebarFolderSearch(query: "a", isEngaged: true)
		_ = search.reduce(.rowHovered(UUID(2)))
		#expect(search.selection(in: results) == UUID(2))
		_ = search.reduce(.moved(.down, results: results))
		#expect(search.selection(in: results) == UUID(3))
		_ = search.reduce(.rowHovered(UUID(1)))
		#expect(search.reduce(.submitted(results: results)) == .open(UUID(1)))
	}

	@Test
	internal func theSelectionStaysWhileItsRowIsListedAndFallsBackToTheFirst() {
		var search = SidebarFolderSearch(query: "a", isEngaged: true)
		_ = search.reduce(.rowHovered(UUID(3)))

		// Filtering keeps the selected row.
		#expect(search.selection(in: [UUID(2), UUID(3)]) == UUID(3))
		// Filtering it out selects the first remaining result.
		#expect(search.selection(in: [UUID(1), UUID(2)]) == UUID(1))
	}

	@Test
	internal func resultIDsFollowTheListedOrder() {
		let folder = SidebarItem(
			id: .folder(UUID(10)),
			title: "Research",
			children: [
				.init(id: .folder(UUID(11)), title: "Papers", children: [
					.init(id: .tab(UUID(2)), title: "Attention"),
				]),
				.init(id: .tab(UUID(1)), title: "Overview"),
				.init(id: .tab(UUID(3)), title: "Notes"),
			]
		)
		let contents = SidebarFolderPreview(folder: folder, tabs: [:])
		#expect(contents.resultIDs() == [UUID(1), UUID(3), UUID(2)])
		#expect(contents.resultIDs(matching: "Papers") == [UUID(2)])
		#expect(contents.resultIDs(matching: "ov") == [UUID(1)])
	}
}

extension UUID {
	fileprivate init(_ value: Int) {
		self.init(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
	}
}

/// DEV-1275: a Split View in a folder is one row naming its panes, and the search finds it by any pane.
internal struct SidebarFolderPreviewSplitTests {
	@Test
	internal func aSplitViewIsOneRowNamingItsPanes() throws {
		let split = SidebarItem.Split(
			id: UUID(20),
			members: [
				.init(id: .tab(UUID(1)), title: "Swift Forums"),
				.init(id: .tab(UUID(2)), title: "Swift Evolution"),
			]
		)
		let folder = SidebarItem(
			id: .folder(UUID(10)),
			title: "Reading",
			children: [
				.init(id: .tab(UUID(1)), title: "Swift Forums", split: split),
				.init(id: .tab(UUID(3)), title: "Linear"),
			]
		)
		let preview = SidebarFolderPreview(folder: folder, tabs: [:])
		let row = try #require(preview.entries.first)
		#expect(preview.entries.count == 2)
		#expect(row.title == "Swift Forums | Swift Evolution")
		#expect(row.splitPanes == 2)
		#expect(row.symbol == "rectangle.split.2x1")
		#expect(preview.resultIDs(matching: "evolution") == [UUID(1)])
	}

	@Test
	internal func aNamedSplitViewKeepsItsName() throws {
		let split = SidebarItem.Split(
			id: UUID(20),
			members: [.init(id: .tab(UUID(1)), title: "A"), .init(id: .tab(UUID(2)), title: "B")],
			title: "Research",
			isVertical: true
		)
		let folder = SidebarItem(id: .folder(UUID(10)), title: "F", children: [.init(id: .tab(UUID(1)), title: "A", split: split)])
		let row = try #require(SidebarFolderPreview(folder: folder, tabs: [:]).entries.first)
		#expect(row.title == "Research")
		#expect(row.symbol == "rectangle.split.1x2")
	}
}
