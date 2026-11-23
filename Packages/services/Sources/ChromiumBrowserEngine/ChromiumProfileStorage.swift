import BrowserCore
import Foundation

/// The profile Chromium keeps a profile's website data under: this Mac's alias for it, when a merge
/// gave it one (DEV-1216), else its own ID, with the profile that owns Chromium's own directory as
/// `nil`. And back, from what Chromium reports to the app's profile.
extension Profile.ID {
	internal func chromiumProfile(legacy: Profile.ID) -> UUID? {
		let storage: UUID = ProfileStorageAliases.shared.storageID(for: rawValue)
		return storage == legacy.rawValue ? nil : storage
	}

	internal static func chromium(
		_ profile: UUID?,
		legacy: Profile.ID
	) -> Profile.ID {
		.init(rawValue: ProfileStorageAliases.shared.profileID(forStorage: profile ?? legacy.rawValue))
	}
}
