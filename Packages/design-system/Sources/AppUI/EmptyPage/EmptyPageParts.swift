import AppKit
import BrowserCore
import SwiftUI

// MARK: - Environment

extension EnvironmentValues {
	/// A fixed time for snapshots; nil runs the live clock.
	@Entry
	public var emptyPageFixedTime: Double? = nil

	/// Stops the homepage's motion while something covers it in its window, as Reduce Motion and
	/// a hidden window do (DEV-1248).
	@Entry
	public var emptyPageMotionPaused: Bool = false

	/// Whether the homepage's window is on screen; nil watches the window. Tests set it, as a
	/// window kept off every screen is never visible.
	@Entry
	internal var emptyPageWindowIsVisible: Bool? = nil

	/// A scripted pointer for snapshots, which have no real one.
	@Entry
	public var emptyPageScriptedPointer: EmptyPagePointer? = nil

	/// The person's shortcuts, for the homepage's guide; empty means the defaults.
	@Entry
	public var browserShortcuts: [ShortcutBinding] = []

	/// Whether the homepage's timeline is running, for parts that look different held still.
	@Entry
	internal var emptyPageIsMoving: Bool = true
}

// MARK: - Clock

/// Seconds since launch, kept small so shaders get a precise `float`.
internal enum EmptyPageClock {
	private static let start: Date = .init()

	internal static var now: Double { time(at: .init()) }

	/// Never negative: a timeline's first frame can carry a date from before the clock started.
	internal static func time(at date: Date) -> Double {
		max(0, date.timeIntervalSince(start))
	}
}

/// Redraws its content with the time, at most 30 times a second. It stops while Reduce Motion is
/// on, while something covers the page, while its window is off screen (hidden, minimised, on
/// another OS workspace or under other windows), and when a snapshot fixes the time. It keeps
/// running in a window that is on screen but not focused (DEV-1248).
internal struct EmptyPageTimeline<Content: View>: View {
	@Environment(\.emptyPageFixedTime)
	private var fixedTime

	@Environment(\.emptyPageMotionPaused)
	private var isPaused

	@Environment(\.emptyPageWindowIsVisible)
	private var windowIsVisibleOverride

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var windowIsVisible: Bool = true

	private let content: (Double) -> Content

	internal init(@ViewBuilder content: @escaping (Double) -> Content) {
		self.content = content
	}

	internal var body: some View {
		if let fixedTime {
			content(fixedTime)
		} else {
			let isHeld: Bool = Self.isHeld(
				isPaused: isPaused,
				reduceMotion: reduceMotion,
				windowIsVisible: windowIsVisibleOverride ?? windowIsVisible
			)
			TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isHeld)) { context in
				let _ = RenderTrace.body("EmptyPageTimeline.frame")
				content(EmptyPageClock.time(at: context.date))
					.environment(\.emptyPageIsMoving, !isHeld)
			}
			.background {
				if windowIsVisibleOverride == nil {
					EmptyPageWindowVisibility { windowIsVisible = $0 }
				}
			}
		}
	}

	internal static func isHeld(
		isPaused: Bool,
		reduceMotion: Bool,
		windowIsVisible: Bool
	) -> Bool {
		isPaused || reduceMotion || !windowIsVisible
	}
}

/// Reports whether its window is on screen: macOS's occlusion state, which is off for a hidden
/// or minimised window, one on another OS workspace and one wholly under other windows. Focus
/// doesn't count.
private struct EmptyPageWindowVisibility: NSViewRepresentable {
	let onChange: (Bool) -> Void

	func makeNSView(context: Context) -> ObservingView {
		let view: ObservingView = .init()
		view.onChange = onChange
		return view
	}

	func updateNSView(
		_ view: ObservingView,
		context: Context
	) {
		view.onChange = onChange
	}

	final class ObservingView: NSView {
		var onChange: ((Bool) -> Void)?

