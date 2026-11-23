import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct OrganizationMoveTests {
	@Test
	internal func nestedSameProfileMovePreservesIdentitiesAndRestoresAfterRestart() throws {
		let original = fixture()
		let root = original.folders[0].id
		let nested = original.folders[1].id
		let moved = try original.moving(
			[.folder(root), .folder(nested), .tab(original.tabs[0].id)],
			to: .spaceRoot,
			in: original.spaces[1].id,
			newTabID: {
				Issue.record("No replacement needed")
				return .init(rawValue: UUID())
			}
		)
		expectNoDifference(moved.roots, [.folder(root)])
		expectNoDifference(moved.replacements, [])
		expectNoDifference(moved.updated.tabs, original.tabs)
		expectNoDifference(moved.updated.folders.map(\.spaceID), [original.spaces[1].id, original.spaces[1].id])
		expectNoDifference(moved.updated.folders.map(\.children), original.folders.map(\.children))
		expectNoDifference(moved.updated.spaces[0].savedItems, [])
		expectNoDifference(moved.updated.spaces[1].savedItems, [.folder(root)])
		let restored = try JSONDecoder().decode(
			BrowserOrganization.self,
			from: JSONEncoder().encode(moved.updated)
		)
		try restored.validate()
		expectNoDifference(restored, moved.updated)
	}

	@Test
	internal func crossProfileSubtreeCopiesEveryTabAndPreservesSavedURLs() throws {
		let original = fixture()
		let move = try original.moving(
			[.folder(original.folders[0].id), .tab(original.tabs[2].id)],
			to: .spaceRoot,
			in: original.spaces[2].id,
			newTabID: { .init(rawValue: UUID()) }
		)
		expectNoDifference(move.replacements.map(\.source), Array(original.tabs))
		#expect(Set(move.movedTabIDs).isDisjoint(with: original.tabs.map(\.id)))
		expectNoDifference(
			move.replacements.map(\.destination.savedDestination),
			original.tabs.map(\.savedDestination)
		)
		expectNoDifference(move.replacements.map(\.destination.restoration), original.tabs.map(\.restoration))
		expectNoDifference(move.updated.folders.map(\.spaceID), [original.spaces[2].id, original.spaces[2].id])
		expectNoDifference(
			move.updated.folders[0].children,
			[.tab(move.movedTabIDs[0]), .folder(original.folders[1].id)]
		)
		expectNoDifference(move.updated.folders[1].children, [.tab(move.movedTabIDs[1])])
		expectNoDifference(move.updated.spaces[2].unpinnedTabs, [move.movedTabIDs[2]])
		try move.updated.validate()
	}

	@Test
	internal func orderedBlockAfterAnchorDoesNotReverseAndPinsOpenTabs() throws {
		let original = fixture()
		let order: [SavedItem] = [.tab(original.tabs[2].id), .tab(original.tabs[1].id)]
		let move = try original.moving(
			order,
			to: .after(.tab(original.tabs[0].id)),
			in: original.spaces[0].id,
			newTabID: { .init(rawValue: UUID()) }
		)
		expectNoDifference(
			move.updated.folders[0].children,
			[.tab(original.tabs[0].id)] + order + [.folder(original.folders[1].id)]
		)
		expectNoDifference(move.updated.folders[1].children, [])
		#expect(move.updated.tabs[2].savedDestination != nil)
		#expect(move.updated.spaces[0].unpinnedTabs.isEmpty)
	}

	@Test
	internal func invalidCyclesUnpinningAndDuplicateIdentityLeaveSourceIntact() throws {
		let original = fixture()
		#expect(throws: OrganizationMoveError.folderCycle) {
			try original.moving(
				[.folder(original.folders[0].id)],
				to: .folder(original.folders[1].id),
				in: original.spaces[0].id,
				newTabID: { .init(rawValue: UUID()) }
			)
		}
		#expect(throws: OrganizationMoveError.cannotUnpinImplicitly) {
			try original.moving(
				[.tab(original.tabs[0].id)],
				to: .openTabs,
				in: original.spaces[1].id,
				newTabID: { .init(rawValue: UUID()) }
			)
		}
		#expect(throws: OrganizationMoveError.duplicateIdentity) {
			try original.moving(
				[.folder(original.folders[0].id)],
				to: .spaceRoot,
				in: original.spaces[2].id,
				newTabID: { original.tabs[0].id }
			)
		}
		try original.validate()
	}

	@Test
	internal func undoPreservesUnrelatedBrowsingDisclosureAndValidSelection() throws {
		let original = fixture()
		var move = try original.moving(
			[.tab(original.tabs[0].id)],
			to: .spaceRoot,
			in: original.spaces[2].id,
			newTabID: { .init(rawValue: UUID()) }
		)
		let currentURL = URL(string: "https://unrelated.example/new")!
		let untouched = original.tabs[2].id
		let movedURL = URL(string: "https://moved.example/current")!
		move.updated.tabs[move.updated.tabs.index(id: move.replacements[0].destination.id)!].restoration.url = movedURL
		move.updated.tabs[move.updated.tabs.index(id: untouched)!].restoration.url = currentURL
		move.updated.folders[1].isExpanded = true
		move.updated.spaces[0].selectedTabID = untouched
		let reverse = try move.reversed(newTabID: { .init(rawValue: UUID()) })
		expectNoDifference(reverse.updated.tabs[id: untouched]?.restoration.url, currentURL)
		expectNoDifference(reverse.updated.spaces[0].selectedTabID, untouched)
		expectNoDifference(reverse.updated.folders[1].isExpanded, true)
		expectNoDifference(reverse.replacements[0].destination.restoration.url, movedURL)
		expectNoDifference(
			reverse.replacements[0].destination.savedDestination,
			original.tabs[0].savedDestination
		)
		#expect(Set(reverse.updated.tabs.map(\.id)).isDisjoint(with: move.replacements.map(\.destination.id)))
		try reverse.updated.validate()
	}

	@Test
	internal func explicitUnpinningMovesPinnedTabsAmongOpenTabs() throws {
		let original = fixture()
		let inFolder = original.tabs[0].id
		let space = original.spaces[0].id
		let move = try original.moving(
			[.tab(inFolder)],
			to: .openTabs,
			in: space,
			unpinning: true,
			newTabID: { .init(rawValue: UUID()) }
		)
		expectNoDifference(move.updated.spaces[0].unpinnedTabs, [original.tabs[2].id, inFolder])
		#expect(move.updated.tabs[id: inFolder]?.savedDestination == nil)
		#expect(!move.updated.folders[0].children.contains(.tab(inFolder)))

		// Beside a regular tab counts too, and the same unpin keeps the tab's current page.
		let beside = try original.moving(
			[.tab(inFolder)],
			to: .before(.tab(original.tabs[2].id)),
			in: space,
			unpinning: true,
			newTabID: { .init(rawValue: UUID()) }
		)
		expectNoDifference(beside.updated.spaces[0].unpinnedTabs, [inFolder, original.tabs[2].id])
		expectNoDifference(beside.updated.tabs[id: inFolder]?.restoration, original.tabs[0].restoration)

		#expect(throws: OrganizationMoveError.invalidDestination) {
			try original.moving(
				[.folder(original.folders[1].id)],
				to: .openTabs,
				in: space,
				unpinning: true,
				newTabID: { .init(rawValue: UUID()) }
			)
		}
	}

	private func fixture() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: UUID())
		let other = Profile.ID(rawValue: UUID())
		let spaces = (0..<3).map { _ in Space.ID(rawValue: UUID()) }
		let folders = (0..<2).map { _ in Folder.ID(rawValue: UUID()) }
		let tabs: [Tab] = (0..<3).map { index in
			.init(
				id: .init(rawValue: UUID()),
				profileID: profile,
				savedDestination: index < 2
				? .init(title: "Saved \(index)", url: URL(string: "https://capturecontext.dev/saved/\(index)")!)
				: nil,
				restoration: .init(
					title: "Current \(index)",
					url: URL(string: "https://capturecontext.dev/current/\(index)")!
				)
			)
		}
		return .init(
			profiles: [
				.init(id: profile, name: "Default"),
				.init(id: other, name: "Other"),
			],
			spaces: [
				.init(
					id: spaces[0],
					profileID: profile,
					name: "Source",
					savedItems: [.folder(folders[0])],
					unpinnedTabs: [tabs[2].id],
					selectedTabID: tabs[0].id
				),
				.init(id: spaces[1], profileID: profile, name: "Same"),
				.init(id: spaces[2], profileID: other, name: "Different"),
			],
			folders: [
				.init(
					id: folders[0],
					spaceID: spaces[0],
					name: "Root",
					children: [.tab(tabs[0].id), .folder(folders[1])]
				),
				.init(
					id: folders[1],
					spaceID: spaces[0],
					name: "Nested",
					children: [.tab(tabs[1].id)]
				),
			],
			tabs: tabs
		)
	}
}
