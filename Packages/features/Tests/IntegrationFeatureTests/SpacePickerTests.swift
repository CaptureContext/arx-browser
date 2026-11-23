import AppFeature
import AppKit
import AppUI
import BrowserCore
import CustomDump
import Foundation
import SwiftUI
import Testing
import _ComposableArchitecture

/// DEV-725: the sidebar footer's space picker.
@Suite(.renderTurn, .dependencies)
@MainActor
internal struct SpacePickerTests {
	private let order = (0..<5).map { UUID($0) }

	// Icons are 26 wide and dots 10; gaps run from 3 to 12 with the room. Each space's cell is
	// its icon or dot with half a gap on either side, so five spaces have five gaps' worth.

	@Test
	internal func spacesThatFitShowAsIconsWithRoomyGaps() {
		let layout = SidebarSpacePickerLayout(count: 5, selectedIndex: 2, available: 200)

		#expect(!layout.isDotted)
		#expect(layout.collapsed.isEmpty)
		expectNoDifference(layout.iconIndex, nil)
		expectNoDifference(layout.spacing, 12)
		expectNoDifference(layout.contentWidth, 5 * 26 + 5 * 12)
		#expect(!layout.scrolls)
	}

	@Test
	internal func cellsMeetSoTheRowHasNoDeadSpace() {
		for (count, available, hovered) in [(5, 200.0, nil), (10, 200.0, 7), (40, 200.0, nil), (10, 150.0, 2)] as [(Int, CGFloat, Int?)] {
			let layout = SidebarSpacePickerLayout(count: count, selectedIndex: 0, available: available, hoveredIndex: hovered)

			expectNoDifference(layout.frames.first?.lowerBound, 0)
			expectNoDifference(layout.frames.last?.upperBound, layout.contentWidth)
			for (left, right) in zip(layout.frames, layout.frames.dropFirst()) {
				expectNoDifference(left.upperBound, right.lowerBound)
			}
		}
	}

	@Test
	internal func gapsFollowTheWidthContinuously() {
		let wide = SidebarSpacePickerLayout(count: 5, selectedIndex: 0, available: 160)
		let narrower = SidebarSpacePickerLayout(count: 5, selectedIndex: 0, available: 150)

		expectNoDifference(wide.spacing, 6)
		expectNoDifference(narrower.spacing, 4)
		#expect(!wide.isDotted && !narrower.isDotted)
	}

	@Test
	internal func onceTheIconsDontFitEveryInactiveSpaceIsADot() {
		// All icons need 5 * 26 + 5 * 3 = 145.
		#expect(!SidebarSpacePickerLayout(count: 5, selectedIndex: 2, available: 145).isDotted)
		let dotted = SidebarSpacePickerLayout(count: 5, selectedIndex: 2, available: 144)

		#expect(dotted.isDotted)
		expectNoDifference(dotted.collapsed, [0, 1, 3, 4])
		expectNoDifference(dotted.iconIndex, 2)
	}

	@Test
	internal func atEveryWidthTheRowIsAllIconsOrOneIconAmongDots() {
		for available in stride(from: CGFloat(400), through: 40, by: -1) {
			let layout = SidebarSpacePickerLayout(count: 10, selectedIndex: 4, available: available)
			if layout.isDotted {
				expectNoDifference(layout.collapsed, Set(0..<10).subtracting([4]))
			} else {
				#expect(layout.collapsed.isEmpty)
			}
		}
	}

	@Test
	internal func theHoveredSpaceShowsTheOnlyIcon() {
		let resting = SidebarSpacePickerLayout(count: 10, selectedIndex: 4, available: 200)
		let hovered = SidebarSpacePickerLayout(count: 10, selectedIndex: 4, available: 200, hoveredIndex: 7)
		let hoveringSelected = SidebarSpacePickerLayout(count: 10, selectedIndex: 4, available: 200, hoveredIndex: 4)

		expectNoDifference(resting.iconIndex, 4)

		// The selected space collapses while another is hovered.
		expectNoDifference(hovered.iconIndex, 7)
		expectNoDifference(hovered.collapsed, Set(0..<10).subtracting([7]))
		expectNoDifference(hoveringSelected, resting)

		// Trading the one icon leaves the row as wide as it was.
		expectNoDifference(hovered.contentWidth, resting.contentWidth)
		expectNoDifference(hovered.spacing, resting.spacing)
	}

