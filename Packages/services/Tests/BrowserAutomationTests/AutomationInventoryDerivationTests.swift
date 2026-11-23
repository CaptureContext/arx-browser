import BrowserAutomationClient
import BrowserCore
import CryptoKit
import CustomDump
import Foundation
import Testing
import _TestSupport

/// Pins how much work one projection does: tab locations are walked once per pass, a single
/// target is derived alone, and cached revisions follow every input (DEV-938).
internal struct AutomationInventoryDerivationTests {
	@Test(arguments: ["profile", "spaces", "exactTabs", "content"])
	internal func singleItemsMatchTheFullProjection(grant: String) throws {
		let organization = Self.organization(tabs: 12)
		var client = BrowserAutomationTests.client(organization)
		let profile = organization.profiles[0]
		switch grant {
		case "profile":
			client.scopes = [.profile(profile.id)]

		case "spaces":
			client.scopes = organization.spaces.map { .space($0.id, profileID: $0.profileID) }

		case "exactTabs":
			// An exact grant on a Favorite, a folder tab and an open tab, without their spaces.
			client.scopes = [
				.tab(organization.profiles[0].favorites[0], profileID: profile.id, location: .favorites),
				.tab(organization.folders[1].tabIDs[0], profileID: profile.id, location: .space(organization.spaces[0].id)),
				.tab(organization.spaces[1].unpinnedTabs[0], profileID: profile.id, location: .space(organization.spaces[1].id)),
			]

		default:
			client.scopes = [.space(organization.spaces[0].id, profileID: profile.id)]
			client.capabilities.formUnion([.screenshots, .pageContent])
		}
		let snapshots = Self.snapshots(organization)
		let items = AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: snapshots)
		#expect(items.contains { $0.kind == .tab })

