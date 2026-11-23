import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import LittleArxFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1138: Little Arx windows left unused for Settings' interval are archived,
/// and ones in use or with something going on stay.
@Suite(.dependencies)
@MainActor
internal struct LittleArxAutoArchivingTests {
	nonisolated private static let window: UUID = UUID(91)
	nonisolated private static let start: Date = Date(timeIntervalSince1970: 1_000)

	@Test
	internal func anIdleWindowIsArchivedOnceTheIntervalPasses() async {
		let clock = LockIsolated(Self.start)
		let closed = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = Self.store(clock: clock) {
			$0.browserEngine.close = { id in closed.withValue { $0.append(id) } }
		}
		let tab = store.littleWindows[id: Self.window]!.tab

		store.send(.littleWindows(.element(id: Self.window, action: .ui(.lostFocus))))
		expectNoDifference(store.littleArxIdleSince[Self.window], Self.start)

		clock.setValue(Self.start.addingTimeInterval(10 * 60))
		await store.send(.archiveInactiveTabs).finish()
		#expect(store.littleWindows[id: Self.window] != nil)

		clock.setValue(Self.start.addingTimeInterval(16 * 60))
		await store.send(.archiveInactiveTabs).finish()
		#expect(store.littleWindows[id: Self.window] == nil)
		expectNoDifference(closed.value, [tab.id])

		// As a manual close keeps it: in the Tab Archive of its space.
		#expect(store.workspace.archive.contains { $0.tab.id == tab.id })
	}

	@Test
	internal func theKeyWindowIsNeverArchived() async {
		let clock = LockIsolated(Self.start)
		let store = Self.store(clock: clock)

		store.send(.littleWindows(.element(id: Self.window, action: .ui(.lostFocus))))
		store.send(.ui(.focusWindow(Self.window)))
		#expect(store.littleArxIdleSince[Self.window] == nil)

		clock.setValue(Self.start.addingTimeInterval(60 * 60))
		await store.send(.archiveInactiveTabs).finish()
		#expect(store.littleWindows[id: Self.window] != nil)
	}

	@Test
	internal func somethingTypedKeepsTheWindowAndStartsItsClockOver() async {
		let clock = LockIsolated(Self.start)
		let store = Self.store(clock: clock) {
			$0.browserEngine.evaluateScript = { _, _, _, _, _ in .value("true") }
		}

		store.send(.littleWindows(.element(id: Self.window, action: .ui(.lostFocus))))
		let later = Self.start.addingTimeInterval(20 * 60)
		clock.setValue(later)
		await store.send(.archiveInactiveTabs).finish()
		#expect(store.littleWindows[id: Self.window] != nil)
		expectNoDifference(store.littleArxIdleSince[Self.window], later)
		#expect(store.littleArxArchiving.isEmpty)
	}

	@Test
	internal func aPageThatAsksToStayKeepsTheWindowAndStartsItsClockOver() async {
		let clock = LockIsolated(Self.start)
		let store = Self.store(clock: clock) {
			$0.browserEngine.permitsClosing = { _ in false }
		}

		store.send(.littleWindows(.element(id: Self.window, action: .ui(.lostFocus))))
		let later = Self.start.addingTimeInterval(20 * 60)
		clock.setValue(later)
		await store.send(.archiveInactiveTabs).finish()
		let little = store.littleWindows[id: Self.window]
		#expect(little != nil)
		#expect(little?.isClosing == false)
		expectNoDifference(store.littleArxIdleSince[Self.window], later)
	}

	@Test
	internal func nothingIsArchivedWithTheFeatureFlagOffOrTheSettingAtNever() {
		var state = Self.state()
		state.littleArxIdleSince[Self.window] = Self.start
		let later = Self.start.addingTimeInterval(2 * 24 * 60 * 60)

		state.littleArxAutoArchiveEnabled = false
		#expect(state.littleArxWindowsDue(now: later).isEmpty)

		state.littleArxAutoArchiveEnabled = true
		state.settings.$linkClicks.withLock { $0.littleArxArchiveInterval = nil }
		#expect(state.littleArxWindowsDue(now: later).isEmpty)

		state.settings.$linkClicks.withLock { $0.littleArxArchiveInterval = .day }
		expectNoDifference(state.littleArxWindowsDue(now: later).map(\.id), [Self.window])
	}

