import AppUI
import BrowserCore
import CommandBarFeature
import Foundation
import LittleArxFeature

extension AppFeature.State {
	/// Recent history, then open tabs, then the profile's favorites, as pages the temporary window opens.
	internal func littleArxSuggestions(profileID: Profile.ID) -> [CommandBarFeature.Entry] {
		let tabs = workspace.tabs.filter { $0.profileID == profileID }
		let favorites = Set(workspace.profiles[id: profileID]?.favorites ?? [])
		let history = main.browsingHistory[profileID]?.entries ?? []
		let pages = history.map { (title: $0.title, url: $0.url, symbol: "clock.arrow.circlepath") }
			+ tabs.filter { !favorites.contains($0.id) }.map { (title: $0.displayTitle, url: $0.restoration.url, symbol: "globe") }
			+ tabs.filter { favorites.contains($0.id) }.map { (title: $0.displayTitle, url: $0.restoration.url, symbol: "star") }

		var seen = Set<URL>()
		return pages.compactMap { page in
			guard BrowsingHistoryEntry.accepts(page.url), seen.insert(page.url).inserted
			else { return nil }
			return .init(
				presentation: .init(
					id: "suggestion-" + page.url.absoluteString,
					title: page.title.isEmpty ? page.url.absoluteString : page.title,
					subtitle: (page.url.host() ?? "") + page.url.path(),
					actionTitle: String.localized(.appUI.command.openURL),
					symbol: page.symbol,
					siteIcon: .init(profileID: profileID.rawValue, pageURL: page.url)
				),
				intent: .open(page.url)
			)
		}
	}
}

extension AppFeature.State {
	/// The profiles Little Arx's launcher offers (DEV-1331): the workspace's, in its order, that
	/// have a space for the page to open in.
	internal var littleArxProfileIDs: [Profile.ID] {
		workspace.profiles.ids.filter { profileID in
			workspace.spaces.contains { $0.profileID == profileID }
		}
	}

	/// What the launcher lists for `profileID` (DEV-1331): the space the main window shows when it's
	/// that profile's, else the profile's first, with the profile's own pages and search engine.
	internal func littleArxLauncherProfile(_ profileID: Profile.ID) -> LittleArxFeature.LauncherProfile? {
		guard let profile = workspace.profiles[id: profileID] else { return nil }

		let shown = workspace.spaces[id: main.sidebar.spaceID]
		guard let space = shown?.profileID == profileID ? shown : workspace.spaces.first(where: { $0.profileID == profileID })
		else { return nil }

		return .init(
			profileID: profileID,
			spaceID: space.id,
			searchEngine: profile.searchEngine ?? .google,
			suggestions: littleArxSuggestions(profileID: profileID)
		)
	}
}
