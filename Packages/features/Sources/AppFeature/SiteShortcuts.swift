import AppUI
import BrowserCore
import Foundation
import _ComposableArchitecture

/// The keys a site may take before Arx (DEV-1264, DEV-1073): the commands whose Conflict
/// resolution isn't Arx (DEV-1332), by their current shortcuts, and ⌘Z and ⇧⌘Z (`PageFirstKey`).
///
/// - Site: the page gets the press. A key it leaves runs Arx's command at once; a key it uses
///   stays the page's.
/// - Both, and ⌘Z and ⇧⌘Z: the same, and a key the page used shows a toast ("Press ⌘K again to
///   open the command bar"); pressing it again within the window runs Arx's command. ⌘Z and ⇧⌘Z
///   skip the toast once the person has been on the page for more than two seconds, so a canvas
///   editor keeps its undo.
/// - Delayed: Arx holds the press (`held`) with the toast. Pressed again within the window, the
///   keys run Arx's command and the page sees neither press; otherwise `release` hands the press
///   to the key monitor, which gives it to the page if it still has focus on the same document.
///
/// The window is 2 seconds the first time a command's keys are used on a tab, then 1 second.
public struct SiteShortcutState: Equatable, Sendable {
	/// The page whose view has keyboard focus, and since when.
	public var focus: Focus?

	/// The keys let through to the page, oldest first, until the engine says whether the page
	/// used each. A few at most: the engine follows as many.
	public var offered: [Press]

	/// A key the page used, whose next press runs Arx's command.
	public var armed: Armed?

	/// The toast saying so.
	public var notice: Notice?
	public var noticeGeneration: Int

	/// A Delayed press Arx is holding until its window ends or the keys are pressed again.
	public var held: Held?

	/// Held presses whose window ended: the key monitor gives each to its page, or drops it.
	public var release: [Press]

	/// The commands whose keys were used on each page, for the window's length: 2 seconds the
	/// first time on a tab, then 1.
	public var usedOnPage: [Page: Set<PageFirstKey>]

	public init(
		focus: Focus? = nil,
		offered: [Press] = [],
		armed: Armed? = nil,
		notice: Notice? = nil,
		noticeGeneration: Int = 0,
		held: Held? = nil,
		release: [Press] = [],
		usedOnPage: [Page: Set<PageFirstKey>] = [:]
	) {
		self.focus = focus
		self.offered = offered
		self.armed = armed
		self.notice = notice
		self.noticeGeneration = noticeGeneration
		self.held = held
		self.release = release
		self.usedOnPage = usedOnPage
	}

	/// A page's view, by identity: the view that took keyboard focus.
	public struct Page: Hashable, Sendable {
		public var rawValue: UInt

		public init(_ rawValue: UInt) {
			self.rawValue = rawValue
		}
	}

	/// One key press, as the engine reports it back.
	public struct Key: Hashable, Sendable {
		public var keyCode: UInt16
		public var modifierFlags: UInt64
		public var timestamp: TimeInterval

		public init(
			keyCode: UInt16,
			modifierFlags: UInt64,
			timestamp: TimeInterval
		) {
			self.keyCode = keyCode
			self.modifierFlags = modifierFlags
			self.timestamp = timestamp
		}
	}

	public struct Focus: Equatable, Sendable {
		public var page: Page
		public var since: Date

		public init(page: Page, since: Date) {
			self.page = page
			self.since = since
		}
	}

	public struct Press: Equatable, Sendable {
		public var key: Key
		public var action: PageFirstKey
		public var page: Page

		/// The window that shows the toast; `nil` for one with no toast, such as Page PiP's.
		public var windowID: UUID?

		/// The shortcut as the menu shows it, such as ⌘K.
		public var shortcut: String

		/// Whether the page using this key arms the second press. Off for a key pressed before
		/// a second press ran, whose late answer mustn't start another.
		public var arms: Bool = true

		/// Site, Both or Delayed (DEV-1332). ⌘Z and ⇧⌘Z follow Both's rules.
		public var resolution: ShortcutConflictResolution = .both

		/// How long a second press counts, set as the press arrives.
		public var window: TimeInterval = SiteShortcutState.secondPressInterval

		/// The page's address when the keys were pressed: a held press is given only to the same
		/// document.
		public var url: URL?

		public init(
			key: Key,
			action: PageFirstKey,
			page: Page,
			windowID: UUID?,
			shortcut: String,
			resolution: ShortcutConflictResolution = .both,
			url: URL? = nil
		) {
			self.key = key
			self.action = action
			self.page = page
			self.windowID = windowID
			self.shortcut = shortcut
			self.resolution = resolution
			self.url = url
		}
	}

	public struct Armed: Equatable, Sendable {
		public var action: PageFirstKey
		public var page: Page
		public var until: Date

