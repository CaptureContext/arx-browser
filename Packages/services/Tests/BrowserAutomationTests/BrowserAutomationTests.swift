import BrowserAutomationClient
import BrowserCore
import BrowserMCPServer
import CustomDump
import Foundation
import Testing
import _MCP
import _TestSupport

internal struct BrowserAutomationTests {
	@Test
	internal func inventoryFiltersBeforePaginationAndInvalidatesCursors() throws {
		var organization = Self.organization()
		let client = Self.client(organization)
		organization.tabs[0].restoration.url = URL(
			string: "https://person:synthetic@capturecontext.dev/path?synthetic=private#fragment"
		)!
		let items = AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: [:])
		expectNoDifference(items.map(\.kind), [.space, .tab])
		expectNoDifference(items.last?.url, "https://capturecontext.dev/path")
		#expect(items.allSatisfy { $0.urlSanitized })
		let first = try AutomationInventoryBuilder.page(items, cursor: nil, limit: 1)
		let second = try AutomationInventoryBuilder.page(items, cursor: first.nextCursor, limit: 1)
		expectNoDifference(second.items.map(\.id), [organization.tabs[0].id.rawValue])
		#expect(second.nextCursor == nil)
		organization.tabs[0].restoration.url = URL(string: "https://capturecontext.dev/path?synthetic=changed")!
		let changed = AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: [:])
		#expect(throws: AutomationFailure.staleCursor) {
			try AutomationInventoryBuilder.page(changed, cursor: first.nextCursor, limit: 1)
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationInventoryBuilder.page(items, cursor: nil, limit: 0)
		}
	}

	@Test
	internal func spacesDoNotImplicitlyGrantFavoritesAndProfileOrLocationChangesRevokeTabs() throws {
		var organization = Self.organization()
		var client = Self.client(organization)
		let tab = organization.tabs[0]
		client.scopes = [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))]
		#expect(AutomationAccess.permitsTab(tab.id, client: client, organization: organization))
		organization.spaces[0].unpinnedTabs.removeAll()
		organization.profiles[0].favorites.append(tab.id)
		#expect(!AutomationAccess.permitsTab(tab.id, client: client, organization: organization))
		client = Self.client(organization)
		#expect(!AutomationAccess.permitsTab(tab.id, client: client, organization: organization))
		client.scopes.append(.tab(tab.id, profileID: tab.profileID, location: .favorites))
		#expect(AutomationAccess.permitsTab(tab.id, client: client, organization: organization))
		client.scopes = [.tab(tab.id, profileID: .init(rawValue: UUID(99)), location: .favorites)]
		#expect(!AutomationAccess.permitsTab(tab.id, client: client, organization: organization))
	}

	@Test
	internal func toolParserRejectsUnknownPropertiesDangerousURLsAndUnsupportedOperations() throws {
		let base: [String: Value] = [
			"operationID": .string(UUID(8).uuidString),
			"targetID": .string(UUID(3).uuidString),
			"expectedRevision": .string(String(repeating: "a", count: 64)),
			"action": .string("navigate"),
			"url": .string("https://capturecontext.dev"),
		]
		#expect(throws: Never.self) {
			try AutomationTools.operation(name: "browser_command", arguments: base)
		}
		for (key, value): (String, Value) in [
			("rawJavaScript", .string("1")),
			("url", .string("file:///private")),
			("url", .string("https://a:b@capturecontext.dev")),
			("focus", .string("true")),
			("action", .string("removeProfile")),
			("expectedRevision", .string(String(repeating: "z", count: 64))),
		] {
			var arguments = base
			arguments[key] = value
			#expect(throws: (any Error).self) {
				try AutomationTools.operation(name: "browser_command", arguments: arguments)
			}
		}
		let expectedTools = [
			"browser_inventory",
			"browser_tabs",
			"browser_folders",
			"browser_hosts",
			"browser_spaces",
			"browser_profiles",
			"browser_windows",
			"browser_archive",
			"browser_downloads",
			"browser_capture",
			"browser_inspect",
			"browser_click",
			"browser_wait",
			"browser_replace_text",
			"browser_select_value",
			"browser_keypress",
			"browser_scroll",
			"browser_hover",
			"browser_drag",
			"browser_type",
			"browser_set_checked",
			"browser_upload",
			"browser_dialog",
			"browser_media",
			"browser_sign_in",
			"browser_read",
			"browser_find",
			"browser_find_in_page",
			"browser_pdf",
			"browser_history",
			"browser_links",
			"browser_batch",
			"browser_run",
			"browser_settings",
			"browser_evaluate",
			"browser_logs",
			"browser_password_sign_in",
		]
		expectNoDifference(AutomationTools.definitions.map(\.name), expectedTools)
	}

	@Test
	internal func credentialsCompareDigestsAndLegacyPreferencesRemainDisabled() throws {
		let fixture = AutomationCredential(token: String(repeating: "0", count: 64))
		#expect(AutomationSecurity.matches(token: String(repeating: "0", count: 64), digest: fixture.digest))
		#expect(!AutomationSecurity.matches(token: String(repeating: "1", count: 64), digest: fixture.digest))
		#expect(!AutomationSecurity.matches(token: "short", digest: fixture.digest))
		let encodedPreferences = try JSONEncoder().encode(BrowserPreferences())
		var legacy = try #require(try JSONSerialization.jsonObject(with: encodedPreferences) as? [String: Any])
		legacy["automation"] = nil
		let preferences = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: legacy)
		)
		expectNoDifference(preferences.automation, .init())
	}

	internal static func organization() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: UUID(0))
		let first = Space.ID(rawValue: UUID(1))
		let second = Space.ID(rawValue: UUID(2))
		let tabs: [BrowserCore.Tab] = [3, 4].map {
			.init(
				id: .init(rawValue: UUID($0)),
				profileID: profile,
				restoration: .init(title: "Untrusted page title", url: URL(string: "https://capturecontext.dev")!)
			)
		}
		return .init(
			profiles: [.init(id: profile, name: "Fixture")],
			spaces: [
				.init(id: first, profileID: profile, name: "Allowed", unpinnedTabs: [tabs[0].id]),
				.init(id: second, profileID: profile, name: "Excluded", unpinnedTabs: [tabs[1].id]),
			],
			tabs: tabs
		)
	}

	internal static func client(_ organization: BrowserOrganization) -> AutomationClient {
		.init(
			id: UUID(5),
			name: "Fixture",
			credentialDigest: AutomationCredential(token: String(repeating: "0", count: 64)).digest,
			scopes: [.space(organization.spaces[0].id, profileID: organization.profiles[0].id)],
			allowsRead: true,
			grantRevision: UUID(6)
		)
	}
}
