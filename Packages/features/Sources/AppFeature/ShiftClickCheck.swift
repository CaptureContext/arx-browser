#if DEBUG
import ChromiumBrowserEngine
import Foundation

/// One look at a Shift-click on the app smoke's link page, from the click to the Peek it should
/// open (DEV-1191). The smoke waits until the Peek is idle on the target page, and a timeout names
/// the first step that's behind (`Lag`) instead of only saying no Peek came.
///
/// It holds what the click hit, how far the page's request for a new window got in the engine and
/// the app, and what's on screen now. Page titles are reduced to which fixture page they are.
internal struct ShiftClickCheck: Equatable, CustomStringConvertible {
	/// What the click's point hit in the window when the smoke sent it.
	internal var hit: ClickHit

	/// Which fixture page the source tab shows now.
	internal var source: Page

	/// What the link page saw of the click, from its title.
	internal var pageSaw: PageSaw = .unknown

	/// What became of the first request for new contents after the click, in the engine and then
	/// the app, or nil while none came.
	internal var request: Request?

	/// Whether the app routed that request itself, or nil before it saw it.
	internal var route: SmokeDiagnostics.NewContentsRoute?

	/// The Peek from the source, or nil while there's none.
	internal var peek: Peek?
	internal var windowsAdded: Int
	internal var tabsAdded: Int

	internal var description: String {
		let peek = peek.map { "\($0.isIdle ? "idle" : "busy"),\($0.isLoading ? "loading" : "loaded"),\($0.page.rawValue)" }
		return "hit=\(hit) source=\(source.rawValue) pageSaw=\(pageSaw) request=\(request?.description ?? "none") "
		+ "route=\(route?.rawValue ?? "none") peek=\(peek ?? "none") windowsAdded=\(windowsAdded) tabsAdded=\(tabsAdded)"
	}

	/// The first step that keeps the Peek from showing the target, or nil once it does.
	internal var lag: Lag? {
		if let peek {
			if peek.isIdle, peek.page == .target { return nil }
			return peek.isIdle && !peek.isLoading ? .peekTitle : .peekLoading
		}
		guard hit == .page else { return .clickCovered }
		guard source != .target else { return .shiftLost }
		guard let request else {
			return switch pageSaw {
			case .nothing: .clickNotDelivered
			case .click(shift: false): .shiftLost
			case .click(shift: true), .unknown: .noRequest
			}
		}

		switch request {
		case .declined: return route == .app ? .peekRefused : .appDropped
		case .adopted: return .openedElsewhere
		case .refused: return .engineRefused
		}
	}

	/// The step that's behind, going from the click to the Peek's title.
	internal enum Lag: String, Equatable {
		/// Something else in the window is over the link, so AppKit gave it the click.
		case clickCovered

		/// The page followed the link itself, or saw the click without Shift.
		case shiftLost

		/// The page never saw the click: Chromium didn't deliver it to the page, as can happen to a
		/// page that has only just been drawn.
		case clickNotDelivered

		/// The page saw the Shift-click but never asked for a new window, or Chromium refused it
		/// before the engine heard of it.
		case noRequest

		/// The engine refused the request; `request` names the step.
		case engineRefused

		/// The app neither routed the request nor placed Chromium's page.
		case appDropped

		/// The app sent the link to Peek, but no Peek opened.
		case peekRefused

		/// Chromium's page opened as a window or tab of its own.
		case openedElsewhere

		/// The Peek is still opening or loading.
		case peekLoading

		/// The Peek finished loading something other than the target.
		case peekTitle
	}

	/// Where the click's point landed.
	internal enum ClickHit: Equatable, CustomStringConvertible {
		/// The page's own view or one inside it.
		case page

		/// Another view, named by its class and its two nearest ancestors' classes.
		case other(String)

		/// The smoke didn't click.
		case notClicked

		internal var description: String {
			switch self {
			case .page: "page"
			case let .other(classes): "other(\(classes))"
			case .notClicked: "notClicked"
			}
		}
	}

	/// The fixture page a tab shows, from its title.
	internal enum Page: String, Equatable {
		case link
		case target
		case other

		internal init(title: String?) {
			switch title {
			case "Arx Shift link": self = .link
			case let title? where title.hasPrefix(PageSaw.prefix): self = .link
			case "Arx Shift target": self = .target
			default: self = .other
			}
		}
	}

	/// What the link page saw of the click: the trusted mouse-downs it counts in its title.
	internal enum PageSaw: Equatable, CustomStringConvertible {
		/// The link page, which has seen no mouse-down.
		case nothing

		/// It saw at least one, with Shift held or not.
		case click(shift: Bool)

		/// Not the link page, or a title this can't read.
		case unknown

		fileprivate static let prefix: String = "Arx Shift link \u{00B7} "

		internal init(title: String?) {
			guard let title else {
				self = .unknown
				return
			}
			if title == "Arx Shift link" {
				self = .nothing
				return
			}
			guard title.hasPrefix(Self.prefix) else {
				self = .unknown
				return
			}

			var counts: [String: Int] = [:]
			for field in title.dropFirst(Self.prefix.count).split(separator: " ") {
				let parts = field.split(separator: "=", maxSplits: 1)
				if parts.count == 2, let value = Int(parts[1]) { counts[String(parts[0])] = value }
			}
			guard let down = counts["down"], down > 0 else {
				self = .unknown
				return
			}

			self = .click(shift: (counts["shift"] ?? 0) > 0)
		}

		internal var description: String {
			switch self {
			case .nothing: "nothing"
			case let .click(shift): shift ? "shiftClick" : "click"
			case .unknown: "unknown"
			}
		}
	}

	/// How far a page's request for new contents got in the engine.
	internal enum Request: Equatable, CustomStringConvertible {
		/// The engine refused it at the named step.
		case refused(String)

		/// The engine offered it and the app declined Chromium's page.
		case declined

		/// The app took Chromium's page.
		case adopted

		internal init(_ outcome: NewContentsRecord.Outcome) {
			switch outcome {
			case .declined: self = .declined
			case .adopted: self = .adopted
			case .unknownSource, .retiringProfile, .privacyMismatch, .staleDocument, .noHost, .windowHidden,
				.pageHidden, .mediaFailed:
				self = .refused(outcome.rawValue)
			}
		}

		internal var description: String {
			switch self {
			case let .refused(step): "refused(\(step))"
			case .declined: "declined"
			case .adopted: "adopted"
			}
		}
	}

	internal struct Peek: Equatable {
		internal var isIdle: Bool
		internal var isLoading: Bool
		internal var page: Page
	}
}
#endif
