import Foundation

/// The order of a tab's context menu (DEV-1250): the link, then the tab's own
/// identity and behaviour, then where it sits, then what changes its state, last. A regular tab,
/// a pinned tab, a Favorite and a selection of several tabs share the order, each leaving out
/// what doesn't apply. The rows and the Favorites tiles build their menus from it.
public enum SidebarTabMenu {
	/// Which tab the menu is for.
	public enum Kind: Equatable, Sendable {
		case tab
		case pinned
		case favorite

		/// Several tabs selected together (DEV-883), counted by what they are.
		case selection(Selection)
	}

	public struct Selection: Equatable, Sendable {
		public var openTabCount: Int
		public var savedTabCount: Int

		public init(
			openTabCount: Int,
			savedTabCount: Int
		) {
			self.openTabCount = openTabCount
			self.savedTabCount = savedTabCount
		}
	}

	/// The menu's four groups, in order, a divider between each.
	public enum ItemGroup: CaseIterable, Equatable, Sendable {
		case link
		case identity
		case arrangement
		case state
	}

	public enum Item: Equatable, Hashable, Sendable {
		// Link
		case copy
		case peek

		// Identity and behaviour
		case changeIcon
		case rename
		case updateSavedURL
		case mute
		case volume
		case pictureInPicture
		case badges
		case keepSiteLoaded
		case keepAgentTab

		// Arrangement
		case addSplit
		case duplicate
		case addToNewGroup
		case moveTo

		/// Open in New Window, then Move to Window ▸, or Move N Tabs to Window ▸ for a selection.
		case moveToWindow

		// State
		case close
		case closeOthers
		case closeBelow
		case pin
		case unpin
		case archive
		case removeFavorite
	}

	/// What the tab has that some items need: a tab without sound has no Mute.
	public struct Traits: Equatable, Sendable {
		public var hasAudio: Bool
		public var hasVolume: Bool
		public var canKeepSiteLoaded: Bool
		public var isAgentTab: Bool

		public init(
			hasAudio: Bool = false,
			hasVolume: Bool = false,
			canKeepSiteLoaded: Bool = false,
			isAgentTab: Bool = false
		) {
			self.hasAudio = hasAudio
			self.hasVolume = hasVolume
			self.canKeepSiteLoaded = canKeepSiteLoaded
			self.isAgentTab = isAgentTab
		}
	}

	/// The menu's items by group, its empty groups left out.
	public static func groups(
		for kind: Kind,
		traits: Traits = .init()
	) -> [[Item]] {
		ItemGroup.allCases
			.map { items(in: $0, for: kind, traits: traits) }
			.filter { !$0.isEmpty }
	}

	public static func items(
		in group: ItemGroup,
		for kind: Kind,
		traits: Traits = .init()
	) -> [Item] {
		switch (group, kind) {
		case (.link, .selection):
			return [.copy]

		case (.link, _):
			return [.copy, .peek]

		// Nothing names or tunes several tabs at once.
		case (.identity, .selection):
			return []

		case (.identity, _):
			var items: [Item] = [.changeIcon, .rename]
			if kind != .tab { items.append(.updateSavedURL) }

			// A Favorite's tile has no speaker, so its menu has no Mute either.
			if kind != .favorite, traits.hasAudio {
				items.append(.mute)
				if traits.hasVolume { items.append(.volume) }
			}
			items += [.pictureInPicture, .badges]
			if traits.canKeepSiteLoaded { items.append(.keepSiteLoaded) }
			if kind == .tab, traits.isAgentTab { items.append(.keepAgentTab) }
			return items

		case (.arrangement, .tab):
			return [.addSplit, .duplicate, .addToNewGroup, .moveTo, .moveToWindow]

		case (.arrangement, .pinned):
			return [.addSplit, .duplicate, .moveTo, .moveToWindow]

		case (.arrangement, .favorite):
			return [.moveTo]

		case let (.arrangement, .selection(selection)):
			var items: [Item] = [.duplicate]
			if selection.openTabCount > 0 { items.append(.addToNewGroup) }
			return items + [.moveTo, .moveToWindow]

		case (.state, .tab):
			return [.close, .closeOthers, .closeBelow]

		case (.state, .pinned):
			return [.close, .closeOthers, .unpin]

		case (.state, .favorite):
			return [.close, .unpin, .removeFavorite]

		case let (.state, .selection(selection)):
			var items: [Item] = []
			if selection.openTabCount > 0 { items.append(.pin) }
			if selection.savedTabCount > 0 { items.append(.unpin) }
			if selection.openTabCount > 0 { items.append(.archive) }
			return items + [.close, .closeOthers]
		}
	}
}

extension SidebarTabMenu.Traits {
	/// The traits of `item`'s tab.
	public init(_ item: SidebarItem) {
		self.init(
			hasAudio: item.audio != nil,
			hasVolume: item.audio?.volume != nil,
			canKeepSiteLoaded: item.keepLoaded != nil,
			isAgentTab: item.agent?.openedBy != nil
		)
	}
}
