import CoreGraphics
import Foundation
import Testing

@testable import AppFeature

/// DEV-1096: the page full-screen smoke's page-size wait settles on the size the layout gives the
/// page now, only with the sidebar as asked, and says what it saw when it doesn't. DEV-1183: it also
/// names the side that's behind.
internal struct PageFullScreenSizeCheckTests {
	private let window: CGSize = .init(width: 1_512, height: 982)

	@Test
	internal func settlesOnTheWindowLessTheSidebarWhileItShows() {
		var check = PageFullScreenSizeCheck(window: window, showsSidebar: true, sidebarWidth: 286, reported: .init(width: 1_226, height: 982))
		#expect(check.expected == .init(width: 1_226, height: 982))
		#expect(check.isSettled(showingSidebar: true))
		// Whole CSS pixels against a fractional sidebar.
		check.sidebarWidth = 285.5
		#expect(check.isSettled(showingSidebar: true))

		let hidden = PageFullScreenSizeCheck(window: window, showsSidebar: false, sidebarWidth: 286, reported: .init(width: 1_512, height: 982))
		#expect(hidden.isSettled(showingSidebar: false))
	}

	/// Before the page reports, while it still has its old size, or with the sidebar not yet as
	/// asked, the wait goes on.
	@Test
	internal func waitsForThePageAndTheSidebarAsAsked() {
		#expect(!PageFullScreenSizeCheck(window: window, showsSidebar: true, sidebarWidth: 286, reported: nil).isSettled(showingSidebar: true))
		let stale = PageFullScreenSizeCheck(window: window, showsSidebar: true, sidebarWidth: 286, reported: .init(width: 1_512, height: 982))
		#expect(!stale.isSettled(showingSidebar: true))
		// ⌘S not yet applied: the page still fills the window, which isn't what was asked for.
		let unapplied = PageFullScreenSizeCheck(window: window, showsSidebar: false, sidebarWidth: 286, reported: .init(width: 1_512, height: 982))
		#expect(!unapplied.isSettled(showingSidebar: true))
		#expect(!PageFullScreenSizeCheck(window: window, showsSidebar: nil, sidebarWidth: 286, reported: nil).isSettled(showingSidebar: false))
		// A window that changed size since: the expectation follows it.
		let resized = PageFullScreenSizeCheck(window: .init(width: 1_440, height: 900), showsSidebar: false, sidebarWidth: 286, reported: .init(width: 1_512, height: 982))
		#expect(!resized.isSettled(showingSidebar: false))
	}

	@Test
	internal func describesBothSidesForATimeout() {
		let check = PageFullScreenSizeCheck(window: window, showsSidebar: true, sidebarWidth: 285.5, reported: .init(width: 1_512, height: 982))
		#expect(check.description
			== "sidebar=shown(285.5) window=1512x982 expected=1226.5x982 reported=1512x982 pageView=none lastReport=uncounted windowVisible=true")
		#expect(PageFullScreenSizeCheck(window: window, showsSidebar: nil, sidebarWidth: 286, reported: nil).description
			== "sidebar=no page in full screen window=1512x982 expected=1512x982 reported=none pageView=none lastReport=uncounted windowVisible=true")
		let counted = PageFullScreenSizeCheck(
			window: window,
			showsSidebar: true,
			sidebarWidth: 286,
			reported: .init(width: 1_512, height: 982),
			pageView: .init(width: 1_226, height: 982),
			sinceLastReport: 0.1,
			windowIsVisible: false
		)
		#expect(counted.description
			== "sidebar=shown(286) window=1512x982 expected=1226x982 reported=1512x982 pageView=1226x982 lastReport=0.1s windowVisible=false")
	}

	/// DEV-1183: a timeout names the side that's behind, going from the store to the page's title.
	@Test
	internal func namesTheSideThatIsBehind() {
		let stale: CGSize = .init(width: 1_512, height: 982)
		let fitted: CGSize = .init(width: 1_226, height: 982)
		func check(
			showsSidebar: Bool? = true,
			reported: CGSize? = stale,
			pageView: CGSize? = fitted,
			sinceLastReport: TimeInterval? = 0.1,
			windowIsVisible: Bool = true
		) -> PageFullScreenSizeCheck {
			.init(
				window: window,
				showsSidebar: showsSidebar,
				sidebarWidth: 286,
				reported: reported,
				pageView: pageView,
				sinceLastReport: sinceLastReport,
				windowIsVisible: windowIsVisible
			)
		}

		#expect(check(reported: fitted).lag(showingSidebar: true) == nil)
		// ⌘S's state never reached the store.
		#expect(check(showsSidebar: false).lag(showingSidebar: true) == .sidebar)
		#expect(check(showsSidebar: nil).lag(showingSidebar: true) == .sidebar)
		// The page left full screen, or its title doesn't say it's in it.
		#expect(check(reported: nil).lag(showingSidebar: true) == .page)
		// A window off screen can hold its layout and frames.
		#expect(check(windowIsVisible: false).lag(showingSidebar: true) == .window)
		// The layout never gave the page's view its area, or it has no host.
		#expect(check(pageView: stale).lag(showingSidebar: true) == .layout)
		#expect(check(pageView: nil).lag(showingSidebar: true) == .layout)
		// The view has its area, but the title stopped changing, even if it changed earlier in the
		// wait: the count hasn't gone up for a second.
		#expect(check(sinceLastReport: 1).lag(showingSidebar: true) == .title)
		#expect(check(sinceLastReport: 14).lag(showingSidebar: true) == .title)
		#expect(check(sinceLastReport: 0.9).lag(showingSidebar: true) == .renderer)
		// The view has its area and the page keeps reporting the old size: the run that timed out.
		#expect(check().lag(showingSidebar: true) == .renderer)
		// An older fixture doesn't count its reports, so the title can't be blamed.
		#expect(check(sinceLastReport: nil).lag(showingSidebar: true) == .renderer)
		// Hiding the sidebar again: the page still has the narrower size.
		let narrowed = PageFullScreenSizeCheck(
			window: window,
			showsSidebar: false,
			sidebarWidth: 286,
			reported: fitted,
			pageView: stale,
			sinceLastReport: 0.1
		)
		#expect(narrowed.lag(showingSidebar: false) == .renderer)
	}
}
