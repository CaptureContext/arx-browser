import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

/// Dark pages (DEV-1020): Settings' mode, the Dark Page command and the site menu's switch.
///
/// Settings knows whether they're available (`ARX_DARK_PAGES` and an engine that has them); every
/// window offers the command and the switch while they are and the mode isn't Off. The app shell
/// (`BrowserWindow.applyDarkPages`) sends the engine what to darken, since only it knows whether
/// Arx's windows are dark.
extension AppFeature.State {
	/// Dark pages are offered while they're available and not Off.
	internal var darkPagesOffered: Bool {
		settings.darkPagesAvailable && settings.general.darkPages != .off
	}

	/// Every window's command context and site menu read the same value, including windows
	/// created after it changed.
	internal mutating func reconcileDarkPages() {
		let offered = darkPagesOffered
		if main.darkPagesOffered != offered { main.darkPagesOffered = offered }
		for id in windows.ids where windows[id: id]?.darkPagesOffered != offered {
			windows[id: id]?.darkPagesOffered = offered
		}
	}

	/// The Dark Page command: turns dark pages off for the target page's site in its profile, or
	/// back on. Ordinary windows' web pages only.
	internal func toggleDarkPage(for target: AppFeature.CommandTarget) -> OrganizationChange? {
		guard
			darkPagesOffered,
			case let .window(id, paneID) = target,
			let window = window(id),
			!window.isPrivate
		else { return nil }

		let pane = paneID ?? window.viewer.activePaneID
		let item = window.viewer.panes[id: pane]?.item ?? window.viewer.item
		guard
			let tab = item.tab,
			!tab.isChat,
			let url = item.navigation.url ?? workspace.tabs[id: tab.id]?.restoration.url,
			let site = KeptLoadedSite.site(of: url)
		else { return nil }

		let isOff = (workspace.profiles[id: tab.profileID]?.darkPagesOffSites ?? []).contains {
			KeptLoadedSite.matches(url, site: $0)
		}
		return .setDarkPageSite(tab.profileID, site: site, off: !isOff)
	}
}
