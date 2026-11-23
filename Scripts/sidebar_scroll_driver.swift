// The sidebar scroll driver for `make sidebar-scroll` (DEV-1238).
//
// It drives a running Arx from outside, so it measures any commit's build without a hook in
// the app: phased trackpad scroll events go to the sidebar of Arx's window at a fixed pace,
// and a ScreenCaptureKit stream of the sidebar notes when each new frame of it reaches the
// screen. A gap between frames longer than 1.5 refresh intervals while the list moves is a
// dropped frame. Arx's main thread and whole process CPU come from `proc_pidinfo`.
//
//   sidebar_scroll_driver run --pid PID [--seconds 6] [--pointer inside|outside] [--speed 840]
//              (--rows N | --leg POINTS) [--window 1280x800] [--sidebar-width 286] [--output PATH]
//   sidebar_scroll_driver preflight      the two permissions it needs, exit 3 without them
//   sidebar_scroll_driver self-test      the frame statistics and the CPU counters, no screen needed
//   sidebar_scroll_driver clock-check    that the main display's link ticks at its refresh rate; posts nothing
//
// Built and run by Scripts/sidebar_scroll.py; see Scripts/README.md ("Sidebar scroll").

import AppKit
import ApplicationServices
import CoreMedia
import Darwin
import Foundation
import QuartzCore
import ScreenCaptureKit

// MARK: - Frame statistics

/// Gaps between the frames that reached the screen while the list moved.
struct FrameStatistics: Equatable {
	var frames: Int
	var refreshMilliseconds: Double
	var dropped: Int
	var missedIntervals: Int
	var worstGapMilliseconds: Double
	var p95GapMilliseconds: Double
	var p99GapMilliseconds: Double
	var meanGapMilliseconds: Double
	var firstFrameMilliseconds: Double
	var trailingMilliseconds: Double

	/// `times` are when frames arrived, in seconds; only those within `start ... end` count.
	///
	/// A gap is dropped when it's longer than 1.5 refresh intervals, and it missed as many
	/// intervals as it held beyond the first. The wait after the last frame counts as a gap too,
	/// so a stall at the end isn't missed; the wait for the first one is the input's way to the
	/// screen, a few frames even when nothing is late, so it's reported, not counted. A window
	/// with no frame at all is one gap as long as the window.
	init(times: [Double], refresh: Double, start: Double, end: Double) {
		let end = max(start, end)
		let interval = refresh * 1000
		let inside = times.filter { $0 >= start && $0 <= end }.sorted()
		var gaps = zip(inside.dropFirst(), inside).map { ($0 - $1) * 1000 }
		let trailing = (end - (inside.last ?? start)) * 1000
		let sorted = gaps.sorted()
		gaps.append(trailing)
		let late = gaps.filter { $0 > interval * 1.5 }

		func percentile(_ fraction: Double) -> Double {
			guard !sorted.isEmpty else { return 0 }
			let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded(.up)))
			return sorted[index]
		}

		frames = inside.count
		refreshMilliseconds = interval
		dropped = late.count
		missedIntervals = late.reduce(0) { $0 + max(1, Int(($1 / interval).rounded()) - 1) }
		worstGapMilliseconds = max(sorted.last ?? 0, late.max() ?? 0)
		p95GapMilliseconds = percentile(0.95)
		p99GapMilliseconds = percentile(0.99)
		meanGapMilliseconds = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
		firstFrameMilliseconds = ((inside.first ?? end) - start) * 1000
		trailingMilliseconds = trailing
	}

	var json: [String: Any] {
		[
			"frames": frames,
			"refresh_ms": rounded(refreshMilliseconds, 2),
			"dropped": dropped,
			"missed_intervals": missedIntervals,
			"worst_gap_ms": rounded(worstGapMilliseconds, 1),
			"p95_gap_ms": rounded(p95GapMilliseconds, 1),
			"p99_gap_ms": rounded(p99GapMilliseconds, 1),
			"mean_gap_ms": rounded(meanGapMilliseconds, 2),
			"first_frame_ms": rounded(firstFrameMilliseconds, 1),
			"trailing_ms": rounded(trailingMilliseconds, 1),
		]
	}
}

func rounded(_ value: Double, _ places: Int) -> Double {
	let scale = pow(10, Double(places))
	return (value * scale).rounded() / scale
}

// MARK: - Scroll script

/// A tab row's pitch in the sidebar: `BrowserMetrics.Row.height` and its spacing.
let rowPitch = 36.0

/// What a new window's sidebar shows besides the list, about: the space header, the toolbar
/// row, the Favorites and the footer. Generous, so a leg never reaches the list's end.
let sidebarChrome = 260.0
let legRange = 120.0 ... 1500.0