		let ids = organization.profiles.map(\.id.rawValue)
		+ organization.spaces.map(\.id.rawValue)
		+ organization.folders.map(\.id.rawValue)
		+ organization.tabs.map(\.id.rawValue)
		+ [UUID(9999)]
		for id in ids {
			expectNoDifference(
				AutomationInventoryBuilder.item(id, client: client, organization: organization, snapshots: snapshots),
				items.first { $0.id == id }
			)
		}
		for item in items {
			expectNoDifference(
				AutomationInventoryBuilder.item(
					item.id,
					kind: item.kind,
					client: client,
					organization: organization,
					snapshots: snapshots
				),
				item
			)
		}
	}

	@Test(arguments: [10, 100])
	internal func projectionsWalkTabLocationsOncePerPass(tabs: Int) throws {
		let organization = Self.organization(tabs: tabs)
		var client = BrowserAutomationTests.client(organization)
		client.scopes = [.profile(organization.profiles[0].id)]
		let snapshots = Self.snapshots(organization)
		let target = organization.tabs[tabs / 2].id.rawValue

		let full = try Self.counting {
			_ = AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: snapshots)
		}
		expectNoDifference(full.inventories, 1)
		expectNoDifference(full.locationWalks, 1)

		// Every revision of this projection is cached now: rebuilding it digests nothing.
		let repeated = try Self.counting {
			_ = AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: snapshots)
		}
		expectNoDifference(repeated.revisions, 0)

		let single = try Self.counting {
			let item = AutomationInventoryBuilder.item(
				target,
				client: client,
				organization: organization,
				snapshots: snapshots
			)
			#expect(item != nil)
		}
		expectNoDifference(single.inventories, 0)
		expectNoDifference(single.locationWalks, 1)
		expectNoDifference(single.revisions, 0)
	}

	@Test(arguments: ["grant", "title", "query", "session", "document", "loading", "location", "pin", "owner", "download"])
	internal func cachedRevisionsFollowEveryInput(change: String) throws {
		var organization = Self.organization(tabs: 12)
		var client = BrowserAutomationTests.client(organization)
		client.scopes = [.profile(organization.profiles[0].id)]
		client.capabilities.insert(.screenshots)
		var snapshots = Self.snapshots(organization)
		let tab = organization.spaces[0].unpinnedTabs[0]
		let before = try Self.revision(of: tab, client: client, organization: organization, snapshots: snapshots)

		switch change {
		case "grant":
			client.grantRevision = UUID(77)

		case "title":
			organization.tabs[id: tab]?.customTitle = "Renamed"

		case "query":
			snapshots[tab]?.navigation.url = URL(string: "https://capturecontext.dev/0?changed")!

		case "session":
			snapshots[tab]?.revision += 1

		case "document":
			snapshots[tab]?.documentRevision = 99

		case "loading":
			snapshots[tab]?.navigation.isLoading.toggle()

		case "location":
			organization.spaces[0].unpinnedTabs.removeAll { $0 == tab }
			organization.spaces[1].unpinnedTabs.append(tab)

		case "pin":
			let restoration = try #require(organization.tabs[id: tab]).restoration
			organization.tabs[id: tab]?.savedDestination = .init(title: restoration.title, url: restoration.url)

		case "download":
			snapshots[tab]?.navigation.download = .init(
				id: .init(profileID: organization.profiles[0].id, guid: "transfer"),
				filename: "report.pdf"
			)

		default:
			organization.tabs[id: tab]?.automationClientID = UUID(78)
		}

		let after = try #require(AutomationInventoryBuilder.item(
			tab.rawValue,
			client: client,
			organization: organization,
			snapshots: snapshots
		))

		// Load state and ownership are disclosed beside the revision, and are never served stale either.
		switch change {
		case "loading":
			expectNoDifference(after.sessionState, .loading)

		case "owner":
			expectNoDifference(after.automationClientID, UUID(78))

		case "download":
			expectNoDifference(after.downloadedFile, "report.pdf")

		default:
			#expect(after.revision != before)
		}

		// The changed input must not be answered from the cache: the item matches a full pass.
		expectNoDifference(
			AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: snapshots)
				.first { $0.id == tab.rawValue },
			after
		)
	}

	/// DEV-1116: a tab whose navigation became a download names the file and isn't failed.
	@Test
	internal func aTabWhoseNavigationBecameADownloadNamesTheFile() throws {
		let organization = Self.organization(tabs: 2)
		var client = BrowserAutomationTests.client(organization)
		client.scopes = [.profile(organization.profiles[0].id)]
		let tab = organization.spaces[0].unpinnedTabs[0]
		var snapshots = Self.snapshots(organization)
		snapshots[tab] = .init(
			navigation: .init(download: .init(
				id: .init(profileID: organization.profiles[0].id, guid: "transfer"),
				filename: "report.pdf"
			)),
			revision: 3,
			documentRevision: 1
		)

		let item = try #require(AutomationInventoryBuilder.item(
			tab.rawValue,
			client: client,
			organization: organization,
			snapshots: snapshots
		))
		expectNoDifference(item.downloadedFile, "report.pdf")
		expectNoDifference(item.sessionState, .ready)

		let other = try #require(AutomationInventoryBuilder.items(
			client: client,
			organization: organization,
			snapshots: snapshots
		).first { $0.kind == .tab && $0.id != tab.rawValue })
		expectNoDifference(other.downloadedFile, nil)
	}

	@Test
	internal func digestsAreLowercaseHexSHA256() {
		for input in ["", "arx", String(repeating: "synthetic", count: 40)] {
			let data = Data(input.utf8)
			let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
			expectNoDifference(AutomationSecurity.digest(data), expected)
		}
	}

	private static func counting(
		_ body: () throws -> Void
	) throws -> AutomationInventoryBuilder.Derivations.Counts {
		let derivations = AutomationInventoryBuilder.Derivations()
		try AutomationInventoryBuilder.$derivations.withValue(derivations) { try body() }
		return derivations.counts
	}

	private static func revision(
		of tab: BrowserCore.Tab.ID,
		client: AutomationClient,
		organization: BrowserOrganization,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) throws -> String {
		try #require(AutomationInventoryBuilder.item(
			tab.rawValue,
			client: client,
			organization: organization,
			snapshots: snapshots
		)).revision
	}

	/// One profile with a Favorite, two spaces, a nested folder tree and `tabs` tabs.
	internal static func organization(tabs count: Int) -> BrowserOrganization {
		let profile = Profile.ID(rawValue: UUID(0))
		let first = Space.ID(rawValue: UUID(1))
		let second = Space.ID(rawValue: UUID(2))
		let root = Folder.ID(rawValue: UUID(10))
		let nested = Folder.ID(rawValue: UUID(11))
		let tabs: [BrowserCore.Tab] = (0..<max(count, 6)).map { index in
			.init(
				id: .init(rawValue: UUID(1000 + index)),
				profileID: profile,
				restoration: .init(title: "Page \(index)", url: URL(string: "https://capturecontext.dev/\(index)?private=\(index)")!)
			)
		}
		let ids = tabs.map(\.id)
		var organization = BrowserOrganization(
			profiles: [.init(id: profile, name: "Fixture")],
			spaces: [
				.init(
					id: first,
					profileID: profile,
					name: "First",
					savedItems: [.folder(root), .tab(ids[1])],
					unpinnedTabs: Array(ids[4...]).enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
				),
				.init(
					id: second,
					profileID: profile,
					name: "Second",
					unpinnedTabs: Array(ids[4...]).enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
				),
			],
			folders: [
				.init(id: root, spaceID: first, name: "Root", children: [.folder(nested), .tab(ids[2])]),
				.init(id: nested, spaceID: first, name: "Nested", children: [.tab(ids[3])]),
			],
			tabs: tabs
		)
		organization.profiles[0].favorites = [ids[0]]
		for id in [ids[1], ids[2], ids[3]] {
			let restoration = organization.tabs[id: id]!.restoration
			organization.tabs[id: id]?.savedDestination = .init(title: restoration.title, url: restoration.url)
		}
		return organization
	}

	/// Live sessions for every other tab, so items mix loaded and unloaded states.
	internal static func snapshots(
		_ organization: BrowserOrganization
	) -> [BrowserCore.Tab.ID: BrowserSessionSnapshot] {
		var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [:]
		for (index, tab) in organization.tabs.enumerated() where index.isMultiple(of: 2) {
			snapshots[tab.id] = .init(
				navigation: .init(url: tab.restoration.url, title: tab.restoration.title),
				revision: UInt64(index + 1),
				documentRevision: UInt64(index + 1)
			)
		}
		return snapshots
	}
}

extension Folder {
	fileprivate var tabIDs: [BrowserCore.Tab.ID] {
		children.compactMap {
			guard case let .tab(id) = $0 else { return nil }
			return id
		}
	}
}
