import Foundation

/// Transient session metadata, deliberately excluded from the durable organization snapshot.
public struct BrowsingSession: Identifiable, Equatable, Sendable {
	public let id: ID
	public let tabID: Tab.ID
	public let profileID: Profile.ID
	public var navigation: BrowserNavigation

	public init(
		id: ID,
		tabID: Tab.ID,
		profileID: Profile.ID,
		navigation: BrowserNavigation = .init()
	) {
		self.id = id
		self.tabID = tabID
		self.profileID = profileID
		self.navigation = navigation
	}
}

extension BrowsingSession {
	public typealias ID = BrowserID<Self>
}
