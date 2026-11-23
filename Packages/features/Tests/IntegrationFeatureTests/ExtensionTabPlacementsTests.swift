import BrowserCore
import CustomDump
import Foundation
import Testing

@testable import AppFeature

@Suite(.dependencies)
internal struct ExtensionTabPlacementsTests {
	@Test
	internal func windowsHoldTheirVisibleSpaceInSidebarOrder() {
		let placements = ExtensionTabPlacements.plan(
			[
				.init(number: 7, spaceID: id(10), shown: [id(2), id(3)], active: id(3)),
				.init(number: 8, spaceID: id(20), shown: [id(5)], active: id(5)),
			],
			organization: organization()
		)

		expectNoDifference(placements[id(1)], .init(windowNumber: 7, index: 0, isActive: false, isHighlighted: false))
		expectNoDifference(placements[id(2)], .init(windowNumber: 7, index: 1, isActive: false, isHighlighted: true))
		expectNoDifference(placements[id(3)], .init(windowNumber: 7, index: 2, isActive: true, isHighlighted: true))
		expectNoDifference(placements[id(4)], .init(windowNumber: 7, index: 3, isActive: false, isHighlighted: false))

		// The second window shows another space of the same profile; the shared
		// favorite stays in the first window.
		expectNoDifference(placements[id(5)], .init(windowNumber: 8, index: 0, isActive: true, isHighlighted: true))
		expectNoDifference(placements.count, 5)
	}

	@Test
	internal func aShownTabBelongsToItsWindowAndPrivateWindowsHoldNothing() {
		let placements = ExtensionTabPlacements.plan(
			[
				.init(number: 7, spaceID: id(10), shown: [id(2)], active: id(2)),
				// A later window showing the shared favorite takes it.
				.init(number: 8, spaceID: id(20), shown: [id(1)], active: id(1)),
				.init(number: 9, spaceID: id(30), isPrivate: true, shown: [id(6)], active: id(6)),
				// A Little Arx window holds only its own tab.
				.init(number: 10, spaceID: nil, shown: [id(7)], active: id(7)),
				// Not on screen yet.
				.init(number: 0, spaceID: id(30), shown: [id(6)], active: id(6)),
			],
			organization: organization()
		)

		expectNoDifference(placements[id(2)]?.index, 0)
		expectNoDifference(placements[id(3)]?.index, 1)
		expectNoDifference(placements[id(1)], .init(windowNumber: 8, index: 0, isActive: true, isHighlighted: true))
		expectNoDifference(placements[id(5)], .init(windowNumber: 8, index: 1, isActive: false, isHighlighted: false))
		expectNoDifference(placements[id(6)], nil)
		expectNoDifference(placements[id(7)], .init(windowNumber: 10, index: 0, isActive: true, isHighlighted: true))
	}

	@Test
	internal func independentWindowsHoldOnlyTheOpenTabsTheyKeep() {
		// Both windows show the same space; the second keeps a background tab (DEV-822).
		let placements = ExtensionTabPlacements.plan(
			[
				.init(number: 7, spaceID: id(10), openTabFilter: .excluding([id(4)]), shown: [id(3)], active: id(3)),
				.init(number: 8, spaceID: id(10), openTabFilter: .only([id(4)]), shown: [id(2)], active: id(2)),
			],
			organization: organization()
		)

		expectNoDifference(placements[id(1)], .init(windowNumber: 7, index: 0, isActive: false, isHighlighted: false))
		expectNoDifference(placements[id(3)], .init(windowNumber: 7, index: 1, isActive: true, isHighlighted: true))

		// The pinned tab the second window shows is its own; its background tab stays out of the first.
		expectNoDifference(placements[id(2)], .init(windowNumber: 8, index: 0, isActive: true, isHighlighted: true))
		expectNoDifference(placements[id(4)], .init(windowNumber: 8, index: 1, isActive: false, isHighlighted: false))
		expectNoDifference(placements.count, 4)
	}

	@Test
	internal func anOpenTabKeptByAWindowOnAnotherSpaceIsInNoWindow() {
		let placements = ExtensionTabPlacements.plan(
			[
				.init(number: 7, spaceID: id(10), openTabFilter: .excluding([id(4)]), shown: [id(3)], active: id(3)),
				.init(number: 8, spaceID: id(20), openTabFilter: .only([id(4), id(5)]), shown: [id(5)], active: id(5)),
			],
			organization: organization()
		)

		expectNoDifference(placements[id(4)], nil)
		expectNoDifference(placements[id(5)], .init(windowNumber: 8, index: 0, isActive: true, isHighlighted: true))
	}

	@Test
	internal func aTabSwitchSendsOnlyTheTwoTabsItChanges() {
		let before = ExtensionTabPlacements.plan(
			[.init(number: 7, spaceID: id(10), shown: [id(2)], active: id(2))],
			organization: organization()
		)
		let after = ExtensionTabPlacements.plan(
			[.init(number: 7, spaceID: id(10), shown: [id(3)], active: id(3))],
			organization: organization()
		)

		let changes = ExtensionTabPlacements.changes(from: before, to: after)
		expectNoDifference(changes.count, 2)
		expectNoDifference(changes[id(2)] ?? nil, .init(windowNumber: 7, index: 1, isActive: false, isHighlighted: false))
		expectNoDifference(changes[id(3)] ?? nil, .init(windowNumber: 7, index: 2, isActive: true, isHighlighted: true))
		expectNoDifference(ExtensionTabPlacements.changes(from: after, to: after), [:])
	}

	@Test
	internal func aTabThatLeavesEveryWindowIsSentAsRemoved() {
		let placements = ExtensionTabPlacements.plan(
			[.init(number: 7, spaceID: id(10), shown: [id(2)], active: id(2))],
			organization: organization()
		)
		var remaining = placements
		remaining[id(4)] = nil

		let changes = ExtensionTabPlacements.changes(from: placements, to: remaining)
		expectNoDifference(changes.count, 1)
		#expect(changes[id(4)] == .some(nil))
	}

	private func organization() -> BrowserOrganization {
		let url = URL(string: "https://capturecontext.dev")!
		return .init(
			profiles: [
				.init(id: id(1), name: "Personal", favorites: [id(1)]),
				.init(id: id(2), name: "Work"),
			],
			spaces: [
				.init(id: id(10), profileID: id(1), name: "Research", savedItems: [.tab(id(2))], unpinnedTabs: [id(3), id(4)]),
				.init(id: id(20), profileID: id(1), name: "Reading", unpinnedTabs: [id(5)]),
				.init(id: id(30), profileID: id(2), name: "Work", unpinnedTabs: [id(6)]),
			],
			tabs: (1 ... 6).map { index in
				.init(
					id: id(UInt8(index)),
					profileID: index == 6 ? id(2) : id(1),
					restoration: .init(title: "Example", url: url)
				)
			}
		)
	}

	private func id<Entity>(_ value: UInt8) -> BrowserID<Entity> {
		.init(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value)))
	}
}
