import SwiftUI

/// Plays a tour demo in a loop, scaled to fit the space it's given.
///
/// The demo runs on its own `TimelineView`; nothing per-frame goes through a store. It holds
/// still while the window isn't key, while `isPlaying` is false, and under Reduce Motion, where
/// it shows the demo's key frame. VoiceOver reads the demo's description as one image.
public struct TourDemoPlayer: View {
	public let demo: TourDemo
	public let isPlaying: Bool

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@Environment(\.controlActiveState)
	private var controlActiveState

	@SwiftUI.State
	private var clock: TourDemoClock

	public init(
		demo: TourDemo,
		isPlaying: Bool = true
	) {
		self.demo = demo
		self.isPlaying = isPlaying
		self._clock = .init(initialValue: .init())
	}

	public var body: some View {
		TimelineView(.animation(minimumInterval: nil, paused: !isRunning)) { context in
			TourDemoCanvas(
				demo: demo,
				time: reduceMotion ? demo.keyFrame : clock.time(at: context.date)
			)
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(verbatim: demo.accessibilityDescription))
		.accessibilityAddTraits(.isImage)
		.onAppear { clock.setRunning(isRunning, at: .now) }
		.onDisappear { clock.setRunning(false, at: .now) }
		.onChange(of: isRunning) { _, isRunning in
			clock.setRunning(isRunning, at: .now)
		}
	}

	private var isRunning: Bool {
		isPlaying && !reduceMotion && controlActiveState == .key
	}
}

/// A demo scaled to fit, keeping its aspect ratio.
public struct TourDemoCanvas: View {
	public let demo: TourDemo
	public let time: TimeInterval

	public init(
		demo: TourDemo,
		time: TimeInterval
	) {
		self.demo = demo
		self.time = time
	}

	public var body: some View {
		GeometryReader { proxy in
			let size: CGSize = TourDemo.canvasSize
			let scale: CGFloat = min(proxy.size.width / size.width, proxy.size.height / size.height)

			TourDemoScene(demo: demo, time: time)
				.scaleEffect(scale, anchor: .topLeading)
				.frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
				.frame(width: proxy.size.width, height: proxy.size.height)
		}
		.aspectRatio(TourDemo.canvasSize, contentMode: .fit)
	}
}

/// Elapsed demo time that stops while paused and picks up where it left off.
internal struct TourDemoClock: Equatable {
	internal var elapsed: TimeInterval
	internal var resumedAt: Date?

	internal init(
		elapsed: TimeInterval = 0,
		resumedAt: Date? = nil
	) {
		self.elapsed = elapsed
		self.resumedAt = resumedAt
	}

	internal func time(at date: Date) -> TimeInterval {
		guard let resumedAt else { return elapsed }

		return elapsed + max(0, date.timeIntervalSince(resumedAt))
	}

	internal mutating func setRunning(
		_ isRunning: Bool,
		at date: Date
	) {
		switch (isRunning, resumedAt) {
		case (true, nil):
			resumedAt = date

		case (false, .some):
			elapsed = time(at: date)
			resumedAt = nil

		case (true, .some), (false, nil):
			break
		}
	}
}
