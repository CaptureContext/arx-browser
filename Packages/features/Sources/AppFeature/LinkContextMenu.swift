import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import LocalUIExtensions
import _ComposableArchitecture

/// Owns only the active native menu; targets and private URLs are not persisted.
@MainActor
internal final class LinkContextMenu {
	private let store: StoreOf<AppFeature>
	private let client: BrowserEngineClient
	private let view: @MainActor (BrowserLinkContext) -> NSView?
	private var task: Task<Void, Never>?
	private var menu: NSMenu?

	internal init(
		store: StoreOf<AppFeature>,
		client: BrowserEngineClient,
		view: @escaping @MainActor (BrowserLinkContext) -> NSView?
	) {
		self.store = store
		self.client = client
		self.view = view
	}

	internal func start() {
		guard task == nil else { return }
		let events = client.linkContexts()
		task = Task { @MainActor [weak self] in
			for await context in events {
				guard !Task.isCancelled else { break }
				self?.present(context)
			}
		}
	}

	internal func stop() {
		task?.cancel()
		task = nil
		menu?.cancelTracking()
		menu = nil
	}

	internal func action(
		_ context: BrowserLinkContext,
		placement: LinkContextPlacement,
		mode: LinkCopyMode?
	) -> AppFeature.Action? {
		guard
			store.state.linkContextPlacement(context) == placement,
			client.linkContextIsCurrent(context)
		else { return nil }

		// Every link gets the menu; each item decides whether it applies (DEV-853).
		let availability = context.availability(rules: store.settings.proxyLinkRules)
		if let mode {
			guard availability.copyModes.contains(mode) else { return nil }

			// Copy Link keeps credentials, as in Chromium; a proxy link never carries them.
			let item = mode == .proxy || mode == .markdownProxy
			? LinkTransformer.removingCredentials(context.item)
			: context.item
			return .ui(.copyLinks(mode, items: [item], sourceWindowID: placement.windowID, sourcePaneID: placement.paneID))
		}
		guard availability.proxies else { return nil }
		return .ui(.shareProxyLinks(
			items: [LinkTransformer.removingCredentials(context.item)],
			sourceWindowID: placement.windowID,
			sourcePaneID: placement.paneID
		))
	}

	/// Opens the menu's own link from its own source. Private pages never offer it, nor do
	/// links Arx doesn't open, and a menu that outlived its page, tab, profile or space opens nothing.
	internal func openAction(
		_ context: BrowserLinkContext,
		placement: LinkContextPlacement,
		route: LinkOpenRoute,
		origin: CGPoint?
	) -> AppFeature.Action? {
		guard
			!context.isPrivate,
			context.availability(rules: store.settings.proxyLinkRules).opens,
			store.state.linkContextPlacement(context) == placement,
			client.linkContextIsCurrent(context)
		else { return nil }

		return store.state.linkOpenAction(context.item.url, route: route, placement: placement, origin: origin)
	}

	/// Downloads the menu's own link in its source's ordinary profile. Private pages never
	/// offer it, and neither does a menu that outlived its page or a profile without downloads.
	internal func downloadAction(
		_ context: BrowserLinkContext,
		placement: LinkContextPlacement
	) -> AppFeature.Action? {
		guard
			!context.isPrivate,
			store.state.downloadsReady,
			store.state.workspace.profiles[id: context.profileID] != nil,
			context.availability(rules: store.settings.proxyLinkRules).downloads,
			store.state.linkContextPlacement(context) == placement,
			client.linkContextIsCurrent(context)
		else { return nil }

		return .downloadLink(context)
	}

