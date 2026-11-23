import AppKit
@testable import AppUI
import Foundation
import SwiftUI
import Testing

/// DEV-1235: what one frame of scrolling the sidebar's list costs the main thread. The list is
/// hosted in a window far off every screen and scrolled a step at a time, each step laid out and
/// committed before the next, so a step's time is the work a display frame would have to fit.
///
/// Beside each step's wall time it reports the main thread's CPU time and the instructions it
/// ran, which hold steady when the Mac is busy with something else.
///
/// Off unless `ARX_SIDEBAR_SCROLL_COST` is set: it prints numbers rather than asserting them.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views")
)
internal struct SidebarScrollCostTests {
	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_SIDEBAR_SCROLL_COST"] != nil))
	internal func scrollingTheList() throws {
		let environment = ProcessInfo.processInfo.environment
		let tabs: Int = environment["ARX_SIDEBAR_SCROLL_TABS"].flatMap(Int.init) ?? 400
		let step: CGFloat = environment["ARX_SIDEBAR_SCROLL_STEP"].flatMap(Double.init).map { CGFloat($0) } ?? 40
		let passes: Int = environment["ARX_SIDEBAR_SCROLL_PASSES"].flatMap(Int.init) ?? 3

		let sidebar = ScrolledSidebar(tabs: tabs)
		defer { sidebar.close() }
		let scrollView = try #require(sidebar.scrollView)

		var samples: [ScrollStep] = []
		#if DEBUG
		SidebarRenderTrace.startRecording()
		#endif
		for _ in 0..<passes {
			samples += sidebar.scroll(scrollView, by: step)
			samples += sidebar.scroll(scrollView, by: -step)
		}
		#if DEBUG
		let rowBodies: Int = SidebarRenderTrace.counts?.values.reduce(0, +) ?? 0
		let sidebarBodies: Int = SidebarRenderTrace.views?.values.reduce(0, +) ?? 0
		SidebarRenderTrace.stopRecording()
		#else
		let rowBodies: Int = -1
		let sidebarBodies: Int = -1
		#endif

		func summary(_ value: (ScrollStep) -> Double) -> (median: Double, p90: Double, p99: Double, max: Double) {
			let sorted: [Double] = samples.map(value).sorted()
			func percentile(_ share: Double) -> Double {
				sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
			}
			return (percentile(0.5), percentile(0.9), percentile(0.99), sorted.last ?? 0)
		}
		let wall = summary(\.wall)
		let cpu = summary(\.cpu)
		let instructions = summary(\.instructions)
		let report = String(
			format: "SIDEBAR_SCROLL_COST tabs=%d step=%.0f frames=%d wall median=%.2fms p90=%.2fms p99=%.2fms max=%.2fms | cpu median=%.2fms p90=%.2fms p99=%.2fms | instructions median=%.1fM p90=%.1fM p99=%.1fM | over8.3ms=%d over16.7ms=%d rowBodies=%d sidebarBodies=%d",
			tabs,
			Double(step),
			samples.count,
			wall.median,
			wall.p90,
			wall.p99,
			wall.max,
			cpu.median,
			cpu.p90,
			cpu.p99,
			instructions.median,
			instructions.p90,
			instructions.p99,
			samples.count { $0.wall > 8.33 },
			samples.count { $0.wall > 16.67 },
			rowBodies,
			sidebarBodies
		)
		print(report)
		if let path = environment["ARX_SIDEBAR_SCROLL_COST_OUT"] {
			try (report + "\n").write(toFile: path, atomically: true, encoding: .utf8)
		}
	}
}

extension SidebarScrollCostTests {
	/// DEV-1235: what selecting the next space costs, frame by frame, from the selection changing
	/// until the sidebar has come to rest: the frame that mounts a neighbouring space is the one a
	/// swipe between spaces stutters on as it lands.
	///
	/// Off unless `ARX_SIDEBAR_SWITCH_COST` is set.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_SIDEBAR_SWITCH_COST"] != nil))
	internal func switchingSpace() async throws {
		let environment = ProcessInfo.processInfo.environment
		let tabs: Int = environment["ARX_SIDEBAR_SCROLL_TABS"].flatMap(Int.init) ?? 40
		let spaces: Int = 6

		let pager = SwitchedPager(spaceCount: spaces, tabs: tabs)
		defer { pager.close() }
		_ = await pager.frames(count: 120)

		// To the next space and back, as a swipe or a shortcut goes, or past several at once, as
		// the footer's buttons go.
		let jumps: Bool = environment["ARX_SIDEBAR_SWITCH_JUMPS"] != nil
		let adjacent: [Int] = Array(1..<spaces) + Array((0..<spaces - 1).reversed())
		let route: [Int] = jumps ? [4, 1, 5, 0, 3, 5, 2, 0] : adjacent

		// The worst frame of each switch while the sidebar slides, the frame that takes the
		// selection included, and the worst once it rests, where the pager builds ahead.
		var sliding: [Double] = []
		var resting: [Double] = []

		// Twice: the second visit to a space is the common case.
		for index in route + route {
			let frames: [Double] = await pager.select(index).map(\.instructions)
			sliding.append(frames.prefix(pager.slidingFrames).max() ?? 0)
			resting.append(frames.dropFirst(pager.slidingFrames).max() ?? 0)
		}
		func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
		let report = String(
			format: "SIDEBAR_SWITCH_COST tabs=%d %@ switches=%d instructions | worst frame while sliding: median=%.1fM max=%.1fM | worst frame at rest: median=%.1fM max=%.1fM",
			tabs,
			jumps ? "jumps" : "adjacent",
			sliding.count,
			median(sliding),
			sliding.max() ?? 0,
			median(resting),
			resting.max() ?? 0
		)
		print(report)
		if let path = environment["ARX_SIDEBAR_SCROLL_COST_OUT"] {
			try (report + "\n").write(toFile: path, atomically: true, encoding: .utf8)
		}
	}

