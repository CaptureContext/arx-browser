#if DEBUG
import AppKit
import AppUI
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// The full-screen layout ticket's hand check (DEV-912), on the app's own window.
///
/// 1. Entering macOS full screen (⌃⌘F) closes the traffic lights' space in the sidebar: the
///    sidebar toggle moves from beside the window controls to the toolbar's leading padding, and
///    starts moving before the system's transition ends. The window's buttons leave the sidebar.
/// 2. With the pointer at the screen's top edge, macOS shows the title bar over the page, and the
///    page's frame doesn't move.
/// 3. Leaving full screen brings the space and the buttons back, in step the same way, and the
///    window returns to its frame.
///
/// The toggle's place is read through the app's own accessibility tree, which needs no
/// permission. The top edge is reached by moving the pointer there; if this Mac doesn't reveal
/// the title bar for a moved pointer, the phase says so and fails rather than passing a page
/// that had no title bar to move it.
@MainActor
internal enum WindowFullScreenSmoke {
	/// The toggle's distance from the sidebar's leading edge, at rest.
	internal struct Inset: Equatable, Sendable {
		internal static let windowed: CGFloat = BrowserMetrics.Toolbar.leadingPadding
		+ BrowserMetrics.Toolbar.windowControlsWidth + BrowserMetrics.Toolbar.spacing
		internal static let fullScreen: CGFloat = BrowserMetrics.Toolbar.leadingPadding
	}

	/// One reading of the toggle's inset during a transition.
	internal struct Sample: Equatable, Sendable {
		internal var time: TimeInterval
		internal var inset: CGFloat
	}

	/// How a transition moved the toggle, from its samples.
	internal struct Motion: Equatable, Sendable {
		/// When the toggle first left its starting place, if it did.
		internal var started: TimeInterval?

		/// Where it ended.
		internal var end: CGFloat?

		/// Samples strictly between the two resting places: frames of the animation itself.
		internal var steps: Int

		internal init(
			samples: [Sample],
			from start: CGFloat,
			to end: CGFloat,
			tolerance: CGFloat = 2
		) {
			self.started = samples.first { abs($0.inset - start) > tolerance }?.time
			self.end = samples.last?.inset
			let low = min(start, end) + tolerance
			let high = max(start, end) - tolerance
			self.steps = samples.count { $0.inset > low && $0.inset < high }
		}