		private var observation: NSObjectProtocol?
		private var reported: Bool?

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let observation { NotificationCenter.default.removeObserver(observation) }
			observation = nil
			guard let window else { return }

			observation = NotificationCenter.default.addObserver(
				forName: NSWindow.didChangeOcclusionStateNotification,
				object: window,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.report() }
			}
			report()
		}

		isolated deinit {
			if let observation { NotificationCenter.default.removeObserver(observation) }
		}

		private func report() {
			guard let window else { return }
			let isVisible: Bool = window.occlusionState.contains(.visible)
			guard isVisible != reported else { return }
			reported = isVisible
			onChange?(isVisible)
		}
	}
}

// MARK: - Pointer

/// Where the pointer is over the page, and what it last did there.
public struct EmptyPagePointer: Equatable, Sendable {
	public struct Sample: Equatable, Sendable {
		public var location: CGPoint
		public var time: Double

		public init(
			location: CGPoint,
			time: Double
		) {
			self.location = location
			self.time = time
		}
	}

	public static let trailLength: Int = 48

	/// Nil while the pointer is outside the page.
	public var location: CGPoint?
	public var isPressed: Bool = false
	public var click: Sample = .init(location: .zero, time: -100)

	/// The latest positions, newest last, at least two points apart.
	public var trail: [Sample] = []

	public init() {}

	public var isInside: Bool { location != nil }

	/// The pointer, or where it left the page.
	internal var point: CGPoint { location ?? trail.last?.location ?? .zero }

	public mutating func move(
		to point: CGPoint,
		at time: Double
	) {
		location = point
		if let last = trail.last, hypot(point.x - last.location.x, point.y - last.location.y) <= 2 {
			return
		}
		trail.append(.init(location: point, time: time))
		if trail.count > Self.trailLength {
			trail.removeFirst(trail.count - Self.trailLength)
		}
	}

	/// The trail as `x, y, time` triples, padded to `trailLength` with long-dried samples.
	internal var trailArgument: [Float] {
		let padding: [Sample] = .init(
			repeating: .init(location: trail.first?.location ?? .zero, time: -100),
			count: Self.trailLength - trail.count
		)
		return (padding + trail).flatMap { sample in
			[Float(sample.location.x), Float(sample.location.y), Float(sample.time)]
		}
	}

	internal var clickArgument: Shader.Argument {
		.float3(click.location.x, click.location.y, click.time)
	}
}

/// Tracks the pointer over its content, with the time.
internal struct EmptyPagePointerTracking<Content: View>: View {
	@SwiftUI.State
	private var pointer: EmptyPagePointer = .init()

	@Environment(\.emptyPageScriptedPointer)
	private var scripted

	private let content: (EmptyPagePointer, Double) -> Content

	internal init(@ViewBuilder content: @escaping (EmptyPagePointer, Double) -> Content) {
		self.content = content
	}

	internal var body: some View {
		EmptyPageTimeline { time in
			content(scripted ?? pointer, time)
		}
		.contentShape(.rect)
		.background {
			// SwiftUI's hover reports no moves over this page, so an AppKit tracking area does.
			// Snapshots script the pointer, and ImageRenderer can't draw AppKit views.
			if scripted == nil {
				EmptyPageTrackingArea { location in pointerMoved(to: location) }
			}
		}
		.simultaneousGesture(
			DragGesture(minimumDistance: 0)
				.onChanged { value in dragChanged(value) }
				.onEnded { _ in pointer.isPressed = false }
		)
	}

	private func pointerMoved(to location: CGPoint?) {
		guard let location else {
			pointer.location = nil
			return
		}
		pointer.move(to: location, at: EmptyPageClock.now)
	}

	private func dragChanged(_ value: DragGesture.Value) {
		let now: Double = EmptyPageClock.now
		if !pointer.isPressed {
			pointer.isPressed = true
			pointer.click = .init(location: value.startLocation, time: now)
		}
		pointer.move(to: value.location, at: now)
	}
}

