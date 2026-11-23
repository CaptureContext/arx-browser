import ChromiumBridge
import Foundation

/// ABI50 (DEV-857): a page's link for another app, such as `claude://…`, offered before
/// Chrome's lookup, "Open app?" dialog or launch.
public struct ChromiumExternalLink: Equatable, Sendable {
	/// Chromium's `url::kMaxURLChars`: longer links never reach the app.
	public static let maximumSize: Int = 2 * 1024 * 1024

	/// The link as Chrome escaped it for an external handler.
	public let link: String

	/// The page's ordinary profile key, nil in a private profile.
	public let profileKey: String?

	/// The requesting origin, never the page's full URL. Nil for an unknown or opaque origin.
	public let sourceOrigin: String?
	public let hasUserGesture: Bool

	/// A client or server redirect reached the link.
	public let isRedirect: Bool
	public let isPrivate: Bool
	public let documentRevision: UInt64

	/// Names this offer for ``ChromiumRuntime/isExternalLinkCurrent(_:token:)``.
	public let token: UInt64

	public init(
		link: String,
		profileKey: String?,
		sourceOrigin: String?,
		hasUserGesture: Bool,
		isRedirect: Bool,
		isPrivate: Bool,
		documentRevision: UInt64,
		token: UInt64
	) {
		self.link = link
		self.profileKey = profileKey
		self.sourceOrigin = sourceOrigin
		self.hasUserGesture = hasUserGesture
		self.isRedirect = isRedirect
		self.isPrivate = isPrivate
		self.documentRevision = documentRevision
		self.token = token
	}

	internal init(
		link: String,
		profileKey: String?,
		sourceOrigin: String?,
		flags: UInt32,
		documentRevision: UInt64,
		token: UInt64
	) {
		self.init(
			link: link,
			profileKey: profileKey,
			sourceOrigin: sourceOrigin?.isEmpty == false ? sourceOrigin : nil,
			hasUserGesture: flags & ARX_EXTERNAL_LINK_USER_GESTURE.rawValue != 0,
			isRedirect: flags & ARX_EXTERNAL_LINK_REDIRECT.rawValue != 0,
			isPrivate: flags & ARX_EXTERNAL_LINK_PRIVATE.rawValue != 0,
			documentRevision: documentRevision,
			token: token
		)
	}
}
