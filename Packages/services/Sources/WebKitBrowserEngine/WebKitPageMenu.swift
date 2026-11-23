import AppKit
import BrowserCore

/// Arx's page menu on a WebKit page (DEV-1199): what a right click on the page itself shows,
/// the same commands as a Chromium page's menu (DEV-795).
///
/// WebKit builds the menu and hands it to `WebKitPageView.willOpenMenu`. Where WebKit offers
/// its own Back, Forward and Reload (the page's background, or a player drawn over it, as
/// Netflix's is), Arx's page items take their place. A menu of a video's own items gets them
/// after those. Link, image and text menus stay WebKit's, as do Inspect Element (with
/// developer mode on) and every other item WebKit adds.
public struct WebKitPageMenu: Sendable {
	/// The page menu's commands the host showing the tab can carry out now.
	public var commands: @MainActor @Sendable (Tab.ID) -> Set<BrowserCommand>

	/// A command's title, as the menu bar shows it.
	public var title: @MainActor @Sendable (BrowserCommand) -> String

	/// The title of Exit Full Screen, shown while the page is in full screen.
	public var exitFullScreenTitle: String

	/// A command chosen from the menu, for the host showing the tab.
	public var choose: @MainActor @Sendable (Tab.ID, BrowserCommand) -> Void

	public init(
		commands: @escaping @MainActor @Sendable (Tab.ID) -> Set<BrowserCommand>,
		title: @escaping @MainActor @Sendable (BrowserCommand) -> String,
		exitFullScreenTitle: String,
		choose: @escaping @MainActor @Sendable (Tab.ID, BrowserCommand) -> Void
	) {
		self.commands = commands
		self.title = title
		self.exitFullScreenTitle = exitFullScreenTitle
		self.choose = choose
	}

	/// The page menu's commands in order, as Chromium's page menu lists them; nil is a separator.
	/// Cast and Translate aren't here: WebKit pages have neither.
	public static let layout: [BrowserCommand?] = [
		.goBack, .goForward, .reload,
		nil,
		.savePageAs, .printPage, .sharePage,
		nil,
		.viewSource,
	]

	/// Every command the page menu can show.
	public static var allCommands: Set<BrowserCommand> { Set(layout.compactMap(\.self)) }

	/// WebKit's identifiers for its items (`WKMenuItemIdentifier…`).
	internal enum Identifier {
		internal static let goBack: String = "WKMenuItemIdentifierGoBack"
		internal static let goForward: String = "WKMenuItemIdentifierGoForward"
		internal static let reload: String = "WKMenuItemIdentifierReload"
		internal static let toggleFullScreen: String = "WKMenuItemIdentifierToggleFullScreen"
		internal static let inspectElement: String = "WKMenuItemIdentifierInspectElement"

		/// WebKit's items for the page itself, which Arx's page items replace.
		internal static let navigation: Set<String> = [goBack, goForward, reload]

		/// WebKit's items for a video or audio element.
		internal static let media: Set<String> = [
			toggleFullScreen,
			"WKMenuItemIdentifierShowHideMediaControls",
			"WKMenuItemIdentifierShowHideMediaStats",
			"WKMenuItemIdentifierCopyMediaLink",
			"WKMenuItemIdentifierOpenMediaInNewWindow",
			"WKMenuItemIdentifierDownloadMediaFile",
		]

		/// Items for a link, an image or selected text: a menu with one is about that, not the page.
		internal static let content: Set<String> = [
			"WKMenuItemIdentifierOpenLink",
			"WKMenuItemIdentifierOpenLinkInNewWindow",
			"WKMenuItemIdentifierDownloadLinkedFile",
			"WKMenuItemIdentifierCopyLink",
			"WKMenuItemIdentifierCopyLinkWithHighlight",
			"WKMenuItemIdentifierOpenImageInNewWindow",
			"WKMenuItemIdentifierDownloadImage",
			"WKMenuItemIdentifierCopyImage",
			"WKMenuItemIdentifierCopySubject",
			"WKMenuItemIdentifierCopy",
			"WKMenuItemIdentifierPaste",
			"WKMenuItemIdentifierLookUp",
			"WKMenuItemIdentifierSearchWeb",
			"WKMenuItemIdentifierSpellingMenu",
			"WKMenuItemIdentifierWritingTools",
		]
	}

