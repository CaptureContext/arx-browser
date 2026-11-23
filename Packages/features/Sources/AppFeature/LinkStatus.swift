import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation

/// What a click on a hovered page link will do (DEV-1111), as the link status says it.
internal enum LinkClickOutcome: Equatable, Sendable {
	/// The page follows the link, or the click does nothing Arx describes, such as Control's
	/// context menu: the status shows the address alone.
	case follow
	case backgroundTab
	case foregroundTab
	case newWindow
	case privateWindow
	case peek
	case littleArx

	/// A new Little Arx, which is where a Little Arx's new tabs and windows go (DEV-855).
	case newLittleArx
	case download

	/// The app Air Traffic Control opens this link in, by its name.
	case app(String)

	/// The person's script Air Traffic Control runs with this link, by its handler's name.
	case script(String)

	/// A WebKit page, for a site Settings move to WebKit.
	case webKit
}

/// The choice Chromium makes from a click's modifier keys on macOS, before Arx routes it:
/// Command makes a tab, in front with Shift; Shift alone a window; Option alone a download.
/// Control opens the context menu instead of clicking.
internal enum LinkClickDisposition: Equatable, Sendable {
	case currentTab
	case backgroundTab
	case foregroundTab
	case window
	case download
	case contextMenu

	internal init(_ modifiers: NSEvent.ModifierFlags) {
		let held = modifiers.intersection([.shift, .option, .command, .control])
		if held.contains(.control) {
			self = .contextMenu
		} else if held.contains(.command) {
			self = held.contains(.shift) ? .foregroundTab : .backgroundTab
		} else if held.contains(.shift) {
			self = .window
		} else if held.contains(.option) {
			self = .download
		} else {
			self = .currentTab
		}
	}
}

extension AppFeature.State {
	/// What a click on `link` with `modifiers` held will do, by the same rules the click
	/// itself goes through: Chromium's choice from the keys, then Peek, Little Arx, routing and
	/// Settings › Links, as `linkClickAction`, `crossSiteLinkAction` and
	/// `NativeContentsPresentation` apply them.
	///
	/// - Parameters:
	///   - opensInWebKit: whether a followed link to `link`'s site moves the page to
	///     WebKit (Settings › Websites › WebKit pages), which BrowserWindow decides first.
	internal func linkClickOutcome(
		for link: BrowserHoveredLink,
		modifiers: NSEvent.ModifierFlags,
		opensInWebKit: Bool = false
	) -> LinkClickOutcome {
		let url = link.url
		let disposition = LinkClickDisposition(modifiers)
		if disposition == .contextMenu { return .follow }

		// A link for another app: Arx's prompt when a handler takes it, Chrome's otherwise.
		guard url.hasWebScheme else {
			let decision = settings.routingPreferences.appLinks.decide(
				link: url.absoluteString,
				profileID: link.profileID,
				isPrivate: link.isPrivate,
				sourceOrigin: nil
			)
			guard let decision else { return .follow }

			// A script that can't take this link leaves its prompt only Open app.
			if decision.handling.script != nil, decision.failure == nil { return .script(decision.handler.name) }
			return .app(decision.handling.application?.name ?? decision.handler.application?.name ?? decision.handler.name)
		}

		// Private windows keep Chromium's choice: Arx routes none of their links.
		if link.isPrivate {
			switch disposition {
			case .currentTab, .contextMenu: return link.target == .newContext ? .foregroundTab : .follow
			case .backgroundTab: return .backgroundTab
			case .foregroundTab: return .foregroundTab
			case .window: return .privateWindow
			case .download: return .download
			}
		}

		let placement = nativeContentPlacement(tabID: link.tabID, profileID: link.profileID, isPrivate: false)
		let isLittleArx = placement.map { $0.peekID == nil && littleWindows[id: $0.windowID] != nil } ?? false

		switch disposition {
		case .currentTab, .contextMenu:
			switch link.target {
			// The page's own new tab (`_blank`) comes forward, as Chromium opens it (DEV-952). From a
			// Favorite or a pinned tab it goes to Peek or Little Arx when Settings send that tab's
			// links there (DEV-1312), as `NativeContentsPresentation` does.
			case .newContext:
				if
					!isLittleArx,
					placement?.peekID == nil,
					let route = crossSiteLinkRoute(from: link.tabID),
					route == .peek || route == .littleArx,
					let routed = routeOutcome(route, url: url, placement: placement)
				{
					return routed
				}
				return newTabOutcome(.foregroundTab, shiftHeld: false, placement: placement, isLittleArx: isLittleArx)

			// Routing takes only a navigation of the page itself (ABI43), so a frame's link, or one
			// whose target is unknown, is promised nothing but its address (DEV-1118).
			case .subframe, .unknown:
				return .follow

			case .mainFrame:
				guard link.isCrossSite else { return .follow }
				if opensInWebKit { return .webKit }
				return crossSiteLinkRoute(from: link.tabID).flatMap { routeOutcome($0, url: url, placement: placement) }
				?? .follow
			}

		case .download:
			return .download

		case .window:
			// Where Settings send a Shift-click (DEV-1239), or Chromium's window when that route
			// can't take the link.
			let routed = settings.linkClicks.shiftClickLinkAction.route.flatMap {
				routeOutcome($0, url: url, placement: placement)
			}
			return routed ?? (isLittleArx ? .newLittleArx : .newWindow)

		case .backgroundTab, .foregroundTab:
			if
				settings.linkClicks.littleArxLinkBinding.matches(modifiers),
				let placement,
				nativeContentsSpace(placement) != nil
			{
				return .littleArx
			}
			return newTabOutcome(
				disposition == .backgroundTab ? .backgroundTab : .foregroundTab,
				shiftHeld: modifiers.contains(.shift),
				placement: placement,
				isLittleArx: isLittleArx
			)
		}
	}

