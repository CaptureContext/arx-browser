import Foundation

public struct Space: Identifiable, Equatable, Codable, Sendable {
	public let id: ID
	public let profileID: Profile.ID
	public var name: String
	public var icon: SpaceIcon?
	public var appearance: AppearanceOverride?
	public var savedItems: [SavedItem]
	public var unpinnedTabs: [Tab.ID]
	public var selectedTabID: Tab.ID?

	public init(
		id: ID,
		profileID: Profile.ID,
		name: String,
		icon: SpaceIcon? = nil,
		appearance: AppearanceOverride? = nil,
		savedItems: [SavedItem] = [],
		unpinnedTabs: [Tab.ID] = [],
		selectedTabID: Tab.ID? = nil
	) {
		self.id = id
		self.profileID = profileID
		self.name = name
		self.icon = icon
		self.appearance = appearance
		self.savedItems = savedItems
		self.unpinnedTabs = unpinnedTabs
		self.selectedTabID = selectedTabID
	}
}

extension Space {
	public typealias ID = BrowserID<Self>
}