	/// DEV-1310: what each of five jumps to the next space costs when one follows another 180 ms
	/// later, before the sidebar has rested, from a sidebar that had rested on the first space.
	/// A jump to a space that isn't built yet builds it in the frame that takes the selection,
	/// which is the frame a swipe would uncover it in.
	///
	/// Off unless `ARX_SIDEBAR_QUICK_JUMP_COST` is set.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["ARX_SIDEBAR_QUICK_JUMP_COST"] != nil))
	internal func jumpingQuickly() async throws {
		let environment = ProcessInfo.processInfo.environment
		let tabs: Int = environment["ARX_SIDEBAR_SCROLL_TABS"].flatMap(Int.init) ?? 40
		let passes: Int = environment["ARX_SIDEBAR_SCROLL_PASSES"].flatMap(Int.init) ?? 5
		let spaces: Int = 6

		// A new sidebar each pass, so every space is one never visited.
		var worst: [[Double]] = Array(repeating: [], count: spaces - 1)
		for _ in 0..<passes {
			let pager = SwitchedPager(spaceCount: spaces, tabs: tabs)

			// Long enough at rest for the pager to build every space it builds ahead.
			_ = await pager.frames(count: 300)
			for index in 1..<spaces {
				let frames: [Double] = await pager.jump(to: index, lasting: 0.18).map(\.instructions)
				worst[index - 1].append(frames.max() ?? 0)
			}
			pager.close()
		}
		func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
		let jumps: String = worst
			.enumerated()
			.map { String(format: "jump %d: %.1fM", $0.offset + 1, median($0.element)) }
			.joined(separator: ", ")
		let report = "SIDEBAR_QUICK_JUMP_COST tabs=\(tabs) passes=\(passes) worst frame of each jump, median instructions | \(jumps)"
		print(report)
		if let path = environment["ARX_SIDEBAR_SCROLL_COST_OUT"] {
			try (report + "\n").write(toFile: path, atomically: true, encoding: .utf8)
		}
	}
}

/// What one scroll step cost.
private struct ScrollStep {
	/// Milliseconds on the clock.
	fileprivate var wall: Double

	/// Milliseconds of the main thread's CPU time.
	fileprivate var cpu: Double

	/// Millions of instructions the main thread ran.
	fileprivate var instructions: Double

	fileprivate init(
		wall: Double,
		cpu: Double,
		instructions: Double
	) {
		self.wall = wall
		self.cpu = cpu
		self.instructions = instructions
	}
}

private func threadCPUMilliseconds() -> Double {
	var time = timespec()
	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
	return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1_000_000
}

/// Millions of instructions the calling thread has run, on every kind of core. The kernel's
/// per-thread counts (`PROC_PIDTHREADCOUNTS`): a count and one record of five 64-bit numbers
/// per kind of core, instructions first.
private func threadInstructions() -> Double {
	var threadID: UInt64 = 0
	pthread_threadid_np(nil, &threadID)
	let flavor: Int32 = 34
	let header: Int = 8
	let record: Int = 40
	var buffer = [UInt8](repeating: 0, count: header + record * 4)
	let size: Int32 = buffer.withUnsafeMutableBytes { bytes in
		proc_pidinfo(getpid(), flavor, threadID, bytes.baseAddress, Int32(bytes.count))
	}
	guard size >= Int32(header + record) else { return 0 }

	return buffer.withUnsafeBytes { bytes in
		let levels = Int(bytes.loadUnaligned(as: UInt16.self))
		var total: UInt64 = 0
		for level in 0..<min(levels, 4) where header + record * (level + 1) <= Int(size) {
			total += bytes.loadUnaligned(fromByteOffset: header + record * level, as: UInt64.self)
		}
		return Double(total) / 1_000_000
	}
}

