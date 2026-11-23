import AppKit
import Foundation

/// A window a page's full screen puts in and out of macOS full screen: a browser window, which
/// `NSWindow` is. Tests stand in their own.
@MainActor
internal protocol PageFullScreenWindow: AnyObject {
	var isInFullScreen: Bool { get }
	func toggleFullScreen()
}

extension NSWindow: PageFullScreenWindow {
	internal var isInFullScreen: Bool { styleMask.contains(.fullScreen) }

	internal func toggleFullScreen() {
		toggleFullScreen(nil)
	}
}

/// The windows a page in HTML full screen fills (DEV-949). A browser window that isn't in macOS
/// full screen enters it, and leaves it again when the page does; one the person put in full
/// screen stays there. A Little Arx panel takes a full-screen Space of its own the same way,
/// which brings Arx forward (`LittleArxPanel.enterPageFullScreen()`).
///
/// AppKit refuses a full-screen toggle during another one, so a window in transition is
/// reconciled again when its transition ends. Right after a window leaves full screen, AppKit
/// sometimes drops a toggle outright, with no transition and no notification (DEV-965,
/// DEV-1183): the page then fills a window that never went full screen, or a window stays in a
/// full screen the page has left. So a toggle that hasn't started a transition after
/// `retryDelay` is asked again, up to `maximumAttempts` times in all, and it looks again by
/// itself then, though nothing else changed.
@MainActor
internal final class PageFullScreenWindows {
	/// Browser windows that entered macOS full screen for a page, which leave it afterwards.
	internal private(set) var enteredWindowIDs: Set<UUID> = []

	/// A toggle asked of a window, until its transition starts or the window is where it was asked
	/// to be.
	private struct Toggle {
		var toFullScreen: Bool
		var askedAt: ContinuousClock.Instant
		var attempts: Int
	}

	private var toggles: [UUID: Toggle] = [:]
	private var recheck: Task<Void, Never>?
	private var lastUpdate: (@MainActor () -> Void)?
	private let retryDelay: Duration
	private let maximumAttempts: Int
	private let now: @MainActor () -> ContinuousClock.Instant

	internal init(
		retryDelay: Duration = .milliseconds(1500),
		maximumAttempts: Int = 3,
		now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
	) {
		self.retryDelay = retryDelay
		self.maximumAttempts = maximumAttempts
		self.now = now
	}

	/// Brings the windows in line with the page full screen's window, `target`.
	internal func update(
		target: UUID?,
		browserWindow: @escaping @MainActor (UUID) -> (any PageFullScreenWindow)?,
		littleWindows: [UUID: LittleArxPanel],
		isTransitioning: @escaping @MainActor (UUID) -> Bool
	) {
		lastUpdate = { [weak self] in
			self?.update(
				target: target,
				browserWindow: browserWindow,
				littleWindows: littleWindows,
				isTransitioning: isTransitioning
			)
		}

		for id in enteredWindowIDs where id != target {
			guard let window = browserWindow(id) else {
				enteredWindowIDs.remove(id)
				toggles[id] = nil
				continue
			}
			guard !isTransitioning(id) else { continue }

			enteredWindowIDs.remove(id)
			if window.isInFullScreen { ask(window, id: id, toFullScreen: false) }
		}
		for (id, panel) in littleWindows where id != target && panel.isPageFullScreen {
			panel.exitPageFullScreen()
		}
		retryDroppedToggles(target: target, browserWindow: browserWindow, isTransitioning: isTransitioning)

		guard let target else { return }

		if let panel = littleWindows[target] {
			panel.enterPageFullScreen()
			return
		}
		guard
			let window = browserWindow(target),
			!enteredWindowIDs.contains(target),
			!isTransitioning(target),
			!window.isInFullScreen
		else { return }

		enteredWindowIDs.insert(target)
		ask(window, id: target, toFullScreen: true)
	}

	/// Whether the window is in macOS full screen only for a page, which isn't the window's own
	/// state to remember.
	internal func isFullScreenForPage(_ id: UUID) -> Bool {
		enteredWindowIDs.contains(id)
	}

	/// The person took the window out of macOS full screen themselves.
	internal func windowLeftFullScreen(_ id: UUID) {
		enteredWindowIDs.remove(id)
		toggles[id] = nil
	}

	// MARK: - Dropped toggles

	private func ask(
		_ window: any PageFullScreenWindow,
		id: UUID,
		toFullScreen: Bool
	) {
		let earlier = toggles[id].flatMap { $0.toFullScreen == toFullScreen ? $0.attempts : nil } ?? 0
		toggles[id] = .init(toFullScreen: toFullScreen, askedAt: now(), attempts: earlier + 1)
		window.toggleFullScreen()
		scheduleRecheck()
	}

	/// A toggle whose transition started, or whose window is where it was asked to be, or that's
	/// no longer wanted, is forgotten. One whose window is still where it was, with no transition,
	/// `retryDelay` after it was asked, is asked again, until `maximumAttempts`.
	private func retryDroppedToggles(
		target: UUID?,
		browserWindow: (UUID) -> (any PageFullScreenWindow)?,
		isTransitioning: (UUID) -> Bool
	) {
		for (id, toggle) in toggles {
			let wanted = toggle.toFullScreen ? id == target && enteredWindowIDs.contains(id) : id != target

			// The page came back while the window's exit was dropped: it's still in full screen for
			// the page, and leaves when the page does.
			if !toggle.toFullScreen, id == target, browserWindow(id)?.isInFullScreen == true {
				enteredWindowIDs.insert(id)
			}
			guard
				let window = browserWindow(id),
				wanted,
				!isTransitioning(id),
				window.isInFullScreen != toggle.toFullScreen,
				toggle.attempts < maximumAttempts
			else {
				toggles[id] = nil
				continue
			}
			guard toggle.askedAt.duration(to: now()) >= retryDelay
			else { continue }

			ask(window, id: id, toFullScreen: toggle.toFullScreen)
		}
	}

	/// Looks again once a toggle should have started, though nothing else changed meanwhile.
	private func scheduleRecheck() {
		recheck?.cancel()
		let delay = retryDelay
		recheck = Task { @MainActor [weak self] in
			try? await Task.sleep(for: delay)
			guard !Task.isCancelled, let self, !self.toggles.isEmpty else { return }
			self.lastUpdate?()
		}
	}
}
