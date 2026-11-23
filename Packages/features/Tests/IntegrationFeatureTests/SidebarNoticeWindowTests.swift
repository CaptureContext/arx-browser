import AppFeature
import BrowserCore
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// Each window times its own sidebar notice (DEV-777): a notice or hover in the main window
/// never cancels another window's timer, which would leave that notice up for good.
@Suite(.dependencies)
@MainActor
internal struct SidebarNoticeWindowTests {
	@Test
	internal func hoveringTheMainWindowsNoticeLeavesAnotherWindowsTimerRunning() async {
		let clock: TestClock<Duration> = .init()
		let windowID: UUID = .init(2)
		let store = TestStore(initialState: state(windowID: windowID)) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
		}

		await store.send(.windows(.element(id: windowID, action: .ui(.noticeShown(1)))))

		// Later, the main window shows its notice and the pointer rests on it.
		await clock.advance(by: .seconds(1))
		await store.send(.main(.ui(.noticeShown(1))))
		await store.send(.main(.ui(.noticeHovered(true)))) {
			$0.main.noticeIsHovered = true
		}

		await clock.advance(by: .milliseconds(1_500))
		await store.receive(\.windows[id: windowID].event.noticeExpired) {
			$0.windows[id: windowID]?.sidebar.message = nil
		}

		// The main window's notice waits for its pointer, then gets its own time.
		await clock.advance(by: .seconds(10))
		await store.send(.main(.ui(.noticeHovered(false)))) {
			$0.main.noticeIsHovered = false
		}
		await clock.advance(by: .milliseconds(1_500))
		await store.receive(\.main.event.noticeExpired) {
			$0.main.sidebar.message = nil
		}
	}

	private func state(windowID: UUID) -> AppFeature.State {
		let profile = Profile.ID(rawValue: UUID(0))
		let space = Space.ID(rawValue: UUID(100))
		let organization = BrowserOrganization(
			profiles: [.init(id: profile, name: "Default")],
			spaces: [.init(id: space, profileID: profile, name: "Work")],
			tabs: []
		)
		var main: MainFeature.State = .init(organization: organization, spaceID: space)
		main.sidebar.message = "That item can't be moved to this location."
		var window: MainFeature.State = .init(organization: organization, spaceID: space, id: windowID)
		window.sidebar.message = "There's no room for another pane."
		var state: AppFeature.State = .init(main: main)
		state.windows.append(window)
		return state
	}
}