private func uuid(_ value: Int) -> UUID {
	UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
}

@MainActor
private final class ScrolledSidebar {
	private let window: NSWindow
	private let host: NSHostingView<AnyView>

	internal init(tabs: Int) {
		let size = CGSize(width: 260, height: 900)
		let saved: [SidebarItem] = (0..<4).map { folder in
			SidebarItem(
				id: .folder(uuid(100_000 + folder)),
				title: "Folder \(folder)",
				children: (0..<8).map { index in
					SidebarItem(id: .tab(uuid(50_000 + folder * 100 + index)), title: "Pinned \(folder).\(index)", isPinned: true)
				},
				isExpanded: true
			)
		}
		let open: [SidebarItem] = (0..<tabs).map { index in
			SidebarItem(
				id: .tab(uuid(index)),
				title: "Tab \(index): a page title long enough to truncate in the row",
				isPinned: false
			)
		}
		self.host = NSHostingView(
			rootView: AnyView(
				BrowserSidebar(
					spaceName: "Space",
					savedItems: saved,
					unpinnedTabs: open,
					selectedID: .tab(uuid(3)),
					pinnedHeight: 120,
					onAction: { _ in }
				)
				.environment(\.sidebarTabHoverChanged) { _ in }
				.environment(\.sidebarTabDragChanged) { _ in }
				.environment(\.sidebarHoverPreviews, .init(tabs: { _ in [:] }))
				.frame(width: size.width, height: size.height)
			)
		)
		host.frame = CGRect(origin: .zero, size: size)
		self.window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host

		// In the window server's list, so its layers are committed, but far off every screen.
		window.orderFrontRegardless()
		settle()
	}

	internal var scrollView: NSScrollView? {
		Self.scrollViews(in: host).max { $0.frame.height < $1.frame.height }
	}

	/// Scrolls to the far end in steps of `step` points, and returns each step's milliseconds.
	internal func scroll(
		_ scrollView: NSScrollView,
		by step: CGFloat
	) -> [ScrollStep] {
		let clip = scrollView.contentView
		guard let document = scrollView.documentView else { return [] }
		let top: CGFloat = -clip.contentInsets.top
		let end: CGFloat = max(document.frame.height + clip.contentInsets.bottom - clip.bounds.height, top)

		// `ARX_SIDEBAR_SCROLL_REACH` keeps the scroll to that many points from the top.
		let reach: CGFloat? = ProcessInfo.processInfo.environment["ARX_SIDEBAR_SCROLL_REACH"].flatMap(Double.init).map { CGFloat($0) }
		let bottom: CGFloat = reach.map { min(top + $0, end) } ?? end
		var samples: [ScrollStep] = []
		var y: CGFloat = clip.bounds.origin.y
		while step > 0 ? y < bottom : y > top {
			y = min(max(y + step, top), bottom)
			let start = CACurrentMediaTime()
			let cpuStart: Double = threadCPUMilliseconds()
			let instructionsStart: Double = threadInstructions()
			clip.scroll(to: .init(x: clip.bounds.origin.x, y: y))
			scrollView.reflectScrolledClipView(clip)
			host.layoutSubtreeIfNeeded()
			host.displayIfNeeded()
			CATransaction.flush()

			// One turn, for what SwiftUI puts off to the run loop's end.
			RunLoop.main.run(mode: .default, before: .now)
			host.layoutSubtreeIfNeeded()
			CATransaction.flush()
			samples.append(.init(
				wall: (CACurrentMediaTime() - start) * 1_000,
				cpu: threadCPUMilliseconds() - cpuStart,
				instructions: threadInstructions() - instructionsStart
			))
		}
		return samples
	}

	internal func close() {
		window.close()
	}

	private static func scrollViews(in view: NSView) -> [NSScrollView] {
		(view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews(in:))
	}

	private func settle() {
		for _ in 0..<5 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
	}
}

@MainActor
@Observable
private final class SwitchedSpaces {
	fileprivate var spaces: [SidebarSpace]
	fileprivate var selectedSpaceID: UUID

	fileprivate init(
		spaceCount: Int,
		tabs: Int
	) {
		self.spaces = (0..<spaceCount).map { space in
			let base: Int = (space + 1) * 1_000_000
			return SidebarSpace(
				id: uuid(base),
				name: "Space \(space)",
				// Two profiles, so some switches change the pinned header and some keep it.
				profileID: uuid(900_000_000 + space / 3),
				// A profile's spaces share its Favorites.
				favorites: (0..<6).map { SidebarItem(id: .tab(uuid(800_000_000 + (space / 3) * 100 + $0)), title: "Favorite \($0)") },
				savedItems: [
					SidebarItem(
						id: .folder(uuid(base + 200)),
						title: "Folder",
						children: (0..<8).map { SidebarItem(id: .tab(uuid(base + 300 + $0)), title: "Pinned \($0)") },
						isExpanded: true
					),
				],
				unpinnedTabs: (0..<tabs).map {
					SidebarItem(id: .tab(uuid(base + 1_000 + $0)), title: "Tab \($0): a page title long enough to truncate", isPinned: false)
				},
				selectedID: .tab(uuid(base + 1_000)),
				url: URL(string: "https://example.com/\(space)")
			)
		}
		self.selectedSpaceID = uuid(1_000_000)
	}
}

