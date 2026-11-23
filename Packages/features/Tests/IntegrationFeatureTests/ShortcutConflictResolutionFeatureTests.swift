@testable import AppFeature
import BrowserCore
import CustomDump
import Foundation
@testable import SettingsFeature
import Testing
import _ComposableArchitecture

/// Conflict resolution in Settings › Shortcuts and on the keys (DEV-1332): Arx, Site, Both and
/// Delayed, with the window of 2 seconds the first time on a tab, then 1.
@Suite(.dependencies)
@MainActor
internal struct ShortcutConflictResolutionFeatureTests {
	// MARK: - Settings

	@Test
	internal func thePickerStoresAChoiceAndTheDefaultStoresNothing() async {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		store.state.$keyboardShortcuts.withLock { $0 = [] }
		store.state.$shortcutConflictChoices.withLock { $0 = [] }

		await store.send(.ui(.shortcutConflictResolutionChanged(.reload, .delayed)))
		expectNoDifference(store.state.shortcutConflictChoices, [.init(command: .reload, resolution: .delayed)])

		await store.send(.ui(.shortcutConflictResolutionChanged(.reload, .site)))
		expectNoDifference(store.state.shortcutConflictChoices, [])

		// The recorded shortcuts are untouched by either.
		expectNoDifference(store.state.keyboardShortcuts, [])
	}

	@Test
	internal func commandsThatKeepTheirKeysAndKeysWithoutCommandOfferNoChoice() async {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		store.state.$keyboardShortcuts.withLock { $0 = [] }
		store.state.$shortcutConflictChoices.withLock { $0 = [] }

		// New Little Arx window always stays Arx's, and so does Quit.
		await store.send(.ui(.shortcutConflictResolutionChanged(.littleArx, .site)))
		await store.send(.ui(.shortcutConflictResolutionChanged(.quit, .both)))

		// Space 1's ⌃1 can't be offered to a page first.
		await store.send(.ui(.shortcutConflictResolutionChanged(.space1, .delayed)))

		// Nor can a command whose only key was removed.
		await store.send(.ui(.assignKeyboardShortcut(.reload, nil)))
		await store.send(.ui(.shortcutConflictResolutionChanged(.reload, .both)))
		expectNoDifference(store.state.shortcutConflictChoices, [])

		// Given a ⌘ key again, it can.
		await store.send(.ui(.assignKeyboardShortcut(.reload, .init(key: "r"))))
		await store.send(.ui(.shortcutConflictResolutionChanged(.reload, .both)))
		expectNoDifference(store.state.shortcutConflictChoices, [.init(command: .reload, resolution: .both)])
	}

	@Test
	internal func resetAllRestoresEveryDefaultChoice() async {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		store.state.$keyboardShortcuts.withLock { $0 = [] }
		store.state.$shortcutConflictChoices.withLock { $0 = [.init(command: .reload, resolution: .arx)] }

		await store.send(.ui(.resetKeyboardShortcuts))
		expectNoDifference(store.state.shortcutConflictChoices, [])
	}

	@Test
	internal func aCommandIsCustomizedByItsKeysItsAliasOrItsChoice() {
		var state = SettingsFeature.State()
		state.$keyboardShortcuts.withLock { $0 = [] }
		state.$commandAliases.withLock { $0 = [] }
		state.$shortcutConflictChoices.withLock { $0 = [] }
		#expect(!BrowserCommand.allCases.contains(where: state.isCustomized))

		state.$keyboardShortcuts.withLock { $0.setShortcut(nil, for: .reload) }
		state.$commandAliases.withLock { $0.setAlias("pin", for: .pinTab) }
		state.$shortcutConflictChoices.withLock { $0.setResolution(.arx, for: .findInPage) }
		expectNoDifference(
			Set(BrowserCommand.allCases.filter(state.isCustomized)),
			[.reload, .pinTab, .findInPage]
		)

		// A choice set back to its default isn't a customization.
		state.$shortcutConflictChoices.withLock { $0.setResolution(.site, for: .findInPage) }
		#expect(!state.isCustomized(.findInPage))
	}