/// How far each leg scrolls for `rows` tabs in a window `height` points tall: three fifths of
/// what the list can scroll, so a leg turns back well before the list stops at its end (a list
/// that stops shows no new frames, which would read as drops), within `legRange`. Nil when the
/// list can't scroll that far.
func legPoints(rows: Int, windowHeight height: Double) -> Double? {
	let scrollable = Double(rows) * rowPitch - (height - sidebarChrome)
	let leg = (scrollable * 0.6).rounded()
	guard leg >= legRange.lowerBound else { return nil }
	return min(legRange.upperBound, leg)
}

/// One scroll event of the gesture: how far it moves and its phases.
struct Move: Equatable {
	/// Points, positive down the list (the content moves up), as a trackpad's two fingers
	/// moving up the pad send them with natural scrolling.
	var points: Int

	/// `scrollPhase`: 1 began, 2 changed, 4 ended; 0 during the glide.
	var phase: Int64

	/// `momentumPhase`: 1 began, 2 continued, 3 ended; 0 while the fingers are down.
	var momentum: Int64
}

/// Legs of `leg` points down the list and back up, alternating, at `speed` points a second,
/// for about `seconds`, as frames of `refresh` seconds, each frame the events posted on it.
///
/// Each leg is a gesture, as a trackpad and its momentum deliver it: the fingers begin, move and
/// lift, and a glide slows to rest. The list moves on every frame, so every frame owes a new
/// picture: a gesture's first event carries its first move, the lift and the glide's start
/// share a frame, and so do the glide's end and the next gesture's beginning. Points are
/// whole, the rounding carried over, so a leg adds up to its length. The legs come in pairs,
/// so the list ends where it began and the next run starts there too.
func scrollScript(seconds: Double, refresh: Double, speed: Double, leg: Double) -> [[Move]] {
	let total = max(1, Int((seconds / refresh).rounded()))
	let perFrame = max(1, speed * refresh)
	let length = max(8, Int(leg.rounded()))

	// A glide of a quarter second at most, about an eighth of the leg, falling evenly to a
	// point a frame.
	let glideFrames = max(2, min(Int((0.25 / refresh).rounded()), length / 16))
	let glideShare = Double(length) / 8 / Double(glideFrames * (glideFrames + 1) / 2)
	let glide = (0 ..< glideFrames).map { max(1, Int((Double(glideFrames - $0) * glideShare).rounded())) }
	let fingerPoints = max(2, length - glide.reduce(0, +))
	let fingerFrames = max(2, Int((Double(fingerPoints) / perFrame).rounded()))
	let fingers = (1 ... fingerFrames).map { step in
		Int((Double(fingerPoints) * Double(step) / Double(fingerFrames)).rounded())
			- Int((Double(fingerPoints) * Double(step - 1) / Double(fingerFrames)).rounded())
	}
	var frames: [[Move]] = []
	var way = 1
	var carried: [Move] = []
	while frames.count < total || way < 0 {
		for (index, points) in fingers.enumerated() {
			frames.append(carried + [Move(points: way * points, phase: index == 0 ? 1 : 2, momentum: 0)])
			carried = []
		}
		for (index, points) in glide.enumerated() {
			let lift = index == 0 ? [Move(points: 0, phase: 4, momentum: 0)] : []
			frames.append(lift + [Move(points: way * points, phase: 0, momentum: index == 0 ? 1 : 2)])
		}
		carried = [Move(points: 0, phase: 0, momentum: 3)]
		way = -way
	}
	frames[frames.count - 1] += carried
	return frames
}

// MARK: - CPU counters

enum CPU {
	/// `PROC_PIDLISTTHREADIDS` in libproc's private header: every thread's 64-bit ID.
	private static let listThreadIDs: Int32 = 28

	static let timebase: mach_timebase_info_data_t = {
		var info = mach_timebase_info_data_t()
		mach_timebase_info(&info)
		return info
	}()

	/// The main thread of `pid`: its lowest thread ID, as the first thread a process starts.
	/// Its user and system time in milliseconds, and its name.
	static func mainThread(of pid: pid_t) -> (milliseconds: Double, name: String)? {
		let capacity = 4096
		var identifiers = [UInt64](repeating: 0, count: capacity)
		let bytes = identifiers.withUnsafeMutableBytes { buffer in
			proc_pidinfo(pid, listThreadIDs, 0, buffer.baseAddress, Int32(buffer.count))
		}
		guard bytes > 0 else { return nil }
		let count = Int(bytes) / MemoryLayout<UInt64>.size
		guard let main = identifiers.prefix(count).filter({ $0 != 0 }).min() else { return nil }
		var info = proc_threadinfo()
		let size = Int32(MemoryLayout<proc_threadinfo>.size)
		guard proc_pidinfo(pid, PROC_PIDTHREADID64INFO, main, &info, size) == size else { return nil }
		let name = withUnsafeBytes(of: info.pth_name) { buffer in
			String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
		}
		return (Double(info.pth_user_time + info.pth_system_time) / 1_000_000, name)
	}

