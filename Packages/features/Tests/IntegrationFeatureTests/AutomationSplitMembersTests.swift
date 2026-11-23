import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-992: automation's `openSplit` takes a pinned tab as a target or a member, as the sidebar and
/// the menus do. Since DEV-1006 a Favorite joins as a member, and is refused as the target before
/// anything changes.
@Suite(.dependencies)
@MainActor
internal struct AutomationSplitMembersTests {
	@Test(arguments: [false, true])
	internal func aPinnedTabCanOpenASplit(asTarget: Bool) throws {
		let state = fixture()
		let command = try command(
			state: state,
			target: asTarget ? pinned : open,
			members: [asTarget ? open : pinned]
		)
		expectNoDifference(state.automationValidation(pending(command), snapshots: [:], now: now), nil)
	}

	/// A granted Favorite joins as a member from the grid (DEV-1006), but can't be the target,
	/// which names the split's space and list.
	@Test(arguments: [false, true])
	internal func aFavoriteJoinsButCantBeTheTarget(asTarget: Bool) throws {
		let state = fixture()
		let command = try command(
			state: state,
			target: asTarget ? favorite : open,
			members: [asTarget ? open : favorite]
		)
		expectNoDifference(
			state.automationValidation(pending(command), snapshots: [:], now: now),
			asTarget ? .invalidRequest : nil
		)
	}

	// MARK: - Fixture

	private var open: BrowserCore.Tab.ID { .init(rawValue: UUID(4)) }

	private var pinned: BrowserCore.Tab.ID { .init(rawValue: UUID(3)) }

	private var favorite: BrowserCore.Tab.ID { .init(rawValue: UUID(5)) }

	private var now: Date { Date(timeIntervalSince1970: 100) }

	/// Tab 3 pinned and tab 4 open in Work, tab 5 a Favorite, the whole profile granted to one
	/// client, so each is listed with its real revision.
	private func fixture() -> AppFeature.State {
		var organization = IntegrationFeatureTests().fixture()
		let restoration = organization.tabs[0].restoration
		organization.tabs[0].savedDestination = .init(title: restoration.title, url: restoration.url)
		organization.spaces[0].savedItems = [.tab(pinned)]
		organization.spaces[0].unpinnedTabs = [open]
		organization.tabs.append(.init(
			id: favorite,
			profileID: organization.profiles[0].id,
			savedDestination: .init(title: restoration.title, url: restoration.url),
			restoration: restoration
		))
		organization.profiles[0].favorites = [favorite]
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture client",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.profile(organization.profiles[0].id)],
			allowsRead: true,
			allowsManagement: true,
			mutationGrantUntil: Date(timeIntervalSince1970: 200),
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		return state
	}

	private func command(
		state: AppFeature.State,
		target: BrowserCore.Tab.ID,
		members: [BrowserCore.Tab.ID]
	) throws -> AutomationCommand {
		let items = AutomationInventoryBuilder.items(
			client: state.automationPreferences.clients[0],
			organization: state.workspace,
			snapshots: [:]
		)
		func revision(_ id: BrowserCore.Tab.ID) throws -> String {
			try #require(items.first { $0.id == id.rawValue }).revision
		}
		return try .init(
			operationID: UUID(83),
			action: .openSplit,
			targetID: target.rawValue,
			expectedRevision: revision(target),
			splitTabs: members.map { try .init(id: $0.rawValue, revision: revision($0)) }
		)
	}

	private func pending(_ command: AutomationCommand) -> AutomationState.Pending {
		.init(
			request: .init(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .command(command)),
			grantRevision: UUID(82),
			approved: true,
			executing: true
		)
	}
}
