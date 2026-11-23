import BrowserCore
import CustomDump
import Foundation
import Testing

/// Groups of open tabs (DEV-911).
internal struct TabGroupTests {
	@Test
	internal func groupingGathersTheTabsWhereTheFirstOneIs() throws {
		var organization = fixture()
		try organization.groupTabs([tab(4), tab(2)], in: space, id: group, name: "Reading")

		expectNoDifference(organization.spaces[0].unpinnedTabs, [tab(1), tab(2), tab(4), tab(3), tab(5)])
		expectNoDifference(organization.tabGroups[id: group]?.tabIDs, [tab(2), tab(4)])
		#expect(organization.tabGroup(containing: tab(4))?.name == "Reading")
	}

	@Test
	internal func aTabBetweenTwoMembersJoinsAndAClosedOneLeaves() throws {
		var organization = fixture()
		try organization.groupTabs([tab(2), tab(3)], in: space, id: group, name: "Reading")
		organization.spaces[0].unpinnedTabs = [tab(1), tab(2), tab(5), tab(3), tab(4)]
		organization.normalizeTabGroups()
		expectNoDifference(organization.tabGroups[id: group]?.tabIDs, [tab(2), tab(5), tab(3)])

		try organization.update { organization in
			let closed: [Tab.ID] = [tab(2), tab(5), tab(3)]
			organization.spaces[0].unpinnedTabs.removeAll(where: closed.contains)
			organization.tabs.removeAll { closed.contains($0.id) }
		}
		#expect(organization.tabGroups.isEmpty)
	}

	@Test
	internal func groupsRoundTripAndOlderWorkspacesHaveNone() throws {
		var organization = fixture()
		try organization.groupTabs([tab(1), tab(2)], in: space, id: group, name: "Reading")
		let data = try JSONEncoder().encode(organization)
		expectNoDifference(try JSONDecoder().decode(BrowserOrganization.self, from: data), organization)

		var older = try JSONSerialization.jsonObject(with: data) as! [String: Any]
		older["tabGroups"] = nil
		let decoded = try JSONDecoder().decode(
			BrowserOrganization.self,
			from: JSONSerialization.data(withJSONObject: older)
		)
		#expect(decoded.tabGroups.isEmpty)
	}

	@Test
	internal func pinningAGroupMakesAPinnedFolder() throws {
		var organization = fixture()
		try organization.groupTabs([tab(2), tab(3)], in: space, id: group, name: "Reading")
		organization.tabGroups[id: group]?.isExpanded = false
		let folder = Folder.ID(rawValue: UUID(90))
		try organization.pinTabGroup(group, as: folder)

		expectNoDifference(organization.spaces[0].unpinnedTabs, [tab(1), tab(4), tab(5)])
		expectNoDifference(organization.spaces[0].savedItems, [.folder(folder)])
		expectNoDifference(organization.folders[id: folder]?.children, [.tab(tab(2)), .tab(tab(3))])
		expectNoDifference(organization.folders[id: folder]?.name, "Reading")
		#expect(organization.folders[id: folder]?.isExpanded == false)
		#expect(organization.tabs[id: tab(2)]?.savedDestination?.url == organization.tabs[id: tab(2)]?.restoration.url)
		#expect(organization.tabGroups.isEmpty)
	}

	@Test
	internal func pinningSomeOfAGroupsTabsLeavesTheRestGrouped() throws {
		var organization = fixture()
		try organization.groupTabs([tab(2), tab(3), tab(4)], in: space, id: group, name: "Reading")
		let folder = Folder.ID(rawValue: UUID(90))
		try organization.pinTabGroup(group, as: folder, members: [tab(2), tab(4)])

		expectNoDifference(organization.spaces[0].unpinnedTabs, [tab(1), tab(3), tab(5)])
		expectNoDifference(organization.folders[id: folder]?.children, [.tab(tab(2)), .tab(tab(4))])
		expectNoDifference(organization.tabGroups[id: group]?.tabIDs, [tab(3)])
		#expect(organization.tabs[id: tab(3)]?.savedDestination == nil)
	}

