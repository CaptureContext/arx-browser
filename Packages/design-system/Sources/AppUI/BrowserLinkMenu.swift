import BrowserCore
import SwiftUI

/// UI callbacks capture the hosting window and resolve current tab URLs at invocation.
public struct BrowserLinkActions: Sendable {
	public var copy: @MainActor @Sendable (LinkCopyMode, [UUID]?, Bool) -> Void
	public var share: @MainActor @Sendable ([UUID]?) -> Void

	/// Whether a proxy link rule matches one of the tabs' sites, or the current page's, so the
	/// menu offers the proxy link items (DEV-1262).
	public var proxies: @MainActor @Sendable ([UUID]?) -> Bool

	public init(
		copy: @escaping @MainActor @Sendable (LinkCopyMode, [UUID]?, Bool) -> Void,
		share: @escaping @MainActor @Sendable ([UUID]?) -> Void,
		proxies: @escaping @MainActor @Sendable ([UUID]?) -> Bool
	) {
		self.copy = copy
		self.share = share
		self.proxies = proxies
	}
}

private enum BrowserLinkActionsKey: EnvironmentKey {
	internal static var defaultValue: BrowserLinkActions? { nil }
}

extension EnvironmentValues {
	public var browserLinkActions: BrowserLinkActions? {
		get { self[BrowserLinkActionsKey.self] }
		set { self[BrowserLinkActionsKey.self] = newValue }
	}
}

public struct BrowserLinkMenu: View {
	private let tabIDs: [UUID]?
	private let offersSavedLink: Bool
	private let savedTabID: UUID?
	private let nestsCopies: Bool

	@Environment(\.browserLinkActions)
	private var actions

	/// - Parameters:
	///   - nestsCopies: whether the items sit in a Copy submenu (`CopySubmenuFeatureFlag`,
	///     DEV-1162), as they do unless the flag is off.
	public init(
		tabIDs: [UUID]? = nil,
		offersSavedLink: Bool = false,
		savedTabID: UUID? = nil,
		nestsCopies: Bool = CopySubmenuFeatureFlag.isOn()
	) {
		self.tabIDs = tabIDs
		self.offersSavedLink = offersSavedLink
		self.savedTabID = savedTabID
		self.nestsCopies = nestsCopies
	}

	public var body: some View {
		if let actions {
			let proxies = actions.proxies(tabIDs)
			if nestsCopies {
				copyMenu(actions, proxies: proxies)
			} else {
				topLevelItems(actions, proxies: proxies)
			}
		}
	}

	/// Copy ▸: every copy, then Share Proxy Link after a separator (DEV-1162). The proxy items
	/// only where a proxy link rule matches (DEV-1262).
	private func copyMenu(
		_ actions: BrowserLinkActions,
		proxies: Bool
	) -> some View {
		let sections = LinkCopyMenu.tabSections(proxies: proxies, offersSavedLink: offersSavedLink)
		return Menu(String.localized(.appUI.links.copyMenu.title)) {
			ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
				if index > 0 { Divider() }
				ForEach(section, id: \.self) { item in
					Button(item.copyMenuTitle(tabCount: tabIDs?.count ?? 1, isSavedForTab: isSingleSavedTab)) {
						perform(item, actions)
					}
				}
			}
		}
	}

	private func perform(
		_ item: LinkCopyMenu.Item,
		_ actions: BrowserLinkActions
	) {
		switch item {
		case let .copy(mode): actions.copy(mode, tabIDs, false)
		case .copySaved: actions.copy(.original, savedTabID.map { [$0] } ?? tabIDs, true)
		case .shareProxy: actions.share(tabIDs)
		}
	}

	/// The items as they were before the Copy submenu, with the feature flag off.
	private func topLevelItems(
		_ actions: BrowserLinkActions,
		proxies: Bool
	) -> some View {
		let modes = LinkCopyMode.allCases.filter { proxies || !$0.isProxy }
		return Group {
			if let tabIDs, tabIDs.count > 1 {
				// Several tabs copy their links at once; the other forms wait in a submenu (DEV-883).
				Button(String.localized(.appUI.links.copyLinks(tabIDs.count))) {
					actions.copy(.original, tabIDs, false)
				}
				Menu(String.localized(.appUI.links.copyLinksAs(tabIDs.count))) {
					ForEach(modes.filter { $0 != .original }, id: \.self) { mode in
						Button(mode.linkCopyTitle) { actions.copy(mode, tabIDs, false) }
					}
				}
			} else {
				ForEach(modes, id: \.self) { mode in
					Button(mode.linkCopyTitle) { actions.copy(mode, tabIDs, false) }
				}
			}
			if proxies {
				Button(String.localized(.appUI.links.shareProxy)) { actions.share(tabIDs) }
			}
			if offersSavedLink {
				Button(savedLinkTitle) {
					actions.copy(.original, savedTabID.map { [$0] } ?? tabIDs, true)
				}
			}
		}
	}

	/// A row that copies several tabs' links still copies only its own saved address.
	private var isSingleSavedTab: Bool {
		savedTabID != nil && (tabIDs?.count ?? 0) > 1
	}

	private var savedLinkTitle: String {
		String.localized(isSingleSavedTab ? .appUI.links.copySavedForTab : .appUI.links.copySaved)
	}
}

extension LinkCopyMode {
	public var linkCopyTitle: String {
		switch self {
		case .original: String.localized(.appUI.links.copyOriginal)
		case .clean: String.localized(.appUI.links.copyClean)
		case .markdownOriginal: String.localized(.appUI.links.copyMarkdownOriginal)
		case .proxy: String.localized(.appUI.links.copyProxy)
		case .markdownProxy: String.localized(.appUI.links.copyMarkdownProxy)
		}
	}
}

extension LinkCopyMenu.Item {
	/// The item's short title inside Copy ▸ (DEV-1162), where "Copy" is already said.
	///
	/// - Parameters:
	///   - tabCount: how many tabs' links the menu copies; several make Link "3 Links".
	///   - isSavedForTab: whether Saved Link copies only the row's own tab of several.
	public func copyMenuTitle(
		tabCount: Int = 1,
		isSavedForTab: Bool = false
	) -> String {
		switch self {
		case .copy(.original):
			tabCount > 1
			? String.localized(.appUI.links.copyMenu.links(tabCount))
			: String.localized(.appUI.links.copyMenu.link)
		case .copy(.clean): String.localized(.appUI.links.copyMenu.clean)
		case .copy(.markdownOriginal): String.localized(.appUI.links.copyMenu.markdown)
		case .copy(.proxy): String.localized(.appUI.links.copyMenu.proxy)
		case .copy(.markdownProxy): String.localized(.appUI.links.copyMenu.markdownProxy)
		case .copySaved:
			String.localized(isSavedForTab ? .appUI.links.copyMenu.savedForTab : .appUI.links.copyMenu.saved)
		case .shareProxy: String.localized(.appUI.links.shareProxy)
		}
	}
}
