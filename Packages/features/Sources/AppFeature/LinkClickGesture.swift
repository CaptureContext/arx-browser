import AppKit
import BrowserCore
import BrowserEngineClient
import Foundation
import PeekFeature

/// Sends modified clicks on page links to Peek, Little Arx or a new tab.
///
/// Chromium has already chosen a disposition from the click: Shift asks for a new
/// window, and Command for a new tab. Settings choose where a Shift-click goes (DEV-1239). Option doesn't change Command's disposition, so
/// that part reads the keys held now, and releasing them very quickly falls back to
/// Chromium's choice. Anything that can't be routed also keeps Chromium's choice.
///
/// Neither callback carries the click's position, so Peek opens from where the pointer
/// is when the click arrives, in screen coordinates.
extension AppFeature.State {
	@MainActor
	internal func linkClickAction(
		for offer: BrowserNewContents,
		modifiers: NSEvent.ModifierFlags,
		pointer: CGPoint? = NSEvent.mouseLocation,
		engine: BrowserEngineClient
	) -> AppFeature.Action? {
		let url = offer.tab.restoration.url
		guard
			!offer.isPrivate,
			url.hasWebScheme,
			let source = engine.snapshot(offer.sourceTabID),
			source.revision == offer.sourceSessionRevision,
			source.documentRevision == offer.sourceDocumentRevision,
			let placement = nativeContentPlacement(
				tabID: offer.sourceTabID,
				profileID: offer.tab.profileID,
				isPrivate: false
			)
		else { return nil }

		switch offer.disposition {
		case .window:
			// Shift-click, where Settings say (DEV-1239). A route that can't take the link, such as
			// Peek from a floating page, keeps Chromium's new window.
			guard let route = settings.linkClicks.shiftClickLinkAction.route else { return nil }
			return linkOpenAction(url, route: route, placement: placement, origin: pointer)

		case .foregroundTab, .backgroundTab:
			guard
				settings.linkClicks.littleArxLinkBinding.matches(modifiers),
				let spaceID = nativeContentsSpace(placement)
			else { return nil }

			return .ui(.openLittleArx(spaceID, url))

		case .popup:
			return nil
		}
	}
}

extension AppFeature.State {
	/// Sends a Force Click on a page link to Peek, Little Arx or a new tab, as Settings say.
	/// Nil keeps Chromium's behavior: Look Up, then the ordinary click.
	@MainActor
	internal func linkForceClickAction(
		for click: BrowserLinkForceClick,
		pointer: CGPoint? = NSEvent.mouseLocation,
		engine: BrowserEngineClient
	) -> AppFeature.Action? {
		let url = click.url
		guard
			!click.isPrivate,
			url.hasWebScheme,
			let source = engine.snapshot(click.sourceTabID),
			source.revision == click.sourceSessionRevision,
			source.documentRevision == click.sourceDocumentRevision,
			let placement = nativeContentPlacement(
				tabID: click.sourceTabID,
				profileID: click.profileID,
				isPrivate: false
			)
		else { return nil }

		guard let route = settings.linkClicks.forceClickLinkAction.route else { return nil }
		return linkOpenAction(url, route: route, placement: placement, origin: pointer)
	}
}

extension AppFeature.State {
	/// Sends a plain click on a link to another site where the source tab's kind asks for in
	/// Settings: Favorites, and pinned tabs in a space or its folders, each choose Peek, Little
	/// Arx or a new tab (DEV-727, DEV-1239). Unpinned tabs, Peek, Little Arx and private windows
	/// keep Chromium's behavior, so nil lets the navigation go on.
	@MainActor
	internal func crossSiteLinkAction(
		for link: BrowserCrossSiteLink,
		pointer: CGPoint? = NSEvent.mouseLocation,
		engine: BrowserEngineClient
	) -> AppFeature.Action? {
		guard
			let route = crossSiteLinkRoute(from: link.sourceTabID),
			let source = engine.snapshot(link.sourceTabID),
			source.revision == link.sourceSessionRevision,
			source.documentRevision == link.sourceDocumentRevision,
			let placement = nativeContentPlacement(
				tabID: link.sourceTabID,
				profileID: link.profileID,
				isPrivate: false
			)
		else { return nil }

		return linkOpenAction(link.url, route: route, placement: placement, origin: pointer)
	}
}

extension AppFeature.State {
	/// Where Settings send a plain click on a link to another site in this tab: the choice for
	/// Favorites, or the one for pinned tabs in a space or its folders (DEV-727, DEV-1239). Nil
	/// follows the link in the tab.
	internal func crossSiteLinkRoute(from tabID: BrowserCore.Tab.ID) -> LinkOpenRoute? {
		switch workspace.location(of: tabID) {
		case .favorite?: settings.linkClicks.crossSiteLinkFromFavorites.route
		case .pinned?: settings.linkClicks.crossSiteLinkFromPinnedTabs.route
		case .unpinned?, nil: nil
		}
	}
}

extension ShiftClickLinkAction {
	/// Where Arx opens the link, or nil for Chromium's new window.
	internal var route: LinkOpenRoute? {
		switch self {
		case .peek: .peek
		case .littleArx: .littleArx
		case .newTab: .newTab
		case .newWindow: nil
		}
	}
}

