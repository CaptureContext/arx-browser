import AppKit
import BrowserCore
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1112: ⌥⌘P turns a Little Arx window into Page PiP, with the same page, and Return to Tab
/// turns it back; closing either closes the page.
@Suite(.dependencies)
@MainActor
internal struct LittleArxPictureInPictureTests {
	@Test
	internal func theCommandTurnsLittleArxIntoPagePictureInPictureAndBack() async throws {
		let state = fixture()
		let store = makeStore(state)

		await store.send(.ui(.command(.pagePictureInPicture, .window(Self.littleID))))
		await store.receive(\.littleWindows) {
			$0.littleWindows[id: Self.littleID]?.isPictureInPicture = true
		}

		// The same window and page: nothing floats apart from it, and no page was let go.
		#expect(store.state.pagePictureInPicture == nil)
		// Automatic media PiP leaves the floating page alone.
		expectNoDifference(store.state.media.tabsFloatingElsewhere, [Self.tab.id])
		expectNoDifference(store.state.littleWindows[id: Self.littleID]?.tab.id, Self.tab.id)

		await store.send(.ui(.command(.pagePictureInPicture, .window(Self.littleID))))
		await store.receive(\.littleWindows) {
			$0.littleWindows[id: Self.littleID]?.isPictureInPicture = false
		}
		#expect(store.state.media.tabsFloatingElsewhere.isEmpty)

		// Any number of times; Return to Tab is the way back too.
		await store.send(.ui(.command(.pagePictureInPicture, .window(Self.littleID))))
		await store.receive(\.littleWindows) {
			$0.littleWindows[id: Self.littleID]?.isPictureInPicture = true
		}
		await store.send(.littleWindows(.element(id: Self.littleID, action: .ui(.setPictureInPicture(false))))) {
			$0.littleWindows[id: Self.littleID]?.isPictureInPicture = false
		}
		await store.finish()
	}

	@Test
	internal func closingItsPagePictureInPictureClosesThePage() async throws {
		var state = fixture()
		state.littleWindows[id: Self.littleID]?.isPictureInPicture = true
		let closed = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = makeStore(state, closed: closed)

		await store.send(.littleWindows(.element(id: Self.littleID, action: .ui(.close))))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(store.state.littleWindows[id: Self.littleID] == nil)
		expectNoDifference(closed.value, [Self.tab.id])
	}

	@Test
	internal func littleArxDoesntLendItsPageToAnotherWindow() async throws {
		let state = fixture()
		#expect(state.pagePictureInPictureSource(of: Self.tab.id) == nil)
		// As Page PiP it doesn't fill the screen either.
		var floating = state
		floating.littleWindows[id: Self.littleID]?.isPictureInPicture = true
		#expect(floating.pageFullScreenWindow(showing: Self.tab.id) == nil)
		#expect(state.pageFullScreenWindow(showing: Self.tab.id) == Self.littleID)
	}

	@Test
	internal func itStaysLittleArxWhileBusy() async throws {
		var little = fixture().littleWindows[id: Self.littleID]!
		little.peekID = UUID(99)
		let store = TestStore(initialState: little) { LittleArxFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.setPictureInPicture(true)))
		#expect(!store.state.isPictureInPicture)
	}

	@Test
	internal func theWindowComesBackToItsLittleArxFrame() async throws {
		let panel = LittleArxPanel(commandOnly: false, origin: .init(x: 400, y: 400))
		let littleFrame = panel.frame
		#expect(panel.styleMask.contains(.titled))

		panel.updatePictureInPicture(true, siteKey: nil)
		#expect(panel.isPictureInPicture)
		#expect(!panel.styleMask.contains(.titled))
		#expect(panel.styleMask.contains(.nonactivatingPanel))
		#expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
		#expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
		#expect(panel.pictureInPictureMover != nil)

		panel.updatePictureInPicture(false, siteKey: nil)
		#expect(!panel.isPictureInPicture)
		#expect(panel.styleMask.contains(.titled))
		// Back on the Space it's on, where it stays (DEV-1227).
		#expect(panel.collectionBehavior == LittleArxPanel.windowBehavior)
		#expect(panel.pictureInPictureMover == nil)
		expectNoDifference(panel.frame, littleFrame)

		// And again.
		panel.updatePictureInPicture(true, siteKey: nil)
		panel.updatePictureInPicture(false, siteKey: nil)
		expectNoDifference(panel.frame, littleFrame)
		panel.close()
	}

	// MARK: - Fixture

	private static let littleID: UUID = UUID(20)
	private static let tab: BrowserCore.Tab = .init(
		id: .init(rawValue: UUID(21)),
		profileID: IntegrationFeatureTests().fixture().spaces[0].profileID,
		restoration: .init(title: "Little", url: URL(string: "https://capturecontext.dev/little")!)
	)

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		let space = organization.spaces[0]
		var state = AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		var little = LittleArxFeature.State(id: Self.littleID, spaceID: space.id, tab: Self.tab)
		little.viewer.tab = Self.tab
		state.littleWindows.append(little)
		return state
	}

	private func makeStore(
		_ state: AppFeature.State,
		closed: LockIsolated<[BrowserCore.Tab.ID]> = .init([])
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { id in closed.withValue { $0.append(id) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}
}
