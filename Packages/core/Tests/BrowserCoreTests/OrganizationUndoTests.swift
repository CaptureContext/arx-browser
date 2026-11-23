import BrowserCore
import CustomDump
import Foundation
import Testing

/// Taking a step back on top of the workspace as it is now (DEV-1030).
internal struct OrganizationUndoTests {
	@Test
	internal func aMoveToAnotherSpaceGoesBackAndKeepsWhatCameSince() throws {
		let before = fixture()
		var after = before
		after.spaces[0].unpinnedTabs.removeAll { $0 == one }
		after.spaces[1].unpinnedTabs.append(one)

		// Since: a tab opened in Work, and Home renamed.
		var now = after
		now.tabs.append(tab(five))
		now.spaces[1].unpinnedTabs.insert(five, at: 0)
		now.spaces[0].name = "Home, renamed"

		let reverted = try #require(try now.reverting(after, to: before))
		expectNoDifference(reverted.spaces[0].unpinnedTabs, [one, two])
		expectNoDifference(reverted.spaces[1].unpinnedTabs, [five, four])
		expectNoDifference(reverted.spaces[0].name, "Home, renamed")
	}

	@Test
	internal func aTabMovedAgainSinceStaysWhereItIs() throws {
		let before = fixture()
		var after = before
		after.spaces[0].unpinnedTabs.removeAll { $0 == one }
		after.spaces[1].unpinnedTabs.append(one)
		var now = after
		now.spaces[1].unpinnedTabs.removeAll { $0 == one }
		now.spaces[0].unpinnedTabs.append(one)

		#expect(try now.reverting(after, to: before) == nil)
	}

	@Test
	internal func aDeletedSpaceComesBackWithItsTabsAndFolders() throws {
		let before = fixture()
		let after = try before.applying(.removeSpace(home), uuid: UUID.init)
		var now = after
		now.spaces[0].name = "Work, renamed"

		let reverted = try #require(try now.reverting(after, to: before))
		expectNoDifference(reverted.spaces.ids.elements, [home, work])
		expectNoDifference(reverted.spaces[0], before.spaces[0])
		expectNoDifference(reverted.folders, before.folders)
		expectNoDifference(Set(reverted.tabs.ids), Set(before.tabs.ids))
		expectNoDifference(reverted.spaces[1].name, "Work, renamed")
	}

	/// A space made by the step goes, but not when it's the last one left: the space it was made
	/// beside was deleted for good since.
	@Test
	internal func undoingASpacesCreationNeverLeavesNoSpace() throws {
		let after = fixture()
		let before = try after.applying(.removeSpace(work), uuid: UUID.init)
		let now = try after.applying(.removeSpace(home), uuid: UUID.init)

		#expect(throws: BrowserOrganization.UndoError.conflict) { try now.reverting(after, to: before) }
	}

	@Test
	internal func aClosedTabComesBackWhileRecentlyClosedHoldsIt() throws {
		let before = fixture()
		var after = before
		let entries = after.archiveEntries(for: [one], closedAt: .init(timeIntervalSince1970: 1), groupID: UUID(0), uuid: { UUID(1) })
		try after.archiveClosedTabs(entries)

		let reverted = try #require(try after.reverting(after, to: before))
		expectNoDifference(reverted.spaces[0].unpinnedTabs, [one, two])
		expectNoDifference(reverted.archive, [])
		expectNoDifference(reverted.tabs[id: one], before.tabs[id: one])
	}

	/// ⌘Z passes over a close that ⇧⌘T already reopened.
	@Test
	internal func aClosedTabReopenedSinceIsPassedOver() throws {
		let before = fixture()
		var after = before
		let entries = after.archiveEntries(for: [one], closedAt: .init(timeIntervalSince1970: 1), groupID: UUID(0), uuid: { UUID(1) })
		try after.archiveClosedTabs(entries)
		let now = try after.restoringArchive(entries.map(\.id), uuid: { UUID(2) })

		#expect(try now.reverting(after, to: before) == nil)
	}

