import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import ViewerFeature
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

/// Match site (DEV-1101): the window keeps the color its shown pages offer the chrome.
extension IntegrationFeatureTests {
	@Test
	internal func theShownPagesColorReachesTheChromeAndFollowsItsChanges() async {
		let organization = fixture()
		let tab = organization.tabs[0]
		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		initial.viewer.item.tab = tab
		let store = TestStore(initialState: initial) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		let navy: ChromePalette.RGB = .init(argb: 0xFF10_2040)
		let paper: ChromePalette.RGB = .init(argb: 0xFFFA_F7F0)
		await store.send(.viewer(.item(.event(.navigation(tab.id, 0, Self.page("https://example.com", theme: navy))))))
		expectNoDifference(store.state.siteChromeColor, navy)

		// The site changed its color, as a dark theme-color takes over in the dark scheme.
		await store.send(.viewer(.item(.event(.navigation(tab.id, 0, Self.page("https://example.com", background: paper))))))
		expectNoDifference(store.state.siteChromeColor, paper)

		// A failed load keeps the space's own color.
		var failed = Self.page("https://example.com", background: paper)
		failed.errorCode = -105
		await store.send(.viewer(.item(.event(.navigation(tab.id, 0, failed)))))
		#expect(store.state.siteChromeColor == nil)
	}

	@Test
	internal func aSplitOfTwoSitesKeepsTheSpacesColor() async {
		let organization = fixture()
		let navy: ChromePalette.RGB = .init(argb: 0xFF10_2040)
		var first = ViewerItemFeature.State(tab: organization.tabs[0])
		first.navigation = Self.page("https://example.com", theme: navy)
		var second = ViewerItemFeature.State(tab: organization.tabs[1])
		second.navigation = Self.page("https://www.example.com/other", theme: navy)

		var initial = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		initial.viewer.panes = [
			.init(id: UUID(0), item: first),
			.init(id: UUID(1), item: second),
		]
		initial.viewer.activePaneID = UUID(1)
		initial.viewer.fractions = [0.5, 0.5]
		let store = TestStore(initialState: initial) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		// One site in both panes: the chrome follows it.
		await store.send(.viewer(.item(.event(.navigation(organization.tabs[1].id, 0, second.navigation)))))
		expectNoDifference(store.state.siteChromeColor, navy)

		// The active pane goes to another site: no one page stands for the window.
		await store.send(.viewer(.item(.event(.navigation(
			organization.tabs[1].id,
			0,
			Self.page("https://example.org", theme: navy)
		)))))
		#expect(store.state.siteChromeColor == nil)
	}

	/// The app moves another window's active pane outside that window's reducer, as a selection in
	/// another window does; the window's color is refreshed after it.
	@Test
	internal func aWindowsPanesChangedFromOutsideRefreshItsColor() {
		let organization = fixture()
		let navy: ChromePalette.RGB = .init(argb: 0xFF10_2040)
		let paper: ChromePalette.RGB = .init(argb: 0xFFFA_F7F0)
		var first = ViewerItemFeature.State(tab: organization.tabs[0])
		first.navigation = Self.page("https://example.com/a", theme: navy)
		var second = ViewerItemFeature.State(tab: organization.tabs[1])
		second.navigation = Self.page("https://example.com/b", theme: paper)

		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.panes = [
			.init(id: UUID(0), item: first),
			.init(id: UUID(1), item: second),
		]
		state.viewer.activePaneID = UUID(0)
		state.refreshSiteChromeColor()
		expectNoDifference(state.siteChromeColor, navy)
		#expect(!state.siteChromeColorIsStale)

		state.viewer.activePaneID = UUID(1)
		#expect(state.siteChromeColorIsStale)
		state.refreshSiteChromeColor()
		expectNoDifference(state.siteChromeColor, paper)
	}

	private static func page(
		_ address: String,
		theme: ChromePalette.RGB? = nil,
		background: ChromePalette.RGB? = nil
	) -> BrowserNavigation {
		.init(url: URL(string: address), colors: .init(theme: theme, background: background))
	}
}
