import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct OrganizationManagementTests {
	@Test
	internal func profileReassignmentReplacesEverySpaceTabButNeverFavorites() throws {
		var old = fixture()
		old.tabs[1].automationClientID = UUID()
		let profile = old.profiles[1].id
		let space = old.spaces[0]
		let changed = try old.applying(
			.updateSpace(space.id, profileID: profile, name: "Renamed", icon: .leaf),
			uuid: UUID.init
		)
		try changed.validate()
		expectNoDifference(changed.spaces[0].profileID, profile)
		expectNoDifference(changed.spaces[0].icon, .leaf)
		expectNoDifference(changed.profiles, old.profiles)
		expectNoDifference(changed.tabs.first, old.tabs.first)
		expectNoDifference(changed.tabs(in: space.id).map(\.profileID), [profile, profile])
		#expect(Set(changed.tabs(in: space.id).map(\.id)).isDisjoint(with: old.tabs(in: space.id).map(\.id)))
		expectNoDifference(
			changed.tabs(in: space.id).map(\.customTitle),
			old.tabs(in: space.id).map(\.customTitle)
		)
		expectNoDifference(
			changed.tabs(in: space.id).map(\.automationClientID),
			old.tabs(in: space.id).map(\.automationClientID)
		)
		let client = AutomationClient(
			id: UUID(),
			name: "Fixture",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.space(space.id, profileID: space.profileID)],
			allowsRead: true,
			grantRevision: UUID()
		)
		#expect(!AutomationAccess.permitsSpace(space.id, client: client, organization: changed))
		#expect(!AutomationAccess.permitsTab(changed.tabs[1].id, client: client, organization: changed))
		expectNoDifference(changed.spaces[0].selectedTabID, changed.tabs[2].id)
		expectNoDifference(changed.folders[0].children, [.tab(changed.tabs[1].id)])
	}

	@Test
	internal func deletesSpaceContentsAndProtectsLastSpaceAndLinkedProfiles() throws {
		let old = fixture()
		#expect(throws: OrganizationChangeError.profileHasSpaces) {
			try old.applying(.removeProfile(old.profiles[0].id), uuid: UUID.init)
		}
		let updated = try old.applying(.removeSpace(old.spaces[0].id), uuid: UUID.init)
		expectNoDifference(updated.tabs, [old.tabs[0]])
		expectNoDifference(updated.folders, [])
		#expect(throws: OrganizationChangeError.lastSpace) {
			try updated.applying(.removeSpace(updated.spaces[0].id), uuid: UUID.init)
		}
		let removedProfile = try updated.applying(.removeProfile(old.profiles[0].id), uuid: UUID.init)
		expectNoDifference(removedProfile.tabs, [])
		expectNoDifference(removedProfile.profiles.count, 1)
		#expect(throws: OrganizationChangeError.lastProfile) {
			try removedProfile.applying(.removeProfile(removedProfile.profiles[0].id), uuid: UUID.init)
		}
	}

	@Test
	internal func createsRenamesAndReordersWithoutChangingOwnership() throws {
		let old = fixture()
		let profile = Profile.ID(rawValue: UUID())
		let space = Space.ID(rawValue: UUID())
		var result = try old.applying(.createProfile(profile, name: "  New profile  "), uuid: UUID.init)
		result = try result.applying(
			.createSpace(space, profileID: profile, name: "New space", icon: .book),
			uuid: UUID.init
		)
		result = try result.applying(.renameProfile(profile, name: "Personal"), uuid: UUID.init)
		result = try result.applying(.moveSpace(space, before: result.spaces[0].id), uuid: UUID.init)
		expectNoDifference(result.spaces[0].id, space)
		expectNoDifference(result.spaces[0].profileID, profile)
		expectNoDifference(result.profiles.last?.name, "Personal")
		result = try result.applying(.moveSpace(space, before: nil), uuid: UUID.init)
		expectNoDifference(result.spaces.last?.id, space)
		#expect(throws: OrganizationChangeError.emptyName) {
			try result.applying(.renameProfile(profile, name: " \n "), uuid: UUID.init)
		}
	}

	@Test
	internal func spaceIconIsBackwardCompatibleAndPersistsWithOrdering() throws {
		var organization = fixture()
		organization.spaces[0].icon = .code
		let data = try JSONEncoder().encode(organization)
		expectNoDifference(try JSONDecoder().decode(BrowserOrganization.self, from: data), organization)
		var object = try #require(JSONSerialization.jsonObject(
			with: JSONEncoder().encode(organization.spaces[0])
		) as? [String: Any])
		object.removeValue(forKey: "icon")
		let legacy = try JSONDecoder().decode(
			Space.self,
			from: JSONSerialization.data(withJSONObject: object)
		)
		expectNoDifference(legacy.icon, nil)
	}

	private func fixture() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: UUID())
		let otherProfile = Profile.ID(rawValue: UUID())
		let space = Space.ID(rawValue: UUID())
		let folder = Folder.ID(rawValue: UUID())
		let tabs: [Tab] = (0..<3).map { index in
			.init(
				id: .init(rawValue: UUID()),
				profileID: profile,
				savedDestination: index < 2
				? .init(title: "Pin", url: URL(string: "https://capturecontext.dev")!)
				: nil,
				restoration: .init(title: "Page", url: URL(string: "https://capturecontext.dev/current")!),
				customTitle: "Custom"
			)
		}
		return .init(
			profiles: [
				.init(id: profile, name: "Work", favorites: [tabs[0].id]),
				.init(id: otherProfile, name: "Personal"),
			],
			spaces: [
				.init(
					id: space,
					profileID: profile,
					name: "Work",
					savedItems: [.folder(folder)],
					unpinnedTabs: [tabs[2].id],
					selectedTabID: tabs[2].id
				),
				.init(id: .init(rawValue: UUID()), profileID: otherProfile, name: "Personal"),
			],
			folders: [.init(id: folder, spaceID: space, name: "Nested", children: [.tab(tabs[1].id)])],
			tabs: tabs
		)
	}
}
