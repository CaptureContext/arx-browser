import BrowserCore

/// An already-owned ordinary native options session from an authorized request.
public struct BrowserExtensionViewOffer: Equatable, Sendable {
	public let profileID: Profile.ID
	public let extensionID: String
	public let tab: BrowserCore.Tab

	public init(
		profileID: Profile.ID,
		extensionID: String,
		tab: BrowserCore.Tab
	) {
		self.profileID = profileID
		self.extensionID = extensionID
		self.tab = tab
	}
}
