import BrowserCore
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// The sidebar's notice toast (DEV-777): once shown it stays about 2.5 s, waits while the pointer
/// is over it, and a timer for an older notice never clears a newer one, even with the same text.
@Suite(.dependencies)
@MainActor
internal struct SidebarNoticeTests {
	private let notice: String = "This workspace changed. Try again."

	@Test
	internal func noticeClearsAfterItsDurationOnceShown() async {
		let clock: TestClock<Duration> = .init()
		let store = makeStore(clock: clock)

		await store.send(.ui(.noticeShown(1)))
		await clock.advance(by: .seconds(2))
		await clock.advance(by: .milliseconds(500))
		await store.receive(\.event.noticeExpired) {
			$0.sidebar.message = nil
		}
	}

	@Test
	internal func hoveringHoldsTheNoticeUntilThePointerLeaves() async {
		let clock: TestClock<Duration> = .init()
		let store = makeStore(clock: clock)

		await store.send(.ui(.noticeShown(1)))
		await clock.advance(by: .seconds(2))
		await store.send(.ui(.noticeHovered(true))) {
			$0.noticeIsHovered = true
		}
		await clock.advance(by: .seconds(30))

		await store.send(.ui(.noticeHovered(false))) {
			$0.noticeIsHovered = false
		}
		await clock.advance(by: .seconds(1))
		await clock.advance(by: .milliseconds(500))
		await store.receive(\.event.noticeExpired) {
			$0.sidebar.message = nil
		}
	}

	@Test
	internal func writingTheSameTextAgainMakesANewNotice() {
		var state: SidebarFeature.State = .init(
			organization: .init(profiles: [], spaces: [], tabs: []),
			spaceID: .init(rawValue: UUID(100))
		)
		state.message = notice
		let first: SidebarNotice? = state.notice
		state.message = notice

		expectNoDifference(first?.id, 1)
		expectNoDifference(state.notice, SidebarNotice(id: 2, text: notice))
		state.message = nil
		expectNoDifference(state.notice, nil)
		state.message = notice
		expectNoDifference(state.notice?.id, 3)
	}

	@Test
	internal func theSameTextAgainGetsItsFullTimeAndTheEarlierTimerLeavesIt() async {
		let clock: TestClock<Duration> = .init()

		// Written twice, as a refusal repeated before its toast expired: notice 2.
		let store = makeStore(clock: clock) { $0.sidebar.message = notice }

		// The earlier notice's timer changes nothing.
		await store.send(.event(.noticeExpired(1)))
		await store.send(.ui(.noticeShown(1)))
		await store.send(.ui(.noticeShown(2)))
		await clock.advance(by: .seconds(2))
		await clock.advance(by: .milliseconds(500))
		await store.receive(\.event.noticeExpired) {
			$0.sidebar.message = nil
		}
	}

	@Test
	internal func aReplacementUnderThePointerStaysUntilThePointerLeaves() async {
		let clock: TestClock<Duration> = .init()
		let store = makeStore(clock: clock) { $0.sidebar.message = "There's no room for another pane." }

		// Notice 2 replaced notice 1 while the pointer was over the toast; the toast stays.
		await store.send(.ui(.noticeHovered(true))) {
			$0.noticeIsHovered = true
		}

		// The replacement's task keeps the hover and starts no timer.
		await store.send(.ui(.noticeShown(2)))
		await clock.advance(by: .seconds(30))

		await store.send(.ui(.noticeHovered(false))) {
			$0.noticeIsHovered = false
		}
		await clock.advance(by: .milliseconds(1_500))
		await store.receive(\.event.noticeExpired) {
			$0.sidebar.message = nil
		}
	}

	@Test
	internal func removingTheToastEndsItsHoverAndANewerNoticeGetsATimer() async {
		let clock: TestClock<Duration> = .init()
		let store = makeStore(clock: clock) { $0.noticeIsHovered = true }

		// Notice 1's toast was hovered when it left; notice 1 shows in a new toast.
		await store.send(.ui(.noticeShown(1)))
		await store.send(.ui(.noticeRemoved(0))) {
			$0.noticeIsHovered = false
		}
		await clock.advance(by: .milliseconds(2_500))
		await store.receive(\.event.noticeExpired) {
			$0.sidebar.message = nil
		}

		// Its own toast leaving afterwards changes nothing.
		await store.send(.ui(.noticeRemoved(1)))
	}

	private func makeStore(
		clock: TestClock<Duration>,
		_ configure: (inout MainFeature.State) -> Void = { _ in }
	) -> TestStoreOf<MainFeature> {
		let profile = Profile.ID(rawValue: UUID(0))
		let space = Space.ID(rawValue: UUID(100))
		let organization = BrowserOrganization(
			profiles: [.init(id: profile, name: "Default")],
			spaces: [.init(id: space, profileID: profile, name: "Work")],
			tabs: []
		)
		var state = MainFeature.State(organization: organization, spaceID: space)
		state.sidebar.message = notice
		configure(&state)
		return TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.continuousClock = clock
		}
	}
}
