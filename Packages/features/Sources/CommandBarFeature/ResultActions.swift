import AppUI
import BrowserCore
import Foundation
import _ComposableArchitecture

extension CommandBarFeature {
	/// Something that can be done with a result, listed by ⌘K or the bar's Actions button
	/// (DEV-810). The first is always what Return does.
	public struct ResultAction: Equatable, Identifiable, Sendable {
		public enum Kind: Equatable, Sendable {
			/// Goes to the host as if a result with this intent had been chosen.
			case run(Intent, Destination?)

			/// Removes history and keeps the bar open.
			case removeHistory(Profile.ID, BrowsingHistoryRemoval)
		}

		public var id: String
		public var title: String
		public var symbol: String

		/// The key that runs it from the bar: ↩ for the result's own action.
		public var shortcut: String?
		public var isDestructive: Bool
		public var kind: Kind

		public init(
			id: String,
			title: String,
			symbol: String,
			shortcut: String? = nil,
			isDestructive: Bool = false,
			kind: Kind
		) {
			self.id = id
			self.title = title
			self.symbol = symbol
			self.shortcut = shortcut
			self.isDestructive = isDestructive
			self.kind = kind
		}

		public var presentation: CommandBarActionItem {
			.init(
				id: id,
				title: title,
				symbol: symbol,
				shortcut: shortcut,
				isDestructive: isDestructive
			)
		}
	}

	/// What the bar's host can carry out besides the result's own action. Set before every
	/// presentation: a private window has no Peek, Little Arx or recorded history, and Little
	/// Arx has no tabs of its own.
	public struct ActionAvailability: Equatable, Sendable {
		public var opensNewTabs: Bool
		public var opensPeek: Bool
		public var opensLittleArx: Bool
		public var removesHistory: Bool

		public init(
			opensNewTabs: Bool,
			opensPeek: Bool,
			opensLittleArx: Bool,
			removesHistory: Bool
		) {
			self.opensNewTabs = opensNewTabs
			self.opensPeek = opensPeek
			self.opensLittleArx = opensLittleArx
			self.removesHistory = removesHistory
		}

		public static let all: Self = .init(
			opensNewTabs: true,
			opensPeek: true,
			opensLittleArx: true,
			removesHistory: true
		)

		public static let none: Self = .init(
			opensNewTabs: false,
			opensPeek: false,
			opensLittleArx: false,
			removesHistory: false
		)
	}

	/// The open actions panel, for the result it was opened on.
	@ObservableState
	public struct ActionPanel: Equatable, Sendable {
		public var entryID: String
		public var query: String
		public var selectedID: String?

		public init(
			entryID: String,
			query: String = "",
			selectedID: String? = nil
		) {
			self.entryID = entryID
			self.query = query
			self.selectedID = selectedID
		}
	}
}

extension CommandBarFeature.State {
	/// The highlighted result, whose actions ⌘K lists.
	public var selectedEntry: CommandBarFeature.Entry? {
		let entries = self.entries
		return entries.first { $0.presentation.id == selectedID }
	}

	/// The result the open panel belongs to.
	public var actionPanelEntry: CommandBarFeature.Entry? {
		guard let actionPanel else { return nil }
		return entries.first { $0.presentation.id == actionPanel.entryID }
	}

	/// The open panel's actions, matching what's typed into it.
	public var actionPanelActions: [CommandBarFeature.ResultAction] {
		guard
			let actionPanel,
			let entry = actionPanelEntry
		else { return [] }

		let filter = actionPanel.query.trimmingCharacters(in: .whitespacesAndNewlines)
		let actions = actions(for: entry)
		guard !filter.isEmpty else { return actions }
		return actions.filter { $0.title.localizedCaseInsensitiveContains(filter) }
	}

