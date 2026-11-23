import AppUI
import BrowserCore
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1225: resetting a pin, alone or with others, counts a reset for its row, which shakes once.
@Suite(.dependencies)
@MainActor
internal struct PinResetShakeTests {
	private let profile: Profile.ID = .init(rawValue: UUID(0))
	private let work: Space.ID = .init(rawValue: UUID(1))
	private let pin: BrowserCore.Tab.ID = .init(rawValue: UUID(8))
	private let open: BrowserCore.Tab.ID = .init(rawValue: UUID(3))

	private func state(shakes: Bool = true) -> MainFeature.State {
		let url: URL = URL(string: "https://example.com")!
		let organization: BrowserOrganization = .init(
			profiles: [.init(id: profile, name: "Default")],
			spaces: [
				.init(id: work, profileID: profile, name: "Work", savedItems: [.tab(pin)], unpinnedTabs: [open], selectedTabID: open)
			],
			tabs: [
				.init(id: open, profileID: profile, restoration: .init(title: "Open", url: url)),
				.init(
					id: pin,
					profileID: profile,
					savedDestination: .init(title: "Saved", url: url.appending(path: "saved")),
					restoration: .init(title: "Away", url: url.appending(path: "away"))
				),
			]
		)
		var state: MainFeature.State = .init(organization: organization, spaceID: work)
		state.sidebar.shakesResetPins = shakes
		return state
	}

	@Test
	internal func aResetPinShakesItsRowOnceEachTime() async {
		let store = TestStore(initialState: state()) { MainFeature() } withDependencies: {
			$0.date = .constant(Date(timeIntervalSince1970: 1_000))
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.event(.closeApproved(pin, reset: true, expectedLocation: nil))))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.resetPulses == [.tab(pin.rawValue): 1])

		await store.send(.sidebar(.event(.closeApproved(pin, reset: true, expectedLocation: nil))))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.resetPulses == [.tab(pin.rawValue): 2])
		await store.finish()
	}

	@Test
	internal func closingATabDoesntShake() async {
		let store = TestStore(initialState: state()) { MainFeature() } withDependencies: {
			$0.date = .constant(Date(timeIntervalSince1970: 1_000))
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.event(.closeApproved(open, reset: false, expectedLocation: nil))))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.resetPulses.isEmpty)
		await store.finish()
	}

	@Test
	internal func aBulkResetShakesEachPin() async {
		let store = TestStore(initialState: state()) { MainFeature() } withDependencies: {
			$0.date = .constant(Date(timeIntervalSince1970: 1_000))
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request: BulkTabClose = .init(entries: [], removals: [], resets: [pin], locations: [pin: .pinned(work, folder: nil)])

		await store.send(.event(.bulkCloseFinished(request)))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.resetPulses == [.tab(pin.rawValue): 1])
		await store.finish()
	}

	@Test
	internal func withTheFeatureFlagOffNothingShakes() async {
		let store = TestStore(initialState: state(shakes: false)) { MainFeature() } withDependencies: {
			$0.date = .constant(Date(timeIntervalSince1970: 1_000))
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.sidebar(.event(.closeApproved(pin, reset: true, expectedLocation: nil))))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.sidebar.resetPulses.isEmpty)
		await store.finish()
	}

	@Test
	internal func theShakeAndItsHighlightAreWellUnderHalfASecond() {
		#expect(SidebarResetShake.duration < 0.4)
		let highlight = SidebarResetShake.highlightTimes
		#expect(highlight.in + highlight.hold + highlight.out < 0.5)
		// A couple of quick swings, back to where it was.
		#expect(SidebarResetShake.swings.count >= 3)
		#expect(SidebarResetShake.swings.last?.offset == 0)
	}
}

/// DEV-1225: which count changes shake a row.
internal struct PinResetShakeTriggerTests {
	private let a: SidebarItem.ID = .tab(UUID(1))
	private let b: SidebarItem.ID = .tab(UUID(2))

	@Test
	internal func onlyACountGoingUpShakes() {
		#expect(SidebarResetShake.isReset(from: [a: 0], to: [a: 1]))
		#expect(SidebarResetShake.isReset(from: [a: 0, b: 1], to: [a: 0, b: 2]))
		#expect(!SidebarResetShake.isReset(from: [a: 1], to: [a: 1]))
	}

	@Test
	internal func aSplitMemberJoiningOrLeavingDoesntShake() {
		// B, reset before, leaves A's split, then joins again.
		#expect(!SidebarResetShake.isReset(from: [a: 0, b: 1], to: [a: 0]))
		#expect(!SidebarResetShake.isReset(from: [a: 0], to: [a: 0, b: 1]))
	}
}