	/// What a gesture Settings send to `route` does with the link, or nil where `linkOpenAction`
	/// leaves it to Chromium (DEV-1239).
	private func routeOutcome(
		_ route: LinkOpenRoute,
		url: URL,
		placement: LinkContextPlacement?
	) -> LinkClickOutcome? {
		guard
			let placement,
			let action = linkOpenAction(url, route: route, placement: placement, origin: nil)
		else { return nil }

		switch route {
		case .peek: return .peek
		case .littleArx: return .littleArx
		case .newTab:
			if case .openLinkInBackgroundTab = action { return .backgroundTab }
			return .foregroundTab
		case .newWindow: return .newWindow
		case .privateWindow: return .privateWindow
		case .mainWindow: return .foregroundTab
		}
	}

	/// Where a tab Chromium makes from a link goes, as `NativeContentsPresentation` places it:
	/// a new Little Arx from Little Arx (DEV-855), Peek's own rules, Settings for a window's pane.
	private func newTabOutcome(
		_ chromium: BrowserNewContents.Disposition,
		shiftHeld: Bool,
		placement: LinkContextPlacement?,
		isLittleArx: Bool
	) -> LinkClickOutcome {
		if isLittleArx { return .newLittleArx }

		// Peek's tabs keep Chromium's choice, and a tab in front from Peek opens a window.
		if placement?.peekID != nil { return chromium == .backgroundTab ? .backgroundTab : .newWindow }
		if placement == nil { return chromium == .backgroundTab ? .backgroundTab : .foregroundTab }

		let tab = linkTabDisposition(chromium, shiftHeld: shiftHeld)
		return tab == .backgroundTab ? .backgroundTab : .foregroundTab
	}
}

/// The words a link status shows (DEV-1111): the address, and around it what a click will do.
internal struct LinkStatus: Equatable, Sendable {
	internal var verb: String?
	internal var address: String
	internal var action: String?

	internal init(
		url: URL,
		outcome: LinkClickOutcome
	) {
		self.address = Self.address(url)
		switch outcome {
		case .follow:
			self.verb = nil
			self.action = nil
		case .download:
			self.verb = String.localized(.appUI.linkStatus.download)
			self.action = nil
		default:
			self.verb = String.localized(.appUI.linkStatus.open)
			self.action = Self.action(outcome)
		}
	}

	private static func action(_ outcome: LinkClickOutcome) -> String? {
		switch outcome {
		case .follow, .download: nil
		case .backgroundTab: String.localized(.appUI.linkStatus.backgroundTab)
		case .foregroundTab: String.localized(.appUI.linkStatus.foregroundTab)
		case .newWindow: String.localized(.appUI.linkStatus.newWindow)
		case .privateWindow: String.localized(.appUI.linkStatus.privateWindow)
		case .peek: String.localized(.appUI.linkStatus.peek)
		case .littleArx: String.localized(.appUI.linkStatus.littleArx)
		case .newLittleArx: String.localized(.appUI.linkStatus.newLittleArx)
		case let .app(name): String.localized(.appUI.linkStatus.app(name))
		case let .script(name): String.localized(.appUI.linkStatus.script(name))
		case .webKit: String.localized(.appUI.linkStatus.webKit)
		}
	}

	/// The link as people read it: `https://` left out, as the address bar does, and a bare
	/// site without its trailing slash. Any other scheme stays, so `http://` and `mailto:` show.
	internal static func address(_ url: URL) -> String {
		var text = url.absoluteString
		guard text.lowercased().hasPrefix("https://") else { return text }

		text.removeFirst("https://".count)
		let isSiteOnly = url.path(percentEncoded: true) == "/" && url.query == nil && url.fragment == nil
		if isSiteOnly, text.hasSuffix("/") { text.removeLast() }
		return text
	}

	@MainActor
	internal var view: LinkStatusToast {
		LinkStatusToast(verb: verb, address: address, action: action)
	}
}