	/// Everything that can be done with `entry`, its own action first.
	public func actions(for entry: CommandBarFeature.Entry) -> [CommandBarFeature.ResultAction] {
		typealias Action = CommandBarFeature.ResultAction
		var actions: [Action] = [primaryAction(for: entry)]

		// ⌘↩ opens what's typed as an address while it can be one, whatever the result
		// (DEV-1189); the actions list it as Open as is, and ⌘-click on a row does it too
		// (DEV-1319).
		if openURLTakesCommandReturn, let openURL = openURLEntry {
			actions.append(.init(
				id: Self.openURLID,
				title: String.localized(.appUI.command.openAsIs),
				symbol: "globe",
				shortcut: Shortcut.newTab,
				kind: .run(openURL.intent, nil)
			))
		}
		guard let url = entry.pageURL else { return actions }

		let availability = actionAvailability

		// Peek and Little Arx show web pages only: not an `arx://` chat tab (DEV-810, Codex).
		let isWebPage = BrowsingHistoryEntry.accepts(url)
		let openTab = entry.isOpenTab ? nil : openTabEntry(for: url)

		// ⌘T's Return already opens a new tab; elsewhere it replaces the page or switches.
		let opensNewTab = availability.opensNewTabs && (entry.isOpenTab || mode != .newTab)

		if opensNewTab {
			actions.append(.init(
				id: "open-new-tab",
				title: String.localized(entry.isSearch ? .appUI.command.searchInNewTab : .appUI.command.openInNewTab),
				symbol: "plus.square.on.square",
				shortcut: Shortcut.newTab,
				kind: .run(.openInNewTab(url), nil)
			))
		}
		if let openTab, case let .selectTab(id) = openTab.intent {
			actions.append(.init(
				id: "switch-to-tab",
				title: String.localized(.appUI.command.switchToTab),
				symbol: "square.on.square",
				shortcut: Shortcut.switchToTab,
				kind: .run(.selectTab(id), openTab.destination)
			))
		}
		if availability.opensPeek, isWebPage {
			actions.append(.init(
				id: "open-peek",
				title: String.localized(entry.isSearch ? .appUI.command.searchInPeek : .appUI.links.openInPeek),
				symbol: "eye",
				shortcut: Shortcut.peek,
				kind: .run(.openInPeek(url), nil)
			))
		}
		if availability.opensLittleArx, isWebPage {
			actions.append(.init(
				id: "open-little-arx",
				title: String.localized(entry.isSearch ? .appUI.command.searchInLittleArx : .appUI.links.openInLittleArx),
				symbol: "macwindow",
				shortcut: Shortcut.littleArx,
				kind: .run(.openInLittleArx(url), nil)
			))
		}

		// Searches and suggestions have no address worth copying; pages and typed addresses do.
		if entry.isOpenTab || entry.isHistory || entry.presentation.id == "destination" {
			actions.append(.init(
				id: Self.copyURLActionID,
				title: String.localized(.appUI.command.copyURL),
				symbol: "link",
				shortcut: copyURLShortcut,
				kind: .run(.copyURL(url), nil)
			))
		}
		if availability.removesHistory, case let .openHistory(selection) = entry.intent {
			actions.append(.init(
				id: "delete-history",
				title: String.localized(.appUI.command.deleteFromHistory),
				symbol: "trash",
				shortcut: Shortcut.deleteFromHistory,
				isDestructive: true,
				kind: .removeHistory(selection.profileID, .entries([selection.id]))
			))
			if let host = selection.url.host(), !host.isEmpty {
				let site = BrowsingHistoryRemoval.siteKey(host)
				actions.append(.init(
					id: "delete-history-site",
					title: String.localized(.appUI.command.deleteSiteFromHistory(site)),
					symbol: "trash.square",
					shortcut: Shortcut.deleteSiteFromHistory,
					isDestructive: true,
					kind: .removeHistory(selection.profileID, .site(site))
				))
			}
		}

		// The app's own bindings win: an action whose key is taken shows none and answers to none.
		// Copy URL's key belongs to Copy URL alone, even when it's rebound onto an action's key.
		return actions.map { action in
			guard
				let key = action.shortcut,
				key != "↩",
				action.id != Self.copyURLActionID,
				action.id != Self.openURLID,
				reservedShortcuts.contains(key) || key == copyURLShortcut
					|| (key == Shortcut.newTab && openURLTakesCommandReturn)
			else { return action }

			var free = action
			free.shortcut = nil
			return free
		}
	}

