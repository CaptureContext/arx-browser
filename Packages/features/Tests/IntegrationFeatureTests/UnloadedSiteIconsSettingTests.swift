import BrowserCore
import BrowserSiteIconClient
import BrowserWorkspaceClient
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-796: Settings › General › Fetch icons for tabs that haven't loaded.
@Suite(.dependencies)
@MainActor
internal struct UnloadedSiteIconsSettingTests {
	@Test
	internal func theSettingIsOnByDefaultAndOlderSavesKeepIt() throws {
		#expect(BrowserPreferences().fetchesUnloadedSiteIcons)
		#expect(BrowserPreferences().general.fetchesUnloadedSiteIcons)
		let data = try JSONEncoder().encode(BrowserPreferences())
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		#expect(values.removeValue(forKey: "fetchesUnloadedSiteIcons") != nil)
		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)
		#expect(decoded.fetchesUnloadedSiteIcons)

		var off = BrowserPreferences()
		off.fetchesUnloadedSiteIcons = false
		let saved = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(off))
		#expect(!saved.fetchesUnloadedSiteIcons)
	}

	@Test
	internal func theSwitchSavesTheSettingAndTellsTheEngine() async {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let calls = LockIsolated<[Bool]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.browserSiteIcons = BrowserSiteIconClient(
				setFetchesUnloadedIcons: { enabled in calls.withValue { $0.append(enabled) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.fetchesUnloadedSiteIcons(false))))
		#expect(!store.state.settings.general.fetchesUnloadedSiteIcons)
		#expect(!document.preferences.fetchesUnloadedSiteIcons)

		await store.send(.settings(.ui(.fetchesUnloadedSiteIcons(true))))
		#expect(store.state.settings.general.fetchesUnloadedSiteIcons)
		#expect(document.preferences.fetchesUnloadedSiteIcons)
		expectNoDifference(calls.value, [false, true])
	}
}
