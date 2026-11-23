import AppUI
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// A custom icon for any tab from the icon picker, and a dot for a space without one (DEV-1251).
extension IntegrationFeatureTests {
	@Test
	internal func changeIconOpensTheTabsPickerAndAnIconReplacesItsSiteIcon() async throws {
		let organization = fixture()
		let tab = organization.spaces[0].unpinnedTabs[1]
		let store = TestStore(initialState: iconState(organization)) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.sidebar(.changeIcon(.tab(tab.rawValue))))))
		#expect(store.state.sidebar.iconPickerTabID == tab)
		#expect(store.state.sidebar.tabItem(tab)?.isPickingIcon == true)
		#expect(store.state.sidebar.tabItem(organization.spaces[0].unpinnedTabs[0])?.isPickingIcon == false)

		await store.send(.sidebar(.ui(.sidebar(.setIcon(.tab(tab.rawValue), .star)))))
		expectNoDifference(store.state.sidebar.organization.tabs[id: tab]?.icon, .star)
		expectNoDifference(store.state.sidebar.tabItem(tab)?.customIcon, .star)
		#expect(store.state.sidebar.iconPickerTabID == nil)
		#expect(store.state.sidebar.tabItem(tab)?.isPickingIcon == false)
	}

	@Test
	internal func theResetButtonPutsBackTheSitesIcon() async throws {
		var organization = fixture()
		let tab = organization.spaces[0].unpinnedTabs[0]
		organization.tabs[id: tab]?.icon = .init(emoji: "🦊")
		let store = TestStore(initialState: iconState(organization)) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.sidebar(.changeIcon(.tab(tab.rawValue))))))
		await store.send(.sidebar(.ui(.sidebar(.setIcon(.tab(tab.rawValue), nil)))))

		expectNoDifference(store.state.sidebar.organization.tabs[id: tab]?.icon, nil)
		expectNoDifference(store.state.sidebar.tabItem(tab)?.customIcon, nil)
		#expect(store.state.sidebar.iconPickerTabID == nil)
	}

	@Test
	internal func dismissingThePickerChangesNothing() async throws {
		let organization = fixture()
		let tab = organization.spaces[0].unpinnedTabs[0]
		let store = TestStore(initialState: iconState(organization)) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.sidebar(.changeIcon(.tab(tab.rawValue))))))
		await store.send(.sidebar(.ui(.sidebar(.dismissIconPicker))))

		#expect(store.state.sidebar.iconPickerTabID == nil)
		expectNoDifference(store.state.sidebar.organization, organization)
	}

	/// Pins and Favorites take an icon as open tabs do, and keep it as they move between them.
	@Test
	internal func pinsAndFavoritesKeepTheirIconsAsTheyMove() async throws {
		let organization = fixture()
		let tab = organization.spaces[0].unpinnedTabs[0]
		let store = TestStore(initialState: iconState(organization)) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.sidebar(.setIcon(.tab(tab.rawValue), .leaf)))))
		await store.send(.sidebar(.ui(.sidebar(.move(.tab(tab.rawValue), .savedRoot)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.space.savedItems.contains(.tab(tab)))
		expectNoDifference(store.state.sidebar.organization.tabs[id: tab]?.icon, .leaf)

		await store.send(.sidebar(.ui(.sidebar(.move(.tab(tab.rawValue), .favoritesRoot)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.favorites.map(\.id) == [.tab(tab.rawValue)])
		expectNoDifference(store.state.sidebar.favorites.first?.customIcon, .leaf)
	}

	/// ⌘Z after closing a tab brings it back with its icon (the window undo, DEV-1030).
	@Test
	internal func aClosedTabComesBackWithItsIconOnUndo() async throws {
		var organization = fixture()
		let closed = organization.spaces[0].unpinnedTabs[1]
		organization.tabs[id: closed]?.icon = .init(emoji: "🍲")
		var state = iconState(organization)
		state.sidebar.windowUndo = true
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.event(.closeApproved(closed, reset: false, expectedLocation: nil))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.organization.tabs[id: closed] == nil)
		// Closed, the icon is gone: Tab Archive keeps none.
		#expect(store.state.sidebar.organization.archive.allSatisfy { $0.tab.icon == nil })

		await store.send(.sidebar(.ui(.undo)))

		#expect(store.state.sidebar.space.unpinnedTabs.contains(closed))
		expectNoDifference(store.state.sidebar.organization.tabs[id: closed]?.icon, .init(emoji: "🍲"))
		expectNoDifference(store.state.sidebar.tabItem(closed)?.customIcon, .init(emoji: "🍲"))
	}

	/// ⌘Z takes back a chosen icon too.
	@Test
	internal func undoTakesBackAChosenIcon() async throws {
		let organization = fixture()
		let tab = organization.spaces[0].unpinnedTabs[0]
		var state = iconState(organization)
		state.sidebar.windowUndo = true
		let store = TestStore(initialState: state) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.ui(.sidebar(.setIcon(.tab(tab.rawValue), .star)))))
		await store.send(.sidebar(.ui(.undo)))

		expectNoDifference(store.state.sidebar.organization.tabs[id: tab]?.icon, nil)
	}

	/// Reopened from Recently Closed (⇧⌘T) rather than by ⌘Z, a tab comes back without its icon.
	@Test
	internal func aTabReopenedFromTheArchiveHasNoIcon() async throws {
		var organization = fixture()
		let closed = organization.spaces[0].unpinnedTabs[1]
		organization.tabs[id: closed]?.icon = .star
		let store = TestStore(initialState: iconState(organization)) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.event(.closeApproved(closed, reset: false, expectedLocation: nil))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		await store.send(.ui(.reopenLastClosedTab))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		let reopened = try #require(store.state.sidebar.space.unpinnedTabs.last)
		#expect(reopened != organization.spaces[0].unpinnedTabs[0])
		expectNoDifference(store.state.sidebar.organization.tabs[id: reopened]?.icon, nil)
	}

	/// A space with no icon of its own shows the collapsed space switcher's dot.
	@Test
	internal func aSpaceWithoutAnIconShowsADot() throws {
		var organization = fixture()
		let state = iconState(organization)
		let first = try #require(state.sidebar.sidebarSpace(organization.spaces[0].id))
		expectNoDifference(first.symbol, SpaceIcon.dot.rawValue)
		expectNoDifference(SpaceIcon.dot.symbolName, "circle.fill")

		organization.spaces[0].icon = .book
		let chosen = try #require(iconState(organization).sidebar.sidebarSpace(organization.spaces[0].id))
		expectNoDifference(chosen.symbol, SpaceIcon.book.rawValue)
	}

	/// The picker's reset stores no icon for the space, and a rename keeps it that way.
	@Test
	internal func aResetSpaceIconStoresNoneAndARenameKeepsItThatWay() throws {
		var organization = fixture()
		let space = organization.spaces[0]
		organization.spaces[0].icon = .book

		let reset = try organization.applying(
			.updateSpace(space.id, profileID: space.profileID, name: space.name, icon: nil),
			uuid: UUID.init
		)
		#expect(reset.spaces[0].icon == nil)
		let renamed = try reset.applying(
			.updateSpace(space.id, profileID: space.profileID, name: "Renamed", icon: reset.spaces[0].icon),
			uuid: UUID.init
		)
		#expect(renamed.spaces[0].icon == nil)
		#expect(renamed.spaces[0].name == "Renamed")
	}

	/// A tab in Split View keeps its icon on its segment of the group's row.
	@Test
	internal func aSplitMemberKeepsItsTabsIcon() throws {
		var organization = fixture()
		let space = organization.spaces[0]
		let tabs = Array(space.unpinnedTabs.prefix(2))
		organization.tabs[id: tabs[0]]?.icon = .init(emoji: "🦊")
		organization.splits = [.init(id: .init(rawValue: UUID(700)), spaceID: space.id, tabIDs: tabs)]
		let state = iconState(organization)

		let row = try #require(state.sidebar.sidebarSpace(space.id)?.unpinnedTabs.first { $0.split != nil })
		let members = try #require(row.split?.members)
		expectNoDifference(members.map(\.customIcon), [.init(emoji: "🦊"), nil])
	}

	private func iconState(_ organization: BrowserOrganization) -> MainFeature.State {
		MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
	}
}
