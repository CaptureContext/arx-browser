import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1228: closing the selected tab, or resetting a selected pin or Favorite, selects the tab the
/// window showed before it, instead of leaving none selected.
@Suite(.dependencies)
@MainActor
internal struct PreviousTabSelectionTests {
	private let profile: Profile.ID = .init(rawValue: UUID(0))
	private let work: Space.ID = .init(rawValue: UUID(1))
	private let personal: Space.ID = .init(rawValue: UUID(2))

	private func tab(_ number: Int) -> BrowserCore.Tab.ID { .init(rawValue: UUID(number)) }

	/// Work has open tabs 3, 4 and 5, pin 8 and Favorite 9; Personal has open tab 7. With
	/// `atSavedPages`, the pin and the Favorite show their saved pages, so a reset only deselects.
	private func organization(atSavedPages: Bool = false) -> BrowserOrganization {
		let url: URL = URL(string: "https://example.com")!
		func open(_ number: Int) -> BrowserCore.Tab {
			.init(id: tab(number), profileID: profile, restoration: .init(title: "Tab \(number)", url: url.appending(path: "\(number)")))
		}
		func saved(_ number: Int) -> BrowserCore.Tab {
			.init(
				id: tab(number),
				profileID: profile,
				savedDestination: .init(title: "Saved \(number)", url: url.appending(path: "saved")),
				restoration: atSavedPages
				? .init(title: "Saved \(number)", url: url.appending(path: "saved"))
				: .init(title: "Away \(number)", url: url.appending(path: "away"))
			)
		}
		return .init(
			profiles: [.init(id: profile, name: "Default", favorites: [tab(9)])],
			spaces: [
				.init(
					id: work,
					profileID: profile,
					name: "Work",
					savedItems: [.tab(tab(8))],
					unpinnedTabs: [tab(3), tab(4), tab(5)],
					selectedTabID: tab(3)
				),
				.init(id: personal, profileID: profile, name: "Personal", unpinnedTabs: [tab(7)], selectedTabID: tab(7)),
			],
			tabs: [open(3), open(4), open(5), open(7), saved(8), saved(9)]
		)
	}

	private func makeStore(
		returnsToPreviousTab: Bool = true,
		atSavedPages: Bool = false
	) -> TestStoreOf<MainFeature> {
		var state = MainFeature.State(
			organization: organization(atSavedPages: atSavedPages),
			spaceID: work,
			recentTabSwitcherEnabled: false,
			returnsToPreviousTab: returnsToPreviousTab
		)
		state.sidebar.windowUndo = true
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.date = .constant(Date(timeIntervalSince1970: 1_000))
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
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

	private func close(
		_ number: Int,
		reset: Bool = false,
		in store: TestStoreOf<MainFeature>
	) async {
		await store.send(.sidebar(.event(.closeApproved(tab(number), reset: reset, expectedLocation: nil))))
		await store.skipReceivedActions(strict: false)
	}

	@Test
	internal func closingTheSelectedTabSelectsThePreviousOne() async {
		let store = makeStore()
		await select(4, 5, in: store)

		await close(5, in: store)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(4))
		await store.finish()
	}

	@Test
	internal func resettingASelectedPinSelectsThePreviousTab() async {
		let store = makeStore()
		await select(4, 8, in: store)

		await close(8, reset: true, in: store)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(4))