	/// With an engine that follows every key Arx can bind (DEV-1332), ⌃ shortcuts get a choice.
	@Test
	internal func anEngineThatFollowsEveryKeyOffersChoicesForControlKeys() async {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		store.state.$keyboardShortcuts.withLock { $0 = [] }
		store.state.$shortcutConflictChoices.withLock { $0 = [] }

		await store.send(.ui(.shortcutConflictResolutionChanged(.space1, .both)))
		expectNoDifference(store.state.shortcutConflictChoices, [])

		await store.send(.event(.followsAllShortcutKeys(true)))
		await store.send(.ui(.shortcutConflictResolutionChanged(.space1, .both)))
		expectNoDifference(store.state.shortcutConflictChoices, [.init(command: .space1, resolution: .both)])

		// Still never for a command that keeps its keys.
		await store.send(.ui(.shortcutConflictResolutionChanged(.littleArx, .site)))
		expectNoDifference(store.state.shortcutConflictChoices, [.init(command: .space1, resolution: .both)])
	}

	// MARK: - Site

	/// Site: the page wins at once. A key it uses stays its own, with no toast and no second press;
	/// a key it leaves runs Arx's command (the key monitor does, on `pageLeftKey`).
	@Test
	internal func siteGivesThePageTheKeysWithNoToastOrSecondPress() async {
		let (store, clock, now) = keyStore()
		let first = press(.reload, .site, at: 1)
		await store.send(.ui(.pageFirstKeyPressed(first)))
		#expect(store.state.siteShortcuts.letsThrough(first.key))
		await store.send(.ui(.pageUsedKey(first.key)))
		#expect(store.state.siteShortcuts.armed == nil)
		#expect(store.state.siteShortcuts.notice == nil)

		// Pressed again at once: still the page's.
		now.withValue { $0.addTimeInterval(0.2) }
		let second = press(.reload, .site, at: 2)
		await store.send(.ui(.pageFirstKeyPressed(second)))
		#expect(store.state.siteShortcuts.letsThrough(second.key))

		// The page doesn't use it: the key monitor runs Arx's command.
		await store.send(.ui(.pageLeftKey(second.key)))
		#expect(!store.state.siteShortcuts.letsThrough(second.key))
		await clock.advance(by: .seconds(3))
	}

	// MARK: - Both

