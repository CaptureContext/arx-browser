import BrowserCore
import BrowserEngineClient
import Clocks
import CustomDump
import Foundation
import Testing
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct PageZoomBadgeTests {
	/// A zoom command shows the page's new zoom, and the badge leaves after a pause.
	@Test
	internal func zoomShowsTheNewLevelBriefly() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let clock = TestClock<Duration>()
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 3)) {
			ViewerItemFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.browserEngine.command = { _, command in commands.withValue { $0.append(command) } }
			$0.browserEngine.pageZoom = { _ in 1.1 }
		}

		await store.send(.ui(.command(.zoom(.zoomIn))))
		await store.receive(\.event.zoomed) { $0.zoomBadge = 110 }
		await clock.advance(by: ViewerItemFeature.zoomBadgeDuration)
		await store.receive(\.event.zoomBadgeExpired) { $0.zoomBadge = nil }
		expectNoDifference(commands.value, [.zoom(.zoomIn)])
	}

	/// A page the engine can't zoom stays as it was, with no failure.
	@Test
	internal func aFailedZoomLeavesThePageAlone() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 3)) {
			ViewerItemFeature()
		} withDependencies: {
			$0.browserEngine.command = { _, _ in throw BrowserEngineClient.Failure.unavailable }
		}

		await store.send(.ui(.command(.zoom(.zoomOut))))
		await store.finish()
	}

	/// A badge from a page the item no longer shows is dropped.
	@Test
	internal func aStaleZoomIsDropped() async throws {
		let tab = try #require(IntegrationFeatureTests().fixture().tabs.first)
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 3)) {
			ViewerItemFeature()
		}

		await store.send(.event(.zoomed(tab.id, 2, factor: 1.5)))
	}

	@Test
	internal func zoomCommandsMapToEngineZoom() async throws {
		#expect(BrowserCommand.zoomIn.engineCommand == .zoom(.zoomIn))
		#expect(BrowserCommand.zoomOut.engineCommand == .zoom(.zoomOut))
		#expect(BrowserCommand.actualSize.engineCommand == .zoom(.actualSize))
	}
}
