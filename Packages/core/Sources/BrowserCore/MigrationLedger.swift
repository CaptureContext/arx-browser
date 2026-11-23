import Foundation

/// What earlier imports did, saved with the preferences so an import and its
/// record land in the same write. Retrying or repeating an import reads this
/// instead of comparing URLs, because a source may repeat a URL on purpose.
public struct MigrationLedger: Codable, Equatable, Sendable {
	/// Imported item keys by the space or profile that received them, so removing
	/// that space or profile lets the same data be imported again.
	public var importedItems: [String: Set<String>]

	/// Profiles, spaces and folders created for a source, by source identity.
	public var createdProfiles: [String: Profile.ID]
	public var createdSpaces: [String: Space.ID]
	public var createdFolders: [String: Folder.ID]

	public init(
		importedItems: [String: Set<String>] = [:],
		createdProfiles: [String: Profile.ID] = [:],
		createdSpaces: [String: Space.ID] = [:],
		createdFolders: [String: Folder.ID] = [:]
	) {
		self.importedItems = importedItems
		self.createdProfiles = createdProfiles
		self.createdSpaces = createdSpaces
		self.createdFolders = createdFolders
	}
}
