import SwiftUI

/// The main window's page-load indicator: a short track above the page card with a
/// bright line running through it while loading, and a single pulse of the whole
/// track when loading ends.
public struct BrowserLoadingLine: View {
	private let isLoading: Bool

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var isVisible: Bool

	@SwiftUI.State
	private var pulse: Double

	@SwiftUI.State
	private var started: Date

	public init(isLoading: Bool) {
		self.isLoading = isLoading
		self._isVisible = .init(initialValue: isLoading)
		self._pulse = .init(initialValue: 0)
		self._started = .init(initialValue: .now)
	}

	public var body: some View {
		let metrics = BrowserMetrics.LoadingLine.self
		ZStack(alignment: .leading) {
			Capsule().fill(BrowserTheme.text.opacity(metrics.trackOpacity))
			if isLoading {
				if reduceMotion {
					Capsule().fill(BrowserTheme.text.opacity(metrics.lineOpacity * 0.6))
				} else {
					TimelineView(.animation) { context in
						let span = Self.span(at: context.date.timeIntervalSince(started))
						Capsule()
							.fill(BrowserTheme.text.opacity(metrics.lineOpacity))
							.frame(width: metrics.width * (span.upperBound - span.lowerBound))
							.offset(x: metrics.width * span.lowerBound)
					}
				}
			}

			// The finishing pulse: the whole track lights up, then fades with it.
			Capsule().fill(BrowserTheme.text.opacity(metrics.lineOpacity * pulse))
		}
		.frame(width: metrics.width, height: metrics.height)
		.opacity(isVisible ? 1 : 0)
		.allowsHitTesting(false)
		.accessibilityHidden(true)
		.onChange(of: isLoading) { _, loading in
			if loading {
				started = .now
				pulse = 0
				isVisible = true
			} else {
				finish()
			}
		}
	}

	private func finish() {
		guard isVisible else { return }
		let fade = BrowserMetrics.LoadingLine.finishDuration
		pulse = 1
		withAnimation(.easeOut(duration: fade)) {
			pulse = 0
			isVisible = false
		}
	}

	/// The lit part of the track for one running cycle: the head runs ahead, then the
	/// tail catches up, so the line enters on the left and leaves on the right.
	internal static func span(at elapsed: TimeInterval) -> ClosedRange<CGFloat> {
		let period = BrowserMetrics.LoadingLine.period
		let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: period) / period)
		let head = ease(min(1, phase / 0.7))
		let tail = ease(max(0, (phase - 0.3) / 0.7))
		return tail...max(tail, head)
	}

	private static func ease(_ value: CGFloat) -> CGFloat {
		let x = min(max(value, 0), 1)
		return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
	}
}

/// Little Arx's page-load indicator under the host in the address field: a bar the
/// width of the host that pulses while loading.
internal struct BrowserLoadingUnderline: ViewModifier {
	private let isLoading: Bool

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var dimmed: Bool

	internal init(isLoading: Bool) {
		self.isLoading = isLoading
		self._dimmed = .init(initialValue: false)
	}

	internal func body(content: Content) -> some View {
		let metrics = BrowserMetrics.LoadingUnderline.self

		// The bar is attached before scaling so it keeps the shrunken host's width.
		content
			.overlay(alignment: .bottom) {
				if isLoading {
					Capsule()
						.fill(BrowserTheme.text.opacity(dimmed ? metrics.dimOpacity : metrics.brightOpacity))
						.frame(height: metrics.height)
						.padding(.horizontal, metrics.horizontalInset)
						.offset(y: metrics.drop)
						.transition(.opacity)
						.onAppear {
							dimmed = false
							guard !reduceMotion else { return }
							let pulse: Animation = .easeInOut(duration: metrics.halfPeriod)
								.repeatForever(autoreverses: true)
							withAnimation(pulse) { dimmed = true }
						}
						.accessibilityHidden(true)
				}
			}
			.scaleEffect(isLoading ? metrics.textScale : 1)
			.offset(y: isLoading ? -metrics.lift : 0)
			.animation(.easeOut(duration: 0.2), value: isLoading)
	}
}

extension BrowserMetrics {
	public enum LoadingLine {
		public static let width: CGFloat = 120
		public static let height: CGFloat = 3
		public static let trackOpacity: Double = 0.12
		public static let lineOpacity: Double = 0.75

		/// One run of the line through the track.
		public static let period: TimeInterval = 1.1
		public static let finishDuration: TimeInterval = 0.45
	}

	public enum LoadingUnderline {
		public static let height: CGFloat = 3
		public static let textScale: CGFloat = 0.9

		/// How far the host rises to make room for the bar.
		public static let lift: CGFloat = 3

		/// The bar's distance below the host's baseline box.
		public static let drop: CGFloat = 5
		public static let horizontalInset: CGFloat = 2
		public static let brightOpacity: Double = 0.7
		public static let dimOpacity: Double = 0.15
		public static let halfPeriod: TimeInterval = 0.55
	}
}