		public init(action: PageFirstKey, page: Page, until: Date) {
			self.action = action
			self.page = page
			self.until = until
		}
	}

	public struct Notice: Equatable, Sendable {
		public var windowID: UUID
		public var action: PageFirstKey
		public var shortcut: String

		public init(windowID: UUID, action: PageFirstKey, shortcut: String) {
			self.windowID = windowID
			self.action = action
			self.shortcut = shortcut
		}
	}

	/// A Delayed press being held, until `until`.
	public struct Held: Equatable, Sendable {
		public var press: Press
		public var until: Date
		public var generation: Int

		public init(press: Press, until: Date, generation: Int) {
			self.press = press
			self.until = until
			self.generation = generation
		}
	}

	/// How long a second press of ⌘Z or ⇧⌘Z runs Arx's undo: while the toast is up. Commands'
	/// keys use Conflict resolution's window instead (DEV-1332).
	public static let secondPressInterval: TimeInterval = 2.5

	/// Pages remembered for the window's length; past this, the oldest memory is cleared.
	public static let usedPagesLimit: Int = 64

	/// Whether a held press may still go to its page: the page has focus, on the same address.
	/// A tab switch or a navigation during the window drops it, so it never reaches the wrong
	/// document.
	public static func delivers(
		_ press: Press,
		focusedPage: Page?,
		currentURL: URL?
	) -> Bool {
		focusedPage == press.page && currentURL == press.url
	}

	/// How many keys wait for the engine's answer, as many as it follows.
	public static let offeredLimit: Int = 4

	/// Whether the key should go to the page: true for a key the reducer let through.
	public func letsThrough(_ key: Key) -> Bool {
		offered.contains { $0.key == key }
	}

	/// Whether Arx is holding the key for Delayed (DEV-1332).
	public func holds(_ key: Key) -> Bool {
		held?.press.key == key
	}
}