	/// Every thread of `pid`, user and system, in milliseconds.
	static func process(_ pid: pid_t) -> Double? {
		var usage = rusage_info_v2()
		let result = withUnsafeMutablePointer(to: &usage) { pointer in
			pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
		}
		guard result == 0 else { return nil }
		let ticks = Double(usage.ri_user_time + usage.ri_system_time)
		return ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
	}
}

// MARK: - The window

struct ArxWindow {
	var number: CGWindowID

	/// In global display points, origin at the top left of the main display, as Quartz events use.
	var bounds: CGRect

	/// The largest on-screen, ordinary window `pid` owns.
	static func find(pid: pid_t) -> ArxWindow? {
		let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
		return list.compactMap { entry -> ArxWindow? in
			guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
				  (entry[kCGWindowLayer as String] as? Int) == 0,
				  let number = entry[kCGWindowNumber as String] as? CGWindowID,
				  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
				  let bounds = CGRect(dictionaryRepresentation: dictionary),
				  bounds.width > 400, bounds.height > 300
			else { return nil }
			return ArxWindow(number: number, bounds: bounds)
		}
		.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
	}

	/// The screen showing most of the window, in AppKit's coordinates.
	var screen: NSScreen? {
		let top = NSScreen.screens.first?.frame.maxY ?? 0
		let flipped = CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
		return NSScreen.screens.max { lhs, rhs in
			area(lhs.frame.intersection(flipped)) < area(rhs.frame.intersection(flipped))
		}
	}
}

func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

/// Puts Arx's front window at `size`, near the top left of its screen's visible area, through
/// the Accessibility API, so every run and every build measures the same list in the same
/// window. Nil on success, else why it couldn't.
func resize(pid: pid_t, to size: CGSize, on screen: NSScreen) -> String? {
	let app = AXUIElementCreateApplication(pid)
	var value: CFTypeRef?
	guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
		  let windows = value as? [AXUIElement], !windows.isEmpty
	else { return "Accessibility lists no window for Arx" }
	let main = windows.max { lhs, rhs in
		func area(_ element: AXUIElement) -> CGFloat {
			var size = CGSize.zero
			var raw: CFTypeRef?
			if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &raw) == .success, let raw {
				AXValueGetValue(raw as! AXValue, .cgSize, &size)
			}
			return size.width * size.height
		}
		return area(lhs) < area(rhs)
	}!

	// Accessibility positions are in Quartz's global space: origin at the main display's top left.
	let top = NSScreen.screens.first?.frame.maxY ?? 0
	let visible = screen.visibleFrame
	var origin = CGPoint(x: visible.minX + 40, y: top - visible.maxY + 40)
	var target = CGSize(width: min(size.width, visible.width - 80), height: min(size.height, visible.height - 80))
	guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &target) else {
		return "couldn't make the window's frame"
	}
	let moved = AXUIElementSetAttributeValue(main, kAXPositionAttribute as CFString, position)
	let sized = AXUIElementSetAttributeValue(main, kAXSizeAttribute as CFString, dimensions)
	return moved == .success && sized == .success ? nil : "Accessibility refused the window's frame (\(moved.rawValue), \(sized.rawValue))"
}

// MARK: - Events

enum Events {
	private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
	private static let setWindowLocation: SetWindowLocation? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
		.map { unsafeBitCast($0, to: SetWindowLocation.self) }

	/// The time base of event timestamps: nanoseconds of uptime, as the window server stamps them.
	static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