/// Reports where the pointer is over its area, or nil once it leaves. It takes no clicks.
private struct EmptyPageTrackingArea: NSViewRepresentable {
	let onMove: (CGPoint?) -> Void

	func makeNSView(context: Context) -> TrackingView {
		let view: TrackingView = .init()
		view.onMove = onMove
		return view
	}

	func updateNSView(
		_ view: TrackingView,
		context: Context
	) {
		view.onMove = onMove
	}

	final class TrackingView: NSView {
		var onMove: ((CGPoint?) -> Void)?

		private var area: NSTrackingArea?

		override var isFlipped: Bool { true }

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func updateTrackingAreas() {
			super.updateTrackingAreas()
			if let area {
				removeTrackingArea(area)
			}
			let area: NSTrackingArea = .init(
				rect: .zero,
				options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
				owner: self
			)
			addTrackingArea(area)
			self.area = area
		}

		override func mouseEntered(with event: NSEvent) {
			report(event)
		}

		override func mouseMoved(with event: NSEvent) {
			report(event)
		}

		override func mouseExited(with event: NSEvent) {
			onMove?(nil)
		}

		private func report(_ event: NSEvent) {
			onMove?(convert(event.locationInWindow, from: nil))
		}
	}
}

// MARK: - Drawing

/// AppUI's Metal library, which SwiftPM compiles from `EmptyPageShaders.metal`.
internal enum EmptyPageShaders {
	internal static var libraryURL: URL? {
		Bundle.module.url(forResource: "default", withExtension: "metallib")
	}
}

/// Calls one of the homepage's shaders, from AppUI's own Metal library.
internal func emptyPageShader(
	_ name: String,
	_ arguments: [Shader.Argument]
) -> Shader {
	Shader(function: .init(library: .bundle(.module), name: name), arguments: arguments)
}

/// A rectangle filled by a color shader that receives its size.
internal struct EmptyPageShaderFill: View {
	private let shader: @Sendable (CGSize) -> Shader

	internal init(_ shader: @escaping @Sendable (CGSize) -> Shader) {
		self.shader = shader
	}

	internal var body: some View {
		Rectangle()
			.fill(.white)
			.visualEffect { content, proxy in
				content.colorEffect(shader(proxy.size))
			}
	}
}

/// Seeded pseudo-random numbers in 0..<1, the same every frame.
internal func emptyPageSeeded(_ index: Int, _ salt: Int) -> Double {
	let value: Double = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43_758.5453
	return value - value.rounded(.down)
}

/// A faint grid of dots or lines for the pointer to bend.
internal struct EmptyPageGrid: View {
	internal enum Style {
		case dots
		case lines
	}

	internal let style: Style
	internal let spacing: CGFloat

	internal var body: some View {
		Canvas { context, size in
			var path: Path = .init()
			switch style {
			case .dots:
				var y: CGFloat = spacing / 2
				while y < size.height {
					var x: CGFloat = spacing / 2
					while x < size.width {
						path.addEllipse(in: .init(x: x - 1.4, y: y - 1.4, width: 2.8, height: 2.8))
						x += spacing
					}
					y += spacing
				}
				context.fill(path, with: .color(BrowserTheme.text.opacity(0.22)))
			case .lines:
				var x: CGFloat = 0
				while x < size.width {
					path.move(to: .init(x: x, y: 0))
					path.addLine(to: .init(x: x, y: size.height))
					x += spacing
				}
				var y: CGFloat = 0
				while y < size.height {
					path.move(to: .init(x: 0, y: y))
					path.addLine(to: .init(x: size.width, y: y))
					y += spacing
				}
				context.stroke(path, with: .color(BrowserTheme.text.opacity(0.08)), lineWidth: 1)
			}
		}
	}
}

