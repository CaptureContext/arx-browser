import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// DEV-1187: which changes to the sidebar's rows animate. New, closed and moved rows spring; a
/// switch to another profile, the first fill, a drop landing in Favorites and Reduce Motion change
/// at once; a collapsing space and the flag off keep whatever animation the change brought.
@Suite
internal struct SidebarRowMotionTests {
	private static func tab(_ index: Int) -> SidebarItem.ID {
		.tab(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!)
	}

	private static func folder(_ index: Int) -> SidebarItem.ID {
		.folder(UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", index))!)
	}

	private static let rows: SidebarRowMotion.Rows = .init(ids: [tab(1), tab(2), tab(3)])

	private static func decision(
		to new: SidebarRowMotion.Rows,
		from old: SidebarRowMotion.Rows = rows,
		isEnabled: Bool = true,
		reduceMotion: Bool = false,
		isSettled: Bool = true,
		isLanding: Bool = false
	) -> SidebarRowMotion.Decision {
		SidebarRowMotion.decision(
			from: old,
			to: new,
			isEnabled: isEnabled,
			reduceMotion: reduceMotion,
			isSettled: isSettled,
			isLanding: isLanding
		)
	}

	@Test
	internal func aNewTabAtTheTopSprings() {
		#expect(Self.decision(to: .init(ids: [Self.tab(9), Self.tab(1), Self.tab(2), Self.tab(3)])) == .spring)
	}

	@Test
	internal func aTabOpenedBelowAnotherSprings() {
		// A link's tab or a duplicate, under the tab it came from.
		#expect(Self.decision(to: .init(ids: [Self.tab(1), Self.tab(9), Self.tab(2), Self.tab(3)])) == .spring)
	}

	@Test
	internal func aClosedOrArchivedTabSprings() {
		#expect(Self.decision(to: .init(ids: [Self.tab(1), Self.tab(3)])) == .spring)
	}

	@Test
	internal func aReorderSprings() {
		#expect(Self.decision(to: .init(ids: [Self.tab(2), Self.tab(1), Self.tab(3)])) == .spring)
	}

	@Test
	internal func aMoveBetweenSectionsSprings() {
		// Pinned, then the open tabs: tab 1, the last pinned row, moves to the top of the open
		// tabs, which leaves the order of the rows as it was.
		let old: SidebarRowMotion.Rows = .init(sections: [[Self.folder(1), Self.tab(1)], [Self.tab(2), Self.tab(3)]])
		let new: SidebarRowMotion.Rows = .init(sections: [[Self.folder(1)], [Self.tab(1), Self.tab(2), Self.tab(3)]])
		#expect(Self.decision(to: new, from: old) == .spring)
		// And a tab moved into a folder.
		let filed: SidebarRowMotion.Rows = .init(sections: [[Self.folder(1), Self.tab(1), Self.tab(2)], [Self.tab(3)]])
		#expect(Self.decision(to: filed, from: old) == .spring)
	}

	@Test
	internal func aTabMovingIntoTheFolderAboveItSprings() {
		// Every row keeps its place; only the tab's depth changes.
		let old: SidebarRowMotion.Rows = .init(sections: [[.init(id: Self.folder(1)), .init(id: Self.tab(1), depth: 1), .init(id: Self.tab(2))]])
		let new: SidebarRowMotion.Rows = .init(sections: [[.init(id: Self.folder(1)), .init(id: Self.tab(1), depth: 1), .init(id: Self.tab(2), depth: 1)]])
		#expect(Self.decision(to: new, from: old) == .spring)
	}

	@Test
	internal func aFolderOpeningOrClosingSprings() {
		let closed: SidebarRowMotion.Rows = .init(ids: [Self.folder(1), Self.tab(3)])
		let open: SidebarRowMotion.Rows = .init(ids: [Self.folder(1), Self.tab(1), Self.tab(2), Self.tab(3)])
		#expect(Self.decision(to: open, from: closed) == .spring)
		#expect(Self.decision(to: closed, from: open) == .spring)
	}

	@Test
	internal func aFavoriteAddedOrRemovedSprings() {
		let profile = UUID()
		let old: SidebarRowMotion.Rows = .init(owner: profile, ids: [Self.tab(1), Self.tab(2)])
		#expect(Self.decision(to: .init(owner: profile, ids: [Self.tab(1), Self.tab(2), Self.tab(3)]), from: old) == .spring)
		#expect(Self.decision(to: .init(owner: profile, ids: [Self.tab(2)]), from: old) == .spring)
	}

	@Test
	internal func unchangedRowsKeepTheChangesOwnAnimation() {
		// A title, an icon or the selection changing leaves the rows as they are.
		#expect(Self.decision(to: Self.rows) == .inherit)
	}

	@Test
	internal func theFlagOffKeepsTheChangesOwnAnimation() {
		let new: SidebarRowMotion.Rows = .init(ids: [Self.tab(9), Self.tab(1), Self.tab(2), Self.tab(3)])
		#expect(Self.decision(to: new, isEnabled: false) == .inherit)
		#expect(Self.decision(to: new, isEnabled: false, reduceMotion: true, isSettled: false) == .inherit)
	}

	@Test
	internal func reduceMotionChangesAtOnce() {
		#expect(Self.decision(to: .init(ids: [Self.tab(9), Self.tab(1), Self.tab(2), Self.tab(3)]), reduceMotion: true) == .still)
		#expect(Self.decision(to: .init(ids: [Self.tab(1), Self.tab(3)]), reduceMotion: true) == .still)
	}

	@Test
	internal func theFirstFillChangesAtOnce() {
		let empty: SidebarRowMotion.Rows = .init(ids: [])
		#expect(Self.decision(to: Self.rows, from: empty, isSettled: false) == .still)
		// Once settled, a first tab in an empty space slides in.
		#expect(Self.decision(to: .init(ids: [Self.tab(1)]), from: empty) == .spring)
	}

	@Test
	internal func aProfileSwitchChangesAtOnce() {
		let old: SidebarRowMotion.Rows = .init(owner: UUID(), ids: [Self.tab(1), Self.tab(2)])
		let new: SidebarRowMotion.Rows = .init(owner: UUID(), ids: [Self.tab(3)])
		#expect(Self.decision(to: new, from: old) == .still)
		// Even when both profiles have the same favorites.
		#expect(Self.decision(to: .init(owner: UUID(), sections: old.sections), from: old) == .still)
	}

	@Test
	internal func aDropLandingChangesAtOnce() {
		let profile = UUID()
		let old: SidebarRowMotion.Rows = .init(owner: profile, ids: [Self.tab(1)])
		let new: SidebarRowMotion.Rows = .init(owner: profile, ids: [Self.tab(1), Self.tab(2)])
		#expect(Self.decision(to: new, from: old, isLanding: true) == .still)
	}

	@Test
	internal func aSpaceCollapsingKeepsItsOwnAnimation() {
		let expanded: SidebarRowMotion.Rows = .init(ids: [Self.tab(1), Self.tab(2), Self.tab(3)])
		let collapsed: SidebarRowMotion.Rows = .init(ids: [Self.tab(2)], isExpanded: false)
		#expect(Self.decision(to: collapsed, from: expanded) == .inherit)
		#expect(Self.decision(to: expanded, from: collapsed) == .inherit)
	}

	@Test
	internal func theSpringIsShortAndBarelyOvershoots() {
		#expect(SidebarRowMotion.progress(at: 0) == 0)
		let samples: [CGFloat] = stride(from: 0.0, through: 1.0, by: 1.0 / 120.0).map(SidebarRowMotion.progress)
		#expect(samples.max()! < 1.05, "overshoot \(samples.max()!)")
		#expect(abs(SidebarRowMotion.progress(at: 0.45) - 1) < 0.02)
		// More than half way in a tenth of a second, so a new tab reads at once.
		#expect(SidebarRowMotion.progress(at: 0.1) > 0.5)
	}

	@Test
	internal func theFlagIsOnByDefault() {
		let defaults = UserDefaults(suiteName: "SidebarRowMotionTests-\(UUID())")!
		let flag = FeatureFlag.sidebarRowAnimations
		#expect(flag.name == "ARX_SIDEBAR_ROW_ANIMATIONS")
		#expect(flag.isOn(environment: [:], defaults: defaults))
		#expect(!flag.isOn(environment: [flag.name: "off"], defaults: defaults))
		#expect(flag.needsRelaunch)
		#expect(!flag.isRisky)
	}
}

#if DEBUG
/// The decisions the real sidebar and Favorites take, through their views.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views")
)
internal struct SidebarRowMotionHostedTests {
	@Test
	internal func aTabOpenedAfterTheSidebarSettledSprings() {
		let host = MotionHost(tabs: 3)
		defer { host.close() }
		host.waitToSettle()

		let decisions = host.recording { $0.tabs.insert(.init(id: .tab(UUID()), title: "New", isPinned: false), at: 0) }
		#expect(decisions == [.spring])
	}