	/// A trackpad's scroll event over `point` of `window`, posted straight to `pid`'s queue. The
	/// event names the window and where in it the fingers are, so it goes to the sidebar wherever
	/// the cursor rests.
	static func scroll(_ move: Move, at point: CGPoint, in window: ArxWindow, pid: pid_t, time: UInt64) {
		// Wheel deltas follow the content: a move down the list scrolls by a negative wheel delta.
		guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
								  wheel1: Int32(-move.points), wheel2: 0, wheel3: 0) else { return }
		event.flags = []
		event.location = point
		event.timestamp = time
		event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
		event.setIntegerValueField(.scrollWheelEventScrollPhase, value: move.phase)
		event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: move.momentum)
		place(event, at: point, in: window)
		event.postToPid(pid)
	}

	/// The cursor moved to `point`, so Arx's tracking areas know where it rests.
	static func moveCursor(to point: CGPoint, in window: ArxWindow, pid: pid_t) {
		CGWarpMouseCursorPosition(point)
		guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
		event.timestamp = now()
		place(event, at: point, in: window)
		event.postToPid(pid)
	}

	private static func place(_ event: CGEvent, at point: CGPoint, in window: ArxWindow) {
		// kCGMouseEventWindowUnderMousePointer and …ThatCanHandleThisEvent.
		for field in [51, 52] {
			if let key = CGEventField(rawValue: UInt32(field)) {
				event.setIntegerValueField(key, value: Int64(window.number))
			}
		}
		setWindowLocation?(event, CGPoint(x: point.x - window.bounds.minX, y: point.y - window.bounds.minY))
	}
}

// MARK: - Frames on screen

/// A ScreenCaptureKit stream of the sidebar's part of the window: every frame the window server
/// composes with new content in it arrives as a complete frame, so its arrival times are the
/// frames a person sees.
final class FrameRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
	private let queue = DispatchQueue(label: "sidebar-scroll.frames")
	private let lock = NSLock()
	private var completeTimes: [Double] = []
	private var idleCount = 0
	private var stream: SCStream?
	private(set) var failure: String?

	var times: [Double] { lock.withLock { completeTimes } }
	var idle: Int { lock.withLock { idleCount } }

	func start(window: ArxWindow, crop: CGRect, refresh: Double) -> String? {
		var content: SCShareableContent?
		var error: Error?
		let found = DispatchSemaphore(value: 0)
		SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) {
			content = $0
			error = $1
			found.signal()
		}
		guard wait(found, seconds: 10) else { return "ScreenCaptureKit didn't list the windows" }
		guard let window = content?.windows.first(where: { $0.windowID == window.number }) else {
			return "ScreenCaptureKit can't see Arx's window: \(error.map { "\($0)" } ?? "not listed")"
		}
		let filter = SCContentFilter(desktopIndependentWindow: window)
		let configuration = SCStreamConfiguration()
		configuration.sourceRect = crop

		// Half the sidebar's points: enough to tell frames apart, little for the capture to copy.
		configuration.width = max(32, Int(crop.width / 2))
		configuration.height = max(32, Int(crop.height / 2))
		configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(60, (1 / refresh).rounded()) * 2))
		configuration.queueDepth = 8
		configuration.showsCursor = false
		configuration.capturesAudio = false
		let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
		do {
			try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
		} catch {
			return "ScreenCaptureKit refused the stream output: \(error)"
		}
		var started: Error?
		let began = DispatchSemaphore(value: 0)
		stream.startCapture {
			started = $0
			began.signal()
		}
		guard wait(began, seconds: 10) else { return "ScreenCaptureKit didn't start the stream" }
		if let started { return "ScreenCaptureKit couldn't start: \(started)" }
		self.stream = stream
		return nil
	}

	func stop() {
		guard let stream else { return }
		let stopped = DispatchSemaphore(value: 0)
		stream.stopCapture { _ in stopped.signal() }
		_ = wait(stopped, seconds: 5)
		self.stream = nil
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
		let arrived = CACurrentMediaTime()
		guard type == .screen,
			  let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
			  let raw = attachments.first?[.status] as? Int,
			  let status = SCFrameStatus(rawValue: raw)
		else { return }

		// The display time is when the window server composed it, in host time: mach ticks.
		let shown = (attachments.first?[.displayTime] as? UInt64).map {
			Double($0) * Double(CPU.timebase.numer) / Double(CPU.timebase.denom) / 1e9
		}
		lock.withLock {
			switch status {
			case .complete: completeTimes.append(shown ?? arrived)
			case .idle: idleCount += 1
			default: break
			}
		}
	}

	func stream(_ stream: SCStream, didStopWithError error: Error) {
		lock.withLock { failure = "\(error)" }
	}
}

/// Waits for `semaphore` while the main run loop keeps turning.
func wait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
	let deadline = Date(timeIntervalSinceNow: seconds)
	while Date() < deadline {
		if semaphore.wait(timeout: .now()) == .success { return true }
		RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
	}
	return false
}

// MARK: - The pacer

/// The screen's display link: it posts one move per frame and notes when each frame came, so a
/// late harness shows in its own gaps rather than as Arx's dropped frames.
final class Pacer: NSObject {
	var onTick: ((CADisplayLink) -> Void)?
	private(set) var ticks: [Double] = []
	private(set) var interval: Double = 1.0 / 60

