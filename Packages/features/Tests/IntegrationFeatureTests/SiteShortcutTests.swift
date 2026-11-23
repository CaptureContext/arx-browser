@testable import AppFeature
import AppKit
import BrowserCore
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// The keys a site may take before Arx (DEV-1264, DEV-1073). The page gets the first press; a key
/// it used shows a toast, and a second press runs Arx's command. ⌘Z and ⇧⌘Z stay the site's
/// without a toast once the person has been on the page for more than two seconds.
extension IntegrationFeatureTests {
	// MARK: - ⌘K, ⌘L and ⌘S

	@Test
	internal func aKeyThePageUsedShowsTheToastAndASecondPressRunsArxs() async throws {
		let clock: TestClock<Duration> = .init()
		let now: LockIsolated<Date> = .init(.init(timeIntervalSinceReferenceDate: 1_000))
		let state = siteShortcutState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.date = .init { now.value }
		}
		let first = press(.command(.commandBar), at: 1, window: state.main.id)

		await store.send(.ui(.pageFirstKeyPressed(first))) {
			$0.siteShortcuts.offered = [first]
			$0.siteShortcuts.usedOnPage = [Self.sitePage: [.command(.commandBar)]]
		}
		#expect(store.state.siteShortcuts.letsThrough(first.key))