	/// Puts Arx's page items in WebKit's menu for `tabID`, when the menu is the page's.
	/// `exitFullScreen` is the Exit Full Screen action while the page is in full screen.
	@MainActor
	internal func adjust(
		_ menu: NSMenu,
		for tabID: Tab.ID,
		exitFullScreen: (@MainActor () -> Void)?
	) {
		let identifiers = Set(menu.items.compactMap { $0.identifier?.rawValue })
		guard identifiers.isDisjoint(with: Identifier.content) else { return }

		let replacesNavigation = !identifiers.isDisjoint(with: Identifier.navigation)
		guard replacesNavigation || !identifiers.isDisjoint(with: Identifier.media) else { return }

		var items = pageItems(for: tabID)

		// WebKit's own Exit Full Screen for a video stands; otherwise Arx's leads, as Chromium's does.
		if let exitFullScreen, !identifiers.contains(Identifier.toggleFullScreen) {
			let item = WebKitMenuAction.item(exitFullScreenTitle, perform: exitFullScreen)
			items.insert(contentsOf: [item, .separator()], at: 0)
		}
		guard !items.isEmpty else { return }

		if replacesNavigation {
			let first = menu.items.firstIndex { Identifier.navigation.contains($0.identifier?.rawValue ?? "") } ?? 0
			for item in menu.items where Identifier.navigation.contains(item.identifier?.rawValue ?? "") {
				menu.removeItem(item)
			}
			for (offset, item) in items.enumerated() {
				menu.insertItem(item, at: first + offset)
			}
		} else {
			// After the video's own items, in a group of their own before Inspect Element's.
			let inspect = menu.items.firstIndex { $0.identifier?.rawValue == Identifier.inspectElement }
			var index = inspect ?? menu.items.count
			if let inspect, inspect > 0, menu.items[inspect - 1].isSeparatorItem { index = inspect - 1 }
			for item in [.separator()] + items {
				menu.insertItem(item, at: index)
				index += 1
			}
		}
		Self.tidySeparators(menu)
	}

	/// The page items the host can carry out now, in `layout` order, with one separator between
	/// groups and none at either end.
	@MainActor
	internal func pageItems(for tabID: Tab.ID) -> [NSMenuItem] {
		let available = commands(tabID)
		var items: [NSMenuItem] = []
		var pendingSeparator = false
		for command in Self.layout {
			guard let command else {
				pendingSeparator = !items.isEmpty
				continue
			}
			guard available.contains(command) else { continue }

			if pendingSeparator {
				items.append(.separator())
				pendingSeparator = false
			}
			let choose = self.choose
			items.append(WebKitMenuAction.item(title(command)) { choose(tabID, command) })
		}
		return items
	}

	/// No separator first, last or after another.
	@MainActor
	internal static func tidySeparators(_ menu: NSMenu) {
		var previousIsSeparator = true
		for item in menu.items {
			if item.isSeparatorItem, previousIsSeparator {
				menu.removeItem(item)
			} else {
				previousIsSeparator = item.isSeparatorItem
			}
		}
		if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
	}
}

/// A menu item's action as a closure.
@MainActor
internal final class WebKitMenuAction: NSObject {
	private let perform: @MainActor () -> Void

	private init(_ perform: @escaping @MainActor () -> Void) {
		self.perform = perform
	}

	internal static func item(
		_ title: String,
		perform: @escaping @MainActor () -> Void
	) -> NSMenuItem {
		let action = WebKitMenuAction(perform)
		let item = NSMenuItem(title: title, action: #selector(WebKitMenuAction.invoke(_:)), keyEquivalent: "")
		item.target = action

		// The item keeps its target alive: NSMenuItem holds its target weakly.
		item.representedObject = action
		return item
	}

	@objc
	internal func invoke(_ sender: Any?) {
		perform()
	}
}
