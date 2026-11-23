import BrowserAutomationClient
import BrowserCore
import BrowserMCPServer
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

internal struct AutomationFolderInventoryTests {
	@Test(arguments: ["membership", "order", "parent", "nestedName", "profile", "space"])
	internal func revisionsBindTheCompleteOrderedTree(change: String) throws {
		var organization = fixture()
		let client = client(organization)
		let previous = try revision(organization, client: client)
		switch change {
		case "membership":
			organization.folders[1].children.removeAll()
			organization.spaces[0].savedItems.append(.tab(organization.tabs[1].id))

		case "order":
			organization.folders[0].children.reverse()

		case "parent":
			organization.folders[1].children.removeAll()
			organization.folders[0].children.append(.tab(organization.tabs[1].id))

		case "nestedName":
			organization.folders[1].name = "Renamed child"

		case "profile":
			let tab = organization.tabs[1]
			organization.tabs[1] = .init(
				id: tab.id,
				profileID: .init(rawValue: UUID(99)),
				savedDestination: tab.savedDestination,
				restoration: tab.restoration
			)

		default:
			organization.folders[1].spaceID = organization.spaces[1].id
		}
		#expect(try revision(organization, client: client) != previous)
	}

	@Test
	internal func navigationDisclosureAndUnrelatedTreesDoNotInvalidateMoves() throws {
		var organization = fixture()
		let client = client(organization)
		let previous = try revision(organization, client: client)
		organization.tabs[1].restoration = .init(title: "New page", url: URL(string: "https://capturecontext.dev/new?private=synthetic")!)
		organization.folders[1].isExpanded.toggle()
		organization.spaces[0].selectedTabID = organization.tabs[1].id
		organization.folders.append(.init(id: .init(rawValue: UUID(12)), spaceID: organization.spaces[1].id, name: "Unrelated"))
		organization.spaces[1].savedItems.append(.folder(organization.folders[2].id))
		expectNoDifference(try revision(organization, client: client), previous)

		let snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [
			organization.tabs[1].id: .init(navigation: .init(url: organization.tabs[1].restoration.url), revision: 50)
		]
		let items = AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: snapshots)
		expectNoDifference(items.first { $0.id == organization.folders[0].id.rawValue }?.revision, previous)
	}

	@Test
	internal func parserAdvertisesFolderMovesAndRequiresExplicitDestinationRevision() throws {
		let arguments: [String: Value] = [
			"operationID": .string(UUID(8).uuidString),
			"action": .string("moveFolder"),
			"targetID": .string(UUID(10).uuidString),
			"expectedRevision": .string(String(repeating: "a", count: 64)),
			"destinationID": .string(UUID(2).uuidString),
			"destinationRevision": .string(String(repeating: "b", count: 64)),
		]
		let operation = try AutomationTools.operation(name: "browser_command", arguments: arguments)
		expectNoDifference(operation, .command(.init(
			operationID: UUID(8),
			action: .moveFolder,
			targetID: UUID(10),
			expectedRevision: String(repeating: "a", count: 64),
			destinationID: UUID(2),
			destinationRevision: String(repeating: "b", count: 64)
		)))
		for field in ["destinationID", "destinationRevision"] {
			var missing = arguments
			missing[field] = nil
			#expect(throws: AutomationFailure.invalidRequest) {
				try AutomationTools.operation(name: "browser_command", arguments: missing)
			}
		}
		#expect(AutomationCommand.Action.supported.contains(.moveFolder))
		#expect(AutomationCommand.Action.supported.contains(.closeTab))
		let folders = try #require(AutomationTools.definitions.first { $0.name == "browser_folders" }?.inputSchema)
		let tabs = try #require(AutomationTools.definitions.first { $0.name == "browser_tabs" }?.inputSchema)
		#expect(String(decoding: try JSONEncoder().encode(folders), as: UTF8.self).contains("moveFolder"))
		#expect(String(decoding: try JSONEncoder().encode(tabs), as: UTF8.self).contains("closeTab"))
	}

	private func fixture() -> BrowserOrganization {
		var organization = BrowserAutomationTests.organization()
		let rootID = Folder.ID(rawValue: UUID(10))
		let nestedID = Folder.ID(rawValue: UUID(11))
		organization.folders = [
			.init(
				id: rootID,
				spaceID: organization.spaces[0].id,
				name: "Root",
				children: [.folder(nestedID), .tab(organization.tabs[0].id)]
			),
			.init(
				id: nestedID,
				spaceID: organization.spaces[0].id,
				name: "Nested",
				children: [.tab(organization.tabs[1].id)]
			),
		]
		for index in organization.tabs.indices {
			let restoration = organization.tabs[index].restoration
			organization.tabs[index].savedDestination = .init(title: restoration.title, url: restoration.url)
		}
		organization.spaces[0].savedItems = [.folder(rootID)]
		organization.spaces[0].unpinnedTabs = []
		organization.spaces[1].unpinnedTabs = []
		return organization
	}

	private func client(_ organization: BrowserOrganization) -> AutomationClient {
		var client = BrowserAutomationTests.client(organization)
		client.scopes = organization.spaces.map { .space($0.id, profileID: $0.profileID) }
		return client
	}

	private func revision(
		_ organization: BrowserOrganization,
		client: AutomationClient
	) throws -> String {
		let items = AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: [:])
		return try #require(items.first { $0.id == organization.folders[0].id.rawValue }?.revision)
	}
}
