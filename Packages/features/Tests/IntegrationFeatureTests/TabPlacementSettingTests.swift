import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-913: the sidebar on the right, and where new tabs open.
@Suite(.dependencies)
@MainActor
internal struct TabPlacementSettingTests {
	@Test
	internal func theDefaultsKeepTheSidebarLeftAndNewTabsAtTheBottom() throws {
		#expect(BrowserPreferences().general.sidebarPosition == .left)
		#expect(BrowserPreferences().general.newTabPlacement == .bottom)
		let data = try JSONEncoder().encode(BrowserPreferences())
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		values["sidebarPosition"] = nil
		values["newTabPlacement"] = "somewhereNew"
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		#expect(decoded.sidebarPosition == .left)
		#expect(decoded.newTabPlacement == .bottom)
	}

	@Test
	internal func settingsSaveTheSidebarSideAndNewTabsOpenWhereTheySay() async {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .constant(UUID(50))
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.sidebarPosition(.right))))
		#expect(document.preferences.sidebarPosition == .right)

		await store.send(.settings(.ui(.newTabPlacement(.top))))
		#expect(document.preferences.newTabPlacement == .top)
		// A tab the current tab opens goes right below it, whatever the setting says (DEV-1243).
		await store.send(.main(.ui(.openInNewTab(URL(string: "https://example.com/top")!))))
		expectNoDifference(store.state.main.sidebar.space.unpinnedTabs[1], .init(rawValue: UUID(50)))
	}

	@Test
	internal func aNewTabGoesWhereItsPlacementSays() throws {
		var organization = IntegrationFeatureTests().fixture()
		let open = organization.spaces[0].unpinnedTabs
		let new = BrowserCore.Tab.ID(rawValue: UUID(60))

		var top = organization
		top.placeNewTab(new, inSpaceAt: 0, placement: .top, current: open[1])
		expectNoDifference(top.spaces[0].unpinnedTabs, [new] + open)

		var below = organization
		below.placeNewTab(new, inSpaceAt: 0, placement: .belowCurrent, current: open[0])
		expectNoDifference(below.spaces[0].unpinnedTabs, [open[0], new, open[1]])

		// Below a pinned tab, which isn't among the open tabs: at the bottom.
		var bottom = organization
		bottom.placeNewTab(new, inSpaceAt: 0, placement: .belowCurrent, current: .init(rawValue: UUID(99)))
		expectNoDifference(bottom.spaces[0].unpinnedTabs, open + [new])

		// A tab another tab opened goes directly below it, every time (DEV-1243, DEV-1325).
		let second = BrowserCore.Tab.ID(rawValue: UUID(61))
		organization.placeOpenedTab(new, inSpaceAt: 0, opener: open[0])
		organization.placeOpenedTab(second, inSpaceAt: 0, opener: open[0])
		expectNoDifference(organization.spaces[0].unpinnedTabs, [open[0], second, new, open[1]])

		// From a tab that isn't among the open tabs, a Favorite or a pinned tab: first, every time.
		var pinned = IntegrationFeatureTests().fixture()
		let pin = BrowserCore.Tab.ID(rawValue: UUID(99))
		pinned.placeOpenedTab(new, inSpaceAt: 0, opener: pin)
		pinned.placeOpenedTab(second, inSpaceAt: 0, opener: pin)
		expectNoDifference(pinned.spaces[0].unpinnedTabs, [second, new] + open)

		// After the opener's whole Split View, which stays whole.
		var split = IntegrationFeatureTests().fixture()
		split.splits = [.init(id: .init(rawValue: UUID(70)), spaceID: split.spaces[0].id, tabIDs: open)]
		split.placeOpenedTab(new, inSpaceAt: 0, opener: open[0])
		expectNoDifference(split.spaces[0].unpinnedTabs, open + [new])
	}
}
