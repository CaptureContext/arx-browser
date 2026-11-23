import ChromiumBridge
import Foundation

/// ABI55 (DEV-885). A click on a site's web notification that finished.
public struct ChromiumNotificationClick: Equatable, Sendable {
	/// The ordinary profile's key, empty for the legacy Default profile.
	public let profileKey: String

	/// The notification's origin, `scheme://host[:port]`.
	public let origin: URL

	/// A service worker's notification rather than one a page made itself.
	public let isPersistent: Bool

	/// The site's page or service worker already showed or opened a tab.
	public let isHandled: Bool

	/// The page that made a non-persistent notification is gone.
	public let pageIsGone: Bool

	public init(
		profileKey: String,
		origin: URL,
		isPersistent: Bool,
		isHandled: Bool,
		pageIsGone: Bool
	) {
		self.profileKey = profileKey
		self.origin = origin
		self.isPersistent = isPersistent
		self.isHandled = isHandled
		self.pageIsGone = pageIsGone
	}

	/// Reads the native report. Nil for anything but an http(s) origin without a path.
	internal init?(
		profileKey: String,
		origin: String,
		flags: UInt32
	) {
		guard
			profileKey.isEmpty || UUID(uuidString: profileKey)?.uuidString.lowercased() == profileKey,
			let url = URL(string: origin, encodingInvalidCharacters: false),
			let scheme = url.scheme,
			["http", "https"].contains(scheme),
			url.host() != nil,
			url.path().isEmpty,
			url.query() == nil,
			url.fragment() == nil,
			url.user() == nil
		else { return nil }

		self.init(
			profileKey: profileKey,
			origin: url,
			isPersistent: flags & ARX_NOTIFICATION_PERSISTENT.rawValue != 0,
			isHandled: flags & ARX_NOTIFICATION_HANDLED.rawValue != 0,
			pageIsGone: flags & ARX_NOTIFICATION_PAGE_GONE.rawValue != 0
		)
	}
}
