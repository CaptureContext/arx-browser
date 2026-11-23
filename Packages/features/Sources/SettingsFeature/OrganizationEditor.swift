import BrowserCore
import Foundation

public struct OrganizationEditor: Equatable, Sendable {
	public enum Kind: Equatable, Sendable {
		case profile(Profile.ID?)
		case space(Space.ID?)
		case removeProfile(Profile.ID)
		case removeSpace(Space.ID)
	}

	public var kind: Kind
	public var name: String
	public var profileID: Profile.ID?
	public var originalProfileID: Profile.ID?

	/// Nil: none of the space's own, so it shows a dot (DEV-1251).
	public var icon: SpaceIcon?
	public var eraseWebsiteData: Bool
	public var eraseConfirmation: String

	/// Why Arx opened the editor by itself, shown above what it does.
	public var note: String?

	/// A removal another Mac syncs: delete it from this Mac only, which the other Macs keep, rather
	/// than remove it from iCloud (DEV-1336), the safe choice the sheet starts with. It applies only
	/// when the sheet asks, while another Mac syncs Profiles and spaces.
	public var keepsElsewhere: Bool

	public init(
		kind: Kind = .profile(nil),
		name: String = "",
		profileID: Profile.ID? = nil,
		originalProfileID: Profile.ID? = nil,
		icon: SpaceIcon? = nil,
		eraseWebsiteData: Bool = false,
		eraseConfirmation: String = "",
		note: String? = nil,
		keepsElsewhere: Bool = true
	) {
		self.kind = kind
		self.name = name
		self.profileID = profileID
		self.originalProfileID = originalProfileID
		self.icon = icon
		self.eraseWebsiteData = eraseWebsiteData
		self.eraseConfirmation = eraseConfirmation
		self.note = note
		self.keepsElsewhere = keepsElsewhere
	}

	/// The profile or space a removal removes.
	public var removedID: UUID? {
		switch kind {
		case let .removeProfile(id): id.rawValue
		case let .removeSpace(id): id.rawValue
		case .profile, .space: nil
		}
	}

	public init(profile: Profile) {
		self.init(kind: .profile(profile.id), name: profile.name)
	}

	public init(space: Space) {
		self.init(
			kind: .space(space.id),
			name: space.name,
			profileID: space.profileID,
			originalProfileID: space.profileID,
			icon: space.icon
		)
	}

	public var isRemoval: Bool {
		switch kind {
		case .removeProfile, .removeSpace: true
		case .profile, .space: false
		}
	}

	public var isSpace: Bool {
		if case .space = kind { return true }
		return false
	}

	public var changesProfile: Bool {
		originalProfileID != nil && originalProfileID != profileID
	}

	internal func change(uuid: () -> UUID) throws -> OrganizationChange {
		switch kind {
		case .profile(nil):
			return .createProfile(.init(rawValue: uuid()), name: name)

		case let .profile(id?):
			return .renameProfile(id, name: name)

		case .space(nil):
			guard let profileID else { throw OrganizationChangeError.missingItem }
			return .createSpace(
				.init(rawValue: uuid()),
				profileID: profileID,
				name: name,
				icon: icon
			)

		case let .space(id?):
			guard let profileID else { throw OrganizationChangeError.missingItem }
			return .updateSpace(
				id,
				profileID: profileID,
				name: name,
				icon: icon
			)

		case let .removeProfile(id):
			return .removeProfile(id)

		case let .removeSpace(id):
			return .removeSpace(id)
		}
	}
}
