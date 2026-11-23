import BrowserCore
import Foundation

/// A Force Click on an http(s) link in a tab's current document.
public struct BrowserLinkForceClick: Equatable, Sendable {
	public let sourceTabID: BrowserCore.Tab.ID
	public let profileID: BrowserCore.Profile.ID
	public let sourceSessionRevision: UInt64
	public let sourceDocumentRevision: UInt64
	public let url: URL
	public let isPrivate: Bool

	public init(
		sourceTabID: BrowserCore.Tab.ID,
		profileID: BrowserCore.Profile.ID,
		sourceSessionRevision: UInt64,
		sourceDocumentRevision: UInt64,
		url: URL,
		isPrivate: Bool = false
	) {
		self.sourceTabID = sourceTabID
		self.profileID = profileID
		self.sourceSessionRevision = sourceSessionRevision
		self.sourceDocumentRevision = sourceDocumentRevision
		self.url = url
		self.isPrivate = isPrivate
	}
}
