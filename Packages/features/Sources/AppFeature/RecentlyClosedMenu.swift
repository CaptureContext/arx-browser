import AppKit
import AppUI
import BrowserCore
import BrowserSiteIconClient
import _ComposableArchitecture

/// Archive ▸ Recently Closed (DEV-908): rebuilt each time it opens from the windows closed in
/// this session and the newest archived tabs of the front window's profile. Choosing a tab
/// restores it as ⇧⌘T does.
@MainActor
internal final class RecentlyClosedMenu: NSObject, NSMenuDelegate {
	private let store: StoreOf<AppFeature>
	private let siteIcons: BrowserSiteIconClient
	private var iconTasks: [Task<Void, Never>] = []

	internal init(
		store: StoreOf<AppFeature>,
		siteIcons: BrowserSiteIconClient
	) {
		self.store = store
		self.siteIcons = siteIcons
		super.init()
	}

	internal func menuNeedsUpdate(_ menu: NSMenu) {
		cancelIcons()
		menu.removeAllItems()

		let state = store.state
		let windows = state.recentlyClosedWindows.reversed().filter {
			state.reopenableClosedWindow($0.id) != nil
		}
		for closed in windows {
			let name = state.workspace.spaces[id: closed.spaceID]?.name ?? ""
			let item = NSMenuItem(
				title: String.localized(.appUI.menu.closedWindow(name)),
				action: #selector(reopenWindow(_:)),
				keyEquivalent: ""
			)
			item.target = self
			item.representedObject = closed.id.uuidString
			item.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
			menu.addItem(item)
		}

		let tabs = state.recentlyClosedTabs()
		if !windows.isEmpty, !tabs.isEmpty { menu.addItem(.separator()) }
		for entry in tabs {
			let title = entry.tab.displayTitle.isEmpty
			? entry.tab.restoration.url.absoluteString
			: entry.tab.displayTitle
			let item = NSMenuItem(title: title, action: #selector(reopenTab(_:)), keyEquivalent: "")
			item.target = self
			item.representedObject = entry.id.rawValue.uuidString
			item.toolTip = entry.tab.restoration.url.absoluteString
			item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
			menu.addItem(item)
			loadIcon(for: entry.tab, into: item)
		}

		if windows.isEmpty, tabs.isEmpty {
			let empty = NSMenuItem(
				title: String.localized(.appUI.menu.recentlyClosedEmpty),
				action: nil,
				keyEquivalent: ""
			)
			empty.isEnabled = false
			menu.addItem(empty)
		}
	}

	internal func menuDidClose(_ menu: NSMenu) {
		cancelIcons()
	}

	@objc
	private func reopenWindow(_ sender: NSMenuItem) {
		guard
			let raw = sender.representedObject as? String,
			let id = UUID(uuidString: raw)
		else { return }

		store.send(.ui(.reopenClosedWindow(id)))
	}

	@objc
	private func reopenTab(_ sender: NSMenuItem) {
		guard
			let raw = sender.representedObject as? String,
			let id = UUID(uuidString: raw)
		else { return }

		store.send(.ui(.reopenArchivedTab(.init(rawValue: id))))
	}

	/// The tab's stored site icon, shown when it arrives; the globe stays otherwise.
	private func loadIcon(
		for tab: BrowserCore.Tab,
		into item: NSMenuItem
	) {
		let key = BrowserSiteIconKey(profileID: tab.profileID, pageURL: tab.restoration.url)
		let stream = siteIcons.icons(key)
		iconTasks.append(Task { @MainActor [weak item] in
			for await data in stream {
				guard
					let data,
					let image = NSImage(data: data)
				else { continue }

				image.size = NSSize(width: 16, height: 16)
				item?.image = image
				return
			}
		})
	}

	private func cancelIcons() {
		for task in iconTasks { task.cancel() }
		iconTasks.removeAll()
	}
}
