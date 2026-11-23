import AppKit
import ChromiumEngine

/// DEV-936. A page that's created and never mounted is hidden to Chromium: its timers are
/// throttled, and it freezes once it falls outside the five most recent tabs. Its first
/// mount shows it. The host validates fresh owned storage and the loopback fixture first.
///
/// Each fixture page reports its state in its title (`Scripts/core/background_visibility_fixture.py`),
/// which a hidden page still updates and a frozen page can't.
@MainActor
internal final class BackgroundVisibilitySmoke {
	internal static let argument: String = "--background-visibility-fixture"

	/// Pages opened after the background page, enough to push it past Chromium's five
	/// protected tabs whatever the visible page counts for.
	private static let laterPageCount: Int = 5

	private enum Failure: Error, CustomStringConvertible {
		case timedOut(String)
		case unexpected(String)

		internal var description: String {
			switch self {
			case let .timedOut(phase): "timed-out phase=\(phase)"
			case let .unexpected(detail): "unexpected \(detail)"
			}
		}
	}

	/// One title report: `ARXVIS <case> first=… vis=… slow=… fast=… ms=… state=… painted=…`.
	private struct Report: Equatable {
		internal var name: String
		internal var first: String
		internal var visibility: String
		internal var slow: Int
		internal var fast: Int
		internal var milliseconds: Int
		internal var state: String
		internal var painted: Int

		internal init?(_ title: String) {
			let tokens = title.split(separator: " ").map(String.init)
			guard tokens.count == 9, tokens[0] == "ARXVIS"
			else { return nil }

			var values: [String: String] = [:]
			for token in tokens.dropFirst(2) {
				let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
				guard parts.count == 2 else { return nil }
				values[parts[0]] = parts[1]
			}
			guard
				let first = values["first"],
				let visibility = values["vis"],
				let slow = values["slow"].flatMap({ Int($0) }),
				let fast = values["fast"].flatMap({ Int($0) }),
				let milliseconds = values["ms"].flatMap({ Int($0) }),
				let state = values["state"],
				let painted = values["painted"].flatMap({ Int($0) })
			else { return nil }

			self.name = tokens[1]
			self.first = first
			self.visibility = visibility
			self.slow = slow
			self.fast = fast
			self.milliseconds = milliseconds
			self.state = state
			self.painted = painted
		}

		/// Fast-timer ticks per second between two reports.
		internal func fastRate(since earlier: Report) -> Double {
			let seconds = Double(milliseconds - earlier.milliseconds) / 1000
			guard seconds > 0 else { return .infinity }
			return Double(fast - earlier.fast) / seconds
		}
	}