	@Test
	internal func aNewTabGoesAwayUnlessMovedSince() throws {
		let before = fixture()
		var after = before
		after.tabs.append(tab(five))
		after.spaces[0].unpinnedTabs.append(five)

		let reverted = try #require(try after.reverting(after, to: before))
		expectNoDifference(reverted, before)

		var now = after
		now.spaces[0].unpinnedTabs.removeAll { $0 == five }
		now.spaces[1].unpinnedTabs.append(five)
		#expect(try now.reverting(after, to: before) == nil)
	}

	@Test
	internal func aDeletedFolderComesBackWithItsTabs() throws {
		let before = fixture()
		var after = before
		after.spaces[0].savedItems = []
		after.folders.remove(id: folder)
		after.tabs.remove(id: three)

		let reverted = try #require(try after.reverting(after, to: before))
		expectNoDifference(reverted, before)
	}

	@Test
	internal func aFavoriteGoesBackIntoItsFolder() throws {
		let before = fixture()
		var after = before
		after.folders[id: folder]?.children = []
		after.profiles[0].favorites = [three]

		let reverted = try #require(try after.reverting(after, to: before))
		expectNoDifference(reverted, before)
	}

	@Test
	internal func aPinnedTabGetsBackItsOpenState() throws {
		let before = fixture()
		var after = before
		after.spaces[0].unpinnedTabs.removeAll { $0 == two }
		after.spaces[0].savedItems.append(.tab(two))
		after.tabs[id: two]?.savedDestination = .init(title: "Two", url: url)

		// Since: Two's page loaded somewhere else.
		var now = after
		now.tabs[id: two]?.restoration.url = URL(string: "https://example.com/later")!

		let reverted = try #require(try now.reverting(after, to: before))
		expectNoDifference(reverted.spaces[0].unpinnedTabs, [one, two])
		expectNoDifference(reverted.tabs[id: two]?.savedDestination, nil)
		expectNoDifference(reverted.tabs[id: two]?.restoration.url, URL(string: "https://example.com/later")!)
	}

	@Test
	internal func aStepTakenBackAlreadyHasNothingLeft() throws {
		let before = fixture()
		var after = before
		after.spaces[0].name = "Renamed"

		let reverted = try #require(try after.reverting(after, to: before))
		#expect(try reverted.reverting(after, to: before) == nil)
	}

	/// A closed tab whose space is gone since stays in Recently Closed.
	@Test
	internal func aClosedTabWithNowhereToGoStaysInRecentlyClosed() throws {
		let before = fixture()
		var after = before
		let entries = after.archiveEntries(for: [four], closedAt: .init(timeIntervalSince1970: 1), groupID: UUID(0), uuid: { UUID(1) })
		try after.archiveClosedTabs(entries)
		let now = try after.applying(.removeSpace(work), uuid: UUID.init)

		#expect(try now.reverting(after, to: before) == nil)
	}

	@Test
	internal func aProfileTheStepMadeGoesWithItsSpace() throws {
		let before = fixture()
		var after = before
		let made = Profile.ID(rawValue: UUID(11))
		after.profiles.append(.init(id: made, name: "New"))
		after.spaces.append(.init(id: Space.ID(rawValue: UUID(22)), profileID: made, name: "New"))

		let reverted = try #require(try after.reverting(after, to: before))
		expectNoDifference(reverted, before)
	}

	@Test
	internal func aSpaceMovedToAnotherProfileGoesBack() throws {
		var before = fixture()
		let other = Profile.ID(rawValue: UUID(11))
		before.profiles.append(.init(id: other, name: "Other"))
		let after = try before.applying(
			.updateSpace(work, profileID: other, name: "Work", icon: .stack),
			uuid: { UUID(90) }
		)

		let reverted = try #require(try after.reverting(after, to: before))
		expectNoDifference(reverted.spaces[id: work]?.profileID, profile)
		expectNoDifference(reverted.spaces[id: work]?.unpinnedTabs, [four])
		expectNoDifference(reverted.tabs[id: four], before.tabs[id: four])
	}

	@Test
	internal func aNewFolderMovedSinceStays() throws {
		let before = fixture()
		var after = before
		let made = Folder.ID(rawValue: UUID(31))
		after.folders.append(.init(id: made, spaceID: home, name: "New"))
		after.spaces[0].savedItems.append(.folder(made))
		var now = after
		now.spaces[0].savedItems.removeAll { $0 == .folder(made) }
		now.folders[id: folder]?.children.append(.folder(made))

		#expect(try now.reverting(after, to: before) == nil)
	}

