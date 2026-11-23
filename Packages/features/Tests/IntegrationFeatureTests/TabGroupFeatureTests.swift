import AppUI
import BrowserCore
import CustomDump
import Foundation
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// Groups of open tabs in the sidebar (DEV-911).
extension IntegrationFeatureTests {
	@Test
	internal func aSelectionBecomesACollapsibleRenamableGroup() async throws {
		let (organization, open) = groupFixture()
		var state = SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.moveSelection = [.tab(open[3].rawValue), .tab(open[1].rawValue)]
		let store = TestStore(initialState: state) { SidebarFeature() } withDependencies: {
			$0.uuid = .constant(UUID(70))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.sidebar(.groupTabs(state.moveSelection))))
		let group = try #require(store.state.organization.tabGroups.first)
		expectNoDifference(group.tabIDs, [open[1], open[3]])
		expectNoDifference(store.state.space.unpinnedTabs, [open[0], open[1], open[3], open[2]])
		#expect(store.state.moveSelection.isEmpty)

		let row = try #require(store.state.openTabs.first { $0.isTabGroup })
		expectNoDifference(row.id, .folder(group.id.rawValue))
		expectNoDifference(row.children.map(\.id), [.tab(open[1].rawValue), .tab(open[3].rawValue)])

		await store.send(.ui(.sidebar(.rename(row.id, "Reading"))))
		await store.send(.ui(.sidebar(.toggle(row.id))))
		expectNoDifference(store.state.organization.tabGroups.first?.name, "Reading")
		#expect(store.state.organization.tabGroups.first?.isExpanded == false)

		await store.send(.ui(.undo))
		await store.send(.ui(.undo))
		expectNoDifference(store.state.organization.tabGroups, [])
	}

	@Test
	internal func droppingATabOnAGroupJoinsItAndDraggingItOutLeaves() async throws {
		var (organization, open) = groupFixture()
		try organization.groupTabs(
			[open[0], open[1]],
			in: organization.spaces[0].id,
			id: .init(rawValue: UUID(70)),
			name: "Reading"
		)
		let group = SidebarItem.ID.folder(UUID(70))
		let space = organization.spaces[0].id
		let store = TestStore(initialState: SidebarFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { SidebarFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.move(.tab(open[3].rawValue), .inside(group), space)))
		expectNoDifference(store.state.organization.tabGroups.first?.tabIDs, [open[0], open[1], open[3]])

		await store.send(.ui(.move(.tab(open[0].rawValue), .unpinnedRoot, space)))
		expectNoDifference(store.state.organization.tabGroups.first?.tabIDs, [open[1], open[3]])
		expectNoDifference(store.state.space.unpinnedTabs.last, open[0])

		// Above the group's row is outside it; just under it is inside.
		await store.send(.ui(.move(.tab(open[2].rawValue), .before(group), space)))
		expectNoDifference(store.state.organization.tabGroups.first?.tabIDs, [open[1], open[3]])
		await store.send(.ui(.move(.tab(open[2].rawValue), .after(group), space)))
		expectNoDifference(store.state.organization.tabGroups.first?.tabIDs, [open[2], open[1], open[3]])
	}

	@Test
	internal func droppingAGroupsOnlyTabOnItKeepsTheGroup() async throws {
		var (organization, open) = groupFixture()
		try organization.groupTabs([open[1]], in: organization.spaces[0].id, id: .init(rawValue: UUID(70)), name: "Reading")
		let store = TestStore(initialState: SidebarFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { SidebarFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.move(.tab(open[1].rawValue), .inside(.folder(UUID(70))), organization.spaces[0].id)))
		expectNoDifference(store.state.organization.tabGroups.first?.tabIDs, [open[1]])
	}

	/// The sidebar sends a dragged row as `moveItems`, even alone.
	@Test
	internal func aSingleDraggedTabJoinsTheGroupItIsDroppedOn() async throws {
		var (organization, open) = groupFixture()
		try organization.groupTabs(
			[open[0], open[1]],
			in: organization.spaces[0].id,
			id: .init(rawValue: UUID(70)),
			name: "Reading"
		)
		let store = TestStore(initialState: SidebarFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { SidebarFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.moveItems([.tab(open[3].rawValue)], .inside(.folder(UUID(70))), organization.spaces[0].id)))
		await store.receive(\.ui.move)
		expectNoDifference(store.state.organization.tabGroups.first?.tabIDs, [open[0], open[1], open[3]])
	}

	@Test
	internal func pinningAGroupMakesAFolderAsOneUndo() async throws {
		var (organization, open) = groupFixture()
		try organization.groupTabs(
			[open[1], open[2]],
			in: organization.spaces[0].id,
			id: .init(rawValue: UUID(70)),
			name: "Reading"
		)
		let store = TestStore(initialState: SidebarFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { SidebarFeature() } withDependencies: {
			$0.uuid = .constant(UUID(80))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.sidebar(.pinTabGroup(.folder(UUID(70))))))
		expectNoDifference(store.state.space.savedItems, [.folder(.init(rawValue: UUID(80)))])
		expectNoDifference(store.state.savedItems.first?.children.map(\.id), [.tab(open[1].rawValue), .tab(open[2].rawValue)])
		#expect(store.state.organization.tabGroups.isEmpty)

		await store.send(.ui(.undo))
		expectNoDifference(store.state.organization, organization)

		await store.send(.ui(.sidebar(.ungroupTabGroup(.folder(UUID(70))))))
		#expect(store.state.organization.tabGroups.isEmpty)
		expectNoDifference(store.state.space.unpinnedTabs, organization.spaces[0].unpinnedTabs)
	}

	/// A group whose tabs were split up before normalizing shows once, never as two rows with one
	/// identity.
	@Test
	internal func aGroupShowsOnceEvenBeforeItsTabsAreTogetherAgain() async throws {
		let (organization, open) = groupFixture()
		var sidebar = SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		sidebar.organization.tabGroups = [.init(
			id: .init(rawValue: UUID(70)),
			spaceID: organization.spaces[0].id,
			name: "Reading",
			tabIDs: [open[0], open[2]]
		)]

		let rows = sidebar.openTabs.map(\.id)
		expectNoDifference(rows.filter { $0 == .folder(UUID(70)) }.count, 1)
	}

	private func groupFixture() -> (BrowserOrganization, [BrowserCore.Tab.ID]) {
		var organization = fixture()
		let profile = organization.profiles[0].id
		let extra: [BrowserCore.Tab] = [5, 6].map {
			.init(
				id: .init(rawValue: UUID($0)),
				profileID: profile,
				restoration: .init(title: "Page \($0)", url: URL(string: "https://example.com/\($0)")!)
			)
		}
		organization.tabs.append(contentsOf: extra)
		organization.spaces[0].unpinnedTabs.append(contentsOf: extra.map(\.id))
		return (organization, organization.spaces[0].unpinnedTabs)
	}
}
