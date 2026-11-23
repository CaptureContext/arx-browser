import BrowserCore
import Foundation

/// A plain click on an http(s) link to another site in a tab's current document (DEV-727).
///
/// The engine has deferred the navigation. Taking it cancels the navigation and the tab
/// stays where it was; declining lets it go on.
public struct BrowserCrossSiteLink: Equatable, Sendable {
	public let sourceTabID: BrowserCore.Tab.ID
	public let profileID: BrowserCore.Profile.ID
	public let sourceSessionRevision: UInt64
	public let sourceDocumentRevision: UInt64
	public let url: URL

	public init(
		sourceTabID: BrowserCore.Tab.ID,
		profileID: BrowserCore.Profile.ID,
		sourceSessionRevision: UInt64,
		sourceDocumentRevision: UInt64,
		url: URL
	) {
		self.sourceTabID = sourceTabID
		self.profileID = profileID
		self.sourceSessionRevision = sourceSessionRevision
		self.sourceDocumentRevision = sourceDocumentRevision
		self.url = url
	}
}
