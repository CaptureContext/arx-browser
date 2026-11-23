#if DEBUG
import AppKit
import BrowserCore
import ChromiumBrowserEngine
import Foundation

/// A failed app-smoke check that names itself, so a one-off failure explains itself from the log.
///
/// Values are identifiers, counts, revisions and geometry. They never carry URLs, titles,
/// credentials or other page text.
internal struct AutomationSmokeMismatch: Error, CustomStringConvertible {
	internal var failure: AutomationSmokeFailure
	internal var check: String
	internal var expected: String
	internal var actual: String

	/// Key window and front app when the check failed; `nil` until a main-actor caller records it.
	internal var focus: String?

	internal init(
		_ failure: AutomationSmokeFailure,
		check: String,
		expected: String,
		actual: String,
		focus: String? = nil
	) {
		self.failure = failure
		self.check = check
		self.expected = expected
		self.actual = actual
		self.focus = focus
	}

	internal var description: String {
		"\(failure.rawValue) check=\(check) expected=\(expected) actual=\(actual) \(focus ?? "focus=unrecorded")"
	}

	internal static func require<Value: Equatable>(
		_ check: String,
		_ actual: Value,
		equals expected: Value,
		failure: AutomationSmokeFailure = .captureMismatch
	) throws {
		guard actual != expected else { return }

		throw Self(failure, check: check, expected: "\(expected)", actual: "\(actual)")
	}

	internal static func require(
		_ check: String,
		_ holds: Bool,
		expected: String,
		actual: @autoclosure () -> String,
		failure: AutomationSmokeFailure = .captureMismatch
	) throws {
		guard !holds else { return }

		throw Self(failure, check: check, expected: expected, actual: actual())
	}
}

/// A smoke wait or request whose condition never held, named by its call site.
///
/// Its description is also written to standard error when it's thrown, so the runtime log
/// keeps it even where a caller folds the error into a generic failure.
internal struct SmokeTimeout: Error, CustomStringConvertible {
	internal let site: String
	internal let waited: Duration
	internal let state: String
	internal let focus: String

	internal init(
		site: String,
		waited: Duration,
		state: String,
		focus: String
	) {
		self.site = site
		self.waited = waited
		self.state = state
		self.focus = focus
	}

	internal var description: String {
		let seconds = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
		let elapsed = String(format: "%.1fs", seconds)
		return "timedOut waitingFor=\(site) waited=\(elapsed) lastState=(\(state)) \(focus)"
	}
}

@MainActor
internal enum SmokeDiagnostics {
	/// What the app did with the engine's last request for new contents, by the engine's
	/// `NewContentsRecord.sequence`, so a smoke's timeout can tell a routed link from a dropped one
	/// (DEV-1191).
	internal static var lastNewContentsRoute: (sequence: Int, route: NewContentsRoute)?

	internal enum NewContentsRoute: String, Equatable, Sendable {
		/// The app opened the link its own way, in Peek or Little Arx, and declined Chromium's page.
		case app

		/// The app left it to Chromium's choice and placed the page, or dropped it.
		case chromium
	}

	internal static func noteNewContentsRoute(
		_ route: NewContentsRoute,
		engine: ChromiumBrowserEngine
	) {
		guard let sequence = engine.lastNewContents?.sequence else { return }

		lastNewContentsRoute = (sequence, route)
	}

	/// Logs and returns a timeout for the wait at `site`, recording the focus now.
	internal static func timeout(
		site: String,
		since start: ContinuousClock.Instant,
		state: String
	) -> SmokeTimeout {
		let timeout = SmokeTimeout(
			site: site,
			waited: ContinuousClock.now - start,
			state: state,
			focus: focus()
		)
		FileHandle.standardError.write(Data("ARX_SMOKE_TIMEOUT \(timeout)\n".utf8))
		return timeout
	}

	/// The key and main windows of this process and the frontmost app.
	///
	/// Windows are named by class and number, not title, because titles can carry page text.
	internal static func focus() -> String {
		let front = NSWorkspace.shared.frontmostApplication
		let ownProcess = ProcessInfo.processInfo.processIdentifier
		let frontApp = front.map { app in
			let owner = app.processIdentifier == ownProcess ? "self" : "other"
			return "\(app.bundleIdentifier ?? "unknown")[\(app.processIdentifier),\(owner)]"
		}

		return [
			"keyWindow=\(NSApp.keyWindow.map(describe) ?? "none")",
			"mainWindow=\(NSApp.mainWindow.map(describe) ?? "none")",
			"appActive=\(NSApp.isActive)",
			"frontApp=\(frontApp ?? "none")",
		].joined(separator: " ")
	}

	/// Records the focus on a mismatch thrown by `body` before any `defer` can move it.
	internal static func focused<Value>(_ body: () throws -> Value) throws -> Value {
		do {
			return try body()
		} catch var mismatch as AutomationSmokeMismatch where mismatch.focus == nil {
			mismatch.focus = focus()
			throw mismatch
		}
	}

	/// As `changes(from:to:)` for a page's snapshot, naming the navigation's own fields that
	/// differ too, as `navigation(colors,title)`: a snapshot's navigation is most of what a page
	/// changes (DEV-1172).
	internal static func snapshotChanges(
		from old: BrowserSessionSnapshot?,
		to new: BrowserSessionSnapshot?
	) -> String {
		let fields = changes(from: old, to: new)
		guard let old, let new, old.navigation != new.navigation else { return fields }

		let navigation = "navigation(\(changes(from: old.navigation, to: new.navigation)))"
		return fields.split(separator: ",")
			.map { $0 == "navigation" ? navigation : String($0) }
			.joined(separator: ",")
	}

	/// Names the stored properties that differ between two values of the same type.
	///
	/// Booleans and numbers show both values; anything else shows only its name,
	/// because it may hold a URL or page text.
	internal static func changes<Value>(
		from old: Value?,
		to new: Value?
	) -> String {
		guard let old, let new else {
			return "presence \(old == nil ? "none" : "some")->\(new == nil ? "none" : "some")"
		}

		let oldChildren = Mirror(reflecting: old).children
		let newChildren = Array(Mirror(reflecting: new).children)
		let differences = zip(oldChildren, newChildren).compactMap { pair -> String? in
			let (before, after) = pair
			let label = before.label ?? "?"
			let beforeText = String(describing: before.value)
			let afterText = String(describing: after.value)
			guard beforeText != afterText else { return nil }

			// Both sides: an optional that's nil on one side says nothing of what the other holds,
			// which may be page text.
			return isScalar(before.value) && isScalar(after.value)
			? "\(label) \(beforeText)->\(afterText)"
			: label
		}

		return differences.isEmpty ? "none" : differences.joined(separator: ",")
	}

	private static func describe(_ window: NSWindow) -> String {
		var flags: [String] = []
		if !window.isVisible { flags.append("hidden") }
		if !window.occlusionState.contains(.visible) { flags.append("occluded") }
		if window.isMiniaturized { flags.append("miniaturized") }

		let suffix = flags.isEmpty ? "" : "(\(flags.joined(separator: ",")))"
		return "\(type(of: window))#\(window.windowNumber)\(suffix)"
	}

	private static func isScalar(_ value: Any) -> Bool {
		if value is Bool || value is any BinaryInteger || value is any BinaryFloatingPoint { return true }

		let mirror = Mirror(reflecting: value)
		guard mirror.displayStyle == .optional else { return false }

		return mirror.children.first.map { isScalar($0.value) } ?? true
	}
}
#endif