	@Test
	internal func hoveringChangesNothingWhileEveryIconFits() {
		let resting = SidebarSpacePickerLayout(count: 5, selectedIndex: 0, available: 200)
		let hovered = SidebarSpacePickerLayout(count: 5, selectedIndex: 0, available: 200, hoveredIndex: 3)

		expectNoDifference(hovered, resting)
	}

	@Test
	internal func withTheLibraryOpenEverySpaceIsADotUntilOneIsHovered() {
		let resting = SidebarSpacePickerLayout(count: 10, selectedIndex: nil, available: 150)
		let hovered = SidebarSpacePickerLayout(count: 10, selectedIndex: nil, available: 150, hoveredIndex: 2)

		expectNoDifference(resting.collapsed.count, 10)
		expectNoDifference(resting.iconIndex, nil)
		expectNoDifference(hovered.iconIndex, 2)
		#expect(hovered.contentWidth <= 150 + 0.001)
		#expect(!hovered.scrolls)
	}

	/// Where an item's middle sits in the picker: the row is centered while it fits.
	private func center(
		_ index: Int,
		in layout: SidebarSpacePickerLayout,
		available: CGFloat
	) -> CGFloat {
		let leading = layout.scrolls ? 0 : (available - layout.contentWidth) / 2
		return leading + (layout.frames[index].lowerBound + layout.frames[index].upperBound) / 2
	}

