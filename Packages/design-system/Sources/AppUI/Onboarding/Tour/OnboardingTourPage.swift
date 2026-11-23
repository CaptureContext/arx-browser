import SwiftUI

/// A tour page: the headline, one line, a looping demo and a note that it's sample data.
///
/// The footer is drawn by the onboarding window. A small Pause button beside the note stops
/// the demo for people who'd rather it held still; it's reachable from the keyboard.
public struct OnboardingTourPage: View {
	public let demo: TourDemo
	public let frozenTime: TimeInterval?

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var isPlaying: Bool

	/// - Parameters:
	///   - frozenTime: Holds the demo at this time and hides Pause, for snapshots.
	public init(
		demo: TourDemo,
		frozenTime: TimeInterval? = nil
	) {
		self.demo = demo
		self.frozenTime = frozenTime
		self._isPlaying = .init(initialValue: true)
	}

	public var body: some View {
		OnboardingPageLayout(
			title: demo.headline,
			message: demo.message
		) {
			VStack(spacing: 10) {
				Group {
					if let frozenTime {
						TourDemoCanvas(demo: demo, time: frozenTime)
					} else {
						TourDemoPlayer(demo: demo, isPlaying: isPlaying)
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)

				HStack(spacing: 8) {
					Text(localized: .appUI.onboarding.tour.note)
						.font(.caption)
						.foregroundStyle(.secondary)

					if !reduceMotion, frozenTime == nil {
						Button {
							isPlaying.toggle()
						} label: {
							Image(systemName: isPlaying ? "pause.fill" : "play.fill")
								.font(.system(size: 9, weight: .semibold))
								.frame(width: 16, height: 16)
						}
						.buttonStyle(.borderless)
						.foregroundStyle(.secondary)
						.help(playTitle)
						.accessibilityLabel(playTitle)
					}
				}
			}
			.padding(.bottom, 4)
		}
	}

	private var playTitle: String {
		isPlaying
		? String.localized(.appUI.onboarding.tour.pause)
		: String.localized(.appUI.onboarding.tour.play)
	}
}