	@objc
	func tick(_ link: CADisplayLink) {
		ticks.append(link.timestamp)
		let measured = link.targetTimestamp - link.timestamp
		if measured > 0.002, measured < 0.05 { interval = measured }
		onTick?(link)
	}
}

// MARK: - Run

struct Options {
	var pid: pid_t = 0
	var seconds = 6.0
	var pointerInside = true
	var speed = 840.0
	var rows: Int?
	var leg: Double?
	var sidebarWidth = 286.0
	var windowSize = CGSize(width: 1280, height: 800)
	var output: String?

	init(_ arguments: ArraySlice<String>) throws {
		var rest = arguments
		while let name = rest.popFirst() {
			guard let value = rest.popFirst() else { throw Failure.usage("\(name) needs a value") }
			switch name {
			case "--pid": pid = try number(value, name).map { pid_t($0) } ?? 0
			case "--seconds": seconds = try number(value, name) ?? seconds
			case "--pointer":
				guard ["inside", "outside"].contains(value) else { throw Failure.usage("--pointer is inside or outside") }
				pointerInside = value == "inside"
			case "--speed": speed = try number(value, name) ?? speed
			case "--leg": leg = try number(value, name)
			case "--rows": rows = try number(value, name).map { Int($0) }
			case "--sidebar-width": sidebarWidth = try number(value, name) ?? sidebarWidth
			case "--window":
				let parts = value.split(separator: "x").compactMap { Double($0) }
				guard parts.count == 2, parts.allSatisfy({ $0 >= 400 && $0 <= 10_000 }) else {
					throw Failure.usage("--window is WIDTHxHEIGHT, such as 1280x800")
				}
				windowSize = CGSize(width: parts[0], height: parts[1])
			case "--output": output = value
			default: throw Failure.usage("unknown option \(name)")
			}
		}
		guard pid > 0 else { throw Failure.usage("--pid is required") }
		guard seconds > 0.5, seconds <= 120 else { throw Failure.usage("--seconds is in (0.5, 120]") }
		guard speed > 0, (leg ?? 1) > 0, (rows ?? 1) > 0, sidebarWidth > 40 else {
			throw Failure.usage("--speed, --leg, --rows and --sidebar-width are positive")
		}
		guard (rows == nil) != (leg == nil) else { throw Failure.usage("give --rows or --leg") }
	}

	private func number(_ text: String, _ name: String) throws -> Double? {
		guard let value = Double(text), value.isFinite else { throw Failure.usage("\(name) takes a number") }
		return value
	}
}

enum Failure: Error {
	case usage(String)
	case permission(String)
	case run(String)
}

func preflight() -> [String] {
	var missing: [String] = []
	if !CGPreflightPostEventAccess() || !AXIsProcessTrusted() { missing.append("Accessibility") }
	if !CGPreflightScreenCaptureAccess() { missing.append("Screen Recording") }
	return missing
}

