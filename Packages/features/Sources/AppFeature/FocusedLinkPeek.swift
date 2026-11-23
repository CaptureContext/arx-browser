import BrowserCore
import BrowserEngineClient
import Foundation

/// Open Focused Link in Peek (DEV-713): the link that has keyboard focus in the command's
/// page, in any frame, opens in Peek over that page. The engine reads the link without
/// clicking or focusing anything; nothing happens for a focused non-link, a text field,
/// a private window, or a page inside Peek.
extension AppFeature.State {
	/// The tab whose page the command reads: the target pane's tab, or Little Arx's tab.
	internal func focusedLinkSourceTab(for target: AppFeature.CommandTarget) -> BrowserCore.Tab.ID? {
		guard case let .window(id, paneID) = target else { return nil }

		if let little = littleWindows[id: id] {
			guard !little.isCommandOnly, !little.isClosing, !little.isPromoting else { return nil }
			return little.tab.id
		}
		let host = id == main.id ? (windowIsOpen ? main : nil) : windows[id: id]
		guard
			let host,
			!host.isPrivate,
			!host.isClosing,
			let pane = host.viewer.panes[id: paneID ?? host.viewer.activePaneID]
		else { return nil }

		return pane.item.tab?.id
	}

	/// Peek for the engine's answer, through the same route as Force Click and the link
	/// menu, with no click point: Peek grows from the pane. `source` is the tab's session
	/// now; nil when its session or document changed since the engine read the link, or
	/// the link can't open in Peek.
	internal func focusedLinkPeekAction(
		for link: BrowserFocusedLink,
		source: BrowserSessionSnapshot?
	) -> AppFeature.Action? {
		guard
			!link.isPrivate,
			link.url.hasWebScheme,
			let source,
			source.revision == link.sourceSessionRevision,
			source.documentRevision == link.sourceDocumentRevision,
			let placement = nativeContentPlacement(
				tabID: link.sourceTabID,
				profileID: link.profileID,
				isPrivate: false
			)
		else { return nil }

		return linkOpenAction(link.url, route: .peek, placement: placement, origin: nil)
	}
}