	/// A split view separated by the step comes back, unless a split made since holds its tabs.
	@Test
	internal func aSeparatedSplitComesBackUnlessItsTabsWereSplitAgain() throws {
		var before = fixture()
		before.splits = [.init(id: .init(rawValue: UUID(50)), spaceID: home, tabIDs: [one, two])]
		var after = before
		after.splits = []

		let reverted = try #require(try after.reverting(after, to: before))
		expectNoDifference(reverted.splits, before.splits)

		var now = after
		now.splits = [.init(id: .init(rawValue: UUID(51)), spaceID: home, tabIDs: [one, two], title: "Newer")]
		#expect(try now.reverting(after, to: before) == nil)
	}

	/// A tab the step took out of a split stays in a split made with it since.
	@Test
	internal func aTabSplitAgainSinceStaysInItsNewerSplit() throws {
		var before = fixture()
		before.tabs.append(tab(five))
		before.spaces[0].unpinnedTabs = [one, two, five]
		before.splits = [.init(id: .init(rawValue: UUID(50)), spaceID: home, tabIDs: [one, two, five])]
		var after = before
		after.splits[0].tabIDs = [one, two]
		after.splits[0].fractions = [0.5, 0.5]
		var now = after
		now.spaces[0].unpinnedTabs = [one, two, five, four]
		now.spaces[1].unpinnedTabs = []
		now.spaces[1].selectedTabID = nil
		now.splits.append(.init(id: .init(rawValue: UUID(51)), spaceID: home, tabIDs: [five, four]))
		try now.update { _ in }

		let reverted = try now.reverting(after, to: before) ?? now
		expectNoDifference(reverted.splits[id: .init(rawValue: UUID(51))]?.tabIDs, [five, four])
	}

	/// A tab the step took out of a group stays in a group that was already there and took it in
	/// since.
	@Test
	internal func aTabGroupedAgainSinceStaysInTheGroupThatTookItIn() throws {
		let six = Tab.ID(rawValue: UUID(46))
		let first = TabGroup.ID(rawValue: UUID(60))
		let second = TabGroup.ID(rawValue: UUID(61))
		var before = fixture()
		before.tabs.append(contentsOf: [tab(five), tab(six)])
		before.spaces[0].unpinnedTabs = [one, two, five, four, six]
		before.spaces[1].unpinnedTabs = []
		before.spaces[1].selectedTabID = nil
		before.tabGroups = [
			.init(id: first, spaceID: home, name: "First", tabIDs: [one, two, five]),
			.init(id: second, spaceID: home, name: "Second", tabIDs: [four, six]),
		]
		var after = before
		after.tabGroups[id: first]?.tabIDs = [one, two]
		after.spaces[0].name = "Home, renamed"
		var now = after
		now.spaces[0].unpinnedTabs = [one, two, four, six, five]
		now.tabGroups[id: second]?.tabIDs = [four, six, five]
		try now.update { _ in }

		let reverted = try #require(try now.reverting(after, to: before))
		expectNoDifference(reverted.spaces[0].name, "Home")
		expectNoDifference(reverted.tabGroups[id: first]?.tabIDs, [one, two])
		expectNoDifference(reverted.tabGroups[id: second]?.tabIDs, [four, six, five])
	}

	/// A pin's saved address the step changed goes back, keeping a name given since.
	@Test
	internal func aSavedAddressGoesBackAndKeepsANewerName() throws {
		let before = fixture()
		var after = before
		let changed = URL(string: "https://example.com/changed")!
		after.tabs[id: three]?.savedDestination?.url = changed
		var now = after
		now.tabs[id: three]?.savedDestination?.title = "Renamed"

		let reverted = try #require(try now.reverting(after, to: before))
		expectNoDifference(reverted.tabs[id: three]?.savedDestination, .init(title: "Renamed", url: url))
	}

