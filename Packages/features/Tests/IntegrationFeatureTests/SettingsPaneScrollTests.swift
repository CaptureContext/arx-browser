import BrowserCore
import CustomDump
import Foundation
@testable import SettingsFeature
import SwiftUI
import Testing
import _ComposableArchitecture

/// Back from a Settings page returns its pane to where it was scrolled (Max, 18 Nov).
@MainActor
@Suite(.dependencies)
internal struct SettingsPaneScrollTests {
	private static let advanced: SettingsLocation = .init(category: .advanced, page: nil)
	private static let featureFlags: SettingsLocation = .init(category: .advanced, page: .featureFlags)
	private static let general: SettingsLocation = .init(category: .general, page: nil)

	@Test
	internal func backReturnsThePaneToWhereItWasScrolled() {
		var scroll = SettingsPaneScroll()
		scroll.navigated(
			from: Self.advanced,
			to: Self.featureFlags,
			lastOffset: .init(category: .advanced, offset: 640)
		)
		scroll.navigated(from: Self.featureFlags, to: Self.advanced, lastOffset: nil)

		#expect(scroll[position: .advanced].y == 640)
		#expect(scroll[position: .general].edge == .top)
	}

	@Test
	internal func anotherPaneFromTheSidebarStartsAtItsTop() {
		var scroll = SettingsPaneScroll()
		scroll.navigated(
			from: Self.advanced,
			to: Self.featureFlags,
			lastOffset: .init(category: .advanced, offset: 640)
		)
		scroll.navigated(from: Self.featureFlags, to: Self.advanced, lastOffset: nil)
		scroll.navigated(from: Self.advanced, to: Self.general, lastOffset: nil)
		#expect(scroll[position: .general].edge == .top)

		// And coming back to Advanced from the sidebar starts it at its top too.
		scroll.navigated(from: Self.general, to: Self.advanced, lastOffset: nil)
		#expect(scroll[position: .advanced].edge == .top)
	}

	@Test
	internal func aPageReachedFromAnotherPaneLeavesItsOwnPaneAtItsTop() {
		var scroll = SettingsPaneScroll()

		// The sidebar's search opens Advanced › Feature Flags from General, scrolled down.
		scroll.navigated(
			from: Self.general,
			to: Self.featureFlags,
			lastOffset: .init(category: .general, offset: 300)
		)
		scroll.navigated(from: Self.featureFlags, to: Self.advanced, lastOffset: nil)

		#expect(scroll[position: .advanced].edge == .top)
	}

	@Test
	internal func anotherPanesOffsetIsNotUsed() {
		var scroll = SettingsPaneScroll()
		scroll.navigated(
			from: Self.advanced,
			to: Self.featureFlags,
			lastOffset: .init(category: .general, offset: 300)
		)

		#expect(scroll[position: .advanced].edge == .top)
	}

	@Test
	internal func aPageOpenedFromAPageKeepsThePanesPosition() {
		var scroll = SettingsPaneScroll()
		let keptLoaded = SettingsLocation(category: .advanced, page: .keptLoadedSites)
		scroll.navigated(
			from: Self.advanced,
			to: Self.featureFlags,
			lastOffset: .init(category: .advanced, offset: 640)
		)
		scroll.navigated(
			from: Self.featureFlags,
			to: keptLoaded,
			lastOffset: .init(category: .advanced, offset: 12)
		)
		scroll.navigated(from: keptLoaded, to: Self.advanced, lastOffset: nil)

		#expect(scroll[position: .advanced].y == 640)
	}

	@Test
	internal func scrollingThePaneKeepsWhatSwiftUIReports() {
		var scroll = SettingsPaneScroll()
		scroll[position: .advanced] = .init(y: 80)

		#expect(scroll.category == .advanced)
		#expect(scroll[position: .advanced].y == 80)
		#expect(scroll[position: .links].edge == .top)
	}

	/// Back, ⌘[ and ← all send `pagePresented(nil)`: the pane stays, so its scroll comes back.
	@Test
	internal func backKeepsThePane() async {
		var state = SettingsFeature.State()
		state.category = .advanced
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}

		await store.send(.ui(.pagePresented(.featureFlags))) { $0.page = .featureFlags }
		await store.send(.ui(.pagePresented(nil))) { $0.page = nil }
		#expect(store.state.category == .advanced)
		await store.finish()
	}

	@Test
	internal func theFeatureFlagIsOnByDefault() {
		let flag = FeatureFlag.settingsScrollRestore
		#expect(flag.name == SettingsScrollRestore.featureFlag)
		#expect(flag.isOnByDefault)
		#expect(flag.needsRelaunch)
		#expect(!flag.isRisky)
		#expect(!flag.isReadByEngine)
	}
}
