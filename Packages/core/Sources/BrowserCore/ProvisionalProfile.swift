import Foundation

/// The profile and space a first launch starts with, before onboarding has run (DEV-841).
///
/// It's named Default and holds no tabs. When onboarding ends after an import that made
/// profiles of its own, an untouched Default is removed so only the imported profiles
/// remain; otherwise it simply stops being provisional.
public struct ProvisionalProfile: Codable, Equatable, Sendable {
	/// The name of the stand-in profile and its space.
	public static let name: String = "Default"

	public var profileID: Profile.ID
	public var spaceID: Space.ID

	public init(
		profileID: Profile.ID,
		spaceID: Space.ID
	) {
		self.profileID = profileID
		self.spaceID = spaceID
	}

	/// The first-launch workspace: one Default profile with one empty Default space.
	public var organization: BrowserOrganization {
		.init(
			profiles: [pristineProfile],
			spaces: [pristineSpace]
		)
	}

	/// Whether the workspace still holds this profile exactly as a first launch made it:
	/// same name and settings (whether it syncs aside), its one empty space, no tabs, favorites, folders, archived
	/// tabs or imported items. History, saved passwords and extensions live outside the
	/// workspace and are checked separately.
	public func isPristine(
		in organization: BrowserOrganization,
		ledger: MigrationLedger
	) -> Bool {
		// Kept on this Mac for onboarding's iCloud step (DEV-1215) it's still as a first launch made it.
		organization.profiles[id: profileID].map { profile in
			var profile: Profile = profile
			profile.syncsWithICloud = nil
			return profile
		} == pristineProfile
		&& organization.spaces.filter { $0.profileID == profileID } == [pristineSpace]
		&& !organization.tabs.contains { $0.profileID == profileID }
		&& !organization.folders.contains { $0.spaceID == spaceID }
		&& !organization.archive.contains { $0.tab.profileID == profileID || $0.originalSpaceID == spaceID }
		&& ledger.importedItems[profileID.rawValue.uuidString, default: []].isEmpty
		&& ledger.importedItems[spaceID.rawValue.uuidString, default: []].isEmpty
	}

	/// Profiles an import made that still have a space to show, in workspace order.
	public func importedProfiles(
		in organization: BrowserOrganization,
		ledger: MigrationLedger
	) -> [Profile.ID] {
		let created = Set(ledger.createdProfiles.values)
		return organization.profiles.map(\.id).filter { id in
			id != profileID
			&& created.contains(id)
			&& organization.spaces.contains { $0.profileID == id }
		}
	}

	private var pristineProfile: Profile {
		.init(id: profileID, name: Self.name)
	}

	private var pristineSpace: Space {
		.init(id: spaceID, profileID: profileID, name: Self.name)
	}
}