		// The pin stays, back at its saved page.
		#expect(store.state.sidebar.organization.tabs[id: tab(8)]?.restoration.title == "Saved 8")
		await store.finish()
	}

	@Test
	internal func resettingASelectedFavoriteSelectsThePreviousTab() async {
		let store = makeStore()
		await select(4, 9, in: store)

		await close(9, reset: true, in: store)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(4))
		await store.finish()
	}

	// MARK: - ⌘Z

	/// ⌘Z takes back the reset or close, with the tab selected again, and never skips it for an
	/// older edit (DEV-1228, batch 16's review): the previous tab's selection is part of its step.
	@Test(arguments: [8, 9])
	internal func undoingAResetAtTheSavedPageSelectsItAgain(_ number: Int) async {
		let store = makeStore(atSavedPages: true)

		// An older, unrelated edit: closing a tab that isn't selected.
		await close(3, in: store)
		await select(4, number, in: store)

		await close(number, reset: true, in: store)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(4))

		await store.send(.sidebar(.ui(.undo)))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(number))

		// The older edit stays.
		#expect(store.state.sidebar.organization.tabs[id: tab(3)] == nil)
		await store.finish()
	}

	@Test
	internal func undoingACloseBringsItBackSelected() async {
		let store = makeStore()
		await close(3, in: store)
		await select(4, 5, in: store)

		await close(5, in: store)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(4))

		await store.send(.sidebar(.ui(.undo)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.organization.tabs[id: tab(5)] != nil)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(5))
		#expect(store.state.sidebar.organization.tabs[id: tab(3)] == nil)
		await store.finish()
	}

	/// A tab chosen after the automatic one is the person's: ⌘Z takes the reset back but leaves it.
	@Test
	internal func aTabChosenAfterwardsStaysSelected() async {
		let store = makeStore(atSavedPages: true)
		await select(4, 8, in: store)
		await close(8, reset: true, in: store)
		await select(5, in: store)

		await store.send(.sidebar(.ui(.undo)))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(5))
		await store.finish()
	}

	@Test
	internal func withThePreviousTabClosedNothingIsSelected() async {
		let store = makeStore()
		await select(4, 5, in: store)

		// The previous tab goes first, while 5 is selected; then 5 has nothing to go back to.
		await close(4, in: store)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(5))
		await close(5, in: store)
		#expect(store.state.sidebar.selectedTab == nil)
		await store.finish()
	}

	@Test
	internal func closingATabThatIsntSelectedChangesNothing() async {
		let store = makeStore()
		await select(4, 5, in: store)

		await close(3, in: store)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(5))
		await store.finish()
	}

	@Test
	internal func aPreviousTabInAnotherSpaceIsntGoneBackTo() async {
		let store = makeStore()
		await select(4, in: store)
		await store.send(.sidebar(.ui(.spaceSelected(personal))))
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.sidebar.selectedTab?.id, tab(7))

		// Closing it doesn't take the window to Work.
		await close(7, in: store)
		#expect(store.state.sidebar.spaceID == personal)
		#expect(store.state.sidebar.selectedTab == nil)
		await store.finish()
	}

	@Test
	internal func eachWindowGoesBackToItsOwnPreviousTab() async {
		let first = makeStore()
		let second = makeStore()
		await select(4, 5, in: first)
		await select(3, 5, in: second)

		await close(5, in: first)
		await close(5, in: second)
		expectNoDifference(first.state.sidebar.selectedTab?.id, tab(4))
		expectNoDifference(second.state.sidebar.selectedTab?.id, tab(3))
		await first.finish()
		await second.finish()
	}

	@Test
	internal func withTheFeatureFlagOffTheSelectionClearsAsBefore() async {
		let store = makeStore(returnsToPreviousTab: false)
		await select(4, 5, in: store)

		await close(5, in: store)
		#expect(store.state.sidebar.selectedTab == nil)
		#expect(store.state.recentTabs.isEmpty)
		await store.finish()
	}

	@Test
	internal func aPreviousTabMovedToAnotherSpaceIsntGoneBackTo() async {
		let store = makeStore()
		await select(8, 4, in: store)

		// Another window moved the pin to Personal.
		var organization = store.state.sidebar.organization
		organization.spaces[id: work]?.savedItems = []
		organization.spaces[id: personal]?.savedItems = [.tab(tab(8))]
		await store.send(.reconcile(organization))
		await store.skipReceivedActions(strict: false)

		await close(4, in: store)
		#expect(store.state.sidebar.spaceID == work)
		#expect(store.state.sidebar.selectedTab == nil)
		await store.finish()
	}

	@Test
	internal func aClosedTabShownLastLeavesNothingToGoBackTo() async {
		let store = makeStore()

		// 3, 4, 5 shown; 4 closes in the background, then 5 while it shows.
		await select(4, 5, in: store)
		await close(4, in: store)
		await close(5, in: store)
		#expect(store.state.sidebar.selectedTab == nil)

		// 3 is shown next: what was shown before it closed, so closing 3 has nowhere to go.
		await select(3, in: store)
		await close(3, in: store)
		#expect(store.state.sidebar.selectedTab == nil)
		await store.finish()
	}
}
