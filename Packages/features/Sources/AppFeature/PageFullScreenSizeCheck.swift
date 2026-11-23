import CoreGraphics
import Foundation

/// One look at a page in full screen beside, or without, the window's sidebar (DEV-1096): the size
/// the layout gives the page, which is the window less the sidebar while it shows, against the size
/// the page reports. The page full-screen smoke waits until they agree, and says what it last saw
/// when they never do.
///
/// DEV-1183: a look also has the size of the page's view where the layout put it, how long since
/// the page's report count last went up, and whether the window is visible, so a timeout names the
/// side that's behind (`Lag`) instead of only the two sizes.
internal struct PageFullScreenSizeCheck: Equatable, CustomStringConvertible {
	/// Within this many points, as the page reports whole CSS pixels.
	internal static let tolerance: CGFloat = 1

	/// The page reports every 100 ms, so a title whose count hasn't gone up for this long, ten
	/// reports' worth, stopped reaching the app.
	internal static let staleReport: TimeInterval = 1

	internal var window: CGSize

	/// Whether the page in full screen shows the sidebar beside it, or nil when no page is.
	internal var showsSidebar: Bool?
	internal var sidebarWidth: CGFloat

	/// The page's own size while its element is in full screen, or nil before it says so.
	internal var reported: CGSize?

	/// The size of the page's view in the window, or nil while it has no host.
	internal var pageView: CGSize?

	/// Seconds since the page's report count last went up, or nil when it doesn't count them.
	internal var sinceLastReport: TimeInterval?

	/// Whether any of the window is visible on screen.
	internal var windowIsVisible: Bool

	internal init(
		window: CGSize,
		showsSidebar: Bool?,
		sidebarWidth: CGFloat,
		reported: CGSize?,
		pageView: CGSize? = nil,
		sinceLastReport: TimeInterval? = nil,
		windowIsVisible: Bool = true
	) {
		self.window = window
		self.showsSidebar = showsSidebar
		self.sidebarWidth = sidebarWidth
		self.reported = reported
		self.pageView = pageView
		self.sinceLastReport = sinceLastReport
		self.windowIsVisible = windowIsVisible
	}

	/// The page's area in the layout now.
	internal var expected: CGSize {
		.init(width: window.width - (showsSidebar == true ? sidebarWidth : 0), height: window.height)
	}

	/// The sidebar is as asked, and the page reports the size the layout gives it.
	internal func isSettled(showingSidebar: Bool) -> Bool {
		guard showsSidebar == showingSidebar, let reported else { return false }
		return Self.matches(reported, expected)
	}

	/// Which side keeps the page from the size it should have: the first that's behind, going from
	/// the store to the page's title. Nil once settled.
	internal func lag(showingSidebar: Bool) -> Lag? {
		guard !isSettled(showingSidebar: showingSidebar) else { return nil }
		guard showsSidebar == showingSidebar else { return .sidebar }
		guard reported != nil else { return .page }
		guard windowIsVisible else { return .window }
		guard let pageView, Self.matches(pageView, expected) else { return .layout }
		if let sinceLastReport, sinceLastReport >= Self.staleReport { return .title }
		return .renderer
	}

	internal var description: String {
		let sidebar: String = switch showsSidebar {
		case true?: "shown(\(Self.points(sidebarWidth)))"
		case false?: "hidden"
		case nil: "no page in full screen"
		}
		return "sidebar=\(sidebar) window=\(Self.size(window)) expected=\(Self.size(expected)) "
		+ "reported=\(reported.map(Self.size) ?? "none") pageView=\(pageView.map(Self.size) ?? "none") "
		+ "lastReport=\(sinceLastReport.map { String(format: "%.1fs", $0) } ?? "uncounted") "
		+ "windowVisible=\(windowIsVisible)"
	}

	/// The side that's behind when a page in full screen doesn't have the size the layout gives it.
	internal enum Lag: String, Equatable {
		/// The store's sidebar for the page isn't the one ⌘S asked for.
		case sidebar

		/// The page isn't in full screen, or its title doesn't say so.
		case page

		/// The window isn't visible, so AppKit, SwiftUI and Chromium may hold its layout and frames.
		case window

		/// The page's view doesn't have the area the layout should give it: the app's layout is behind.
		case layout

		/// The page's view has its area, but the page's reports stopped reaching the app's snapshot.
		case title

		/// The page's view has its area and the page keeps reporting another size: Chromium never
		/// resized the page.
		case renderer
	}

	private static func matches(
		_ size: CGSize,
		_ expected: CGSize
	) -> Bool {
		abs(size.width - expected.width) <= tolerance
		&& abs(size.height - expected.height) <= tolerance
	}

	private static func size(_ size: CGSize) -> String {
		"\(points(size.width))x\(points(size.height))"
	}

	private static func points(_ value: CGFloat) -> String {
		value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
	}
}