func run(_ options: Options) throws -> [String: Any] {
	let missing = preflight()
	guard missing.isEmpty else {
		throw Failure.permission("the app running this command needs " + missing.joined(separator: " and ")
			+ " in System Settings › Privacy & Security")
	}
	guard let app = NSRunningApplication(processIdentifier: options.pid) else { throw Failure.run("no process \(options.pid)") }

	// A display link and ScreenCaptureKit want an application connected to the window server.
	_ = NSApplication.shared
	app.activate(from: NSRunningApplication.current, options: [])
	if NSWorkspace.shared.frontmostApplication?.processIdentifier != options.pid {
		app.activate()
	}
	var candidate: ArxWindow?
	let searchUntil = Date(timeIntervalSinceNow: 10)
	while Date() < searchUntil {
		RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
		candidate = ArxWindow.find(pid: options.pid)
		if candidate != nil, NSWorkspace.shared.frontmostApplication?.processIdentifier == options.pid { break }
	}
	guard let found = candidate, let screen = found.screen else { throw Failure.run("Arx (pid \(options.pid)) has no window on screen") }
	if let problem = resize(pid: options.pid, to: options.windowSize, on: screen) { throw Failure.run(problem) }
	RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
	guard let window = ArxWindow.find(pid: options.pid) else { throw Failure.run("Arx's window went away") }

	// The sidebar is the window's left `sidebarWidth` points (Arx's default sidebar).
	let sidebarWidth = min(options.sidebarWidth, Double(window.bounds.width) / 2)
	guard let leg = options.leg ?? options.rows.flatMap({ legPoints(rows: $0, windowHeight: Double(window.bounds.height)) }) else {
		throw Failure.run("\(options.rows ?? 0) tabs don't scroll far enough in a window \(Int(window.bounds.height)) points tall")
	}
	let crop = CGRect(x: 0, y: 0, width: sidebarWidth, height: Double(window.bounds.height))
	let over = CGPoint(x: window.bounds.minX + sidebarWidth / 2, y: window.bounds.midY)
	let away = CGPoint(x: window.bounds.maxX - min(200, window.bounds.width / 4), y: window.bounds.midY)
	Events.moveCursor(to: options.pointerInside ? over : away, in: window, pid: options.pid)
	RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))

	let pacer = Pacer()
	let link = screen.displayLink(target: pacer, selector: #selector(Pacer.tick(_:)))
	link.add(to: .main, forMode: .common)

	// A second of the display link first: its interval, and a clock already running.
	RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
	let refresh = pacer.interval

	let recorder = FrameRecorder()
	if let problem = recorder.start(window: window, crop: crop, refresh: refresh) {
		link.invalidate()
		throw Failure.run(problem)
	}

	// The stream's first frames are the whole sidebar at once, not motion.
	RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

	let script = scrollScript(seconds: options.seconds, refresh: refresh, speed: options.speed, leg: leg)
	let mainBefore = CPU.mainThread(of: options.pid)
	let processBefore = CPU.process(options.pid)
	let firstTick = pacer.ticks.count
	var sent = 0
	var events = 0
	var start = 0.0
	var end = 0.0
	let began = Events.now()
	pacer.onTick = { _ in
		guard sent < script.count else { return }
		if sent == 0 { start = CACurrentMediaTime() }
		let time = began + UInt64(Double(sent) * refresh * 1e9)
		for move in script[sent] {
			Events.scroll(move, at: over, in: window, pid: options.pid, time: time)
			events += 1
		}
		sent += 1
		if sent == script.count { end = CACurrentMediaTime() }
	}

	// Twice the script's own length: it finishes a pair of legs, which can outlast `--seconds`.
	let deadline = Date(timeIntervalSinceNow: Double(script.count) * refresh * 2 + 5)
	while sent < script.count, Date() < deadline {
		RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
	}
	if end == 0 { end = CACurrentMediaTime() }

	// The last move's frame: one more refresh for it to reach the screen.
	RunLoop.main.run(until: Date(timeIntervalSinceNow: refresh * 3))
	let mainAfter = CPU.mainThread(of: options.pid)
	let processAfter = CPU.process(options.pid)
	pacer.onTick = nil
	link.invalidate()
	recorder.stop()

	if let failure = recorder.failure { throw Failure.run("the capture stopped: \(failure)") }
	guard sent == script.count else { throw Failure.run("the driver posted \(sent) of \(script.count) frames' events in time") }

	// Frames count from the first move's frame to the last one's.
	let frames = FrameStatistics(times: recorder.times, refresh: refresh, start: start + refresh, end: end + refresh)
	let ticks = Array(pacer.ticks.dropFirst(firstTick)).filter { $0 >= start && $0 <= end }
	let harness = FrameStatistics(times: ticks, refresh: refresh, start: start, end: end)
	let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == options.pid
	let seconds = end - start
	var result: [String: Any] = frames.json
	result.merge([
		"pointer": options.pointerInside ? "inside" : "outside",
		"seconds": rounded(seconds, 3),
		"events": events,
		"scroll_frames": sent,
		"idle_frames": recorder.idle,
		"harness_dropped": harness.dropped,
		"harness_missed_intervals": harness.missedIntervals,
		"harness_worst_gap_ms": rounded(harness.worstGapMilliseconds, 1),
		"arx_frontmost_at_end": frontmost,
		"window": [Int(window.bounds.minX), Int(window.bounds.minY), Int(window.bounds.width), Int(window.bounds.height)],
		"sidebar_width": sidebarWidth,
		"speed_points_per_s": options.speed,
		"leg_points": leg,
	]) { $1 }
	if let before = mainBefore, let after = mainAfter {
		let cpu = after.milliseconds - before.milliseconds
		result["main_cpu_ms"] = rounded(cpu, 1)
		result["main_cpu_percent"] = seconds > 0 ? rounded(cpu / (seconds * 1000) * 100, 1) : 0
		result["main_cpu_ms_per_frame"] = sent > 0 ? rounded(cpu / Double(sent), 2) : 0
		result["main_thread"] = after.name
	}
	if let before = processBefore, let after = processAfter {
		result["process_cpu_ms"] = rounded(after - before, 1)
	}
	return result
}

// MARK: - Self-test