		/// Moved after the transition began, before it finished, and came to rest at `end`.
		///
		/// `steps` isn't required: the app's own accessibility tree may report SwiftUI's settled
		/// layout rather than the frame on screen mid-animation, so a correct build could show none.
		/// The phase prints it, and the animation's smoothness stays something to look at.
		internal func isInStep(
			began: TimeInterval,
			finished: TimeInterval,
			end target: CGFloat,
			tolerance: CGFloat = 2
		) -> Bool {
			guard let started, let end else { return false }
			return started >= began && started <= finished && abs(end - target) <= tolerance
		}
	}

	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		window: NSWindow
	) async throws {
		guard !window.styleMask.contains(.fullScreen) else { throw HandCheckSmoke.Failure("the window starts in full screen") }
		guard store.main.sidebar.sidebarIsVisible else { throw HandCheckSmoke.Failure("the sidebar is hidden") }
		guard let tab = store.main.viewer.item.tab?.id else { throw HandCheckSmoke.Failure("no tab") }

		window.makeKeyAndOrderFront(nil)
		let frame = window.frame
		try await HandCheckSmoke.wait("toggle found", context: { describeButtons(in: window) }) {
			inset(in: window) != nil
		}
		guard let windowedInset = inset(in: window), abs(windowedInset - Inset.windowed) <= 2
		else { throw HandCheckSmoke.Failure("windowed toggle inset \(String(describing: inset(in: window))), expected \(Inset.windowed)") }
		print("ARX_HAND_CHECK_FULL_SCREEN_TOGGLE frame=\(toggle(in: window).map { NSStringFromRect($0.accessibilityFrame()) } ?? "none")")
		guard buttonsAreInSidebar(window) else { throw HandCheckSmoke.Failure("the window buttons aren't in the sidebar before full screen") }

		// 1. Into full screen.
		let entering = try await transition(window, entering: true)
		let enterMotion = Motion(samples: entering.samples, from: Inset.windowed, to: Inset.fullScreen)
		guard enterMotion.isInStep(began: entering.began, finished: entering.finished, end: Inset.fullScreen)
		else { throw HandCheckSmoke.Failure("entering: the space didn't close in step: \(report(enterMotion, entering))") }
		guard !buttonsAreInSidebar(window) else { throw HandCheckSmoke.Failure("full screen: the window buttons stayed in the sidebar") }
		print("ARX_HAND_CHECK_FULL_SCREEN_ENTERED \(report(enterMotion, entering))")

		// 2. The top edge.
		try await hoverTopEdge(engine: engine, tab: tab, window: window)

		// 3. Out of full screen.
		let leaving = try await transition(window, entering: false)
		let leaveMotion = Motion(samples: leaving.samples, from: Inset.fullScreen, to: Inset.windowed)
		guard leaveMotion.isInStep(began: leaving.began, finished: leaving.finished, end: Inset.windowed)
		else { throw HandCheckSmoke.Failure("leaving: the space didn't come back in step: \(report(leaveMotion, leaving))") }
		try await HandCheckSmoke.wait("window buttons back in the sidebar") { buttonsAreInSidebar(window) }
		try await HandCheckSmoke.wait("window frame restored", context: { "\(window.frame) != \(frame)" }) {
			window.frame.equalTo(frame)
		}
		print("ARX_HAND_CHECK_FULL_SCREEN_LEFT \(report(leaveMotion, leaving))")
		print(HandCheckSmoke.Phase.fullScreen.successMarker)
	}

	// MARK: - Transitions

	/// When the transition's will- and did-notifications arrived.
	@MainActor
	private final class Marks {
		var began: TimeInterval?
		var finished: TimeInterval?
	}

	private struct Transition {
		var began: TimeInterval
		var finished: TimeInterval
		var samples: [Sample]

		/// When the window buttons changed sides, sidebar or title bar: SwiftUI's own layout, as
		/// against the accessibility frames, which may trail it.
		var buttonsMoved: TimeInterval?
	}

	/// Toggles full screen and samples the toggle's inset every frame until the transition ends
	/// and a little after it, for the animation's tail.
	private static func transition(
		_ window: NSWindow,
		entering: Bool
	) async throws -> Transition {
		let marks = Marks()
		let center = NotificationCenter.default
		let names: (NSNotification.Name, NSNotification.Name) = entering
		? (NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification)
		: (NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification)
		let observers = [
			center.addObserver(forName: names.0, object: window, queue: .main) { _ in
				MainActor.assumeIsolated { marks.began = ProcessInfo.processInfo.systemUptime }
			},
			center.addObserver(forName: names.1, object: window, queue: .main) { _ in
				MainActor.assumeIsolated { marks.finished = ProcessInfo.processInfo.systemUptime }
			},
		]
		defer { observers.forEach(center.removeObserver) }

		var samples: [Sample] = []
		var buttonsMoved: TimeInterval?
		let buttonsWereInSidebar = buttonsAreInSidebar(window)
		window.toggleFullScreen(nil)
		let deadline = ProcessInfo.processInfo.systemUptime + 10
		var settled: TimeInterval?
		while ProcessInfo.processInfo.systemUptime < deadline {
			let now = ProcessInfo.processInfo.systemUptime
			if let inset = inset(in: window) { samples.append(.init(time: now, inset: inset)) }
			if buttonsMoved == nil, buttonsAreInSidebar(window) != buttonsWereInSidebar { buttonsMoved = now }
			if marks.finished != nil, settled == nil { settled = now }

			// SwiftUI's 0.5 s ease can outlast the system's transition a little.
			if let settled, now - settled > 0.7 { break }
			try await Task.sleep(for: .milliseconds(8))
		}
		guard let began = marks.began, let finished = marks.finished
		else { throw HandCheckSmoke.Failure("\(entering ? "entering" : "leaving") full screen didn't finish") }
		guard window.styleMask.contains(.fullScreen) == entering
		else { throw HandCheckSmoke.Failure("the window's full screen is \(!entering) after the transition") }
		return .init(began: began, finished: finished, samples: samples, buttonsMoved: buttonsMoved)
	}

	private static func report(
		_ motion: Motion,
		_ transition: Transition
	) -> String {
		let started = motion.started.map { String(format: "%.3f", $0 - transition.began) } ?? "never"
		let buttons = transition.buttonsMoved.map { String(format: "%.3f", $0 - transition.began) } ?? "never"
		return "began=0 buttons=\(buttons) started=\(started) finished=\(String(format: "%.3f", transition.finished - transition.began)) "
		+ "end=\(motion.end.map { String(format: "%.1f", $0) } ?? "nil") steps=\(motion.steps) samples=\(transition.samples.count)"
	}

	// MARK: - The top edge

	private static func hoverTopEdge(
		engine: ChromiumBrowserEngine,
		tab: BrowserCore.Tab.ID,
		window: NSWindow
	) async throws {
		guard let page = engine.contentHostFixtureView(tab), page.window === window, let screen = window.screen
		else { throw HandCheckSmoke.Failure("no page view in full screen") }

		func pageFrame() -> NSRect { window.convertToScreen(page.convert(page.bounds, to: nil)) }
		let before = pageFrame()
		let away = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
		movePointer(to: away)
		try await Task.sleep(for: .milliseconds(500))

		movePointer(to: NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 1))
		var revealed = false
		var frames: Set<String> = []
		let deadline = ProcessInfo.processInfo.systemUptime + 3
		while ProcessInfo.processInfo.systemUptime < deadline {
			frames.insert(NSStringFromRect(pageFrame()))
			if titleBarIsShown(window: window, screen: screen) { revealed = true }
			try await Task.sleep(for: .milliseconds(16))
		}
		let during = pageFrame()
		movePointer(to: away)
		try await Task.sleep(for: .milliseconds(800))

		guard revealed else {
			throw HandCheckSmoke.Failure(
				"the title bar never showed with the pointer at the top edge; this Mac may not reveal it for a moved pointer: check by hand"
			)
		}
		guard frames.count == 1, during.equalTo(before)
		else { throw HandCheckSmoke.Failure("the page moved while the title bar showed: \(frames.sorted())") }
		print("ARX_HAND_CHECK_FULL_SCREEN_TOP_EDGE page=\(NSStringFromRect(before))")
	}

	/// Moves the pointer, in AppKit's screen coordinates, and tells the system it moved.
	private static func movePointer(to point: NSPoint) {
		let height = NSScreen.screens.first?.frame.height ?? 0
		let location = CGPoint(x: point.x, y: height - point.y)
		CGWarpMouseCursorPosition(location)
		CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)?
			.post(tap: .cghidEventTap)
	}

	/// In full screen the window's buttons live in the title bar macOS slides down from the top
	/// edge: it shows once their frame is on the screen.
	private static func titleBarIsShown(
		window: NSWindow,
		screen: NSScreen
	) -> Bool {
		guard
			let button = window.standardWindowButton(.closeButton),
			let host = button.window,
			host.isVisible
		else { return false }

		let frame = host.convertToScreen(button.convert(button.bounds, to: nil))
		return frame.minY >= screen.frame.minY && frame.maxY <= screen.frame.maxY
	}

	// MARK: - The sidebar toggle

	/// Whether the window's close button sits in the sidebar's window controls.
	private static func buttonsAreInSidebar(_ window: NSWindow) -> Bool {
		window.standardWindowButton(.closeButton)?.superview is WindowControlsView
	}

	/// The sidebar toggle's distance from the window's leading edge, from the app's own
	/// accessibility tree. The sidebar is pinned on the leading edge in the fixture.
	private static func inset(in window: NSWindow) -> CGFloat? {
		guard let toggle = toggle(in: window) else { return nil }
		return toggle.accessibilityFrame().minX - window.frame.minX
	}

	private static func toggle(in window: NSWindow) -> NSAccessibilityProtocol? {
		let elements = HandCheckSmoke.accessibilityElements(in: window)

		// By its help, when an assistive client has SwiftUI fill its elements in.
		let help = String.localized(.appUI.sidebar.toggleHelp)
		if let toggle = elements.first(where: { $0.accessibilityRole() == .button && $0.accessibilityHelp() == help }) {
			return toggle
		}

		// Else by its place: without an assistive client attached, SwiftUI's in-process tree gives
		// the toggle no role, help or identifier, only its frame. It's the toolbar's first small
		// element after the window buttons, or first of all in full screen.
		let top = window.frame.maxY

		// Past the window buttons' view while it's in the sidebar, the elements inside it included.
		let leading = window.standardWindowButton(.closeButton)?.superview
			.flatMap { $0 as? WindowControlsView }
			.map { window.convertToScreen($0.convert($0.bounds, to: nil)).maxX - 1 }
			?? window.frame.minX
		return elements
			.filter { element in
				let frame = element.accessibilityFrame()
				let role = element.accessibilityRole()
				return role != .button && role != .group
					&& frame.minX >= leading
					&& top - frame.maxY >= 0 && top - frame.maxY < BrowserMetrics.Toolbar.height
					&& frame.width > 0 && frame.width <= 40
			}
			.min { $0.accessibilityFrame().minX < $1.accessibilityFrame().minX }
	}

	private static func describeButtons(in window: NSWindow) -> String {
		// What sits in the toolbar's corner, whatever its role: the toggle should be there.
		let top = window.frame.maxY
		return HandCheckSmoke.accessibilityElements(in: window)
			.filter {
				let frame = $0.accessibilityFrame()
				return frame.minX - window.frame.minX < 200 && top - frame.maxY < 60 && frame.width < 100
			}
			.prefix(20)
			.map {
				"\($0.accessibilityRole()?.rawValue ?? "?")[\($0.accessibilityHelp() ?? "")|\($0.accessibilityLabel() ?? "")|\($0.accessibilityIdentifier())]@\(Int($0.accessibilityFrame().minX - window.frame.minX))"
			}
			.joined(separator: ", ")
	}
}
#endif
