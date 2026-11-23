import AppUI
import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct PreviewEditingTests {
	@Test
	func regularTabsReorderInBothDirections() throws {
		var model = PreviewFixture.organization
		try model.move(.tab(rawID(16)), to: .before(.tab(rawID(15))), in: PreviewFixture.id(1))
		expectNoDifference(model.spaces[0].unpinnedTabs, [PreviewFixture.id(16), PreviewFixture.id(15)])
		try model.move(.tab(rawID(16)), to: .unpinnedRoot, in: PreviewFixture.id(1))
		expectNoDifference(model.spaces[0].unpinnedTabs, [PreviewFixture.id(15), PreviewFixture.id(16)])
		let movedTabs = model.tabs.filter { [rawID(15), rawID(16)].contains($0.id.rawValue) }
		#expect(movedTabs.allSatisfy { $0.savedDestination == nil })
	}

	@Test
	func pinnedTabDropsIntoEmptyRegularSection() throws {
		var model = PreviewFixture.organization
		try model.update { $0.removeTab(PreviewFixture.id(17)) }
		try model.move(.tab(rawID(12)), to: .unpinnedRoot, in: PreviewFixture.id(2))
		expectNoDifference(model.spaces[1].unpinnedTabs, [PreviewFixture.id(12)])
		expectNoDifference(model.location(of: PreviewFixture.id(12)), .unpinned(PreviewFixture.id(2)))
		let tab = try #require(model.tabs[id: PreviewFixture.id(12)])
		#expect(tab.savedDestination == nil)
		#expect(model.spaces[0].selectedTabID == nil)
	}

	@Test
	func pinnedTabInsertsBetweenRegularTabs() throws {
		var model = PreviewFixture.organization
		try model.move(.tab(rawID(12)), to: .before(.tab(rawID(16))), in: PreviewFixture.id(1))
		expectNoDifference(
			model.spaces[0].unpinnedTabs,
			[PreviewFixture.id(15), PreviewFixture.id(12), PreviewFixture.id(16)]
		)
		let tab = try #require(model.tabs[id: PreviewFixture.id(12)])
		#expect(tab.savedDestination == nil)
		try model.validate()
	}

	@Test(arguments: [1, 12, 15] as [UInt8])
	func spaceIconDropsPreservePinnedOrOpenStatus(_ value: UInt8) throws {
		var model = PreviewFixture.organization
		let id: BrowserCore.Tab.ID = PreviewFixture.id(value)
		try model.moveTab(.tab(id.rawValue), toSpace: PreviewFixture.id(2))
		let expected: BrowserOrganization.TabLocation = value == 15
		? .unpinned(PreviewFixture.id(2))
		: .pinned(PreviewFixture.id(2), folder: nil)
		expectNoDifference(model.location(of: id), expected)
		try model.validate()
	}

	@Test
	func spaceIconDropsRejectCrossProfileMovesAtomically() throws {
		var model = PreviewFixture.organization
		model.profiles.append(.init(id: PreviewFixture.id(2), name: "Separate profile"))
		model.spaces.append(
			.init(
				id: PreviewFixture.id(3),
				profileID: PreviewFixture.id(2),
				name: "Separate space"
			)
		)
		let original = model
		#expect(throws: (any Error).self) {
			try model.moveTab(.tab(rawID(15)), toSpace: PreviewFixture.id(3))
		}
		expectNoDifference(model, original)
	}

	@Test
	func resettingPinRestoresDestinationAndKeepsItsPlace() throws {
		var model = PreviewFixture.organization
		let id: BrowserCore.Tab.ID = PreviewFixture.id(12)
		let index = try #require(model.tabs.index(id: id))
		let destination = try #require(model.tabs[index].savedDestination)
		model.tabs[index].restoration = .init(
			title: "Navigated page",
			url: URL(string: "https://capturecontext.dev/other")!
		)
		let location = model.location(of: id)
		try model.update { $0.resetPinnedTab(id) }
		expectNoDifference(
			model.tabs[index].restoration,
			.init(
				title: destination.title,
				url: destination.url
			)
		)
		expectNoDifference(model.location(of: id), location)
		#expect(model.spaces[0].selectedTabID == nil)
	}

	@Test(arguments: [1, 12, 15] as [UInt8])
	func removingTabClearsItsOwnershipAndSelection(_ value: UInt8) throws {
		var model = PreviewFixture.organization
		let id: BrowserCore.Tab.ID = PreviewFixture.id(value)
		model.spaces[0].selectedTabID = id
		try model.update { $0.removeTab(id) }
		#expect(!model.tabs.ids.contains(id))
		#expect(model.location(of: id) == nil)
		#expect(model.spaces[0].selectedTabID == nil)
	}

	@Test
	func pinnedTabActionsDependOnSelectionAndInitialState() {
		var item = SidebarItem(id: .tab(rawID(12)), title: "Pinned page")
		expectNoDifference(item.tabAction(isSelected: true), .reset)
		expectNoDifference(item.tabAction(isSelected: false), .removePin)
		item.isAtInitialState = false
		expectNoDifference(item.tabAction(isSelected: false), .reset)
		item.isPinned = false
		expectNoDifference(item.tabAction(isSelected: true), .close)
		expectNoDifference(item.tabAction(isSelected: false), .close)
	}

	@Test
	func favoriteSelectionFollowsSpacesInTheSameProfile() throws {
		var model = PreviewFixture.organization
		model.spaces[0].selectedTabID = PreviewFixture.id(1)
		model.preserveFavoriteSelection(from: PreviewFixture.id(1), to: PreviewFixture.id(2))
		expectNoDifference(model.spaces[1].selectedTabID, PreviewFixture.id(1))
		model.preserveFavoriteSelection(from: PreviewFixture.id(2), to: PreviewFixture.id(1))
		expectNoDifference(model.spaces[0].selectedTabID, PreviewFixture.id(1))
		try model.validate()
	}

	@Test(arguments: [12, 15, nil] as [UInt8?])
	func spaceSpecificOrEmptySelectionKeepsDestinationSelection(_ selected: UInt8?) throws {
		var model = PreviewFixture.organization
		model.spaces[0].selectedTabID = selected.map { PreviewFixture.id($0) }
		model.preserveFavoriteSelection(from: PreviewFixture.id(1), to: PreviewFixture.id(2))
		expectNoDifference(model.spaces[1].selectedTabID, PreviewFixture.id(17))
		try model.validate()
	}

	@Test
	func favoriteSelectionDoesNotCrossProfiles() throws {
		var model = PreviewFixture.organization
		model.profiles.append(.init(id: PreviewFixture.id(2), name: "Separate profile"))
		model.spaces.append(
			.init(
				id: PreviewFixture.id(3),
				profileID: PreviewFixture.id(2),
				name: "Separate space"
			)
		)
		model.spaces[0].selectedTabID = PreviewFixture.id(1)
		model.preserveFavoriteSelection(from: PreviewFixture.id(1), to: PreviewFixture.id(3))
		#expect(model.spaces[2].selectedTabID == nil)
		try model.validate()
	}

	@Test
	func reordersFavoritesWithoutClearingOtherSpaceSelections() throws {
		var model = PreviewFixture.organization
		model.spaces[1].selectedTabID = PreviewFixture.id(1)
		try model.move(.tab(rawID(1)), to: .before(.tab(rawID(3))), in: PreviewFixture.id(1))
		expectNoDifference(
			Array(model.profiles[0].favorites.prefix(3)),
			[PreviewFixture.id(2), PreviewFixture.id(1), PreviewFixture.id(3)]
		)
		expectNoDifference(model.spaces[1].selectedTabID, PreviewFixture.id(1))
		try model.validate()
	}

	@Test
	func movingOpenTabToFavoritesSavesItsDestination() throws {
		var model = PreviewFixture.organization
		try model.move(.tab(rawID(15)), to: .favoritesRoot, in: PreviewFixture.id(1))
		expectNoDifference(model.location(of: PreviewFixture.id(15)), .favorite(PreviewFixture.id(1)))
		let tab = try #require(model.tabs[id: PreviewFixture.id(15)])
		expectNoDifference(tab.savedDestination?.url, tab.restoration.url)
	}

	@Test
	func foldersCannotEnterFavorites() throws {
		var model = PreviewFixture.organization
		let original = model
		#expect(throws: (any Error).self) {
			try model.move(.folder(rawID(2)), to: .before(.tab(rawID(1))), in: PreviewFixture.id(1))
		}
		expectNoDifference(model, original)
	}

	@Test
	func reordersWithinTheSameParent() async throws {
		var model = PreviewFixture.organization
		try model.move(.tab(rawID(12)), to: .before(.tab(rawID(11))), in: PreviewFixture.id(1))
		let folder = try #require(model.folders[id: PreviewFixture.id(6)])
		expectNoDifference(
			folder.children,
			[.tab(PreviewFixture.id(12)), .tab(PreviewFixture.id(11)), .tab(PreviewFixture.id(13))]
		)
	}

	@Test
	func nestsFolderAndRetainsItsChildren() async throws {
		var model = PreviewFixture.organization
		try model.move(.folder(rawID(6)), to: .inside(.folder(rawID(2))), in: PreviewFixture.id(1))
		try model.validate()
		let folder = try #require(model.folders[id: PreviewFixture.id(2)])
		expectNoDifference(folder.children.last, .folder(PreviewFixture.id(6)))
		expectNoDifference(
			model.location(of: PreviewFixture.id(12)),
			.pinned(PreviewFixture.id(1), folder: PreviewFixture.id(6))
		)
	}

	@Test
	func rejectsDroppingParentIntoItsDescendantWithoutChangingData() async throws {
		var model = PreviewFixture.organization
		let original = model
		#expect(throws: (any Error).self) {
			try model.move(.folder(rawID(2)), to: .inside(.folder(rawID(7))), in: PreviewFixture.id(1))
		}
		expectNoDifference(model, original)
	}

	@Test
	func droppingOpenTabIntoFolderPinsIt() async throws {
		var model = PreviewFixture.organization
		try model.move(.tab(rawID(15)), to: .inside(.folder(rawID(7))), in: PreviewFixture.id(1))
		expectNoDifference(
			model.location(of: PreviewFixture.id(15)),
			.pinned(PreviewFixture.id(1), folder: PreviewFixture.id(7))
		)
		let tab = try #require(model.tabs[id: PreviewFixture.id(15)])
		expectNoDifference(tab.savedDestination?.url, tab.restoration.url)
	}

	@Test
	func unpinningBeforeAnOpenTabKeepsItsIdentity() async throws {
		var model = PreviewFixture.organization
		try model.move(.tab(rawID(12)), to: .before(.tab(rawID(15))), in: PreviewFixture.id(1))
		expectNoDifference(
			model.spaces[0].unpinnedTabs,
			[PreviewFixture.id(12), PreviewFixture.id(15), PreviewFixture.id(16)]
		)
		let tab = try #require(model.tabs[id: PreviewFixture.id(12)])
		#expect(tab.savedDestination == nil)
	}

	@Test
	func foldersCannotEnterOpenTabs() async throws {
		var model = PreviewFixture.organization
		let original = model
		#expect(throws: (any Error).self) {
			try model.move(.folder(rawID(2)), to: .before(.tab(rawID(15))), in: PreviewFixture.id(1))
		}
		expectNoDifference(model, original)
	}
}

private func rawID(_ value: UInt8) -> UUID {
	let id: BrowserCore.Tab.ID = PreviewFixture.id(value)
	return id.rawValue
}