func selfTest() -> [String] {
	var failures: [String] = []
	func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

	// Sixty frames a sixtieth apart: none dropped.
	let refresh = 1.0 / 60
	let steady = (0 ..< 60).map { Double($0) * refresh }
	let smooth = FrameStatistics(times: steady, refresh: refresh, start: 0, end: steady.last!)
	check(smooth.dropped == 0 && smooth.missedIntervals == 0, "steady frames counted as dropped: \(smooth)")
	check(abs(smooth.worstGapMilliseconds - 16.7) < 0.1, "steady worst gap \(smooth.worstGapMilliseconds)")

	// Three frames missing in the middle: one gap of four intervals, three intervals missed.
	var holed = steady
	holed.removeSubrange(20 ..< 23)
	let hole = FrameStatistics(times: holed, refresh: refresh, start: 0, end: steady.last!)
	check(hole.dropped == 1, "a hole of three frames: \(hole.dropped) dropped")
	check(hole.missedIntervals == 3, "a hole of three frames: \(hole.missedIntervals) missed")
	check(abs(hole.worstGapMilliseconds - 66.7) < 0.1, "a hole of three frames: worst \(hole.worstGapMilliseconds)")

	// A gap of 1.4 intervals is jitter, not a drop; 1.6 is a drop.
	let jitter = FrameStatistics(times: [0, refresh, refresh * 2.4, refresh * 3.4], refresh: refresh, start: 0, end: refresh * 3.4)
	check(jitter.dropped == 0, "1.4 intervals counted as a drop")
	let late = FrameStatistics(times: [0, refresh, refresh * 2.6, refresh * 3.6], refresh: refresh, start: 0, end: refresh * 3.6)
	check(late.dropped == 1, "1.6 intervals not counted as a drop")

	// The wait for the first frame is latency, not a drop; frames outside the window don't count;
	// a stall at the end does.
	let latent = FrameStatistics(times: [-1, 0.03, 0.03 + refresh, 5], refresh: refresh, start: 0, end: 0.03 + refresh)
	check(latent.frames == 2, "frames outside the window counted: \(latent.frames)")
	check(latent.dropped == 0 && abs(latent.firstFrameMilliseconds - 30) < 0.1, "the first frame's wait counted: \(latent)")
	let stalledEnd = FrameStatistics(times: [0, refresh], refresh: refresh, start: 0, end: 0.2)
	check(stalledEnd.dropped == 1 && stalledEnd.missedIntervals == 10, "a stall at the end: \(stalledEnd)")

	// No frame in a second at 60 Hz: one gap, the 59 intervals after the first missed.
	let empty = FrameStatistics(times: [], refresh: refresh, start: 0, end: 1)
	check(empty.frames == 0 && empty.dropped == 1 && empty.missedIntervals == 59, "no frames at all: \(empty)")

	// At 120 Hz a 16.7 ms gap is a drop.
	let fast = FrameStatistics(times: [0, 1.0 / 120, 1.0 / 120 + 1.0 / 60], refresh: 1.0 / 120, start: 0, end: 1.0 / 120 + 1.0 / 60)
	check(fast.dropped == 1, "a 60 Hz gap at 120 Hz isn't a drop")

	// Legs: short lists in tall windows don't scroll; long ones share the longest leg.
	check(legPoints(rows: 1, windowHeight: 900) == nil, "a single tab scrolls")
	check(legPoints(rows: 30, windowHeight: 2000) == nil, "30 tabs scroll in a 2000-point window")
	if let leg = legPoints(rows: 30, windowHeight: 900) {
		check(leg < 30 * rowPitch - (900 - sidebarChrome), "a 30-tab leg reaches the list's end: \(leg)")
	} else {
		failures.append("30 tabs don't scroll in a 900-point window")
	}
	check(legPoints(rows: 150, windowHeight: 900) == legRange.upperBound && legPoints(rows: 400, windowHeight: 1400) == legRange.upperBound, "long lists' legs")

	// The script: the list moves on every frame, legs alternate, each a whole gesture adding up to
	// its length, at the pace asked, in pairs that end where they began.
	for (rate, leg) in [(60.0, 600.0), (120.0, 600.0), (120.0, 208.0), (60.0, 120.0), (120.0, 1500.0)] {
		let script = scrollScript(seconds: 6, refresh: 1 / rate, speed: 840, leg: leg)
		let label = "\(Int(rate)) Hz, \(Int(leg)) pt legs"
		check(script.count >= Int(6 * rate), "\(label): \(script.count) frames for 6 s")
		check(script.allSatisfy { frame in frame.reduce(0) { $0 + $1.points } != 0 }, "\(label): a frame that moves nothing")
		check(script.flatMap { $0 }.reduce(0) { $0 + $1.points } == 0, "\(label): the list doesn't end where it began")
		var legs: [Int] = []
		var current = 0
		for move in script.flatMap({ $0 }) {
			current += move.points
			if move.momentum == 3 { legs.append(current); current = 0 }
		}
		check(legs.count >= 2 && legs.count % 2 == 0, "\(label): legs \(legs)")
		check(legs.allSatisfy { abs($0) == Int(leg) }, "\(label): legs of other lengths \(Set(legs))")
		check(script.first?.first == Move(points: script.first?.first?.points ?? 0, phase: 1, momentum: 0)
			&& (script.first?.first?.points ?? 0) > 0, "\(label): the first event isn't a beginning down the list")
		let pace = 840 / rate + 1
		check(script.flatMap { $0 }.filter { $0.phase == 2 }.allSatisfy { Double(abs($0.points)) <= pace }, "\(label): fingers faster than 840 points a second")
		check(script.flatMap { $0 }.contains { $0.momentum == 2 }, "\(label): no glide after the fingers lift")
	}

	// CPU: a child spinning its main thread shows up in both counters.
	let child = Process()
	child.executableURL = URL(fileURLWithPath: "/bin/sh")
	child.arguments = ["-c", "while :; do :; done"]
	do {
		try child.run()
		Thread.sleep(forTimeInterval: 0.05)

		// Up to three seconds for 20 ms of it: a loaded Mac gives the child little time.
		let before = CPU.mainThread(of: child.processIdentifier)
		var after = before
		var process: Double?
		let until = Date(timeIntervalSinceNow: 3)
		repeat {
			Thread.sleep(forTimeInterval: 0.1)
			after = CPU.mainThread(of: child.processIdentifier)
			process = CPU.process(child.processIdentifier)
		} while Date() < until && (after?.milliseconds ?? 0) - (before?.milliseconds ?? 0) <= 20
		child.terminate()
		child.waitUntilExit()
		if let before, let after {
			check(after.milliseconds - before.milliseconds > 20, "a spinning main thread used \(after.milliseconds - before.milliseconds) ms in 3 s")
		} else {
			failures.append("proc_pidinfo can't read another process's main thread")
		}
		check((process ?? 0) > 20, "proc_pid_rusage read \(process ?? -1) ms for a spinning process")
	} catch {
		failures.append("couldn't start /bin/sh: \(error)")
	}
	return failures
}