@Reducer
internal struct SiteShortcuts {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.date.now)
	private var now

	@Dependency(\.continuousClock)
	private var clock

	private enum Cancellation: Hashable {
		case noticeTimer
		case heldTimer
	}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.pageTookKeyFocus) { state, page in
			state.siteShortcuts.focus = .init(page: page, since: now)
			if state.siteShortcuts.armed?.page != page { state.siteShortcuts.armed = nil }

			// Another tab: a held press is dropped, never given to the wrong page (DEV-1332).
			guard let held = state.siteShortcuts.held, held.press.page != page else { return .none }

			state.siteShortcuts.held = nil
			return .merge(.cancel(id: Cancellation.heldTimer), dismissNotice(&state))
		}

		Pullback(\.ui.pageFirstKeyPressed) { state, value in
			var press = value

			// Delayed's second press: Arx's command, and the page sees neither press (DEV-1332).
			if
				let held = state.siteShortcuts.held,
				held.press.action == press.action,
				held.press.page == press.page,
				now < held.until
			{
				state.siteShortcuts.held = nil
				return .merge(.cancel(id: Cancellation.heldTimer), dismissNotice(&state))
			}
			if
				let armed = state.siteShortcuts.armed,
				armed.action == press.action,
				armed.page == press.page,
				now < armed.until
			{
				// The second press: Arx's command runs, and the page doesn't see it. Earlier presses
				// still waiting for the page keep their answer, but don't arm it again.
				state.siteShortcuts.armed = nil
				for index in state.siteShortcuts.offered.indices
				where state.siteShortcuts.offered[index].action == press.action
					&& state.siteShortcuts.offered[index].page == press.page {
					state.siteShortcuts.offered[index].arms = false
				}
				return dismissNotice(&state)
			}
			state.siteShortcuts.armed = nil
			if case .command = press.action {
				press.window = ShortcutConflictResolution.window(firstUseOnTab: noteUse(of: press, in: &state))
			}

			// Another key while one is held: the held one goes to the page first.
			var effects: [Effect<Action>] = []
			if let held = state.siteShortcuts.held {
				state.siteShortcuts.held = nil
				state.siteShortcuts.release.append(held.press)
				effects.append(.cancel(id: Cancellation.heldTimer))
			}
			guard press.resolution == .delayed else {
				state.siteShortcuts.offered.append(press)
				if state.siteShortcuts.offered.count > SiteShortcutState.offeredLimit {
					state.siteShortcuts.offered.removeFirst()
				}
				return .merge(effects)
			}

			// Delayed: Arx holds the keys for the window, with the toast at once.
			let generation = state.siteShortcuts.noticeGeneration + 1
			state.siteShortcuts.held = .init(
				press: press,
				until: now.addingTimeInterval(press.window),
				generation: generation
			)
			effects.append(showNotice(for: press, &state))
			effects.append(
				.run { [clock, window = press.window] send in
					try await clock.sleep(for: .milliseconds(Int(window * 1000)))
					await send(.event(.siteShortcutHeldKeyExpired(generation)))
				}
				.cancellable(id: Cancellation.heldTimer, cancelInFlight: true)
			)
			return .merge(effects)
		}

		Pullback(\.event.siteShortcutHeldKeyExpired) { state, generation in
			guard let held = state.siteShortcuts.held, held.generation == generation else { return .none }

			state.siteShortcuts.held = nil
			state.siteShortcuts.release.append(held.press)
			return dismissNotice(&state)
		}

		// The key monitor gave a released press to its page, which answers as for Site, or dropped it.
		Pullback(\.ui.heldKeyDelivered) { state, press in
			state.siteShortcuts.release.removeAll { $0.key == press.key }
			var delivered = press
			delivered.resolution = .site
			state.siteShortcuts.offered.append(delivered)
			if state.siteShortcuts.offered.count > SiteShortcutState.offeredLimit {
				state.siteShortcuts.offered.removeFirst()
			}
			return .none
		}

		Pullback(\.ui.heldKeyDropped) { state, key in
			state.siteShortcuts.release.removeAll { $0.key == key }
			return .none
		}

		Pullback(\.ui.pageLeftKey) { state, key in
			state.siteShortcuts.offered.removeAll { $0.key == key }
			return .none
		}

		Pullback(\.ui.pageUsedKey) { state, key in
			guard let index = state.siteShortcuts.offered.firstIndex(where: { $0.key == key })
			else { return .none }

			let press = state.siteShortcuts.offered.remove(at: index)

			// Site: the page wins, with no toast and no second press (DEV-1332).
			guard press.arms, press.resolution == .both else { return .none }
			if press.action.rule == .settledFocus, hasSettled(on: press.page, state.siteShortcuts.focus) {
				return .none
			}
			state.siteShortcuts.armed = .init(
				action: press.action,
				page: press.page,
				until: now.addingTimeInterval(press.window)
			)
			return showNotice(for: press, &state)
		}

		Pullback(\.ui.dismissSiteShortcutNotice) { state in
			dismissNotice(&state)
		}

		Pullback(\.event.siteShortcutNoticeExpired) { state, generation in
			guard generation == state.siteShortcuts.noticeGeneration else { return .none }

			state.siteShortcuts.notice = nil
			return .none
		}
	}

	/// The toast for a press, gone when its window ends: "Press ⌘K again to open the command bar".
	private func showNotice(
		for press: SiteShortcutState.Press,
		_ state: inout State
	) -> Effect<Action> {
		guard let windowID = press.windowID else { return dismissNotice(&state) }

		state.siteShortcuts.notice = .init(
			windowID: windowID,
			action: press.action,
			shortcut: press.shortcut
		)
		state.siteShortcuts.noticeGeneration += 1

		// One toast at the corner at a time.
		state.discardLinkFeedback(in: windowID)
		let generation = state.siteShortcuts.noticeGeneration

		// ⌘Z's toast stays as long as any toast; a command's as long as its window (DEV-1332).
		let duration: Duration = if case .command = press.action {
			.milliseconds(Int(press.window * 1000))
		} else {
			ArxToastMetrics.duration
		}
		let timer: Effect<Action> = .run { [clock] send in
			try await clock.sleep(for: duration)
			await send(.event(.siteShortcutNoticeExpired(generation)))
		}
		.cancellable(id: Cancellation.noticeTimer)
		return .concatenate(.cancel(id: Cancellation.noticeTimer), timer)
	}

	/// Notes that the press's command was used on its page. Returns whether it's the first time
	/// on this tab, which gives the longer window.
	private func noteUse(
		of press: SiteShortcutState.Press,
		in state: inout State
	) -> Bool {
		if
			state.siteShortcuts.usedOnPage[press.page] == nil,
			state.siteShortcuts.usedOnPage.count >= SiteShortcutState.usedPagesLimit
		{
			state.siteShortcuts.usedOnPage.removeAll()
		}
		return state.siteShortcuts.usedOnPage[press.page, default: []].insert(press.action).inserted
	}

	/// Whether the person has been on the page for more than two seconds. A page whose focus Arx
	/// didn't see arrive counts as settled: the site keeps its key, as it would without Arx.
	private func hasSettled(on page: SiteShortcutState.Page, _ focus: SiteShortcutState.Focus?) -> Bool {
		guard let focus, focus.page == page else { return true }

		return now.timeIntervalSince(focus.since) > PageFirstKey.settledFocusInterval
	}

	private func dismissNotice(_ state: inout State) -> Effect<Action> {
		guard state.siteShortcuts.notice != nil else { return .none }

		state.siteShortcuts.notice = nil
		return .cancel(id: Cancellation.noticeTimer)
	}
}
