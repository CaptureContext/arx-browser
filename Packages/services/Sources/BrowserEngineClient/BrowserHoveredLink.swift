import BrowserCore
import Foundation

/// The link under the pointer in a tab's page (DEV-1111), as Chrome's status bubble shows it,
/// for the link status that says what a click will do. Without the link's user name or
/// password; nothing about it is stored.
public struct BrowserHoveredLink: Equatable, Sendable {
	/// Where a plain click on the link navigates (DEV-1118): the link's target, else its
	/// document's `<base target>`, as the page's frames said.
	public enum Target: Equatable, Sendable {
		/// Not known: a plain click may navigate the page, a frame or a new tab.
		case unknown

		/// The page itself.
		case mainFrame

		/// A frame inside the page.
		case subframe

		/// A new tab or window (`_blank`).
		case newContext
	}

	public let tabID: BrowserCore.Tab.ID
	public let profileID: BrowserCore.Profile.ID
	public let isPrivate: Bool
	public let url: URL

	/// An http(s) link to another site than the page's, as the engine decides it for a
	/// ``BrowserCrossSiteLink``.
	public let isCrossSite: Bool
	public let target: Target

	public init(
		tabID: BrowserCore.Tab.ID,
		profileID: BrowserCore.Profile.ID,
		isPrivate: Bool,
		url: URL,
		isCrossSite: Bool,
		target: Target
	) {
		self.tabID = tabID
		self.profileID = profileID
		self.isPrivate = isPrivate
		self.url = url
		self.isCrossSite = isCrossSite
		self.target = target
	}
}