extension ForceClickLinkAction {
	/// Where Arx opens the link, or nil for Chromium's Look Up.
	internal var route: LinkOpenRoute? {
		switch self {
		case .peek: .peek
		case .littleArx: .littleArx
		case .newTab: .newTab
		case .off: nil
		}
	}
}

extension CrossSiteLinkAction {
	/// Where Arx opens the link, or nil to follow it in its tab.
	internal var route: LinkOpenRoute? {
		switch self {
		case .peek: .peek
		case .littleArx: .littleArx
		case .newTab: .newTab
		case .currentTab: nil
		}
	}
}

/// Where an explicit link route opens a page link: a Shift-click, a Force Click, a link to
/// another site from a Favorite or a pinned tab, the link menu, or the keyboard.
internal enum LinkOpenRoute: CaseIterable, Equatable, Sendable {
	/// A new tab, from the link menu (DEV-795) or a gesture Settings send there (DEV-1239): behind the page right after it, or in
	/// front where new tabs open when Settings bring link tabs forward (DEV-952).
	case newTab

	/// A new window on the source's space, from the link menu only (DEV-815).
	case newWindow

	/// A new private window, from the link menu only (DEV-815).
	case privateWindow
	case peek
	case littleArx

	/// A new tab in the main window, on the Little Arx's space: the link menu's one way
	/// out of Little Arx, whose links otherwise stay in Little Arx (DEV-855).
	case mainWindow
}

extension AppFeature.State {
	/// Opens a link from a placement that is already bound to its source tab, profile and
	/// space. Nil where Arx leaves the link to Chromium: links that aren't http(s), and
	/// Peek from a page inside Peek. Callers reject private sources before resolving a
	/// placement, so nothing here reaches a private window.
	internal func linkOpenAction(
		_ url: URL,
		route: LinkOpenRoute,
		placement: LinkContextPlacement,
		origin: CGPoint?
	) -> AppFeature.Action? {
		guard url.hasWebScheme else { return nil }

		switch route {
		case .peek:
			// A floating page has no pane for a Peek to cover (DEV-1105).
			guard
				placement.peekID == nil,
				placement.floatingTabID == nil,
				let peek = peekSource(windowID: placement.windowID, paneID: placement.paneID),
				PeekFeature.previewURL(url.absoluteString) != nil
			else { return nil }

			return .ui(.peekURLFromSource(url, peek, origin: origin))

		case .littleArx:
			guard let spaceID = nativeContentsSpace(placement) else { return nil }
			return .ui(.openLittleArx(spaceID, url))

		case .newTab:
			// A page in a window's pane; Peek and Little Arx have no tabs of their own.
			guard
				placement.peekID == nil,
				let host = window(placement.windowID)
			else { return nil }

			// A floating page's tabs open behind it, right after it in its own space: the window
			// behind may show another (DEV-1105).
			if let floating = placement.floatingTabID {
				return .openLinkInBackgroundTab(url, opener: floating, windowID: placement.windowID)
			}

			// Behind the page and right after it, unless Settings bring link tabs forward (DEV-952).
			let opener = host.viewer.panes[id: placement.paneID]?.item.tab?.id
			if !settings.general.switchesToLinkTabs, let opener {
				return .openLinkInBackgroundTab(url, opener: opener, windowID: placement.windowID)
			}

			return placement.windowID == main.id
			? .main(.ui(.openInNewTab(url)))
			: .windows(.element(id: placement.windowID, action: .ui(.openInNewTab(url))))

		case .newWindow:
			// The source's space, so the link opens in its profile; never a private one.
			guard
				let spaceID = nativeContentsSpace(placement),
				workspace.spaces[id: spaceID] != nil
			else { return nil }
			return .openInNewWindow(url, spaceID)

		case .mainWindow:
			guard
				placement.peekID == nil,
				let little = littleWindows[id: placement.windowID],
				workspace.spaces[id: little.spaceID] != nil
			else { return nil }
			return .openInMainWindow(url, little.spaceID)

		case .privateWindow:
			// From Little Arx or Peek too: the window's downloads follow the source's profile.
			let opener = nativeContentsSpace(placement).flatMap { workspace.spaces[id: $0]?.profileID }
			return .openInPrivateWindow(url, opener: opener)
		}
	}
}

extension Optional where Wrapped == NSEvent {
	/// Where a routed link click opens Peek from. Return on a focused link activates it
	/// too, and the pointer may be anywhere then, so a key event opens Peek from the pane.
	@MainActor
	internal var linkActivationPointer: CGPoint? {
		switch self?.type {
		case .keyDown?, .keyUp?: nil
		default: NSEvent.mouseLocation
		}
	}
}

extension LittleArxLinkBinding {
	internal func matches(_ modifiers: NSEvent.ModifierFlags) -> Bool {
		let held = modifiers.intersection([.shift, .option, .command, .control])
		switch self {
		case .optionCommand: return held == [.option, .command]
		case .shiftOptionCommand: return held == [.shift, .option, .command]
		case .off: return false
		}
	}
}
