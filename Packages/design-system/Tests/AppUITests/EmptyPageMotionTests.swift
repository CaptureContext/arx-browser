#if DEBUG
// Frames are counted only in Debug builds.
import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// DEV-1248: the homepage keeps moving while its window is on screen, focused or not, and stops
/// while something covers it or its window is off screen.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to run a timeline")
)
internal struct EmptyPageMotionTests {
	/// The test's window is never key and the test runner is never the active app, so it stands
	/// for a window that has lost focus. Before DEV-1248 the homepage drew no frames here.
	@Test
	internal func itKeepsMovingInAWindowThatLostFocus() {
		let frames = Self.frames(paused: false, windowIsVisible: true)
		#expect(frames > 3, "\(frames) frames in an unfocused window")
	}

	@Test
	internal func itStopsWhileSomethingCoversIt() {
		let frames = Self.frames(paused: true, windowIsVisible: true)
		#expect(frames <= 1, "\(frames) frames while covered")
	}

	@Test
	internal func itStopsWhileItsWindowIsOffScreen() {
		let frames = Self.frames(paused: false, windowIsVisible: false)
		#expect(frames <= 1, "\(frames) frames in a hidden window")
	}

	@Test
	internal func itHoldsForAnyOneReason() {
		#expect(!EmptyPageTimeline<EmptyView>.isHeld(isPaused: false, reduceMotion: false, windowIsVisible: true))
		#expect(EmptyPageTimeline<EmptyView>.isHeld(isPaused: true, reduceMotion: false, windowIsVisible: true))
		#expect(EmptyPageTimeline<EmptyView>.isHeld(isPaused: false, reduceMotion: true, windowIsVisible: true))
		#expect(EmptyPageTimeline<EmptyView>.isHeld(isPaused: false, reduceMotion: false, windowIsVisible: false))
	}

	/// The Spaces overview covers the page only once it has opened over the whole window, and
	/// only while the sidebar holding it is in view.
	@Test
	internal func theSpacesOverviewCoversThePageOnceOpenAndInView() {
		typealias Layout = BrowserSidebarLayout<EmptyView, EmptyView>
		#expect(Layout.isPageCovered(libraryFillsWindow: true, libraryProgress: 1, isSidebarVisible: true))
		#expect(!Layout.isPageCovered(libraryFillsWindow: true, libraryProgress: 0.5, isSidebarVisible: true))
		#expect(!Layout.isPageCovered(libraryFillsWindow: false, libraryProgress: 1, isSidebarVisible: true))
		#expect(!Layout.isPageCovered(libraryFillsWindow: true, libraryProgress: 1, isSidebarVisible: false))
	}

	/// The homepage's timeline frames in half a second, hosted in a window kept off every screen.
	private static func frames(
		paused: Bool,
		windowIsVisible: Bool
	) -> Int {
		let size: CGSize = .init(width: 800, height: 600)
		let host = NSHostingView(rootView: BrowserEmptyPage(isCustomizable: false)
			.environment(\.emptyPageMotionPaused, paused)
			.environment(\.emptyPageWindowIsVisible, windowIsVisible)
			.frame(width: size.width, height: size.height))
		host.frame = .init(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		defer { window.close() }

		// Let the first frame land before counting.
		host.layoutSubtreeIfNeeded()
		RunLoop.main.run(until: .now.addingTimeInterval(0.2))
		return RenderTrace.recording {
			RunLoop.main.run(until: .now.addingTimeInterval(0.5))
		}["EmptyPageTimeline.frame", default: 0]
	}
}
#endif