// MARK: - Main

func write(_ object: [String: Any], to path: String?) {
	guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
	if let path {
		FileManager.default.createFile(atPath: path, contents: data)
	} else {
		FileHandle.standardOutput.write(data)
		FileHandle.standardOutput.write(Data("\n".utf8))
	}
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "self-test":
	let failures = selfTest()
	failures.forEach { FileHandle.standardError.write(Data("self-test: \($0)\n".utf8)) }
	print(failures.isEmpty ? "sidebar scroll driver self-test passed" : "sidebar scroll driver self-test failed")
	exit(failures.isEmpty ? 0 : 1)
case "clock-check":
	_ = NSApplication.shared
	guard let screen = NSScreen.main ?? NSScreen.screens.first else {
		print("no screen")
		exit(1)
	}
	let pacer = Pacer()
	let link = screen.displayLink(target: pacer, selector: #selector(Pacer.tick(_:)))
	link.add(to: .main, forMode: .common)
	RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
	link.invalidate()
	let clock = FrameStatistics(times: pacer.ticks, refresh: pacer.interval, start: pacer.ticks.first ?? 0, end: pacer.ticks.last ?? 0)
	write(["ticks": pacer.ticks.count, "screen_max_fps": screen.maximumFramesPerSecond].merging(clock.json) { $1 }, to: nil)
	exit(pacer.ticks.count > 20 ? 0 : 1)
case "preflight":
	let missing = preflight()
	write(["missing": missing], to: nil)
	exit(missing.isEmpty ? 0 : 3)
case "run":
	var output: String?
	do {
		let options = try Options(arguments.dropFirst())
		output = options.output
		write(try run(options), to: output)
		exit(0)
	} catch let Failure.usage(message) {
		FileHandle.standardError.write(Data("usage: \(message)\n".utf8))
		exit(2)
	} catch let Failure.permission(message) {
		write(["error": message, "permission": true], to: output)
		exit(3)
	} catch let Failure.run(message) {
		write(["error": message], to: output)
		exit(1)
	} catch {
		write(["error": "\(error)"], to: output)
		exit(1)
	}
default:
	FileHandle.standardError.write(Data("usage: sidebar_scroll_driver run --pid PID [options] | preflight | self-test\n".utf8))
	exit(2)
}
