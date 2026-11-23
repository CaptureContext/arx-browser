import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _TestSupport

internal struct AutomationInventoryScopeTests {
	@Test
	internal func tabOnlyGrantWithholdsExcludedAncestryAndItsChanges() async throws {
		var organization = fixture()
		let client = tabClient(organization)
		let original = inventory(organization, client: client)
		expectNoDifference(original.map(\.kind), [.tab, .tab])
		#expect(original.allSatisfy { $0.spaceID == nil && $0.parentID == nil })
		#expect(original.allSatisfy { $0.profileID == organization.profiles[0].id.rawValue })
		let encoded = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
		for id in organization.spaces.map(\.id.rawValue) + organization.folders.map(\.id.rawValue) {
			#expect(!encoded.contains(id.uuidString))
		}

		let first = try AutomationInventoryBuilder.page(original, cursor: nil, limit: 1)
		let cursor = try #require(first.nextCursor)
		organization.folders[0].children.removeAll()
		organization.folders[1].children.append(.tab(organization.tabs[0].id))
		organization.folders[0].name = "Changed excluded name"
		organization.spaces[0].name = "Changed excluded space"
		let moved = inventory(organization, client: client)
		expectNoDifference(moved, original)
		let second = try AutomationInventoryBuilder.page(moved, cursor: cursor, limit: 1)
		expectNoDifference(second.items.map(\.id), [organization.tabs[1].id.rawValue])
		#expect(second.nextCursor == nil)
	}

	@Test(arguments: [false, true])
	internal func hiddenSpaceMoveRequiresMatchingTabScopeWithoutDisclosingLocation(
		grantedDestination: Bool
	) async throws {
		var organization = fixture()
		var client = tabClient(organization)
		let tab = organization.tabs[0]
		let destination = organization.spaces[1].id
		if grantedDestination {
			client.scopes.append(.tab(tab.id, profileID: tab.profileID, location: .space(destination)))
		}
		let original = inventory(organization, client: client)
		let first = try AutomationInventoryBuilder.page(original, cursor: nil, limit: 1)
		let cursor = try #require(first.nextCursor)

		organization.folders[0].children.removeAll()
		organization.spaces[1].savedItems.append(.tab(tab.id))
		let moved = inventory(organization, client: client)
		expectNoDifference(
			AutomationAccess.permitsTab(tab.id, client: client, organization: organization),
			grantedDestination
		)
		if grantedDestination {
			expectNoDifference(moved, original)
			let second = try AutomationInventoryBuilder.page(moved, cursor: cursor, limit: 1)
			expectNoDifference(second.items.map(\.id), [organization.tabs[1].id.rawValue])

		} else {
			expectNoDifference(moved.map(\.id), [organization.tabs[1].id.rawValue])
			#expect(throws: AutomationFailure.staleCursor) {
				try AutomationInventoryBuilder.page(moved, cursor: cursor, limit: 1)
			}
		}
	}

	@Test
	internal func spaceGrantKeepsVisibleParentAndMoveRevision() async throws {
		var organization = fixture()
		var client = tabClient(organization)
		client.scopes = [.space(organization.spaces[0].id, profileID: organization.profiles[0].id)]
		let tab = organization.tabs[0]
		let original = try #require(inventory(organization, client: client).first { $0.id == tab.id.rawValue })
		expectNoDifference(original.spaceID, organization.spaces[0].id.rawValue)
		expectNoDifference(original.parentID, organization.folders[0].id.rawValue)

		organization.folders[0].children.removeAll()
		organization.folders[1].children.append(.tab(tab.id))
		let moved = try #require(inventory(organization, client: client).first { $0.id == tab.id.rawValue })
		expectNoDifference(moved.parentID, organization.folders[1].id.rawValue)
		#expect(moved.revision != original.revision)
	}

	private func inventory(
		_ organization: BrowserOrganization,
		client: AutomationClient
	) -> [AutomationInventoryItem] {
		AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: [:])
	}

	private func tabClient(_ organization: BrowserOrganization) -> AutomationClient {
		var client = BrowserAutomationTests.client(organization)
		client.scopes = organization.tabs.map {
			.tab($0.id, profileID: $0.profileID, location: .space(organization.spaces[0].id))
		}
		return client
	}

	private func fixture() -> BrowserOrganization {
		var organization = BrowserAutomationTests.organization()
		let first = Folder.ID(rawValue: UUID(10))
		let second = Folder.ID(rawValue: UUID(11))
		let space = organization.spaces[0].id
		organization.folders = [
			.init(id: first, spaceID: space, name: "Excluded first", children: [.tab(organization.tabs[0].id)]),
			.init(id: second, spaceID: space, name: "Excluded second", children: [.tab(organization.tabs[1].id)]),
		]
		for index in organization.tabs.indices {
			let restoration = organization.tabs[index].restoration
			organization.tabs[index].savedDestination = .init(title: restoration.title, url: restoration.url)
		}
		organization.spaces[0].savedItems = [.folder(first), .folder(second)]
		organization.spaces[0].unpinnedTabs.removeAll()
		organization.spaces[1].unpinnedTabs.removeAll()
		return organization
	}
}