/// Motes rising slowly and twinkling.
internal struct EmptyPageDust: View {
	internal let time: Double

	internal var body: some View {
		Canvas { context, size in
			for index in 0..<90 {
				let speed: Double = 6 + emptyPageSeeded(index, 1) * 10
				let travel: Double = (emptyPageSeeded(index, 2) * (size.height + 40) + time * speed)
					.truncatingRemainder(dividingBy: size.height + 40)
				let y: Double = size.height - travel + 20
				let x: Double = emptyPageSeeded(index, 3) * size.width + sin(time * 0.3 + emptyPageSeeded(index, 4) * 9) * 18
				let radius: Double = 0.6 + emptyPageSeeded(index, 5) * 1.4
				let twinkle: Double = 0.5 + 0.5 * sin(time * (0.8 + emptyPageSeeded(index, 6)) + emptyPageSeeded(index, 7) * 9)
				context.fill(
					Path(ellipseIn: .init(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
					with: .color(BrowserTheme.text.opacity(0.06 + 0.14 * twinkle))
				)
			}
		}
	}
}

// MARK: - Cursor

/// The custom pointer: a shape with an optional fill and stroke.
internal struct EmptyPageCursor: View {
	private struct Key: Hashable {
		let cursor: EmptyPageStyle.Cursor
		let colorScheme: ColorScheme
	}

	/// Rendered pointers, so dragging a slider renders each size once.
	@MainActor
	private static var images: [Key: Image] = [:]

	internal let cursor: EmptyPageStyle.Cursor

	/// The shape as the system pointer, with its hot spot in the middle; nil for the regular one,
	/// so AppKit shows the regular pointer everywhere else.
	@MainActor
	internal static func pointerStyle(
		_ cursor: EmptyPageStyle.Cursor,
		colorScheme: ColorScheme
	) -> PointerStyle? {
		guard cursor.shape != .regular else { return nil }

		let key: Key = .init(cursor: cursor, colorScheme: colorScheme)
		if let image = images[key] {
			return .image(image, hotSpot: .center)
		}
		let renderer: ImageRenderer = .init(
			content: EmptyPageCursor(cursor: cursor)
				.padding(cursor.strokeWidth)
				.environment(\.colorScheme, colorScheme)
		)
		renderer.scale = 2
		guard let rendered = renderer.nsImage else { return nil }

		let image: Image = .init(nsImage: rendered)
		images[key] = image
		return .image(image, hotSpot: .center)
	}

	internal var body: some View {
		let size: CGFloat = cursor.size
		ZStack {
			switch cursor.shape {
			case .regular:
				EmptyView()
			case .circle:
				painted(Circle())
			case .square:
				painted(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
			case .triangle:
				painted(EmptyPageTriangle(cornerRadius: size * 0.14))
			}
		}
		.frame(width: size, height: size)
	}

	private func painted(_ shape: some Shape) -> some View {
		shape
			.fill(cursor.fill.style)
			.overlay {
				if cursor.strokeWidth > 0 {
					shape.stroke(cursor.stroke.style, lineWidth: cursor.strokeWidth)
				}
			}
	}
}

/// An equilateral triangle, point up, with rounded corners, as wide as its frame.
internal struct EmptyPageTriangle: Shape {
	internal var cornerRadius: CGFloat

	internal func path(in rect: CGRect) -> Path {
		let height: CGFloat = rect.width * sqrt(3) / 2
		let top: CGFloat = rect.midY - height / 2
		let points: [CGPoint] = [
			.init(x: rect.midX, y: top),
			.init(x: rect.maxX, y: top + height),
			.init(x: rect.minX, y: top + height),
		]
		var path: Path = .init()
		path.move(to: .init(x: (points[2].x + points[0].x) / 2, y: (points[2].y + points[0].y) / 2))
		for index in points.indices {
			path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % points.count], radius: cornerRadius)
		}
		path.closeSubpath()
		return path
	}
}
