import BrowserCore
import Foundation

public struct HistorySelection: Equatable, Sendable {
	public let id: UUID
	public let profileID: Profile.ID
	public let spaceID: Space.ID
	public let url: URL

	public init(
		id: UUID,
		profileID: Profile.ID,
		spaceID: Space.ID,
		url: URL
	) {
		self.id = id
		self.profileID = profileID
		self.spaceID = spaceID
		self.url = url
	}
}
