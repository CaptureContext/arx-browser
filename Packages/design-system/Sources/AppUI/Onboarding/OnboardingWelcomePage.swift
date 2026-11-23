import SwiftUI

/// The first onboarding page: the Arx app logo, the "arx" wordmark, a tagline and Get Started.
///
/// The entrance plays once when the page appears. It is view-local state, so no
/// animation frames reach a store. Under Reduce Motion everything fades in place.
public struct OnboardingWelcomePage: View {
	public let getStarted: () -> Void

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var hasAppeared: Bool

	/// - Parameters:
	///   - hasAppeared: Starts the page in its final state, for snapshots.
	///   - getStarted: Get Started, also on Return.
	public init(
		hasAppeared: Bool = false,
		getStarted: @escaping () -> Void
	) {
		self.getStarted = getStarted
		self._hasAppeared = .init(initialValue: hasAppeared)
	}

	public var body: some View {
		VStack(spacing: 0) {
			OnboardingAppLogo(size: 112)
				.scaleEffect(hasAppeared || reduceMotion ? 1 : 0.6)
				.rotationEffect(hasAppeared || reduceMotion ? .zero : .degrees(-12))
				.opacity(hasAppeared ? 1 : 0)
				.animation(entrance(delay: 0), value: hasAppeared)
				.padding(.bottom, 28)

			Text(verbatim: ArxWordmark.text)
				.font(.arxWordmark(size: 64, weight: ArxWordmark.weights.upperBound))
				.foregroundStyle(.primary)
				.accessibilityLabel(Text(localized: .appUI.onboarding.welcome.wordmark))
				.accessibilityAddTraits(.isHeader)
				.modifier(Rise(isVisible: hasAppeared, reduceMotion: reduceMotion))
				.animation(entrance(delay: 0.12), value: hasAppeared)

			Text(localized: .appUI.onboarding.welcome.tagline)
				.font(.title3)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.top, 8)
				.modifier(Rise(isVisible: hasAppeared, reduceMotion: reduceMotion))
				.animation(entrance(delay: 0.2), value: hasAppeared)

			OnboardingPrimaryButton(String.localized(.appUI.onboarding.getStarted), action: getStarted)
			.padding(.top, 32)
			.modifier(Rise(isVisible: hasAppeared, reduceMotion: reduceMotion))
			.animation(entrance(delay: 0.3), value: hasAppeared)
		}
		.padding(32)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onAppear { hasAppeared = true }
	}

	private func entrance(delay: Double) -> Animation {
		reduceMotion
		? .easeOut(duration: 0.3).delay(delay)
		: .spring(duration: 0.7, bounce: 0.3).delay(delay)
	}
}

/// The Arx app logo: the mark on a keycap tile, as in the app icon.
public struct OnboardingAppLogo: View {
	public let size: CGFloat

	public init(size: CGFloat) {
		self.size = size
	}

	public var body: some View {
		let shape: RoundedRectangle = .init(
			cornerRadius: size * 0.225,
			style: .continuous
		)
		let markWidth: CGFloat = size * 0.56

		ZStack {
			shape
				.fill(.background)
				.shadow(color: .black.opacity(0.18), radius: size * 0.08, y: size * 0.04)
			shape
				.strokeBorder(.primary.opacity(0.08), lineWidth: 1)
			ArxLogo()
				.fill(.primary)
				.frame(
					width: markWidth,
					height: markWidth * ArxLogo.designSize.height / ArxLogo.designSize.width
				)
		}
		.frame(width: size, height: size)
		.accessibilityHidden(true)
	}
}

private struct Rise: ViewModifier {
	internal let isVisible: Bool
	internal let reduceMotion: Bool

	internal func body(content: Content) -> some View {
		content
			.opacity(isVisible ? 1 : 0)
			.offset(y: isVisible || reduceMotion ? 0 : 12)
	}
}