	private let runtime: ChromiumRuntime
	private let baseURL: URL
	private var pages: [ChromiumPage] = []
	private var windows: [NSWindow] = []
	private var phase: String = "startup"
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) {
		self.runtime = runtime
		self.baseURL = url
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_BACKGROUND_VISIBILITY_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_BACKGROUND_VISIBILITY_SMOKE_FAILED phase=\(phase) reason=\(error)")
			}

			for page in pages { page.close() }
			for window in windows { window.orderOut(nil) }
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		phase = "load"
		let visible = try makePage("visible")
		mount(visible)
		let background = try makePage("background")
		let visibleStart = try await report(visible) { $0.slow >= 1 }
		let backgroundStart = try await report(background) { $0.slow >= 1 }

		phase = "starts-hidden"
		guard background.view.window == nil
		else { throw Failure.unexpected("background page has a window") }
		guard backgroundStart.first == "hidden", backgroundStart.visibility == "hidden"
		else { throw Failure.unexpected("background first=\(backgroundStart.first) vis=\(backgroundStart.visibility)") }
		guard visibleStart.first == "visible", visibleStart.visibility == "visible"
		else { throw Failure.unexpected("visible first=\(visibleStart.first) vis=\(visibleStart.visibility)") }
		diagnostic("ARX_BACKGROUND_VISIBILITY_SMOKE_STARTS_HIDDEN")

		phase = "throttled"

		// The 1 Hz timer keeps running in a hidden page; the 10 Hz probe beside it shows
		// Chromium's background timer alignment (one wake-up a second), which a 1 Hz timer
		// alone can't. A visible page runs the probe at full rate.
		try await Task.sleep(for: .seconds(6))
		let visibleLater = try await report(visible) { $0.slow > visibleStart.slow }
		let backgroundLater = try await report(background) { $0.slow > backgroundStart.slow }
		let visibleRate = visibleLater.fastRate(since: visibleStart)
		let backgroundRate = backgroundLater.fastRate(since: backgroundStart)
		diagnostic(
			"ARX_BACKGROUND_VISIBILITY_SMOKE_RATES visible=\(Int(visibleRate * 10)) background=\(Int(backgroundRate * 10)) (ticks per 10 s)"
		)
		guard visibleRate >= 6, backgroundRate <= 2.5, backgroundLater.slow >= backgroundStart.slow + 3
		else { throw Failure.unexpected("timer rates visible=\(visibleRate) background=\(backgroundRate)") }
		diagnostic("ARX_BACKGROUND_VISIBILITY_SMOKE_THROTTLED")

		phase = "frozen"
		for index in 0..<Self.laterPageCount {
			let later = try makePage("later-\(index)")
			_ = try await report(later) { $0.slow >= 1 }
		}
		try await requireFrozen(background)
		diagnostic("ARX_BACKGROUND_VISIBILITY_SMOKE_FROZEN")

		phase = "first-show"

		// The first mount shows the page as a click on its tab would: it resumes, becomes
		// visible and draws. The time is the click-to-shown floor for a frozen page.
		let started = ContinuousClock.now
		mount(background)
		let shown = try await report(background, within: .seconds(10)) {
			$0.visibility == "visible" && $0.painted >= 1
		}
		let elapsed = ContinuousClock.now - started
		guard !background.view.isHiddenOrHasHiddenAncestor, shown.first == "hidden"
		else { throw Failure.unexpected("shown page view hidden or first=\(shown.first)") }
		let milliseconds = Int((elapsed / .milliseconds(1)).rounded())
		diagnostic("ARX_BACKGROUND_VISIBILITY_SMOKE_SHOWN_MS=\(milliseconds)")
		diagnostic("ARX_BACKGROUND_VISIBILITY_SMOKE_FIRST_SHOW")
	}

	/// The page is frozen and none of its timers runs for three seconds. Chromium unfreezes
	/// an InfiniteTabs-frozen page for five seconds each minute, so a resume in the middle
	/// waits for the next freeze.
	private func requireFrozen(_ page: ChromiumPage) async throws {
		for _ in 0..<3 {
			let frozen = try await report(page, within: .seconds(30)) { $0.state == "frozen" }
			try await Task.sleep(for: .seconds(3))
			guard let still = Report(page.navigation.title)
			else { throw Failure.unexpected("title \(page.navigation.title)") }
			if still == frozen { return }
			guard still.state != "frozen"
			else { throw Failure.unexpected("a frozen page's timers ran") }
		}
		throw Failure.timedOut(phase)
	}

	private func makePage(_ name: String) throws -> ChromiumPage {
		let page = try runtime.makePage()
		pages.append(page)
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
		else { throw Failure.unexpected("base URL") }
		components.path = "/visibility/page.html"
		components.queryItems = [.init(name: "case", value: name)]
		guard let url = components.url
		else { throw Failure.unexpected("page URL") }
		try page.navigate(to: url)
		return page
	}

	private func mount(_ page: ChromiumPage) {
		let window = NSWindow(
			contentRect: .init(x: 80 + windows.count * 40, y: 80, width: 800, height: 600),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		let container = NSView(frame: .init(x: 0, y: 0, width: 800, height: 600))
		window.contentView = container
		page.view.frame = container.bounds
		page.view.autoresizingMask = [.width, .height]
		container.addSubview(page.view)
		windows.append(window)
		window.makeKeyAndOrderFront(nil)
	}

	private func report(
		_ page: ChromiumPage,
		within limit: Duration = .seconds(15),
		where condition: (Report) -> Bool
	) async throws -> Report {
		let deadline = ContinuousClock.now + limit
		while true {
			if let report = Report(page.navigation.title), condition(report) { return report }
			guard ContinuousClock.now < deadline
			else { throw Failure.timedOut(phase) }

			try await Task.sleep(for: .milliseconds(50))
		}
	}

	private func diagnostic(_ message: String) {
		FileHandle.standardError.write(Data((message + "\n").utf8))
	}
}