	@Test
	internal func bothArmsTheSecondPressForTwoSecondsTheFirstTimeOnATabThenOne() async throws {
		let (store, clock, now) = keyStore()
		let first = press(.findInPage, .both, at: 1)
		await store.send(.ui(.pageFirstKeyPressed(first)))
		await store.send(.ui(.pageUsedKey(first.key)))
		expectNoDifference(store.state.siteShortcuts.armed?.until, now.value.addingTimeInterval(2))
		let title = SiteShortcutToast.title(try #require(store.state.siteShortcuts.notice))
		#expect(title.contains("⌘F"))

		// Inside the window: Arx's command, and the page doesn't get the keys.
		now.withValue { $0.addTimeInterval(1.9) }
		let second = press(.findInPage, .both, at: 2)
		await store.send(.ui(.pageFirstKeyPressed(second)))
		#expect(!store.state.siteShortcuts.letsThrough(second.key))
		#expect(store.state.siteShortcuts.armed == nil)
		#expect(store.state.siteShortcuts.notice == nil)

		// Used again on this tab: a 1-second window now.
		now.withValue { $0.addTimeInterval(5) }
		let third = press(.findInPage, .both, at: 3)
		await store.send(.ui(.pageFirstKeyPressed(third)))
		await store.send(.ui(.pageUsedKey(third.key)))
		expectNoDifference(store.state.siteShortcuts.armed?.until, now.value.addingTimeInterval(1))

		// Outside it: the page gets the keys again.
		now.withValue { $0.addTimeInterval(1.2) }
		let fourth = press(.findInPage, .both, at: 4)
		await store.send(.ui(.pageFirstKeyPressed(fourth)))
		#expect(store.state.siteShortcuts.letsThrough(fourth.key))
		await clock.advance(by: .seconds(3))
	}

	/// Both shows the toast and opens the window only when the page used the keys
	/// ("Use Both" (`promptAfterConsumedByWebView`). Left, Arx's command just runs (DEV-1332).
	@Test
	internal func bothWithoutThePageUsingTheKeysRunsArxsAtOnceWithNoToast() async {
		let (store, clock, _) = keyStore()
		let first = press(.findInPage, .both, at: 1)
		await store.send(.ui(.pageFirstKeyPressed(first)))
		await store.send(.ui(.pageLeftKey(first.key)))
		#expect(store.state.siteShortcuts.armed == nil)
		#expect(store.state.siteShortcuts.notice == nil)
		#expect(!store.state.siteShortcuts.letsThrough(first.key))
		await clock.advance(by: .seconds(3))
	}

	@Test
	internal func theToastGoesWhenTheWindowEnds() async {
		let (store, clock, _) = keyStore()
		let first = press(.findInPage, .both, at: 1)
		await store.send(.ui(.pageFirstKeyPressed(first)))
		await store.send(.ui(.pageUsedKey(first.key)))
		#expect(store.state.siteShortcuts.notice != nil)

		await clock.advance(by: .milliseconds(1_999))
		#expect(store.state.siteShortcuts.notice != nil)
		await clock.advance(by: .milliseconds(1))
		await store.receive(\.event.siteShortcutNoticeExpired)
		#expect(store.state.siteShortcuts.notice == nil)
	}

	// MARK: - Delayed

	@Test
	internal func delayedHoldsTheKeysAndASecondPressRunsArxsWithoutThePage() async {
		let (store, clock, now) = keyStore()
		let first = press(.findInPage, .delayed, at: 1)
		await store.send(.ui(.pageFirstKeyPressed(first)))
		#expect(store.state.siteShortcuts.holds(first.key))
		#expect(!store.state.siteShortcuts.letsThrough(first.key))
		#expect(store.state.siteShortcuts.notice != nil)

		now.withValue { $0.addTimeInterval(1.5) }
		let second = press(.findInPage, .delayed, at: 2)
		await store.send(.ui(.pageFirstKeyPressed(second)))
		#expect(store.state.siteShortcuts.held == nil)
		#expect(store.state.siteShortcuts.notice == nil)
		#expect(store.state.siteShortcuts.release.isEmpty)
		#expect(!store.state.siteShortcuts.letsThrough(second.key))

		// The held press's timer was cancelled: nothing reaches the page later.
		await clock.advance(by: .seconds(3))
		#expect(store.state.siteShortcuts.release.isEmpty)
	}

	@Test
	internal func delayedGivesThePageTheKeysWhenTheWindowEnds() async {
		let (store, clock, now) = keyStore()
		let first = press(.findInPage, .delayed, at: 1)
		await store.send(.ui(.pageFirstKeyPressed(first)))

		await clock.advance(by: .milliseconds(1_999))
		#expect(store.state.siteShortcuts.holds(first.key))
		await clock.advance(by: .milliseconds(1))
		await store.receive(\.event.siteShortcutHeldKeyExpired)
		#expect(store.state.siteShortcuts.held == nil)
		#expect(store.state.siteShortcuts.notice == nil)
		expectNoDifference(store.state.siteShortcuts.release.map(\.key), [first.key])

		// The key monitor gives it to the page, which answers as for Site.
		await store.send(.ui(.heldKeyDelivered(first)))
		#expect(store.state.siteShortcuts.release.isEmpty)
		#expect(store.state.siteShortcuts.letsThrough(first.key))
		expectNoDifference(store.state.siteShortcuts.offered.last?.resolution, .site)

		// Used again on the tab: 1 second.
		now.withValue { $0.addTimeInterval(5) }
		let again = press(.findInPage, .delayed, at: 5)
		await store.send(.ui(.pageFirstKeyPressed(again)))
		expectNoDifference(store.state.siteShortcuts.held?.until, now.value.addingTimeInterval(1))

		// A second press after the window is a new first press, held again.
		await clock.advance(by: .seconds(1))
		await store.receive(\.event.siteShortcutHeldKeyExpired)
		now.withValue { $0.addTimeInterval(1.1) }
		let late = press(.findInPage, .delayed, at: 6)
		await store.send(.ui(.pageFirstKeyPressed(late)))
		#expect(store.state.siteShortcuts.holds(late.key))
		await clock.advance(by: .seconds(3))
	}

	@Test
	internal func aTabSwitchDuringTheWindowDropsTheHeldKeys() async {
		let (store, clock, _) = keyStore()
		let first = press(.findInPage, .delayed, at: 1)
		await store.send(.ui(.pageFirstKeyPressed(first)))
		#expect(store.state.siteShortcuts.holds(first.key))

		await store.send(.ui(.pageTookKeyFocus(.init(2))))
		#expect(store.state.siteShortcuts.held == nil)
		#expect(store.state.siteShortcuts.notice == nil)

		await clock.advance(by: .seconds(3))
		#expect(store.state.siteShortcuts.release.isEmpty)
	}

	/// The key monitor's last check before it gives a released press to the page: the same page
	/// with focus, on the same document. A navigation during the window drops it.
	@Test
	internal func aHeldPressGoesOnlyToTheSameDocument() {
		var held = press(.findInPage, .delayed, at: 1)
		held.url = URL(string: "https://docs.example/1")
		#expect(SiteShortcutState.delivers(held, focusedPage: Self.page, currentURL: held.url))
		#expect(!SiteShortcutState.delivers(held, focusedPage: SiteShortcutState.Page(2), currentURL: held.url))
		#expect(!SiteShortcutState.delivers(held, focusedPage: Self.page, currentURL: URL(string: "https://docs.example/2")))
		#expect(!SiteShortcutState.delivers(held, focusedPage: nil, currentURL: nil))
	}

	@Test
	internal func anotherKeyWhileOneIsHeldReleasesTheHeldOneFirst() async {
		let (store, clock, _) = keyStore()
		let held = press(.findInPage, .delayed, at: 1)
		await store.send(.ui(.pageFirstKeyPressed(held)))
		let other = press(.printPage, .both, at: 2)
		await store.send(.ui(.pageFirstKeyPressed(other)))
		#expect(store.state.siteShortcuts.held == nil)
		expectNoDifference(store.state.siteShortcuts.release.map(\.key), [held.key])
		#expect(store.state.siteShortcuts.letsThrough(other.key))
		await clock.advance(by: .seconds(3))
	}

	// MARK: - Fixtures

	private static let page: SiteShortcutState.Page = .init(1)

	private func keyStore() -> (TestStoreOf<AppFeature>, TestClock<Duration>, LockIsolated<Date>) {
		let clock: TestClock<Duration> = .init()
		let now: LockIsolated<Date> = .init(.init(timeIntervalSinceReferenceDate: 1_000))
		let organization = IntegrationFeatureTests().fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.date = .init { now.value }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return (store, clock, now)
	}

	private func press(
		_ command: BrowserCommand,
		_ resolution: ShortcutConflictResolution,
		at timestamp: TimeInterval
	) -> SiteShortcutState.Press {
		.init(
			key: .init(keyCode: 3, modifierFlags: 1 << 20, timestamp: timestamp),
			action: .command(command),
			page: Self.page,
			windowID: UUID(70),
			shortcut: command.shortcut?.display ?? "",
			resolution: resolution
		)
	}
}