	/// The action a key runs from the bar or the panel, if the result in question has one:
	/// the open panel's result, or else the highlighted one.
	public func actionID(forShortcut key: String) -> String? {
		if key == Shortcut.newTab, openURLTakesCommandReturn { return Self.openURLID }
		guard let entry = actionPanelEntry ?? selectedEntry else { return nil }
		return actions(for: entry).first { $0.shortcut == key }?.id
	}

	public static let copyURLActionID: String = "copy-url"

	/// Whether the bar is open on a result with Copy URL, which the app's Copy URL key then runs.
	public var offersCopyURL: Bool {
		isPresented && (actionPanelEntry ?? selectedEntry).map { entry in
			actions(for: entry).contains { $0.id == Self.copyURLActionID }
		} == true
	}

	/// What Return does on the highlighted result: its actions' first.
	public var primaryActionTitle: String? {
		selectedEntry.map { primaryAction(for: $0).title }
	}

	/// What Return does on `entry`, named for the result.
	private func primaryAction(for entry: CommandBarFeature.Entry) -> CommandBarFeature.ResultAction {
		let title: String
		let symbol: String
		switch entry.intent {
		case .selectTab:
			title = String.localized(.appUI.command.switchToTab)
			symbol = "square.on.square"

		case .open where entry.isSearch:
			title = String.localized(.appUI.command.search)
			symbol = "magnifyingglass"

		case .open, .openHistory, .openInNewTab:
			title = String.localized(.appUI.command.open)
			symbol = "arrow.up.right"

		case .selectSpace:
			title = String.localized(.appUI.command.switchToSpace)
			symbol = "square.stack"

		case .revealFolder:
			title = String.localized(.appUI.command.openFolder)
			symbol = "folder"

		case .useShortcut:
			title = entry.presentation.actionTitle
			symbol = "magnifyingglass"

		case .command, .disabledCommand, .newFolder, .toggleSidebar, .undo, .openInPeek, .openInLittleArx, .copyURL:
			title = entry.presentation.title
			symbol = entry.presentation.symbol

		case .copyText:
			title = entry.presentation.actionTitle
			symbol = "doc.on.doc"

		case .openSettings:
			title = entry.presentation.actionTitle
			symbol = "gearshape"
		}
		return .init(
			id: "primary",
			title: title,
			symbol: symbol,
			shortcut: "↩",
			kind: .run(entry.intent, entry.destination)
		)
	}

	/// A listed open tab showing `url`, for Switch to Tab on a history or address result.
	private func openTabEntry(for url: URL) -> CommandBarFeature.Entry? {
		candidates.first { $0.isOpenTab && $0.pageURL == url }
	}
}

extension CommandBarFeature.State {
	/// The keys each action answers to, following Arx's link clicks: ⌘ for a new tab, ⇧ for
	/// Peek, ⌥⌘ for Little Arx. Copy URL uses the app's Copy URL binding.
	public enum Shortcut {
		public static let newTab: String = "⌘↩"
		public static let switchToTab: String = "⌃↩"
		public static let peek: String = "⇧↩"
		public static let littleArx: String = "⌥⌘↩"
		public static let deleteFromHistory: String = "⌃X"
		public static let deleteSiteFromHistory: String = "⌃⇧X"
	}
}

extension CommandBarFeature.Entry {
	internal var isOpenTab: Bool {
		if case .selectTab = intent { return true }
		return false
	}

	/// Whether `removal` takes this result out of the profile's history.
	internal func isRemoved(
		by removal: BrowsingHistoryRemoval,
		profileID: Profile.ID
	) -> Bool {
		guard case let .openHistory(selection) = intent, selection.profileID == profileID
		else { return false }

		return removal.matches(.init(
			id: selection.id,
			url: selection.url,
			title: "",
			lastVisited: .distantPast
		))
	}
}
