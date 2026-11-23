import CustomDump
import Foundation
import Testing
@testable import BrowserCore

internal struct AutomationCapabilityTests {
	@Test
	internal func legacyGrantsMigrateWithTheSameEffectiveAccess() throws {
		func decode(_ flags: [String: Bool]) throws -> AutomationClient {
			var object: [String: Any] = [
				"id": id(1).uuidString,
				"name": "Legacy",
				"credentialDigest": String(repeating: "a", count: 64),
				"scopes": [Any](),
				"grantRevision": id(2).uuidString,
			]
			for (key, value) in flags { object[key] = value }
			let data = try JSONSerialization.data(withJSONObject: object)
			return try JSONDecoder().decode(AutomationClient.self, from: data)
		}

		let everything = try decode([
			"allowsRead": true,
			"allowsScreenshots": true,
			"allowsPageContent": true,
			"allowsPageInteraction": true,
			"allowsSignIn": true,
			"allowsManagement": true,
		])
		expectNoDifference(
			everything.capabilities,
			[.read, .screenshots, .pageContent, .interact, .signIn, .organize]
		)
		expectNoDifference(everything.approvalPolicy, .alwaysAsk)
		#expect(!everything.allowsFocusedTab)

		// Interaction used to need the management toggle as well, so on its own it granted nothing.
		let interactionOnly = try decode([
			"allowsRead": true,
			"allowsPageContent": true,
			"allowsPageInteraction": true,
			"allowsManagement": false,
		])
		expectNoDifference(interactionOnly.capabilities, [.read, .pageContent])

		// The oldest records only stored read and management.
		let oldest = try decode(["allowsRead": true, "allowsManagement": false])
		expectNoDifference(oldest.capabilities, [.read])
	}

	@Test
	internal func capabilityRecordsRoundTripWithoutLegacyFields() throws {
		let client = AutomationClient(
			id: id(1),
			name: "Agent",
			credentialDigest: String(repeating: "b", count: 64),
			scopes: [.profile(.init(rawValue: id(3)))],
			capabilities: [.read, .history, .organize],
			approvalPolicy: .destructiveOnly,
			allowsFocusedTab: true,
			grantRevision: id(2)
		)
		let data = try JSONEncoder().encode(client)
		let text = String(decoding: data, as: UTF8.self)
		#expect(!text.contains("allowsManagement"))
		expectNoDifference(try JSONDecoder().decode(AutomationClient.self, from: data), client)
	}

	@Test
	internal func profileScopeCoversLaterSpacesAndFavoritesButNotOtherProfiles() {
		let profile = Profile.ID(rawValue: id(10))
		let other = Profile.ID(rawValue: id(11))
		let page: URL = URL(string: "https://capturecontext.dev")!
		let favorite = Tab(id: .init(rawValue: id(20)), profileID: profile, restoration: .init(title: "Favorite", url: page))
		let foreign = Tab(id: .init(rawValue: id(21)), profileID: other, restoration: .init(title: "Foreign", url: page))
		var organization = BrowserOrganization(
			profiles: [
				.init(id: profile, name: "Work", favorites: [favorite.id]),
				.init(id: other, name: "Home"),
			],
			spaces: [
				.init(id: .init(rawValue: id(30)), profileID: profile, name: "First"),
				.init(id: .init(rawValue: id(31)), profileID: other, name: "Elsewhere", unpinnedTabs: [foreign.id]),
			],
			tabs: [favorite, foreign]
		)
		var client = AutomationClient(
			id: id(1),
			name: "Agent",
			credentialDigest: String(repeating: "c", count: 64),
			scopes: [.profile(profile)],
			capabilities: [.read],
			grantRevision: id(2)
		)

		let later = Space(id: .init(rawValue: id(32)), profileID: profile, name: "Created later")
		organization.spaces.append(later)
		#expect(AutomationAccess.permitsSpace(later.id, client: client, organization: organization))
		#expect(AutomationAccess.permitsTab(favorite.id, client: client, organization: organization))
		#expect(!AutomationAccess.permitsSpace(.init(rawValue: id(31)), client: client, organization: organization))
		#expect(!AutomationAccess.permitsTab(foreign.id, client: client, organization: organization))

		client.scopes = []
		#expect(!AutomationAccess.permitsSpace(later.id, client: client, organization: organization))
	}

	@Test
	internal func everyPolicyIsCheckedAgainstEveryRiskTier() {
		let expected: [AutomationApprovalPolicy: [AutomationRiskTier: Bool]] = [
			.alwaysAsk: [.read: true, .mutate: false, .destructive: false],
			.destructiveOnly: [.read: true, .mutate: true, .destructive: false],
			.never: [.read: true, .mutate: true, .destructive: true],
		]
		for policy in AutomationApprovalPolicy.allCases {
			for tier in [AutomationRiskTier.read, .mutate, .destructive] {
				#expect(
					policy.skipsApproval(for: tier) == expected[policy]?[tier],
					"\(policy) \(tier)"
				)
			}
		}
	}

	@Test
	internal func operationsDeclareTheirTierAndClasses() {
		func command(_ action: AutomationCommand.Action) -> AutomationOperation {
			.command(.init(
				operationID: id(1),
				action: action,
				targetID: id(2),
				expectedRevision: String(repeating: "a", count: 64)
			))
		}

		expectNoDifference(command(.closeTab).riskTier, .destructive)
		expectNoDifference(command(.reload).riskTier, .mutate)
		expectNoDifference(command(.reload).requiredCapabilities, [.read, .organize])
		expectNoDifference(AutomationOperation.inventory(cursor: nil, limit: 1).riskTier, .read)
		expectNoDifference(AutomationOperation.inventory(cursor: nil, limit: 1).requiredCapabilities, [.read])

		let summary = AutomationGrantSummary(capabilities: [.organize, .read], allowsFocusedTab: true)
		expectNoDifference(summary.capabilities, [.read, .organize])
		#expect(summary.contains([.read]))
		#expect(!summary.contains([.read, .interact]))
	}

	@Test
	internal func recoveryClearsCapabilitiesPolicyAndFocusedTab() {
		let preferences = AutomationPreferences(
			isEnabled: true,
			clients: [
				AutomationClient(
					id: id(1),
					name: "Agent",
					credentialDigest: String(repeating: "d", count: 64),
					scopes: [.profile(.init(rawValue: id(3)))],
					capabilities: Set(AutomationCapability.allCases),
					approvalPolicy: .never,
					allowsFocusedTab: true,
					grantRevision: id(2)
				),
			]
		)
		let revoked = preferences.revokingGrants(makeID: { id(9) }).clients[0]
		#expect(revoked.capabilities.isEmpty && revoked.scopes.isEmpty)
		expectNoDifference(revoked.approvalPolicy, .alwaysAsk)
		#expect(!revoked.allowsFocusedTab)
		expectNoDifference(revoked.grantRevision, id(9))
	}
}

private func id(_ value: Int) -> UUID {
	UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}
