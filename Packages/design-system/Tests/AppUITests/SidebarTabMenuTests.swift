@testable import AppUI
import CustomDump
import Foundation
import Testing

/// The tab menus' order (DEV-1250): the link, the tab's identity and behaviour, where it sits,
/// then what changes its state, for a regular tab, a pinned tab, a Favorite and a selection.
internal struct SidebarTabMenuTests {
	private static let everything: SidebarTabMenu.Traits = .init(
		hasAudio: true,
		hasVolume: true,
		canKeepSiteLoaded: true,
		isAgentTab: true
	)

	@Test
	internal func aRegularTabsMenu() {
		expectNoDifference(
			SidebarTabMenu.groups(for: .tab, traits: Self.everything),
			[
				[.copy, .peek],
				[.changeIcon, .rename, .mute, .volume, .pictureInPicture, .badges, .keepSiteLoaded, .keepAgentTab],
				[.addSplit, .duplicate, .addToNewGroup, .moveTo, .moveToWindow],
				[.close, .closeOthers, .closeBelow],
			]
		)
	}

	@Test
	internal func aPinnedTabsMenuEndsWithUnpin() {
		expectNoDifference(
			SidebarTabMenu.groups(for: .pinned, traits: Self.everything),
			[
				[.copy, .peek],
				[.changeIcon, .rename, .updateSavedURL, .mute, .volume, .pictureInPicture, .badges, .keepSiteLoaded],
				[.addSplit, .duplicate, .moveTo, .moveToWindow],
				[.close, .closeOthers, .unpin],
			]
		)
	}

	@Test
	internal func aFavoritesMenuEndsWithRemoveFavorite() {
		expectNoDifference(
			SidebarTabMenu.groups(for: .favorite, traits: Self.everything),
			[
				[.copy, .peek],
				[.changeIcon, .rename, .updateSavedURL, .pictureInPicture, .badges, .keepSiteLoaded],
				[.moveTo],
				[.close, .unpin, .removeFavorite],
			]
		)
	}

	@Test
	internal func aSelectionsMenuHasNoIdentityGroup() {
		expectNoDifference(
			SidebarTabMenu.groups(for: .selection(.init(openTabCount: 2, savedTabCount: 1))),
			[
				[.copy],
				[.duplicate, .addToNewGroup, .moveTo, .moveToWindow],
				[.pin, .unpin, .archive, .close, .closeOthers],
			]
		)
	}

	@Test
	internal func aSelectionOfPinnedTabsOnlyUnpins() {
		expectNoDifference(
			SidebarTabMenu.groups(for: .selection(.init(openTabCount: 0, savedTabCount: 3))),
			[
				[.copy],
				[.duplicate, .moveTo, .moveToWindow],
				[.unpin, .close, .closeOthers],
			]
		)
	}

	@Test
	internal func aSilentTabLeavesOutItsSoundAndSiteItems() {
		expectNoDifference(
			SidebarTabMenu.items(in: .identity, for: .tab),
			[.changeIcon, .rename, .pictureInPicture, .badges]
		)

		// Volume only where the engine can turn the tab down.
		expectNoDifference(
			SidebarTabMenu.items(in: .identity, for: .tab, traits: .init(hasAudio: true)),
			[.changeIcon, .rename, .mute, .pictureInPicture, .badges]
		)
	}

	/// Every menu keeps the groups' order, and each item belongs to one group in all of them.
	@Test
	internal func everyItemKeepsItsGroupAcrossTheMenus() {
		let kinds: [SidebarTabMenu.Kind] = [
			.tab,
			.pinned,
			.favorite,
			.selection(.init(openTabCount: 1, savedTabCount: 1)),
		]
		var groupOfItem: [SidebarTabMenu.Item: SidebarTabMenu.ItemGroup] = [:]
		for kind in kinds {
			for group in SidebarTabMenu.ItemGroup.allCases {
				for item in SidebarTabMenu.items(in: group, for: kind, traits: Self.everything) {
					let previous = groupOfItem.updateValue(group, forKey: item)
					#expect(previous == nil || previous == group, "\(item) in \(group) for \(kind)")
				}
			}
		}
	}
}
