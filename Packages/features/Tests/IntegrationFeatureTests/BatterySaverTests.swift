import BrowserCore
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Settings › General › Battery Saver and its notice (DEV-915).
@Suite(.dependencies)
@MainActor
internal struct BatterySaverSettingsTests {
	@Test
	internal func settingsSavesTheChoice() async throws {
		let state = SettingsFeature.State()
		state.$batterySaver.withLock { $0 = .whenBatteryLow }
		let store = TestStore(initialState: state) { SettingsFeature() }
		store.exhaustivity = .off

		await store.send(.ui(.batterySaverMode(.whenUnplugged)))
		#expect(store.state.batterySaver == .whenUnplugged)
		await store.send(.ui(.batterySaverMode(.never)))
		#expect(store.state.batterySaver == .never)
	}

	@Test
	internal func turningOnShowsANoticeAndOffDoesNot() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off

		await store.send(.batterySaver(.changed(isActive: false)))
		#expect(store.state.main.sidebar.message == nil)
		await store.send(.batterySaver(.changed(isActive: true)))
		#expect(store.state.main.sidebar.message?.isEmpty == false)
	}
}