	@Test
	internal func closingAndPinningTabsSpring() {
		let host = MotionHost(tabs: 3)
		defer { host.close() }
		host.waitToSettle()

		#expect(host.recording { $0.tabs.removeLast() } == [.spring])
		#expect(host.recording { state in
			var pinned = state.tabs.removeFirst()
			pinned.isPinned = true
			state.saved.append(pinned)
		} == [.spring])
	}

	@Test
	internal func aRenameAnimatesNothing() {
		let host = MotionHost(tabs: 3)
		defer { host.close() }
		host.waitToSettle()

		#expect(host.recording { $0.tabs[1].title = "Renamed" } == [])
	}

	@Test
	internal func theFirstFillChangesAtOnce() {
		let host = MotionHost(tabs: 0)
		defer { host.close() }

		let decisions = host.recording { state in
			state.tabs = (0..<5).map { .init(id: .tab(UUID()), title: "Restored \($0)", isPinned: false) }
		}
		#expect(decisions == [.still])
	}

	@Test
	internal func theFlagOffLeavesChangesAlone() {
		let host = MotionHost(tabs: 3, isEnabled: false)
		defer { host.close() }
		host.waitToSettle()

		#expect(host.recording { $0.tabs.removeFirst() } == [.inherit])
	}

	@Test
	internal func favoritesOfAnotherProfileChangeAtOnce() {
		let host = MotionHost(tabs: 1, favorites: 2)
		defer { host.close() }
		host.waitToSettle()

		#expect(host.recording { $0.favorites.removeLast() } == [.spring])
		#expect(host.recording { state in
			state.profileID = UUID()
			state.favorites = [.init(id: .tab(UUID()), title: "Other", isPinned: true)]
		} == [.still])
	}
}

