import BrowserCore
import Foundation

/// A tab's link for another app, such as `claude://…`, before Chrome asks or launches
/// anything (DEV-857).
///
/// Taking it means Chrome shows and launches nothing: the app asks with its own prompt and
/// opens the link or runs the handler's script. Declining leaves it to Chrome.
public struct BrowserExternalLink: Equatable, Sendable {
	public let sourceTabID: BrowserCore.Tab.ID

	/// The tab's profile; a private window's own private profile.
	public let profileID: BrowserCore.Profile.ID
	public let isPrivate: Bool
	public let sourceDocumentRevision: UInt64

	/// Names this offer for `BrowserEngineClient.externalLinkIsCurrent`.
	public let sourceToken: UInt64

	/// The link as the engine escaped it for an app.
	public let link: String

	/// The requesting page's origin, never its full URL.
	public let sourceOrigin: String?
	public let hasUserGesture: Bool
	public let isRedirect: Bool

	public init(
		sourceTabID: BrowserCore.Tab.ID,
		profileID: BrowserCore.Profile.ID,
		isPrivate: Bool,
		sourceDocumentRevision: UInt64,
		sourceToken: UInt64 = 0,
		link: String,
		sourceOrigin: String?,
		hasUserGesture: Bool,
		isRedirect: Bool
	) {
		self.sourceTabID = sourceTabID
		self.profileID = profileID
		self.isPrivate = isPrivate
		self.sourceDocumentRevision = sourceDocumentRevision
		self.sourceToken = sourceToken
		self.link = link
		self.sourceOrigin = sourceOrigin
		self.hasUserGesture = hasUserGesture
		self.isRedirect = isRedirect
	}
}