	private func present(_ context: BrowserLinkContext) {
		defer { client.dismissLinkContext(context) }
		guard
			let placement = store.state.linkContextPlacement(context),
			client.linkContextIsCurrent(context),
			let view = view(context),
			let window = view.window,
			window.identifier == placement.menuWindowIdentifier,
			window.isVisible, !window.isMiniaturized, !view.isHiddenOrHasHiddenAncestor,
			context.x < view.bounds.width, context.y < view.bounds.height
		else { return }

		let availability = context.availability(rules: store.settings.proxyLinkRules)
		let menu = NSMenu()
		menu.autoenablesItems = false
		if availability.proxies {
			let result = LinkTransformer.proxy(
				LinkTransformer.removingCredentials(context.item),
				rules: store.settings.proxyLinkRules
			)
			let destination = NSMenuItem(
				title: String(result.output.absoluteString.prefix(160)),
				action: nil,
				keyEquivalent: ""
			)
			destination.isEnabled = false
			menu.addItem(destination)
			let rule = NSMenuItem(title: linkTransformationMessage(result.outcome), action: nil, keyEquivalent: "")
			rule.isEnabled = false
			menu.addItem(rule)

		} else {
			// mailto:, tel:, other ports, and sites no proxy link rule matches (DEV-1262).
			let destination = NSMenuItem(
				title: String(context.item.url.absoluteString.prefix(160)),
				action: nil,
				keyEquivalent: ""
			)
			destination.isEnabled = false
			menu.addItem(destination)
		}
		menu.addItem(.separator())
		let point = NSPoint(
			x: view.bounds.minX + context.x,
			y: view.isFlipped ? view.bounds.minY + context.y : view.bounds.maxY - context.y
		)
		let origin = window.convertPoint(toScreen: view.convert(point, to: nil))
		let routes = LinkOpenRoute.allCases.filter {
			openAction(context, placement: placement, route: $0, origin: origin) != nil
		}
		for route in routes {
			menu.addItem(NSMenuItem(route.linkMenuTitle) { [weak self, weak view] in
				guard
					let self,
					let view,
					view.window === window,
					let action = openAction(context, placement: placement, route: route, origin: origin)
				else { return }
				store.send(action)
			})
		}
		if !routes.isEmpty { menu.addItem(.separator()) }

		// Download Linked File, in the source's ordinary profile (DEV-815).
		if downloadAction(context, placement: placement) != nil {
			menu.addItem(NSMenuItem(String.localized(.appUI.links.downloadLinkedFile)) { [weak self, weak view] in
				guard
					let self,
					let view,
					view.window === window,
					let action = downloadAction(context, placement: placement)
				else { return }
				store.send(action)
			})
			menu.addItem(.separator())
		}

		// Copy ▸ holds every copy, then Share Proxy Link (DEV-1162); a lone copy, such as a
		// mailto: link's Copy Email Address, stays at the top level with its full title.
		let sections = LinkCopyMenu.sections(modes: availability.copyModes, sharesProxy: availability.proxies)
		let nestsCopies = CopySubmenuFeatureFlag.isOn() && LinkCopyMenu.nests(sections)
		func copyItem(_ item: LinkCopyMenu.Item) -> NSMenuItem {
			let mode: LinkCopyMode? = if case let .copy(mode) = item { mode } else { nil }
			let title = Self.title(of: item, availability: availability, nested: nestsCopies)
			return NSMenuItem(title) { [weak self, weak view] in
				guard
					let self,
					let view,
					view.window === window,
					let action = action(context, placement: placement, mode: mode)
				else { return }
				store.send(action)
			}
		}

		// Share… with the plain link (DEV-815).
		let share = NSMenuItem(String.localized(.appUI.links.share)) { [weak self, weak view] in
			guard
				let self,
				let view,
				view.window === window,
				store.state.linkContextPlacement(context) == placement,
				client.linkContextIsCurrent(context)
			else { return }
			store.send(.ui(.shareLinks(items: [context.item], sourceWindowID: placement.windowID)))
		}
		if nestsCopies {
			let copies = NSMenu(title: String.localized(.appUI.links.copyMenu.title))
			for (index, section) in sections.enumerated() {
				if index > 0 { copies.addItem(.separator()) }
				for item in section { copies.addItem(copyItem(item)) }
			}
			let parent = NSMenuItem(title: copies.title, action: nil, keyEquivalent: "")
			parent.submenu = copies
			menu.addItem(parent)
			menu.addItem(share)
		} else {
			// Without the feature flag: the copies, Share…, then Share Proxy Link.
			for item in sections.joined() where item != .shareProxy { menu.addItem(copyItem(item)) }
			menu.addItem(share)
			if availability.proxies { menu.addItem(copyItem(.shareProxy)) }
		}

		// DEV-890: extensions' items for the link, from the engine, which runs the chosen one.
		_ = client.appendLinkExtensionItems(context, menu)
		if store.settings.general.developerModeEnabled {
			menu.addItem(.separator())
			menu.addItem(NSMenuItem(String.localized(.appUI.developer.inspectElement)) { [weak self, weak view] in
				guard
					let self,
					let view,
					view.window === window,
					store.state.linkContextPlacement(context) == placement
				else { return }
				_ = client.inspectLinkContext(context)
			})
		}
		self.menu = menu
		let closing = NotificationCenter.default.addObserver(
			forName: NSWindow.willCloseNotification, object: window, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.menu?.cancelTracking() }
		}
		defer { NotificationCenter.default.removeObserver(closing) }
		menu.popUp(positioning: nil, at: point, in: view)
		self.menu = nil
	}
}

extension LinkContextPlacement {
	/// The window whose page shows the link: Page PiP's panel for a page floating there that no
	/// pane shows (DEV-1123), which still routes its links through the window it floats from.
	@MainActor
	internal var menuWindowIdentifier: NSUserInterfaceItemIdentifier {
		floatingTabID == nil
		? LinkSharingClient.windowIdentifier(for: windowID)
		: .init(PagePictureInPicturePanel.identifier)
	}
}

extension LinkContextMenu {
	/// An item's title: short inside Copy ▸, and outside it as Chromium names them, Copy Email
	/// Address for mailto: and Copy Link for other links Arx doesn't open.
	fileprivate static func title(
		of item: LinkCopyMenu.Item,
		availability: LinkMenuAvailability,
		nested: Bool
	) -> String {
		if nested { return item.copyMenuTitle() }

		switch item {
		case .copy(.original) where !availability.opens:
			return availability.isEmailAddress
			? String.localized(.appUI.links.copyEmailAddress)
			: String.localized(.appUI.links.copyLink)
		case let .copy(mode):
			return mode.linkCopyTitle
		case .copySaved:
			return String.localized(.appUI.links.copySaved)
		case .shareProxy:
			return String.localized(.appUI.links.shareProxy)
		}
	}
}

extension LinkOpenRoute {
	fileprivate var linkMenuTitle: String {
		switch self {
		case .newTab: String.localized(.appUI.links.openInNewTab)
		case .newWindow: String.localized(.appUI.links.openInNewWindow)
		case .privateWindow: String.localized(.appUI.links.openInPrivateWindow)
		case .peek: String.localized(.appUI.links.openInPeek)
		case .littleArx: String.localized(.appUI.links.openInLittleArx)
		case .mainWindow: String.localized(.appUI.links.openInMainWindow)
		}
	}
}