private struct SwitchedPagerRoot: View {
	fileprivate let inputs: SwitchedSpaces

	fileprivate var body: some View {
		SidebarPager(
			spaces: inputs.spaces.map(\.summary),
			selectedSpaceID: inputs.selectedSpaceID,
			space: { [inputs] id in inputs.spaces.first { $0.id == id } },
			spaceMenu: { _ in AnyView(EmptyView()) },
			onSelectSpace: { [inputs] in inputs.selectedSpaceID = $0 },
			onAction: { _, _ in },
			onCopyURL: {}
		) {
			Color.clear.frame(height: 40)
		} libraryPanel: {
			EmptyView()
		}
		.environment(\.sidebarWidths, .init(base: 260, expanded: 260))
		.environment(\.sidebarHoverPreviews, .init(tabs: { _ in [:] }))
		.environment(\.sidebarTabHoverChanged) { _ in }
	}
}

@MainActor
private final class SwitchedPager {
	private let inputs: SwitchedSpaces
	private let window: NSWindow
	private let host: NSHostingView<SwitchedPagerRoot>

	fileprivate init(
		spaceCount: Int,
		tabs: Int
	) {
		let size = CGSize(width: 260, height: 900)
		self.inputs = .init(spaceCount: spaceCount, tabs: tabs)
		self.host = NSHostingView(rootView: SwitchedPagerRoot(inputs: inputs))
		host.frame = CGRect(origin: .zero, size: size)
		self.window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host

		// The track's spring runs on the screen's display link, so the window sits on a screen,
		// transparent and passing every click through.
		if let screen = NSScreen.main {
			window.alphaValue = 0
			window.ignoresMouseEvents = true
			window.setFrameOrigin(screen.visibleFrame.origin)
			window.orderFrontRegardless()
		}
	}

	/// Selects the space at `index` and returns what each frame cost until the sidebar rests.
	fileprivate func select(_ index: Int) async -> [ScrollStep] {
		inputs.selectedSpaceID = inputs.spaces[index].id

		// The slide, which the track's spring ends within 0.4 s, then long enough at rest for the
		// pager to build the new neighbours.
		let start = CACurrentMediaTime()
		let slide: [ScrollStep] = await frames(until: { CACurrentMediaTime() - start > 0.45 })
		slidingFrames = slide.count
		return await slide + frames(count: 150)
	}

	/// Selects the space at `index` and returns what each frame cost for `seconds`, which can
	/// end before the sidebar has landed on it.
	fileprivate func jump(
		to index: Int,
		lasting seconds: TimeInterval
	) async -> [ScrollStep] {
		inputs.selectedSpaceID = inputs.spaces[index].id
		let start = CACurrentMediaTime()
		return await frames(until: { CACurrentMediaTime() - start > seconds })
	}

	fileprivate func close() {
		window.close()
	}

	/// How many of the last switch's frames fell before the sidebar came to rest.
	fileprivate private(set) var slidingFrames: Int = 0

	private func frames(until isDone: () -> Bool) async -> [ScrollStep] {
		var result: [ScrollStep] = await frames(count: 4)
		while !isDone(), result.count < 400 { result += await frames(count: 1) }
		return result
	}

	fileprivate func frames(count: Int) async -> [ScrollStep] {
		var steps: [ScrollStep] = []
		for _ in 0..<count {
			let start = CACurrentMediaTime()
			let cpuStart: Double = threadCPUMilliseconds()
			let instructionsStart: Double = threadInstructions()

			// The pager's own tasks wait their turn on the main actor, which this gives them.
			try? await Task.sleep(for: .milliseconds(1))
			spin()
			steps.append(.init(
				wall: (CACurrentMediaTime() - start) * 1_000,
				cpu: threadCPUMilliseconds() - cpuStart,
				instructions: threadInstructions() - instructionsStart
			))
		}
		return steps
	}

	/// A display frame's worth of the run loop, where the track's display link, timers and
	/// SwiftUI's own updates run, then the layout and commit that follow them.
	private func spin() {
		RunLoop.main.run(until: .now.addingTimeInterval(0.008))
		host.layoutSubtreeIfNeeded()
		CATransaction.flush()
	}
}
