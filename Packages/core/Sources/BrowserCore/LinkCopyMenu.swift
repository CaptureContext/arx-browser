/// The Copy submenu (DEV-1162): every way to copy a link, then Share Proxy Link after a
/// separator, nested so they don't crowd the top of a tab's, a link's or the Tab menu. The
/// sidebar, Favorites, split rows, the address bar, Little Arx, the page's link menu and the menu
/// bar all lay it out from here, behind `CopySubmenuFeatureFlag`.
public enum LinkCopyMenu {
	public enum Item: Hashable, Sendable {
		case copy(LinkCopyMode)

		/// A pinned tab's saved address, rather than the page it shows now.
		case copySaved
		case shareProxy
	}

	/// The submenu's sections, a separator between them: the copies in menu order, then Share
	/// Proxy Link. An empty section is left out.
	public static func sections(
		modes: [LinkCopyMode],
		offersSavedLink: Bool = false,
		sharesProxy: Bool
	) -> [[Item]] {
		let copies = modes.map(Item.copy) + (offersSavedLink ? [.copySaved] : [])
		let shares: [Item] = sharesProxy ? [.shareProxy] : []
		return [copies, shares].filter { !$0.isEmpty }
	}

	/// The Copy submenu of a tab's or the page's menu, which acts on tabs rather than one link:
	/// every form of the link, with the proxy forms and Share Proxy Link only when `proxies`, a
	/// proxy link rule matching one of the tabs' sites (DEV-1262).
	public static func tabSections(
		proxies: Bool,
		offersSavedLink: Bool = false
	) -> [[Item]] {
		sections(
			modes: LinkCopyMode.allCases.filter { proxies || !$0.isProxy },
			offersSavedLink: offersSavedLink,
			sharesProxy: proxies
		)
	}

	/// Whether these sections nest in a submenu. A lone item, such as a mailto: link's Copy Email
	/// Address, stays at the top level with its full title.
	public static func nests(_ sections: [[Item]]) -> Bool {
		sections.joined().count > 1
	}
}

extension LinkCopyMenu.Item {
	/// The browser command that runs this item for the current tab, if there is one: the menu
	/// bar's Tab ▸ Copy items are these commands, with their shortcuts.
	public var command: BrowserCommand? {
		switch self {
		case .copy(.original): .copyURL
		case .copy(.clean): .copyCleanLink
		case .copy(.markdownOriginal): .copyMarkdownOriginal
		case .copy(.proxy): .copyProxyLink
		case .copy(.markdownProxy): .copyMarkdownProxy
		case .copySaved: nil
		case .shareProxy: .shareProxyLink
		}
	}
}
