import AppUI
import BrowserCore
import CommandBarFeature
import Foundation

extension MainFeature.State {
	/// The profile's history as command bar entries. The ordinary bar leaves out addresses an
	/// open tab already shows, since the tab is listed itself; Show History keeps them (DEV-795).
	///
	/// - Parameters:
	///   - now: Ranks the entries by `HistoryFrecency` as of this moment, the most
	///     likely first (DEV-1015). Without it they stay newest first, as Show History lists them.
	internal func historyCandidates(
		profileID: Profile.ID,
		excludingOpenTabs: Bool = true,
		rankedAt now: Date? = nil
	) -> [CommandBarFeature.Entry] {
		var seen: Set<URL> = excludingOpenTabs
		? Set(sidebar.organization.tabs.filter { $0.profileID == profileID }.map(\.restoration.url))
		: []
		if !isPrivate, let snapshot = browsingHistory[profileID] {
			let spaceID = sidebar.spaceID
			let entries: [CommandBarFeature.Entry] = snapshot.entries.compactMap { item in
				guard seen.insert(item.url).inserted else { return nil }
				return .init(
					presentation: .init(
						id: "history-\(profileID.rawValue)-\(item.id)",
						title: item.title.isEmpty ? item.url.absoluteString : item.title,
						subtitle: item.url.absoluteString,
						actionTitle: String.localized(.appUI.command.openURL),
						symbol: "clock.arrow.circlepath",
						siteIcon: .init(profileID: profileID.rawValue, pageURL: item.url)
					),
					intent: .openHistory(.init(
						id: item.id,
						profileID: profileID,
						spaceID: spaceID,
						url: item.url
					)),
					frecency: now.map { HistoryFrecency.score(of: item, at: $0, in: spaceID) } ?? 0
				)
			}
			guard now != nil else { return entries }

			// Stable, so equal scores stay newest first.
			return entries.enumerated()
				.sorted { ($0.element.frecency, $1.offset) > ($1.element.frecency, $0.offset) }
				.map(\.element)
		}

		// Private browsing and startup before the index loads retain only this page's transient stack.
		guard viewer.item.tab?.profileID == profileID else { return [] }
		return viewer.item.navigation.history.reversed().compactMap { item in
			guard BrowsingHistoryEntry.accepts(item.url), seen.insert(item.url).inserted
			else { return nil }

			return .init(
				presentation: .init(
					id: "history-" + String(item.id),
					title: item.title.isEmpty ? item.url.absoluteString : item.title,
					subtitle: item.url.absoluteString,
					actionTitle: String.localized(.appUI.command.openURL),
					symbol: "clock.arrow.circlepath"
				),
				intent: .open(item.url)
			)
		}
	}
}

extension MainFeature.State {
	/// Whether a history result chosen in the command bar is still this window's to open: the
	/// entry is recorded, for this profile and space, outside private browsing.
	internal func isCurrent(_ selection: HistorySelection) -> Bool {
		let isRecorded = browsingHistory[selection.profileID]?.entries
			.contains(where: { $0.id == selection.id && $0.url == selection.url }) == true

		return !isPrivate
		&& selection.profileID == sidebar.space.profileID
		&& selection.spaceID == sidebar.spaceID
		&& isRecorded
	}
}