	@Test
	internal func aHoveredDotStaysUnderThePointer() {
		for count in [5, 9, 14, 40] {
			for available in stride(from: CGFloat(120), through: 320, by: 10) {
				for selected in [0, count / 2, nil] {
					let resting = SidebarSpacePickerLayout(count: count, selectedIndex: selected, available: available)
					for index in resting.collapsed {
						let pointer = center(index, in: resting, available: available)
						let hovered = SidebarSpacePickerLayout(
							count: count,
							selectedIndex: selected,
							available: available,
							hoveredIndex: index
						)
						let leading = hovered.scrolls ? 0 : (available - hovered.contentWidth) / 2
						let frame = hovered.frames[index]
						#expect(
							(leading + frame.lowerBound) ... (leading + frame.upperBound) ~= pointer,
							"\(count) spaces in \(available), selected \(String(describing: selected)), hovering \(index)"
						)
						expectNoDifference(hovered.scrolls, resting.scrolls)
					}
				}
			}
		}
	}

	/// Hover goes to the cell under the pointer, and the layout that hover produces must keep the
	/// pointer in that same cell, or the icon would flicker between two spaces.
	@Test
	internal func hoverPassesStraightFromOneSpaceToTheNextWithoutFlickering() {
		func leading(_ layout: SidebarSpacePickerLayout, _ available: CGFloat) -> CGFloat {
			layout.scrolls ? 0 : (available - layout.contentWidth) / 2
		}
		for count in [5, 9, 14, 40] {
			for available in stride(from: CGFloat(120), through: 320, by: 20) {
				for selected in [0, count / 2, nil] {
					// From resting, and from each space already hovered.
					for start in [nil] + stride(from: 0, to: count, by: 3).map(Optional.some) {
						let before = SidebarSpacePickerLayout(
							count: count, selectedIndex: selected, available: available, hoveredIndex: start
						)
						let origin = leading(before, available)
						for x in stride(from: origin, to: origin + before.contentWidth, by: 1) {
							let hovered = before.hoveredSlot(at: x - origin, current: start)
							let after = SidebarSpacePickerLayout(
								count: count, selectedIndex: selected, available: available, hoveredIndex: hovered
							)
							let stays = after.hoveredSlot(at: x - leading(after, available), current: hovered) == hovered
							#expect(stays, "\(count) spaces in \(available), selected \(String(describing: selected)), from \(String(describing: start)), x \(x)")
							if !stays { return }
						}
					}
				}
			}
		}
	}

	/// Among dots, a hover only swaps a dot for its icon in place: every cell keeps its frame, so
	/// the icon's center is exactly where its dot was and the row never moves.
	@Test
	internal func aHoverNeverMovesTheRow() {
		for count in [5, 10, 40] {
			for available in stride(from: CGFloat(100), through: 300, by: 25) {
				for selected in [0, count / 2, nil] {
					let resting = SidebarSpacePickerLayout(count: count, selectedIndex: selected, available: available)
					guard resting.isDotted else { continue }
					for hovered in 0..<count {
						let layout = SidebarSpacePickerLayout(
							count: count, selectedIndex: selected, available: available, hoveredIndex: hovered
						)
						expectNoDifference(layout.frames, resting.frames)
						expectNoDifference(layout.contentWidth, resting.contentWidth)
						expectNoDifference(layout.iconIndex, hovered)
					}
				}
			}
		}
	}

	@Test
	internal func dotsBesideTheIconMoveOutALittleAndTheIconStaysPut() {
		// 40 spaces in 200 points: tight 13-point cells.
		let layout = SidebarSpacePickerLayout(count: 40, selectedIndex: 10, available: 200, hoveredIndex: 20)

		expectNoDifference(layout.nudge(20), 0)
		expectNoDifference(layout.nudge(19), -6)
		expectNoDifference(layout.nudge(21), 6)
		expectNoDifference(layout.nudge(18), -3)
		expectNoDifference(layout.nudge(22), 3)
		expectNoDifference(layout.nudge(17), 0)

		// The selected space is just a dot while another is hovered.
		expectNoDifference(layout.nudge(10), 0)

		// Roomy dots need no nudge, and icons never move.
		expectNoDifference(SidebarSpacePickerLayout(count: 10, selectedIndex: 4, available: 280).nudge(5), 0)
		expectNoDifference(SidebarSpacePickerLayout(count: 5, selectedIndex: 2, available: 300).nudge(3), 0)
	}

	/// What draws past a cell, at the tightest dots: half the widest icon beyond half the cell,
	/// or a dot nudged toward the row's end. The picker keeps that much room at both ends.
	@Test
	internal func theRowsEndsLeaveRoomForWhatDrawsPastACell() {
		typealias Metrics = BrowserMetrics.SpaceSwitcher
		let cell = Metrics.dotWidth + Metrics.minimumSpacing
		let iconOverhang = (Metrics.iconMaximumWidth - cell) / 2
		let nudge = SidebarSpacePickerLayout.iconReach - cell
		let dotOverhang = nudge + Metrics.dotSize / 2 - cell / 2

		#expect(Metrics.edgeInset >= iconOverhang)
		#expect(Metrics.edgeInset >= dotOverhang)
		// The nudge rule really is that large in a tight scrolling row.
		let layout = SidebarSpacePickerLayout(count: 40, selectedIndex: 1, available: 200)
		expectNoDifference(abs(layout.nudge(0)), nudge)
	}

	@Test
	internal func theHintSitsAboveTheFooterOverItsSpace() {
		let origin = SidebarSpaceHintPlacement.origin(
			hint: .init(width: 200, height: 34),
			item: .init(x: 290, y: 710, width: 13, height: 26),
			row: .init(x: 40, y: 705, width: 300, height: 36),
			container: .init(width: 1200, height: 800)
		)

		// Centered on the space, and 8 points clear of the footer's top edge.
		expectNoDifference(origin, .init(x: 296.5 - 100, y: 705 - 8 - 34))
	}

	@Test
	internal func theHintShiftsSidewaysToStayInsideTheWindow() {
		let hint = CGSize(width: 260, height: 34)
		let row = CGRect(x: 0, y: 705, width: 300, height: 36)
		let leftEdge = SidebarSpaceHintPlacement.origin(
			hint: hint, item: .init(x: 10, y: 710, width: 13, height: 26), row: row, container: .init(width: 1200, height: 800)
		)
		let rightEdge = SidebarSpaceHintPlacement.origin(
			hint: hint, item: .init(x: 390, y: 710, width: 13, height: 26), row: row, container: .init(width: 400, height: 800)
		)
		let tooWide = SidebarSpaceHintPlacement.origin(
			hint: .init(width: 500, height: 34), item: .init(x: 100, y: 710, width: 13, height: 26), row: row,
			container: .init(width: 400, height: 800)
		)

		expectNoDifference(leftEdge.x, 8)
		expectNoDifference(rightEdge.x, 400 - 8 - 260)

		// Wider than the window: it starts at the margin rather than off the leading edge.
		expectNoDifference(tooWide.x, 8)

		// Never above the window's top.
		expectNoDifference(
			SidebarSpaceHintPlacement.origin(hint: hint, item: .init(x: 100, y: 10, width: 13, height: 26), row: .init(x: 0, y: 5, width: 300, height: 36), container: .init(width: 1200, height: 800)).y,
			8
		)
	}

	@Test
	internal func dotsThatStillOverflowScroll() {
		let layout = SidebarSpacePickerLayout(count: 40, selectedIndex: 0, available: 200)

		expectNoDifference(layout.collapsed.count, 39)
		expectNoDifference(layout.spacing, 3)
		#expect(layout.scrolls)
	}

	@Test
	internal func theSlotIsTheSpaceUnderThePointer() {
		// Cells are 38 points wide: a 26-point icon with 6 points on either side.
		let layout = SidebarSpacePickerLayout(count: 5, selectedIndex: 0, available: 200)

		expectNoDifference(layout.slot(at: -20), 0)
		expectNoDifference(layout.slot(at: 12), 0)
		expectNoDifference(layout.slot(at: 37), 0)
		expectNoDifference(layout.slot(at: 39), 1)
		expectNoDifference(layout.slot(at: 38 * 2 + 20), 2)
		expectNoDifference(layout.slot(at: 1_000), 4)
		expectNoDifference(SidebarSpacePickerLayout(count: 0, selectedIndex: nil, available: 200).slot(at: 50), 0)
	}

	@Test
	internal func aSmallDragOverItsOwnIconChangesNothing() throws {
		let layout = SidebarSpacePickerLayout(count: 5, selectedIndex: 0, available: 200)
		for x in stride(from: CGFloat(0), through: 31, by: 1) {
			var reorder = try #require(SidebarSpaceReorder(id: order[0], in: order))
			reorder.track(slot: layout.slot(at: x), count: 5)
			expectNoDifference(reorder.destination(in: order), nil)
		}

		// Back over its own place after moving away, the drop leaves the row alone too.
		var reorder = try #require(SidebarSpaceReorder(id: order[2], in: order))
		reorder.track(slot: layout.slot(at: 150), count: 5)
		reorder.track(slot: layout.slot(at: 38 * 2 + 20), count: 5)
		expectNoDifference(reorder.destination(in: order), nil)
	}

	@Test
	internal func draggingInThePickerNamesTheSameDestinationAsTheLibrary() throws {
		let layout = SidebarSpacePickerLayout(count: 5, selectedIndex: 0, available: 200)
		var reorder = try #require(SidebarSpaceReorder(id: order[0], in: order))

		let moved = reorder.track(slot: layout.slot(at: 38 * 3 + 5), count: 5)
		#expect(moved)
		expectNoDifference(reorder.order(order), [order[1], order[2], order[3], order[0], order[4]])
		expectNoDifference(reorder.destination(in: order), .some(order[4]))
		let movedAgain = reorder.track(slot: 3, count: 5)
		#expect(!movedAgain)
		// Clamped to the row.
		let clamped = reorder.track(slot: 99, count: 5)
		#expect(clamped)
		expectNoDifference(reorder.destination(in: order), .some(nil))
	}

	/// The picker sends the Library's move, so both show and save the same order.
	@Test
	internal func aSpaceDroppedInThePickerMovesItInTheLibraryToo() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		let ids = organization.spaces.map(\.id.rawValue)
		var reorder = try #require(SidebarSpaceReorder(id: ids[0], in: ids))
		reorder.track(slot: ids.count - 1, count: ids.count)
		let destination = try #require(reorder.destination(in: ids))

		await store.send(.main(.ui(.changeOrganization(.moveSpace(
			organization.spaces[0].id,
			before: destination.map { .init(rawValue: $0) }
		)))))
		await store.receive(\.delegate.save)
		await store.finish()
		expectNoDifference(store.state.workspace.spaces.map(\.id.rawValue), reorder.order(ids))
		expectNoDifference(store.state.main.sidebar.organization.spaces.map(\.id.rawValue), reorder.order(ids))

		// The selected space stays selected.
		expectNoDifference(store.state.main.sidebar.spaceID, organization.spaces[0].id)
	}
}