	/// A tab the step pinned into a folder stays in it when the folder moved to another space
	/// since, with everything in it.
	@Test
	internal func aTabPinnedIntoAFolderMovedSinceStaysInIt() throws {
		let before = fixture()
		var after = before
		after.spaces[0].unpinnedTabs.removeAll { $0 == one }
		after.folders[id: folder]?.children.append(.tab(one))
		after.tabs[id: one]?.savedDestination = .init(title: "Saved", url: url)
		var now = after
		now.spaces[0].savedItems.removeAll { $0 == .folder(folder) }
		now.spaces[1].savedItems.append(.folder(folder))
		now.folders[id: folder]?.spaceID = work

		let reverted = try now.reverting(after, to: before)
		#expect(reverted == nil || reverted?.folders[id: folder]?.children.contains(.tab(one)) == true)
		#expect(reverted?.spaces[0].unpinnedTabs.contains(one) != true)
	}

	/// A tab the step made in a folder stays when the folder moved to another space since.
	@Test
	internal func aTabMadeInAFolderMovedSinceStays() throws {
		let before = fixture()
		var after = before
		after.tabs.append(tab(five, saved: true))
		after.folders[id: folder]?.children.append(.tab(five))
		var now = after
		now.spaces[0].savedItems.removeAll { $0 == .folder(folder) }
		now.spaces[1].savedItems.append(.folder(folder))
		now.folders[id: folder]?.spaceID = work

		let reverted = try now.reverting(after, to: before)
		#expect(reverted == nil || reverted?.tabs[id: five] != nil)
	}

	/// A tab the step made and someone renamed since stays.
	@Test
	internal func aTabMadeAndRenamedSinceStays() throws {
		let before = fixture()
		var after = before
		after.tabs.append(tab(five))
		after.spaces[0].unpinnedTabs.append(five)
		var now = after
		now.tabs[id: five]?.customTitle = "Mine"

		let reverted = try now.reverting(after, to: before)
		#expect(reverted == nil || reverted?.tabs[id: five]?.customTitle == "Mine")
	}

	/// A pin moved to another folder keeps a saved page changed since.
	@Test
	internal func aMovedPinKeepsItsNewerSavedPage() throws {
		let before = fixture()
		var after = before
		after.folders[id: folder]?.children = []
		after.spaces[0].savedItems.append(.tab(three))
		var now = after
		let newer = Tab.SavedDestination(title: "Newer", url: URL(string: "https://example.com/newer")!)
		now.tabs[id: three]?.savedDestination = newer

		let reverted = try #require(try now.reverting(after, to: before))
		expectNoDifference(reverted.folders[id: folder]?.children, [.tab(three)])
		expectNoDifference(reverted.tabs[id: three]?.savedDestination, newer)
	}

	// MARK: - Fixture

	private let profile = Profile.ID(rawValue: UUID(10))
	private let home = Space.ID(rawValue: UUID(20))
	private let work = Space.ID(rawValue: UUID(21))
	private let folder = Folder.ID(rawValue: UUID(30))
	private let one = Tab.ID(rawValue: UUID(41))
	private let two = Tab.ID(rawValue: UUID(42))
	private let three = Tab.ID(rawValue: UUID(43))
	private let four = Tab.ID(rawValue: UUID(44))
	private let five = Tab.ID(rawValue: UUID(45))
	private let url = URL(string: "https://example.com")!

	private func tab(
		_ id: Tab.ID,
		saved: Bool = false
	) -> Tab {
		.init(
			id: id,
			profileID: profile,
			savedDestination: saved ? .init(title: "Saved", url: url) : nil,
			restoration: .init(title: "Page", url: url)
		)
	}

	/// Home: One and Two open, Three pinned in a folder. Work: Four open.
	private func fixture() -> BrowserOrganization {
		.init(
			profiles: [.init(id: profile, name: "Personal")],
			spaces: [
				.init(id: home, profileID: profile, name: "Home", savedItems: [.folder(folder)], unpinnedTabs: [one, two], selectedTabID: one),
				.init(id: work, profileID: profile, name: "Work", unpinnedTabs: [four], selectedTabID: four),
			],
			folders: [.init(id: folder, spaceID: home, name: "Reading", children: [.tab(three)])],
			tabs: [tab(one), tab(two), tab(three, saved: true), tab(four)]
		)
	}
}

extension UUID {
	fileprivate init(_ value: Int) {
		self.init(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
	}
}
