import BrowserCore
import Foundation

/// A click on a site's web notification that finished (DEV-885). Without `isHandled`, the
/// app shows the site's tab in the profile, or opens the origin when it has none.
public struct BrowserNotificationClick: Equatable, Sendable {
	public let profileID: Profile.ID

	/// The notification's origin, `scheme://host[:port]`.
	public let origin: URL

	/// A service worker's notification rather than one a page made itself.
	public let isPersistent: Bool

	/// The site's page or service worker already showed or opened a tab.
	public let isHandled: Bool

	/// The page that made a non-persistent notification is gone.
	public let pageIsGone: Bool

	public init(
		profileID: Profile.ID,
		origin: URL,
		isPersistent: Bool,
		isHandled: Bool,
		pageIsGone: Bool
	) {
		self.profileID = profileID
		self.origin = origin
		self.isPersistent = isPersistent
		self.isHandled = isHandled
		self.pageIsGone = pageIsGone
	}
}