/// Writes offscreen PNGs of the footer picker for visual self-review, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct SpacePickerSnapshotTests {
	@Test(arguments: [(3, 300), (9, 380), (9, 340), (9, 300), (9, 260), (9, 220), (40, 300)])
	internal func footer(count: Int, width: CGFloat) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let symbols = ["bookmark.fill", "person.2.fill", "chevron.left.forwardslash.chevron.right", "airplane", "basket.fill", "paintpalette.fill", "cloud", "circle.fill", "star"]
		let spaces = (0..<count).map { SidebarSpacePickerEntry(id: UUID($0), name: "Space \($0)") }
		let selected = spaces[min(3, count - 1)].id
		let size = CGSize(width: width, height: 90)
		let host = NSHostingView(
			rootView: HStack(spacing: BrowserMetrics.SpaceSwitcher.spacing) {
				Image(systemName: "archivebox")
				SidebarSpacePicker(spaces: spaces, selectedID: selected, canReorder: true, onMove: { _, _ in }) { space, state in
					SidebarSpaceButton(
						name: space.name,
						symbol: symbols[Int(space.id.uuidString.suffix(2), radix: 16)! % symbols.count],
						isSelected: space.id == selected,
						isCollapsed: state.isCollapsed,
						width: state.width,
						nudge: state.nudge,
						onSelect: {},
						onDropTabs: { _ in }
					)
				}
				Image(systemName: "plus")
			}
			.font(.system(size: 14, weight: .medium))
			.foregroundStyle(BrowserTheme.secondary)
			.padding(.horizontal, 12)
			.padding(.top, 44)
			.frame(width: size.width, height: size.height, alignment: .bottom)
			.background(BrowserChromeBackground(textured: true))
		)
		host.appearance = NSAppearance(named: .darkAqua)
		host.frame = CGRect(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "space-picker-\(count)-\(Int(width)).png"))
		window.close()
	}

	@Test(arguments: [false, true])
	internal func hint(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let space = SidebarSpacePickerEntry(
			id: UUID(1),
			name: "Relax",
			symbol: "cup.and.saucer.fill",
			profileName: "maximkrouk",
			shortcut: ["⌃", "4"]
		)
		let size = CGSize(width: 300, height: 120)
		let host = NSHostingView(
			rootView: VStack(spacing: 16) {
				SidebarSpaceHint(space: space)
				HStack(spacing: 3) {
					ForEach(0..<5) { index in
						SidebarSpaceButton(
							name: "Space",
							symbol: "airplane",
							isSelected: false,
							// The hovered space shows the row's one icon.
							isCollapsed: index != 2,
							onSelect: {},
							onDropTabs: { _ in }
						)
					}
				}
			}
			.frame(width: size.width, height: size.height)
			.background(BrowserChromeBackground(textured: true))
		)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = CGRect(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "space-hint-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
