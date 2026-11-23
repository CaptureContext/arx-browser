@testable import AppUI
import Foundation
import Testing

/// DEV-731: the arrow keys move focus between sidebar rows and open and close folders, as in
/// Finder's list view and NSOutlineView.
internal struct SidebarKeyboardNavigationTests {
	private typealias Navigation = SidebarKeyboardNavigation

	// Work (expanded)
	//   Docs
	//   Archive (expanded)
	//     Old
	//   Later (collapsed, holding Hidden)
	// Mail
	// News (open tab)
	private static let docs: SidebarItem = .init(id: .tab(id(2)), title: "Docs")
	private static let old: SidebarItem = .init(id: .tab(id(4)), title: "Old")
	private static let hidden: SidebarItem = .init(id: .tab(id(6)), title: "Hidden")
	private static let archive: SidebarItem = .init(id: .folder(id(3)), title: "Archive", children: [old], isExpanded: true)
	private static let later: SidebarItem = .init(id: .folder(id(5)), title: "Later", children: [hidden])
	private static let work: SidebarItem = .init(
		id: .folder(id(1)),
		title: "Work",
		children: [docs, archive, later],
		isExpanded: true
	)
	private static let mail: SidebarItem = .init(id: .tab(id(7)), title: "Mail")
	private static let news: SidebarItem = .init(id: .tab(id(8)), title: "News", isPinned: false)

	private static var rows: [SidebarTreeRow] {
		SidebarTreeRow.flatten([work, mail]) + [.init(item: news, depth: 0)]
	}

	@Test
	internal func downAndUpFollowReadingOrderAndSkipCollapsedFolders() {
		let order = [Self.work, Self.docs, Self.archive, Self.old, Self.later, Self.mail, Self.news].map(\.id)
		for (current, next) in zip(order, order.dropFirst()) {
			#expect(Navigation.outcome(of: .down, from: current, in: Self.rows) == .focus(next))
			#expect(Navigation.outcome(of: .up, from: next, in: Self.rows) == .focus(current))
		}
		#expect(!Self.rows.contains { $0.id == Self.hidden.id })
	}

	@Test
	internal func theEndsGoNowhere() {
		#expect(Navigation.outcome(of: .up, from: Self.work.id, in: Self.rows) == nil)
		#expect(Navigation.outcome(of: .down, from: Self.news.id, in: Self.rows) == nil)
	}

	@Test
	internal func rightExpandsACollapsedFolderThenMovesToItsFirstChild() {
		#expect(Navigation.outcome(of: .right, from: Self.later.id, in: Self.rows) == .toggle(Self.later.id))
		#expect(Navigation.outcome(of: .right, from: Self.work.id, in: Self.rows) == .focus(Self.docs.id))
		#expect(Navigation.outcome(of: .right, from: Self.archive.id, in: Self.rows) == .focus(Self.old.id))
	}

	@Test
	internal func rightOnATabOrAnEmptyExpandedFolderDoesNothing() {
		let empty = SidebarItem(id: .folder(Self.id(9)), title: "Empty", isExpanded: true)
		let rows = SidebarTreeRow.flatten([empty, Self.mail])
		#expect(Navigation.outcome(of: .right, from: empty.id, in: rows) == nil)
		#expect(Navigation.outcome(of: .right, from: Self.mail.id, in: rows) == nil)
	}

	@Test
	internal func leftCollapsesAnExpandedFolder() {
		#expect(Navigation.outcome(of: .left, from: Self.work.id, in: Self.rows) == .toggle(Self.work.id))
		#expect(Navigation.outcome(of: .left, from: Self.archive.id, in: Self.rows) == .toggle(Self.archive.id))
	}

	@Test
	internal func leftOnAChildMovesToItsParent() {
		#expect(Navigation.outcome(of: .left, from: Self.docs.id, in: Self.rows) == .focus(Self.work.id))
		#expect(Navigation.outcome(of: .left, from: Self.old.id, in: Self.rows) == .focus(Self.archive.id))
		// A collapsed folder inside another moves to its parent rather than doing nothing.
		#expect(Navigation.outcome(of: .left, from: Self.later.id, in: Self.rows) == .focus(Self.work.id))
	}

	@Test
	internal func leftOnATopLevelTabDoesNothing() {
		#expect(Navigation.outcome(of: .left, from: Self.mail.id, in: Self.rows) == nil)
		#expect(Navigation.outcome(of: .left, from: Self.news.id, in: Self.rows) == nil)
	}

	@Test
	internal func aFolderThatCantDiscloseIsNeverToggled() {
		var locked = Self.later
		locked.interactions.remove(.disclose)
		var open = Self.archive
		open.interactions.remove(.disclose)
		let rows = SidebarTreeRow.flatten([locked, open])
		#expect(Navigation.outcome(of: .right, from: locked.id, in: rows) == nil)
		#expect(Navigation.outcome(of: .left, from: open.id, in: rows) == nil)
	}

	@Test
	internal func aRowMissingFromTheListGoesNowhere() {
		#expect(Navigation.outcome(of: .down, from: Self.hidden.id, in: Self.rows) == nil)
	}

	private static func id(_ value: Int) -> UUID {
		UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
	}
}