/// A sidebar and a Favorites grid in an offscreen window, fed from `State`.
@MainActor
private final class MotionHost {
	struct State {
		var saved: [SidebarItem] = []
		var tabs: [SidebarItem]
		var favorites: [SidebarItem]
		var profileID: UUID = .init()
	}

	private var state: State
	private let isEnabled: Bool
	private let window: NSWindow
	private let host: NSHostingView<AnyView>

	init(
		tabs: Int,
		favorites: Int = 0,
		isEnabled: Bool = true
	) {
		self.state = .init(
			tabs: (0..<tabs).map { .init(id: .tab(UUID()), title: "Tab \($0)", isPinned: false) },
			favorites: (0..<favorites).map { .init(id: .tab(UUID()), title: "Favorite \($0)", isPinned: true) }
		)
		self.isEnabled = isEnabled
		let size = CGSize(width: 260, height: 800)
		self.host = NSHostingView(rootView: AnyView(EmptyView()))
		host.frame = CGRect(origin: .zero, size: size)
		self.window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		render()
		spin(0.06)
	}

	/// Waits out `SidebarRowMotion.settleDelay`, as a window does once it has opened.
	func waitToSettle() {
		spin(0.6)
	}

	func recording(_ change: (inout State) -> Void) -> [SidebarRowMotion.Decision] {
		SidebarRowMotion.startRecording()
		defer { SidebarRowMotion.stopRecording() }
		change(&state)
		render()
		spin(0.06)
		return SidebarRowMotion.recorded ?? []
	}

	func close() {
		window.close()
	}

	private func render() {
		let state = state
		host.rootView = AnyView(
			VStack(spacing: 0) {
				FavoritesGrid(
					items: state.favorites,
					profileID: state.profileID,
					selectedID: nil,
					availableHeight: 400,
					onAction: { _ in }
				)
				BrowserSidebar(
					spaceName: "Space",
					savedItems: state.saved,
					unpinnedTabs: state.tabs,
					selectedID: nil,
					onAction: { _ in }
				)
			}
			.environment(\.sidebarRowMotion, isEnabled)
		)
	}

	private func spin(_ seconds: TimeInterval) {
		let end: Date = .now.addingTimeInterval(seconds)
		while Date.now < end {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.02))
		}
	}
}
#endif