	@Test
	internal func aWindowThatNeverBecameKeyStartsItsClockAtTheFirstLook() {
		var state = Self.state()
		let later = Self.start.addingTimeInterval(60 * 60)
		#expect(state.littleArxWindowsDue(now: later).isEmpty)
		expectNoDifference(state.littleArxIdleSince[Self.window], later)
	}

	@Test
	internal func windowsWithSomethingGoingOnAreSpared() {
		let later = Self.start.addingTimeInterval(60 * 60)
		func due(_ change: (inout AppFeature.State) -> Void) -> Bool {
			var state = Self.state()
			state.littleArxIdleSince[Self.window] = Self.start
			change(&state)
			return !state.littleArxWindowsDue(now: later).isEmpty
		}

		#expect(due { _ in })
		#expect(!due { $0.littleWindows[id: Self.window]?.viewer.navigation.isLoading = true })
		#expect(!due { $0.littleWindows[id: Self.window]?.peekID = UUID(5) })
		#expect(!due { $0.littleWindows[id: Self.window]?.isPromoting = true })
		#expect(!due { $0.littleArxKeyWindowID = Self.window })
		// Floating as Page PiP, it's on screen though not key (DEV-1112).
		#expect(!due { $0.littleWindows[id: Self.window]?.isPictureInPicture = true })
		// A sign-in popup it opened is still open.
		#expect(!due { state in
			let opener = state.littleWindows[id: Self.window]!
			var child = LittleArxFeature.State(
				id: UUID(92),
				spaceID: opener.spaceID,
				tab: .init(
					id: .init(rawValue: UUID(93)),
					profileID: opener.tab.profileID,
					restoration: .init(title: "Sign in", url: URL(string: "https://accounts.example/sign-in")!)
				)
			)
			child.openerWindowID = Self.window
			state.littleWindows.append(child)
		})

		// The WebKit page question waits on the person in this window.
		#expect(!due { state in
			let little = state.littleWindows[id: Self.window]!
			state.webKitPrompt = .init(
				id: UUID(94),
				windowID: Self.window,
				request: .init(
					tabID: little.tab.id,
					profileID: little.tab.profileID,
					url: URL(string: "https://open.spotify.com/track/1")!
				)
			)
		})

		// A launcher with only the command bar isn't archived: it closes when it loses focus.
		#expect(!due { $0.littleWindows[id: Self.window]?.isCommandOnly = true })
		// A WebKit page can't be read for drafts nor asked before it closes.
		#expect(!due { $0.webKitTabs.insert($0.littleWindows[id: Self.window]!.tab.id) })
		// Its space is gone: the Tab Archive can't take it there.
		#expect(!due { state in
			let space = state.littleWindows[id: Self.window]!.spaceID
			state.workspace.spaces.remove(id: space)
		})

		// A chat or another page off the web can't go to the Tab Archive, so it isn't closed.
		#expect(!due { $0.littleWindows[id: Self.window]?.tab.restoration.url = URL(string: "arx://chat/1")! })
	}

	@Test
	internal func aWindowUsedWhileItsPageWasAskedStays() {
		var state = Self.state()
		state.littleArxIdleSince[Self.window] = Self.start
		state.littleArxArchiving.insert(Self.window)
		let later = Self.start.addingTimeInterval(60 * 60)
		#expect(state.littleArxIsStillDue(Self.window, now: later))

		state.littleArxKeyWindowID = Self.window
		#expect(!state.littleArxIsStillDue(Self.window, now: later))
	}

	// MARK: - Fixture

	private static func state() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.windowIsOpen = true
		let space = organization.spaces[0]
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(90)),
			profileID: space.profileID,
			restoration: .init(title: "Little", url: URL(string: "https://example.com/little")!)
		)
		state.littleWindows.append(.init(id: window, spaceID: space.id, tab: tab))
		state.littleArxAutoArchiveEnabled = true
		state.settings.$linkClicks.withLock { $0.littleArxArchiveInterval = .fifteenMinutes }
		return state
	}

	private static func store(
		clock: LockIsolated<Date>,
		dependencies: @escaping (inout DependencyValues) -> Void = { _ in }
	) -> StoreOf<AppFeature> {
		Store(initialState: state()) { AppFeature() } withDependencies: {
			$0.date = .init { clock.value }
			$0.uuid = .incrementing
			$0.browserEngine.evaluateScript = { _, _, _, _, _ in .value("false") }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { _ in }
			$0.browserEngine.events = { _ in .finished }
			dependencies(&$0)
		}
	}
}