	@Test
	internal func pinningNoneOfAGroupsTabsChangesNothing() throws {
		var organization = fixture()
		try organization.groupTabs([tab(2), tab(3)], in: space, id: group, name: "Reading")
		let before = organization
		#expect(throws: TabGroupError.invalidSelection) {
			try organization.pinTabGroup(group, as: Folder.ID(rawValue: UUID(90)), members: [tab(1)])
		}
		expectNoDifference(organization, before)
	}

	@Test
	internal func ungroupingSomeOfAGroupsTabsKeepsThemOutOfTheRest() throws {
		var organization = fixture()
		try organization.groupTabs([tab(2), tab(3), tab(4)], in: space, id: group, name: "Reading")
		organization.ungroupTabs(group, members: [tab(3)])
		organization.normalizeTabGroups()

		expectNoDifference(organization.tabGroups[id: group]?.tabIDs, [tab(2), tab(4)])
		expectNoDifference(organization.spaces[0].unpinnedTabs, [tab(1), tab(2), tab(4), tab(3), tab(5)])

		organization.ungroupTabs(group, members: [tab(2), tab(4)])
		#expect(organization.tabGroups.isEmpty)
	}

	@Test
	internal func ungroupingOneTabOfASplitTakesTheWholeSplitOut() throws {
		var organization = fixture()
		try organization.groupTabs([tab(1), tab(2), tab(3)], in: space, id: group, name: "Reading")
		organization.splits.append(.init(
			id: .init(rawValue: UUID(80)),
			spaceID: space,
			tabIDs: [tab(1), tab(2)]
		))
		try organization.update { $0.ungroupTabs(group, members: [tab(1)]) }

		expectNoDifference(organization.tabGroups[id: group]?.tabIDs, [tab(3)])
		#expect(organization.tabGroup(containing: tab(1)) == nil)
		#expect(organization.tabGroup(containing: tab(2)) == nil)
	}

	@Test
	internal func groupingTabsFromTheMiddleOfAGroupKeepsTheNewGroup() throws {
		var organization = fixture()
		let other = TabGroup.ID(rawValue: UUID(21))
		try organization.groupTabs([tab(1), tab(2), tab(3)], in: space, id: other, name: "Old")
		try organization.groupTabs([tab(2)], in: space, id: group, name: "New")

		expectNoDifference(organization.tabGroups[id: other]?.tabIDs, [tab(1), tab(3)])
		expectNoDifference(organization.tabGroups[id: group]?.tabIDs, [tab(2)])
		expectNoDifference(organization.spaces[0].unpinnedTabs, [tab(1), tab(3), tab(2), tab(4), tab(5)])
	}

	@Test
	internal func aMovePlanTakesItsTabsOutOfTheirGroupsAndItsUndoPutsThemBack() throws {
		var organization = fixture()
		try organization.groupTabs([tab(1), tab(2), tab(3)], in: space, id: group, name: "Reading")
		let move = try organization.moving([.tab(tab(2))], to: .openTabs, in: space, unpinning: true, newTabID: { tab(70) })
		expectNoDifference(move.updated.tabGroups[id: group]?.tabIDs, [tab(1), tab(3)])
		expectNoDifference(move.previous.tabGroups[id: group]?.tabIDs, [tab(1), tab(2), tab(3)])
	}

	@Test
	internal func aSplitIsWhollyInAGroupOrOutOfIt() throws {
		var organization = fixture()
		try organization.groupTabs([tab(3), tab(4)], in: space, id: group, name: "Reading")
		organization.splits = [.init(id: .init(rawValue: UUID(40)), spaceID: space, tabIDs: [tab(2), tab(3)])]
		organization.normalizeTabGroups()
		expectNoDifference(organization.tabGroups[id: group]?.tabIDs, [tab(2), tab(3), tab(4)])
	}

	@Test
	internal func foldingAGroupKeepsAMovesStructure() throws {
		var organization = fixture()
		try organization.groupTabs([tab(1), tab(2)], in: space, id: group, name: "Reading")
		var folded = organization
		folded.tabGroups[id: group]?.isExpanded = false
		folded.tabGroups[id: group]?.name = "Later"
		#expect(folded.hasSameMoveStructure(as: organization))
	}

	@Test
	internal func anotherGroupsTabsEndAGroupsRun() throws {
		var organization = fixture()
		let first = TabGroup.ID(rawValue: UUID(21))
		try organization.groupTabs([tab(2), tab(3)], in: space, id: first, name: "First")
		try organization.groupTabs([tab(4), tab(5)], in: space, id: group, name: "Second")

		// Tab 5 moved to the top, as a split with tab 1 would put it.
		organization.spaces[0].unpinnedTabs = [tab(1), tab(5), tab(2), tab(3), tab(4)]
		organization.normalizeTabGroups()
		expectNoDifference(organization.tabGroups[id: first]?.tabIDs, [tab(2), tab(3)])
		expectNoDifference(organization.tabGroups[id: group]?.tabIDs, [tab(5)])
	}

	@Test
	internal func ungroupingLeavesTheTabsWhereTheyAre() throws {
		var organization = fixture()
		try organization.groupTabs([tab(3), tab(5)], in: space, id: group, name: "Reading")
		let open = organization.spaces[0].unpinnedTabs
		organization.ungroupTabs(group)
		expectNoDifference(organization.spaces[0].unpinnedTabs, open)
		#expect(organization.tabGroups.isEmpty)
	}

	@Test
	internal func groupingRefusesTabsOutsideTheSpacesOpenTabs() throws {
		var organization = fixture()
		#expect(throws: TabGroupError.invalidSelection) {
			try organization.groupTabs([tab(1), tab(99)], in: space, id: group, name: "Reading")
		}
	}

	private let space: Space.ID = .init(rawValue: UUID(10))
	private let group: TabGroup.ID = .init(rawValue: UUID(20))

	private func tab(_ value: Int) -> Tab.ID {
		.init(rawValue: UUID(value))
	}

	private func fixture() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: UUID(30))
		let tabs: [Tab] = (1...5).map {
			.init(
				id: tab($0),
				profileID: profile,
				restoration: .init(title: "Page \($0)", url: URL(string: "https://example.com/\($0)")!)
			)
		}
		return .init(
			profiles: [.init(id: profile, name: "Default")],
			spaces: [.init(id: space, profileID: profile, name: "Work", unpinnedTabs: tabs.map(\.id))],
			tabs: tabs
		)
	}
}

extension UUID {
	fileprivate init(_ value: Int) {
		self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(value)))
	}
}
