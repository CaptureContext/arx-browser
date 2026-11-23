/// The profile displayed when the user chooses a restoration destination.
/// Reassigning the Space must not silently restore under another account.
public struct ArchiveDestination: Equatable, Sendable {
	public let spaceID: Space.ID
	public let profileID: Profile.ID

	public init(
		spaceID: Space.ID,
		profileID: Profile.ID
	) {
		self.spaceID = spaceID
		self.profileID = profileID
	}

	public init(space: Space) {
		self.init(spaceID: space.id, profileID: space.profileID)
	}
}
