import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct SplitGroupTests {
	@Test
	internal func panesStartEqualAndStoredSharesAreRepaired() {
		expectNoDifference(SplitLayout.equal(4), [0.25, 0.25, 0.25, 0.25])
		expectNoDifference(SplitLayout.sanitized([2, 2], count: 2), [0.5, 0.5])
		expectNoDifference(SplitLayout.sanitized([0.5, .nan], count: 2), [0.5, 0.5])
		expectNoDifference(SplitLayout.sanitized([0.5, 0.5], count: 3), SplitLayout.equal(3))
		expectNoDifference(SplitLayout.sanitized([0.5, -1], count: 2), [0.5, 0.5])
	}

	@Test
	internal func normalizingSharesIsIdempotent() {
		let shares = [0.7516410837556654, 0.05903541474109715, 0.18932350150323757]
		let once = SplitLayout.sanitized(shares, count: 3)
		expectNoDifference(SplitLayout.sanitized(once, count: 3), once)
		expectNoDifference(SplitLayout.sanitized(SplitLayout.sanitized(once, count: 3), count: 3), once)
	}

	@Test
	internal func resizingASplitAfterAMoveKeepsItsUndo() throws {
		var organization = fixture()
		try organization.joinSplit([id(2)], with: id(1), newID: id(50))
		let move = try organization.moving([.tab(id(5))], to: .before(.tab(id(1))), in: id(10), newTabID: { id(60) })
		var live = move.updated
		live.splits[id: id(50)]?.fractions = [0.3, 0.7]
		#expect(live.hasSameMoveStructure(as: move.updated))
	}

	@Test
	internal func capacityKeepsEveryPaneAtTheMinimumAndStopsAtFour() {
		let divider = SplitLayout.dividerLength
		expectNoDifference(SplitLayout.capacity(length: 279), 1)
		expectNoDifference(SplitLayout.capacity(length: 280 * 2 + divider - 1), 1)
		expectNoDifference(SplitLayout.capacity(length: 280 * 2 + divider), 2)
		expectNoDifference(SplitLayout.capacity(length: 280 * 3 + divider * 2), 3)
		expectNoDifference(SplitLayout.capacity(length: 5_000), 4)
		expectNoDifference(SplitLayout.capacity(length: .infinity), 1)
	}

	@Test
	internal func extentsRaiseShortPanesToTheMinimumWhenThereIsRoom() {
		let length = 1_200 + SplitLayout.dividerLength * 2
		let extents = SplitLayout.extents([0.1, 0.45, 0.45], length: length)
		expectNoDifference(extents[0], 280)
		#expect(abs(extents.reduce(0, +) - 1_200) < 0.001)
		#expect(abs(extents[1] - extents[2]) < 0.001)

		// Too narrow for the minimum: shares are kept as they are.
		let narrow = SplitLayout.extents([0.5, 0.5], length: 400 + SplitLayout.dividerLength)
		expectNoDifference(narrow, [200, 200])
	}

	@Test
	internal func resizingTradesOnlyBetweenNeighboursAndStopsAtTheMinimum() {
		let length = 1_200 + SplitLayout.dividerLength * 2
		let equal = SplitLayout.equal(3)
		let wider = SplitLayout.resize(equal, divider: 0, by: 100, length: length)
		#expect(abs(wider[0] * 1_200 - 500) < 0.001)
		#expect(abs(wider[1] * 1_200 - 300) < 0.001)
		#expect(abs(wider[2] - equal[2]) < 0.000_001)

		let clamped = SplitLayout.resize(equal, divider: 1, by: 1_000, length: length)
		#expect(abs(clamped[2] * 1_200 - 280) < 0.001)
		#expect(abs(clamped[0] - equal[0]) < 0.000_001)
		expectNoDifference(SplitLayout.resize(equal, divider: 2, by: 10, length: length), equal)
	}

	@Test
	internal func joiningMakesAGroupOfUpToFourOpenTabsKeptTogether() throws {
		var organization = fixture()
		let group = try organization.joinSplit([id(4)], with: id(2), newID: id(50))
		expectNoDifference(organization.splits[id: group]?.tabIDs, [id(2), id(4)])
		expectNoDifference(organization.spaces[0].unpinnedTabs, [id(1), id(2), id(4), id(3), id(5)])

		try organization.joinSplit([id(5), id(1)], with: id(4), at: 0, newID: id(51))
		expectNoDifference(organization.splits.count, 1)
		expectNoDifference(organization.splits[id: group]?.tabIDs, [id(5), id(1), id(2), id(4)])
		expectNoDifference(organization.splits[id: group]?.fractions, SplitLayout.equal(4))

		#expect(throws: BrowserOrganization.SplitError.full) {
			try organization.joinSplit([id(3)], with: id(2), newID: id(52))
		}
		#expect(throws: BrowserOrganization.SplitError.notInOneList) {
			try organization.joinSplit([id(6)], with: id(3), newID: id(52))
		}
	}

	@Test
	internal func closedMovedAndPinnedMembersLeaveAndSingleMemberGroupsDissolve() throws {
		var organization = fixture()
		try organization.joinSplit([id(2), id(3)], with: id(1), newID: id(50))
		organization.splits[id: id(50)]?.fractions = [0.5, 0.25, 0.25]

		try organization.update { candidate in
			candidate.spaces[0].unpinnedTabs.removeAll { $0 == self.id(2) }
			candidate.tabs.remove(id: self.id(2))
		}
		expectNoDifference(organization.splits[id: id(50)]?.tabIDs, [id(1), id(3)])
		expectNoDifference(organization.splits[id: id(50)]?.fractions, [2 / 3, 1 / 3])

		organization.removeFromSplits([id(3)])
		#expect(organization.splits.isEmpty)
	}

	@Test
	internal func groupsPersistAndOlderSnapshotsDecodeWithoutThem() throws {
		var organization = fixture()
		try organization.joinSplit([id(3)], with: id(1), orientation: .vertical, newID: id(50))
		organization.splits[id: id(50)]?.title = "Docs"
		organization.splits[id: id(50)]?.icon = "book"
		organization.splits[id: id(50)]?.fractions = [0.7, 0.3]

		let data = try JSONEncoder().encode(organization)
		let restored = try JSONDecoder().decode(BrowserOrganization.self, from: data)
		expectNoDifference(restored, organization)

		var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		object.removeValue(forKey: "splits")
		let legacy = try JSONDecoder().decode(
			BrowserOrganization.self,
			from: JSONSerialization.data(withJSONObject: object)
		)
		#expect(legacy.splits.isEmpty)
	}

	@Test
	internal func presentationKeepsFourPanesAndReadsTwoPaneProportions() throws {
		let organization = fixture()
		let presentation = BrowserSpacePresentation(
			id: id(10),
			panes: (1 ... 5).map { .init(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, $0)), tabID: id($0)) },
			activePaneID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1)),
			fractions: [0.4, 0.15, 0.15, 0.15, 0.15]
		)
		let sanitized = try #require(presentation.sanitized(in: organization))
		expectNoDifference(sanitized.panes.map(\.tabID), [id(1), id(2), id(3), id(4)])
		expectNoDifference(sanitized.fractions.count, 4)
		#expect(abs(sanitized.fractions[0] - 0.4 / 0.85) < 0.000_001)

		let legacy = Data(#"""
		{"id":"00000000-0000-0000-0000-00000000000A","activePaneID":"00000000-0000-0000-0000-000000000101",
		"orientation":"horizontal","proportion":0.65,"panes":[
		{"id":"00000000-0000-0000-0000-000000000101","tabID":"00000000-0000-0000-0000-000000000001"},
		{"id":"00000000-0000-0000-0000-000000000102","tabID":"00000000-0000-0000-0000-000000000002"}]}
		"""#.utf8)
		let decoded = try JSONDecoder().decode(BrowserSpacePresentation.self, from: legacy)
		expectNoDifference(decoded.fractions, [0.65, 0.35])
		expectNoDifference(decoded.proportion, 0.65)
	}

	@Test
	internal func undoingAMoveToAnotherProfileRestoresTheMemberUnderItsFreshIdentity() throws {
		var organization = fixture()
		organization.profiles.append(.init(id: id(2), name: "Work"))
		organization.spaces.append(.init(id: id(20), profileID: id(2), name: "Work"))
		try organization.joinSplit([id(2)], with: id(1), newID: id(50))

		let move = try organization.moving(
			[.tab(id(2))],
			to: .openTabs,
			in: id(20),
			newTabID: { id(60) }
		)
		expectNoDifference(move.updated.splits.isEmpty, true)
		let undo = try move.reversed(newTabID: { id(61) })
		expectNoDifference(undo.updated.splits.first?.tabIDs, [id(1), id(61)])
	}

	/// Pinned tabs share a split in Pinned or in a folder as open tabs do (DEV-1006).
	@Test
	internal func pinnedTabsShareASplitInPinnedOrInAFolder() throws {
		var organization = listsFixture()
		let pinned = try organization.joinSplit([id(7)], with: id(6), newID: id(50))
		expectNoDifference(organization.splits[id: pinned]?.tabIDs, [id(6), id(7)])
		expectNoDifference(organization.splitList(of: organization.splits[id: pinned]!), .pinned(id(10)))

		let folder = try organization.joinSplit([id(9)], with: id(8), at: 0, newID: id(51))
		expectNoDifference(organization.splits[id: folder]?.tabIDs, [id(9), id(8)])

		// Gathered in pane order where the first one was.
		expectNoDifference(organization.folders[id: id(30)]?.children, [.tab(id(9)), .tab(id(8))])

		// A tab of another list doesn't join until it's brought into this one.
		#expect(throws: BrowserOrganization.SplitError.notInOneList) {
			try organization.joinSplit([id(1)], with: id(6), newID: id(52))
		}
		#expect(throws: BrowserOrganization.SplitError.notInOneList) {
			try organization.joinSplit([id(8)], with: id(7), newID: id(52))
		}
	}

	/// A folder between two pinned tabs breaks their run, as any other row does.
	@Test
	internal func aPinnedSplitKeepsItsLongestRunInItsList() throws {
		var organization = listsFixture()
		try organization.joinSplit([id(7)], with: id(6), newID: id(50))
		try organization.update { candidate in
			candidate.spaces[0].savedItems = [.tab(id(6)), .folder(id(30)), .tab(id(7))]
		}
		#expect(organization.splits.isEmpty)
	}

	/// Moved together, a split stays one: open tabs moved into Pinned, or into a folder, keep it.
	@Test
	internal func aSplitMovedWholeToAnotherListStaysASplit() throws {
		var organization = listsFixture()
		try organization.joinSplit([id(2)], with: id(1), newID: id(50))
		try organization.update { candidate in
			candidate.spaces[0].unpinnedTabs.removeAll { [self.id(1), self.id(2)].contains($0) }
			candidate.folders[id: self.id(30)]?.children.append(contentsOf: [.tab(id(1)), .tab(id(2))])
			candidate.pin([self.id(1), self.id(2)])
		}
		expectNoDifference(organization.splits[id: id(50)]?.tabIDs, [id(1), id(2)])
		expectNoDifference(organization.splitList(of: organization.splits[id: id(50)]!), .folder(id(30)))
	}

	/// Of three, the two still together stay a split wherever the third went.
	@Test
	internal func theListHoldingMostOfASplitKeepsIt() throws {
		var organization = listsFixture()
		try organization.joinSplit([id(2), id(3)], with: id(1), newID: id(50))
		try organization.update { candidate in
			candidate.spaces[0].unpinnedTabs.removeAll { $0 == self.id(1) }
			candidate.spaces[0].savedItems.append(.tab(id(1)))
			candidate.pin([self.id(1)])
		}
		expectNoDifference(organization.splits[id: id(50)]?.tabIDs, [id(2), id(3)])
	}

	/// A Favorite joins a split and stays in the grid; a split needs a tab in a list.
	@Test
	internal func favoritesJoinSplitsWithoutLeavingTheGrid() throws {
		var organization = listsFixture()

		// A Favorite and an open tab.
		let pair = try organization.joinSplit([id(1)], with: id(11), newID: id(50))
		expectNoDifference(organization.splits[id: pair]?.tabIDs, [id(11), id(1)])
		expectNoDifference(organization.listMembers(of: organization.splits[id: pair]!), [id(1)])
		expectNoDifference(organization.profiles[0].favorites, [id(11), id(12)])

		// A Favorite and two open tabs.
		let three = try organization.joinSplit([id(12), id(3)], with: id(2), newID: id(51))
		expectNoDifference(organization.splits[id: three]?.tabIDs, [id(2), id(12), id(3)])
		expectNoDifference(organization.listMembers(of: organization.splits[id: three]!), [id(2), id(3)])

		// Two Favorites alone have no list to share.
		organization.splits = []
		#expect(throws: BrowserOrganization.SplitError.notInOneList) {
			try organization.joinSplit([id(12)], with: id(11), newID: id(52))
		}

		// A split of a Favorite and one tab goes once the tab leaves it.
		try organization.joinSplit([id(1)], with: id(11), newID: id(53))
		try organization.update { candidate in
			candidate.spaces[0].unpinnedTabs.removeAll { $0 == self.id(1) }
			candidate.tabs.remove(id: self.id(1))
		}
		#expect(organization.splits.isEmpty)
	}

	/// A whole split moved to another space of its profile goes with its tabs.
	@Test
	internal func aSplitMovedToAnotherSpaceFollowsIt() throws {
		var organization = listsFixture()
		organization.spaces.append(.init(id: id(20), profileID: id(1), name: "Work"))
		try organization.joinSplit([id(2)], with: id(1), newID: id(50))
		try organization.update { candidate in
			candidate.spaces[0].unpinnedTabs.removeAll { [self.id(1), self.id(2)].contains($0) }
			candidate.spaces[1].savedItems = [.tab(id(1)), .tab(id(2))]
			candidate.pin([self.id(1), self.id(2)])
		}
		expectNoDifference(organization.splits[id: id(50)]?.spaceID, id(20))
		expectNoDifference(organization.splitList(of: organization.splits[id: id(50)]!), .pinned(id(20)))
	}

	/// Pinned splits, in a folder too and with a Favorite, come back as they were after relaunch.
	@Test
	internal func pinnedSplitsPersist() throws {
		var organization = listsFixture()
		try organization.joinSplit([id(7)], with: id(6), newID: id(50))
		try organization.joinSplit([id(9), id(11)], with: id(8), orientation: .vertical, newID: id(51))
		let restored = try JSONDecoder().decode(BrowserOrganization.self, from: JSONEncoder().encode(organization))
		expectNoDifference(restored, organization)
		expectNoDifference(restored.splits.map(\.tabIDs), [[id(6), id(7)], [id(8), id(9), id(11)]])
	}

	/// Moved tab by tab, a split with a Favorite keeps every tab, though the first step trimmed it.
	@Test
	internal func keepingSplitsGivesBackTrimmedMembers() throws {
		var organization = listsFixture()
		try organization.joinSplit([id(2), id(11)], with: id(1), newID: id(50))
		try organization.update { candidate in
			candidate.keepingSplits { candidate in
				for tab in [self.id(1), self.id(2)] as [Tab.ID] {
					candidate.spaces[0].unpinnedTabs.removeAll { $0 == tab }
					candidate.spaces[0].savedItems.append(.tab(tab))
					candidate.pin([tab])
					candidate.normalizeSplits()
				}
			}
		}
		expectNoDifference(organization.splits[id: id(50)]?.tabIDs, [id(1), id(2), id(11)])
		expectNoDifference(organization.splitList(of: organization.splits[id: id(50)]!), .pinned(id(10)))
	}

	/// Open 1–5, Pinned 6 and 7 then a folder with 8 and 9, Favorites 11 and 12.
	private func listsFixture() -> BrowserOrganization {
		let url = URL(string: "https://capturecontext.dev")!
		let saved: Set<UInt8> = [6, 7, 8, 9, 11, 12]
		return .init(
			profiles: [.init(id: id(1), name: "Personal", favorites: [id(11), id(12)])],
			spaces: [
				.init(
					id: id(10),
					profileID: id(1),
					name: "Research",
					savedItems: [.tab(id(6)), .tab(id(7)), .folder(id(30))],
					unpinnedTabs: [id(1), id(2), id(3), id(4), id(5)]
				),
			],
			folders: [.init(id: id(30), spaceID: id(10), name: "Reading", children: [.tab(id(8)), .tab(id(9))])],
			tabs: ([1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12] as [UInt8]).map { index in
				.init(
					id: id(index),
					profileID: id(1),
					savedDestination: saved.contains(index) ? .init(title: "Saved", url: url) : nil,
					restoration: .init(title: "Tab \(index)", url: url)
				)
			}
		)
	}

	private func fixture() -> BrowserOrganization {
		let url = URL(string: "https://capturecontext.dev")!
		return .init(
			profiles: [.init(id: id(1), name: "Personal")],
			spaces: [
				.init(
					id: id(10),
					profileID: id(1),
					name: "Research",
					savedItems: [.tab(id(6))],
					unpinnedTabs: [id(1), id(2), id(3), id(4), id(5)]
				),
			],
			tabs: (1 ... 6).map { index in
				.init(
					id: id(index),
					profileID: id(1),
					savedDestination: index == 6 ? .init(title: "Saved", url: url) : nil,
					restoration: .init(title: "Tab \(index)", url: url)
				)
			}
		)
	}

	private func id<Entity>(_ value: UInt8) -> BrowserID<Entity> {
		.init(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value)))
	}
}

extension BrowserOrganization {
	/// Gives tabs moved into Pinned or a folder the saved page a pinned tab has.
	fileprivate mutating func pin(_ ids: [Tab.ID]) {
		for id in ids {
			tabs[id: id]?.savedDestination = .init(title: "Saved", url: URL(string: "https://capturecontext.dev")!)
		}
	}
}
