import AppKit
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-544: ⌃Tab goes back through the window's tabs in the order they were last shown. A quick
/// ⌃Tab goes straight to the previous tab; held, the switcher shows after its beat, each Tab moves
/// on, ⇧ moves back, letting go of ⌃ goes there and Escape goes nowhere.
@Suite(.dependencies)
@MainActor
internal struct RecentTabSwitcherTests {
	private let work: Space.ID = .init(rawValue: UUID(1))
	private let personal: Space.ID = .init(rawValue: UUID(2))

	private func tab(_ number: Int) -> BrowserCore.Tab.ID { .init(rawValue: UUID(number)) }

	@Test
	internal func theWindowKeepsItsTabsInTheOrderTheyWereLastShown() async {
		let (store, _) = makeStore()

		await select(4, 5, 3, in: store)
		expectNoDifference(store.state.recentTabs.map(\.tabID), [tab(3), tab(5), tab(4)])

		// Never-shown tabs follow in the sidebar's order, after the ones shown.
		expectNoDifference(store.state.recentTabSwitcherTabs.map(\.tabID), [tab(3), tab(5), tab(4), tab(6)])
		await store.finish()
	}

	@Test
	internal func aQuickTapGoesToThePreviousTabWithoutShowingTheSwitcher() async {
		let (store, _) = makeStore()
		await select(4, 5, in: store)

		await store.send(.ui(.tabSwitcher(.step(1))))
		expectNoDifference(store.state.tabSwitcher, TabSwitcher(
			tabs: [tab(5), tab(4), tab(3), tab(6)].map { .init(tabID: $0, spaceID: work) },
			index: 1
		))

		// ⌃ is let go of before the beat: no switcher ever shows.
		await store.send(.ui(.tabSwitcher(.commit)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.tabSwitcher == nil)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(4))
		expectNoDifference(store.state.recentTabs.map(\.tabID), [tab(4), tab(5), tab(3)])

		// Another tap goes back again.
		await store.send(.ui(.tabSwitcher(.step(1))))
		await store.send(.ui(.tabSwitcher(.commit)))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(5))
		await store.finish()
	}

	@Test
	internal func holdingShowsTheSwitcherAfterItsBeatAndLoadsNothing() async {
		// Unloaded tabs are listed as they are.
		let (store, clock) = makeStore(unloaded: [tab(5), tab(6)])
		await select(4, in: store)
		store.exhaustivity = .on

		await store.send(.ui(.tabSwitcher(.step(1)))) {
			$0.tabSwitcher = .init(
				tabs: [self.tab(4), self.tab(3), self.tab(5), self.tab(6)].map { .init(tabID: $0, spaceID: self.work) },
				index: 1
			)
		}
		await clock.advance(by: .milliseconds(149))
		await clock.advance(by: .milliseconds(1))

		// Only the beat: no page is shown or loaded while the switcher is up.
		await store.receive(\.tabSwitcherBeat) {
			$0.tabSwitcher?.isShown = true
		}
		await store.send(.ui(.tabSwitcher(.cancel))) {
			$0.tabSwitcher = nil
		}
		await store.finish()
	}

	@Test
	internal func tabMovesOnShiftMovesBackAndItWraps() async {
		let (store, _) = makeStore()
		await select(4, 5, 6, in: store)

		// [6, 5, 4, 3]

		await store.send(.ui(.tabSwitcher(.step(1))))
		await store.send(.ui(.tabSwitcher(.step(1))))

		// A second press shows it at once.
		#expect(store.state.tabSwitcher?.isShown == true)
		expectNoDifference(store.state.tabSwitcher?.selected?.tabID, tab(4))
		await store.send(.ui(.tabSwitcher(.step(1))))
		expectNoDifference(store.state.tabSwitcher?.selected?.tabID, tab(3))
		await store.send(.ui(.tabSwitcher(.step(1))))
		expectNoDifference(store.state.tabSwitcher?.selected?.tabID, tab(6))
		await store.send(.ui(.tabSwitcher(.step(-1))))
		expectNoDifference(store.state.tabSwitcher?.selected?.tabID, tab(3))
		await store.send(.ui(.tabSwitcher(.step(-1))))
		expectNoDifference(store.state.tabSwitcher?.selected?.tabID, tab(4))

		// Nothing changes until ⌃ is let go of.
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(6))

		await store.send(.ui(.tabSwitcher(.commit)))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(4))
		expectNoDifference(store.state.recentTabs.map(\.tabID), [tab(4), tab(6), tab(5), tab(3)])
		await store.finish()
	}

	@Test
	internal func shiftTabBeginsOnTheTabShownLongestAgo() async {
		let (store, _) = makeStore()
		await select(4, 5, 6, in: store)

		await store.send(.ui(.tabSwitcher(.step(-1))))
		expectNoDifference(store.state.tabSwitcher?.selected?.tabID, tab(3))
		await store.send(.ui(.tabSwitcher(.cancel)))
		await store.finish()
	}

	@Test
	internal func escapeGoesNowhereAndLeavesTheOrderAlone() async {
		let (store, _) = makeStore()
		await select(4, 5, in: store)
		let recent = store.state.recentTabs

		await store.send(.ui(.tabSwitcher(.step(1))))
		await store.send(.ui(.tabSwitcher(.step(1))))
		await store.send(.ui(.tabSwitcher(.cancel)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.tabSwitcher == nil)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(5))
		expectNoDifference(store.state.recentTabs, recent)

		// A late commit after Escape does nothing.
		await store.send(.ui(.tabSwitcher(.commit)))
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(5))
		await store.finish()
	}

	@Test
	internal func aClickedRowGoesThereAtOnce() async {
		let (store, _) = makeStore()
		await select(4, 5, in: store)

		await store.send(.ui(.tabSwitcher(.step(1))))
		await store.send(.ui(.tabSwitcher(.highlight(3))))
		expectNoDifference(store.state.tabSwitcher?.selected?.tabID, tab(6))
		await store.send(.ui(.tabSwitcher(.choose(2))))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.tabSwitcher == nil)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(3))
		await store.finish()
	}

	@Test
	internal func closedTabsLeaveTheOrderAndTheOpenSwitcher() async {
		let (store, _) = makeStore()
		await select(4, 5, 6, in: store)

		// [6, 5, 4, 3]
		await store.send(.ui(.tabSwitcher(.step(1))))
		await store.send(.ui(.tabSwitcher(.step(1))))
		expectNoDifference(store.state.tabSwitcher?.selected?.tabID, tab(4))

		// Tab 5 closes elsewhere while ⌃ is held: the switcher stays on tab 4.
		var organization = store.state.sidebar.organization
		organization.spaces[id: work]?.unpinnedTabs.removeAll { $0 == tab(5) }
		organization.tabs.remove(id: tab(5))
		await store.send(.reconcile(organization))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.recentTabs.map(\.tabID), [tab(6), tab(4), tab(3)])
		expectNoDifference(store.state.tabSwitcher?.tabs.map(\.tabID), [tab(6), tab(4), tab(3)])
		expectNoDifference(store.state.tabSwitcher?.selected?.tabID, tab(4))

		// Down to one tab, there's nothing to switch between.
		organization.spaces[id: work]?.unpinnedTabs = [tab(6)]
		organization.tabs.removeAll { $0.id != tab(6) && $0.id != tab(7) }
		await store.send(.reconcile(organization))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.tabSwitcher == nil)
		expectNoDifference(store.state.recentTabs.map(\.tabID), [tab(6)])
		await store.finish()
	}

	@Test
	internal func aTabOfAnotherSpaceGoesBackToItsSpace() async {
		let (store, _) = makeStore()
		await select(4, in: store)
		await store.send(.sidebar(.ui(.spaceSelected(personal))))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(
			store.state.recentTabs.prefix(2),
			[.init(tabID: tab(7), spaceID: personal), .init(tabID: tab(4), spaceID: work)]
		)

		await store.send(.ui(.tabSwitcher(.step(1))))
		await store.send(.ui(.tabSwitcher(.commit)))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.spaceID, work)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(4))
		await store.finish()
	}

	@Test
	internal func aWindowShowingNoTabYetBeginsOnTheFirst() async {
		// A new window opens with nothing selected.
		var organization = organization()
		organization.spaces[id: work]?.selectedTabID = nil
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: work)) {
			MainFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.tabSwitcher(.step(1))))
		expectNoDifference(store.state.tabSwitcher?.selected?.tabID, tab(3))
		await store.send(.ui(.tabSwitcher(.commit)))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(3))
		await store.finish()
	}

	@Test
	internal func aClosingWindowTakesNoSwitching() async {
		var state = MainFeature.State(organization: organization(), spaceID: work)
		state.isClosing = true
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.continuousClock = TestClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.tabSwitcher(.step(1))))
		#expect(store.state.tabSwitcher == nil)
		await store.finish()
	}

	@Test
	internal func aFavoriteGoesBackToTheSpaceItWasShownIn() async {
		var organization = organization()
		organization.tabs.append(.init(
			id: tab(8),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Favorite", url: URL(string: "https://example.com/favorite")!)
		))
		organization.profiles[0].favorites = [tab(8)]
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: work)) {
			MainFeature()
		} withDependencies: {
			$0.continuousClock = TestClock()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// The Favorite shown in Work, then another tab, then Personal.
		await select(8, 3, in: store)
		await store.send(.sidebar(.ui(.spaceSelected(personal))))
		await store.skipReceivedActions(strict: false)

		await store.send(.ui(.tabSwitcher(.step(1))))
		await store.send(.ui(.tabSwitcher(.step(1))))
		expectNoDifference(store.state.tabSwitcher?.selected, .init(tabID: tab(8), spaceID: work))
		await store.send(.ui(.tabSwitcher(.commit)))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.spaceID, work)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(8))
		await store.finish()
	}

	@Test
	internal func withTheFlagOffNothingIsKeptAndTheSwitcherNeverOpens() async {
		let (store, _) = makeStore(enabled: false)
		await select(4, 5, in: store)
		#expect(store.state.recentTabs.isEmpty)

		await store.send(.ui(.tabSwitcher(.step(1))))
		#expect(store.state.tabSwitcher == nil)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(5))
		await store.finish()
	}

	@Test
	internal func theFlagIsOnByDefaultAndCanBeTurnedOff() {
		let defaults = UserDefaults(suiteName: "RecentTabSwitcherTests.\(UUID())")!
		#expect(RecentTabSwitcherFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(!RecentTabSwitcherFeatureFlag.isOn(environment: ["ARX_RECENT_TAB_SWITCHER": "0"], defaults: defaults))
		defaults.set("off", forKey: RecentTabSwitcherFeatureFlag.name)
		#expect(!RecentTabSwitcherFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(FeatureFlag.recentTabSwitcher.isOnByDefault)
	}

	// MARK: - Keys

	@Test
	internal func controlTabOpensTheSwitcherAndLettingGoOfControlGoesBack() throws {
		let (store, commands) = appStore(enabled: true)
		store.send(.main(.ui(.selectTab(tab(4)))))
		store.send(.main(.ui(.selectTab(tab(5)))))

		#expect(commands.performKeyEquivalent(with: try key(48, "\t", [.control])))
		#expect(store.main.tabSwitcher?.selected?.tabID == tab(4))
		// Each further Tab, with ⌃ still held, goes through the monitor.
		#expect(commands.tabSwitcherKeys.handle(keyDown: try key(48, "\t", [.control])) == true)
		#expect(store.main.tabSwitcher?.selected?.tabID == tab(3))
		#expect(commands.tabSwitcherKeys.handle(keyDown: try key(48, "\t", [.control, .shift])) == true)
		#expect(store.main.tabSwitcher?.selected?.tabID == tab(4))

		commands.tabSwitcherKeys.handle(flagsChanged: try flags([]))
		#expect(store.main.tabSwitcher == nil)
		expectNoDifference(store.main.sidebar.selectedTab?.id, tab(4))

		// With the switcher gone, keys are the page's again.
		#expect(commands.tabSwitcherKeys.handle(keyDown: try key(53, "\u{1B}", [])) == nil)
	}

	@Test
	internal func escapeClosesTheSwitcherWithoutSwitching() throws {
		let (store, commands) = appStore(enabled: true)
		store.send(.main(.ui(.selectTab(tab(4)))))

		#expect(commands.performKeyEquivalent(with: try key(48, "\t", [.control])))
		#expect(store.main.tabSwitcher != nil)
		#expect(commands.tabSwitcherKeys.handle(keyDown: try key(53, "\u{1B}", [.control])) == true)
		#expect(store.main.tabSwitcher == nil)
		expectNoDifference(store.main.sidebar.selectedTab?.id, tab(4))

		// ⌃ let go of afterwards changes nothing.
		commands.tabSwitcherKeys.handle(flagsChanged: try flags([]))
		expectNoDifference(store.main.sidebar.selectedTab?.id, tab(4))
	}

	@Test
	internal func controlTabIsLeftAloneWhileTheWindowCloses() throws {
		let (store, commands) = appStore(enabled: true, closing: true)

		#expect(!commands.performKeyEquivalent(with: try key(48, "\t", [.control])))
		#expect(store.main.tabSwitcher == nil)
		expectNoDifference(store.main.sidebar.selectedTab?.id, tab(3))
	}

	@Test
	internal func withTheFlagOffControlTabIsStillNextTabInTheSidebar() throws {
		let (store, commands) = appStore(enabled: false)
		store.send(.main(.ui(.selectTab(tab(5)))))
		store.send(.main(.ui(.selectTab(tab(3)))))

		#expect(commands.performKeyEquivalent(with: try key(48, "\t", [.control])))
		#expect(store.main.tabSwitcher == nil)
		expectNoDifference(store.main.sidebar.selectedTab?.id, tab(4))
		#expect(commands.performKeyEquivalent(with: try key(48, "\t", [.control, .shift])))
		expectNoDifference(store.main.sidebar.selectedTab?.id, tab(3))
		#expect(commands.tabSwitcherKeys.handle(keyDown: try key(48, "\t", [.control])) == nil)
	}

	// MARK: - Fixture

	/// Work holds tabs 3 to 6, tab 3 selected; Personal holds tab 7.
	private func organization() -> BrowserOrganization {
		var organization = IntegrationFeatureTests().fixture()
		for number in [5, 6, 7] {
			organization.tabs.append(.init(
				id: tab(number),
				profileID: organization.profiles[0].id,
				restoration: .init(title: "Tab \(number)", url: URL(string: "https://example.com/\(number)")!)
			))
		}
		organization.spaces[id: work]?.unpinnedTabs += [tab(5), tab(6)]
		organization.spaces[id: personal]?.unpinnedTabs = [tab(7)]
		organization.spaces[id: personal]?.selectedTabID = tab(7)
		return organization
	}

	private func makeStore(
		enabled: Bool = true,
		unloaded: Set<BrowserCore.Tab.ID> = []
	) -> (TestStoreOf<MainFeature>, TestClock<Duration>) {
		let clock = TestClock()
		var state = MainFeature.State(
			organization: organization(),
			spaceID: work,
			recentTabSwitcherEnabled: enabled,
			// Without going back to the previous tab, which keeps the order too (DEV-1228).
			returnsToPreviousTab: false
		)
		state.sidebar.unloadedTabs = unloaded
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.continuousClock = clock
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return (store, clock)
	}

	private func select(
		_ numbers: Int...,
		in store: TestStoreOf<MainFeature>
	) async {
		for number in numbers {
			await store.send(.ui(.selectTab(tab(number))))
			await store.skipReceivedActions(strict: false)
		}
	}

	private func appStore(
		enabled: Bool,
		closing: Bool = false
	) -> (StoreOf<AppFeature>, BrowserCommands) {
		var initial = AppFeature.State(main: .init(
			organization: organization(),
			spaceID: work,
			recentTabSwitcherEnabled: enabled,
			// Without going back to the previous tab, which keeps the order too (DEV-1228).
			returnsToPreviousTab: false
		))
		initial.windowIsOpen = true
		initial.main.isClosing = closing
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.continuousClock = TestClock()
		}
		return (store, BrowserCommands(store: store))
	}

	private func key(
		_ code: UInt16,
		_ characters: String,
		_ modifiers: NSEvent.ModifierFlags
	) throws -> NSEvent {
		try #require(NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: modifiers,
			timestamp: 0,
			windowNumber: 0,
			context: nil,
			characters: characters,
			charactersIgnoringModifiers: characters,
			isARepeat: false,
			keyCode: code
		))
	}

	private func flags(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
		try #require(NSEvent.keyEvent(
			with: .flagsChanged,
			location: .zero,
			modifierFlags: modifiers,
			timestamp: 0,
			windowNumber: 0,
			context: nil,
			characters: "",
			charactersIgnoringModifiers: "",
			isARepeat: false,
			keyCode: 59
		))
	}
}
