import BrowserCore
import Foundation
import Sharing

/// What iCloud sync tells the windows and Settings about removing profiles and spaces (DEV-1336).
/// AppFeature keeps it current from `WorkspaceSync`'s status; without sync it stays empty.
public struct ICloudRemoval: Equatable, Sendable {
	/// Another Mac syncs Profiles and spaces, so removing a synced profile or space asks whether to
	/// delete it from this Mac only or remove it from iCloud.
	public var asksWhere: Bool

	/// Profiles and spaces another Mac removed from iCloud, by ID.
	public var marked: [UUID: DeletionMark]

	public init(
		asksWhere: Bool = false,
		marked: [UUID: DeletionMark] = [:]
	) {
		self.asksWhere = asksWhere
		self.marked = marked
	}
}

/// A profile or space another Mac removed from iCloud: which Mac, and when "sync deletions after"
/// deletes it here, if it will.
public struct DeletionMark: Equatable, Sendable {
	/// The Mac's name, or `nil` when the device directory doesn't name it.
	public var deviceName: String?
	public var removedAt: Date

	/// `nil`: it stays here until the person removes it.
	public var deletesAt: Date?

	public init(
		deviceName: String?,
		removedAt: Date,
		deletesAt: Date?
	) {
		self.deviceName = deviceName
		self.removedAt = removedAt
		self.deletesAt = deletesAt
	}
}

extension SharedKey where Self == InMemoryKey<ICloudRemoval>.Default {
	/// ``ICloudRemoval``, shared by every window and Settings.
	public static var iCloudRemoval: Self {
		Self[.inMemory("iCloudRemoval"), default: .init()]
	}
}

extension BrowserOrganization {
	/// The synced items a profile or space covers, by ID: itself, a profile's Favorites and spaces,
	/// and each space's folders and saved tabs. Keeping it when it's marked for deletion applies to
	/// all of them (DEV-1336).
	public func itemsCovered(by id: UUID) -> Set<UUID> {
		var items: Set<UUID> = [id]
		var spaceIDs: [Space.ID] = []
		if let profile = profiles[id: .init(rawValue: id)] {
			items.formUnion(profile.favorites.map(\.rawValue))
			spaceIDs = spaces.filter { $0.profileID == profile.id }.map(\.id)
		} else if spaces[id: .init(rawValue: id)] != nil {
			spaceIDs = [.init(rawValue: id)]
		}
		for spaceID in spaceIDs {
			guard let space = spaces[id: spaceID] else { continue }

			items.insert(spaceID.rawValue)
			var saved: [SavedItem] = space.savedItems
			for folder in folders where folder.spaceID == spaceID {
				items.insert(folder.id.rawValue)
				saved.append(contentsOf: folder.children)
			}
			for item in saved {
				if case let .tab(tabID) = item { items.insert(tabID.rawValue) }
			}
		}
		return items
	}
}