		await store.send(.ui(.pageUsedKey(first.key))) {
			$0.siteShortcuts.offered = []
			$0.siteShortcuts.armed = .init(
				action: .command(.commandBar),
				page: Self.sitePage,
				until: now.value.addingTimeInterval(2)
			)
			$0.siteShortcuts.notice = .init(windowID: state.main.id, action: .command(.commandBar), shortcut: "⌘K")
			$0.siteShortcuts.noticeGeneration = 1
		}
		#expect(SiteShortcutToast.title(try #require(store.state.siteShortcuts.notice))
			== "Press ⌘K again to open the command bar")

		// The second press, a moment later: Arx's command, and the page doesn't see it.
		now.withValue { $0.addTimeInterval(1) }
		let second = press(.command(.commandBar), at: 2, window: state.main.id)
		await store.send(.ui(.pageFirstKeyPressed(second))) {
			$0.siteShortcuts.armed = nil
			$0.siteShortcuts.notice = nil
		}
		#expect(!store.state.siteShortcuts.letsThrough(second.key))
		await store.finish()
	}

	@Test
	internal func aKeyThePageLeftRunsArxsCommandWithNoToast() async throws {
		let state = siteShortcutState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date = .constant(.init(timeIntervalSinceReferenceDate: 1_000))
		}
		let pressed = press(.command(.address), at: 1, window: state.main.id)

		await store.send(.ui(.pageFirstKeyPressed(pressed))) {
			$0.siteShortcuts.offered = [pressed]
			$0.siteShortcuts.usedOnPage = [Self.sitePage: [.command(.address)]]
		}
		await store.send(.ui(.pageLeftKey(pressed.key))) {
			$0.siteShortcuts.offered = []
		}

		// A late or foreign report changes nothing.
		await store.send(.ui(.pageUsedKey(pressed.key)))
	}

	@Test
	internal func theToastGoesAfterItsDurationAndTheKeyIsThePagesAgain() async throws {
		let clock: TestClock<Duration> = .init()
		let now: LockIsolated<Date> = .init(.init(timeIntervalSinceReferenceDate: 1_000))
		let state = siteShortcutState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.date = .init { now.value }
		}
		let first = press(.command(.toggleSidebar), at: 1, window: state.main.id, shortcut: "⌘S")

		await store.send(.ui(.pageFirstKeyPressed(first))) {
			$0.siteShortcuts.offered = [first]
			$0.siteShortcuts.usedOnPage = [Self.sitePage: [.command(.toggleSidebar)]]
		}
		await store.send(.ui(.pageUsedKey(first.key))) {
			$0.siteShortcuts.offered = []
			$0.siteShortcuts.armed = .init(
				action: .command(.toggleSidebar),
				page: Self.sitePage,
				until: now.value.addingTimeInterval(2)
			)
			$0.siteShortcuts.notice = .init(windowID: state.main.id, action: .command(.toggleSidebar), shortcut: "⌘S")
			$0.siteShortcuts.noticeGeneration = 1
		}
		// The toast goes as the window ends: 2 seconds, the first time on the tab (DEV-1332).
		await clock.advance(by: .milliseconds(2_000))
		await store.receive(\.event.siteShortcutNoticeExpired) {
			$0.siteShortcuts.notice = nil
		}

		// Later than the second-press window: the page gets the key again, with a 1-second window now.
		now.withValue { $0.addTimeInterval(3) }
		let later = press(.command(.toggleSidebar), at: 5, window: state.main.id, shortcut: "⌘S", firstUse: false)
		await store.send(.ui(.pageFirstKeyPressed(later))) {
			$0.siteShortcuts.armed = nil
			$0.siteShortcuts.offered = [later]
		}
	}

	@Test
	internal func anotherPageTakingFocusEndsTheSecondPress() async throws {
		let clock: TestClock<Duration> = .init()
		let now: LockIsolated<Date> = .init(.init(timeIntervalSinceReferenceDate: 1_000))
		var state = siteShortcutState()
		state.siteShortcuts.armed = .init(action: .command(.commandBar), page: Self.sitePage, until: now.value + 2)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.date = .init { now.value }
		}
		let other: SiteShortcutState.Page = .init(2)

		await store.send(.ui(.pageTookKeyFocus(other))) {
			$0.siteShortcuts.focus = .init(page: other, since: now.value)
			$0.siteShortcuts.armed = nil
		}
	}

	/// DEV-1229: ⌘K has no two-second rule. Long after arriving on a page that uses it, the page
	/// still gets the first press with the toast, and a second press opens the command bar.
	@Test
	internal func theCommandBarKeepsItsSecondPressLongAfterArrivingOnThePage() async throws {
		let clock: TestClock<Duration> = .init()
		let now: LockIsolated<Date> = .init(.init(timeIntervalSinceReferenceDate: 1_000))
		let state = siteShortcutState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.date = .init { now.value }
		}

		await store.send(.ui(.pageTookKeyFocus(Self.sitePage))) {
			$0.siteShortcuts.focus = .init(page: Self.sitePage, since: now.value)
		}
		now.withValue { $0.addTimeInterval(PageFirstKey.settledFocusInterval * 10) }
		let first = press(.command(.commandBar), at: 1, window: state.main.id)
		await store.send(.ui(.pageFirstKeyPressed(first))) {
			$0.siteShortcuts.offered = [first]
			$0.siteShortcuts.usedOnPage = [Self.sitePage: [.command(.commandBar)]]
		}
		await store.send(.ui(.pageUsedKey(first.key))) {
			$0.siteShortcuts.offered = []
			$0.siteShortcuts.armed = .init(
				action: .command(.commandBar),
				page: Self.sitePage,
				until: now.value.addingTimeInterval(2)
			)
			$0.siteShortcuts.notice = .init(windowID: state.main.id, action: .command(.commandBar), shortcut: "⌘K")
			$0.siteShortcuts.noticeGeneration = 1
		}

		let second = press(.command(.commandBar), at: 2, window: state.main.id)
		await store.send(.ui(.pageFirstKeyPressed(second))) {
			$0.siteShortcuts.armed = nil
			$0.siteShortcuts.notice = nil
		}
		#expect(!store.state.siteShortcuts.letsThrough(second.key))
		await store.finish()
	}

	// MARK: - ⌘Z and ⇧⌘Z

	@Test(arguments: [PageFirstKey.undo, .redo])
	internal func undoStaysTheSitesWithNoToastAfterTwoSecondsOnThePage(_ action: PageFirstKey) async throws {
		let now: LockIsolated<Date> = .init(.init(timeIntervalSinceReferenceDate: 1_000))
		let state = siteShortcutState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date = .init { now.value }
		}

		await store.send(.ui(.pageTookKeyFocus(Self.sitePage))) {
			$0.siteShortcuts.focus = .init(page: Self.sitePage, since: now.value)
		}
		now.withValue { $0.addTimeInterval(2.1) }
		for index in 1...2 {
			// Every press goes to the site, the second one too.
			let pressed = press(action, at: Double(index), window: state.main.id)
			await store.send(.ui(.pageFirstKeyPressed(pressed))) {
				$0.siteShortcuts.offered = [pressed]
			}
			await store.send(.ui(.pageUsedKey(pressed.key))) {
				$0.siteShortcuts.offered = []
			}
		}
	}

	@Test(arguments: [PageFirstKey.undo, .redo])
	internal func undoJustAfterArrivingGoesToTheSiteOnceThenToArx(_ action: PageFirstKey) async throws {
		let clock: TestClock<Duration> = .init()
		let now: LockIsolated<Date> = .init(.init(timeIntervalSinceReferenceDate: 1_000))
		let state = siteShortcutState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.date = .init { now.value }
		}
		let shortcut = action == .undo ? "⌘Z" : "⇧⌘Z"

		await store.send(.ui(.pageTookKeyFocus(Self.sitePage))) {
			$0.siteShortcuts.focus = .init(page: Self.sitePage, since: now.value)
		}
		now.withValue { $0.addTimeInterval(1.5) }
		let first = press(action, at: 1, window: state.main.id, shortcut: shortcut)
		await store.send(.ui(.pageFirstKeyPressed(first))) {
			$0.siteShortcuts.offered = [first]
		}
		await store.send(.ui(.pageUsedKey(first.key))) {
			$0.siteShortcuts.offered = []
			$0.siteShortcuts.armed = .init(
				action: action,
				page: Self.sitePage,
				until: now.value.addingTimeInterval(SiteShortcutState.secondPressInterval)
			)
			$0.siteShortcuts.notice = .init(windowID: state.main.id, action: action, shortcut: shortcut)
			$0.siteShortcuts.noticeGeneration = 1
		}
		#expect(SiteShortcutToast.title(try #require(store.state.siteShortcuts.notice))
			== (action == .undo ? "Press ⌘Z again to undo in Arx" : "Press ⇧⌘Z again to redo in Arx"))

		now.withValue { $0.addTimeInterval(1) }
		let second = press(action, at: 2, window: state.main.id, shortcut: shortcut)
		await store.send(.ui(.pageFirstKeyPressed(second))) {
			$0.siteShortcuts.armed = nil
			$0.siteShortcuts.notice = nil
		}
		#expect(!store.state.siteShortcuts.letsThrough(second.key))
		await store.finish()
	}

	@Test(arguments: [PageFirstKey.undo, .redo])
	internal func undoTheSiteDoesntUseIsArxsAtOnce(_ action: PageFirstKey) async throws {
		let now: LockIsolated<Date> = .init(.init(timeIntervalSinceReferenceDate: 1_000))
		let state = siteShortcutState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date = .init { now.value }
		}

		await store.send(.ui(.pageTookKeyFocus(Self.sitePage))) {
			$0.siteShortcuts.focus = .init(page: Self.sitePage, since: now.value)
		}
		let pressed = press(action, at: 1, window: state.main.id)
		await store.send(.ui(.pageFirstKeyPressed(pressed))) {
			$0.siteShortcuts.offered = [pressed]
		}
		await store.send(.ui(.pageLeftKey(pressed.key))) {
			$0.siteShortcuts.offered = []
		}
	}

	@Test
	internal func theCommandBarTheAddressAndTheSidebarStillGoToSitesFirst() {
		// Conflict resolution's defaults (DEV-1332): ⌘K and ⌘S are Both, the site first and then a
		// second press; ⌘L is Arx's.
		let defaults: [ShortcutConflictOverride] = []
		#expect([.commandBar, .toggleSidebar].allSatisfy { defaults.resolution(for: $0) == .both })
		#expect(defaults.resolution(for: .address) == .arx)
		#expect(BrowserCommand.commandBar.shortcut == .init(key: "k"))
		#expect(BrowserCommand.address.shortcut == .init(key: "l"))
		#expect(BrowserCommand.toggleSidebar.shortcut == .init(key: "s"))
		#expect(PageFirstKey.command(.commandBar).rule == .secondPress)
		#expect(PageFirstKey.undo.rule == .settledFocus)
		#expect(PageFirstKey.redo.rule == .settledFocus)
	}

	@Test
	@MainActor
	internal func aHeldKeyRepeatsWhereItsPressWent() throws {
		let press = try #require(Self.keyEvent("z", code: 6, modifiers: .command, repeat: false))
		let repeated = try #require(Self.keyEvent("z", code: 6, modifiers: .command, repeat: true))
		let redo = try #require(Self.keyEvent("z", code: 6, modifiers: [.command, .shift], repeat: true))
		let held: HeldPageFirstKey = .init(press, wentToPage: true)

		#expect(held.matches(repeated))
		#expect(!held.matches(redo))
		#expect(held.wentToPage)
	}

	@Test
	internal func quickPressesEachGetTheirAnswer() async throws {
		let state = siteShortcutState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date = .constant(.init(timeIntervalSinceReferenceDate: 1_000))
		}
		let first = press(.undo, at: 1, window: state.main.id, shortcut: "⌘Z")
		let second = press(.undo, at: 2, window: state.main.id, shortcut: "⌘Z")

		// A busy page answers neither before the second press.
		await store.send(.ui(.pageFirstKeyPressed(first))) {
			$0.siteShortcuts.offered = [first]
		}
		await store.send(.ui(.pageFirstKeyPressed(second))) {
			$0.siteShortcuts.offered = [first, second]
		}
		#expect(store.state.siteShortcuts.letsThrough(first.key))
		await store.send(.ui(.pageLeftKey(first.key))) {
			$0.siteShortcuts.offered = [second]
		}
		await store.send(.ui(.pageLeftKey(second.key))) {
			$0.siteShortcuts.offered = []
		}
	}

	@Test
	internal func aLateAnswerFromBeforeTheSecondPressDoesntArmItAgain() async throws {
		let clock: TestClock<Duration> = .init()
		let now: LockIsolated<Date> = .init(.init(timeIntervalSinceReferenceDate: 1_000))
		let state = siteShortcutState()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.date = .init { now.value }
		}
		let first = press(.command(.toggleSidebar), at: 1, window: state.main.id, shortcut: "⌘S")
		let second = press(.command(.toggleSidebar), at: 2, window: state.main.id, shortcut: "⌘S", firstUse: false)
		var secondDisarmed = second
		secondDisarmed.arms = false

		await store.send(.ui(.pageFirstKeyPressed(first))) {
			$0.siteShortcuts.offered = [first]
			$0.siteShortcuts.usedOnPage = [Self.sitePage: [.command(.toggleSidebar)]]
		}
		await store.send(.ui(.pageFirstKeyPressed(second))) { $0.siteShortcuts.offered = [first, second] }
		await store.send(.ui(.pageUsedKey(first.key))) {
			$0.siteShortcuts.offered = [second]
			$0.siteShortcuts.armed = .init(
				action: .command(.toggleSidebar),
				page: Self.sitePage,
				until: now.value.addingTimeInterval(2)
			)
			$0.siteShortcuts.notice = .init(windowID: state.main.id, action: .command(.toggleSidebar), shortcut: "⌘S")
			$0.siteShortcuts.noticeGeneration = 1
		}

		// The second press runs Arx's command; the press still waiting won't arm it again.
		let third = press(.command(.toggleSidebar), at: 3, window: state.main.id, shortcut: "⌘S")
		await store.send(.ui(.pageFirstKeyPressed(third))) {
			$0.siteShortcuts.armed = nil
			$0.siteShortcuts.notice = nil
			$0.siteShortcuts.offered = [secondDisarmed]
		}
		await store.send(.ui(.pageUsedKey(second.key))) {
			$0.siteShortcuts.offered = []
		}
		await store.finish()
	}

	// MARK: - Fixtures

	@MainActor
	private static func keyEvent(
		_ key: String,
		code: UInt16,
		modifiers: NSEvent.ModifierFlags,
		repeat isRepeat: Bool
	) -> NSEvent? {
		NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: modifiers,
			timestamp: 1,
			windowNumber: 0,
			context: nil,
			characters: key,
			charactersIgnoringModifiers: key,
			isARepeat: isRepeat,
			keyCode: code
		)
	}

	private static let sitePage: SiteShortcutState.Page = .init(1)

	private func siteShortcutState() -> AppFeature.State {
		let organization = fixture()
		return AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
	}

	private func press(
		_ action: PageFirstKey,
		at timestamp: TimeInterval,
		window: UUID,
		shortcut: String = "⌘K",
		firstUse: Bool = true
	) -> SiteShortcutState.Press {
		var press: SiteShortcutState.Press = .init(
			key: .init(keyCode: 40, modifierFlags: 1 << 20, timestamp: timestamp),
			action: action,
			page: Self.sitePage,
			windowID: window,
			shortcut: shortcut
		)

		// A command's window: 2 seconds the first time on the tab, then 1 (DEV-1332).
		if case .command = action { press.window = ShortcutConflictResolution.window(firstUseOnTab: firstUse) }
		return press
	}
}
