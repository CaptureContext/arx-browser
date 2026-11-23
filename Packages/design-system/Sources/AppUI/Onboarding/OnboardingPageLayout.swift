import AppKit
import SwiftUI

/// A page after the welcome: the small logo and wordmark, a title, a one-line message and content.
public struct OnboardingPageLayout<Content: View>: View {
	public let title: String
	public let message: String
	public let content: Content

	public init(
		title: String,
		message: String,
		@ViewBuilder content: () -> Content
	) {
		self.title = title
		self.message = message
		self.content = content()
	}

	public var body: some View {
		VStack(spacing: 0) {
			OnboardingPageHeader(title: title, message: message)

			content
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.padding(.top, 24)
		}
		.padding(.top, OnboardingPageMetrics.top)
		.padding(.horizontal, OnboardingPageMetrics.horizontal)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

/// A page whose content scrolls under its header (DEV-1300): the logo, title, message and
/// `pinned`, such as Make it yours' browsers, stay put as the scroll view's bar, and content
/// passing under them is blurred and veiled with Arx's progressive edge (`arxScrollBar`), as
/// under a header bar, instead of being cut at a line. At the bottom it runs under the
/// window's footer and its soft edge (``SwiftUI/View/onboardingFooterEdge()``).
public struct OnboardingScrollingPageLayout<Pinned: View, Content: View>: View {
	public let title: String
	public let message: String
	public let pinned: Pinned
	public let content: Content

	public init(
		title: String,
		message: String,
		@ViewBuilder pinned: () -> Pinned,
		@ViewBuilder content: () -> Content
	) {
		self.title = title
		self.message = message
		self.pinned = pinned()
		self.content = content()
	}

	public var body: some View {
		ScrollView {
			content
				.frame(maxWidth: .infinity)
				.padding(.horizontal, OnboardingPageMetrics.horizontal)
		}
		.scrollBounceBehavior(.basedOnSize)
		.scrollIndicators(.automatic)
		.onboardingFooterEdge()

		// Content is hidden under the title and the pinned row, so they stay readable, and fades
		// in over the header's last points instead of meeting it at a line.
		.arxScrollBar(
			background: Color(nsColor: .windowBackgroundColor),
			edgeStyle: .onboardingHeader,
			ramp: OnboardingPageMetrics.edgeRamp
		) {
			VStack(spacing: 0) {
				OnboardingPageHeader(title: title, message: message)
				pinned
			}
			.frame(maxWidth: .infinity)

			// The soft edge fades in here, below the header's text.
			.padding(.bottom, OnboardingPageMetrics.edgeRamp)
			.padding(.top, OnboardingPageMetrics.top)
			.padding(.horizontal, OnboardingPageMetrics.horizontal)
		}
	}
}

/// The logo and wordmark, the title and the one-line message at the top of a page.
public struct OnboardingPageHeader: View {
	public let title: String
	public let message: String

	public init(
		title: String,
		message: String
	) {
		self.title = title
		self.message = message
	}

	public var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 6) {
				OnboardingAppLogo(size: 22)
				Text(verbatim: ArxWordmark.text)
					.font(.arxWordmark(size: 18, weight: ArxWordmark.weights.upperBound))
			}
			.accessibilityHidden(true)
			.padding(.bottom, 20)

			Text(title)
				.font(.title.weight(.semibold))
				.multilineTextAlignment(.center)
				.accessibilityAddTraits(.isHeader)

			Text(message)
				.font(.body)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.top, 6)
		}
	}
}

internal enum OnboardingPageMetrics {
	/// From the window's title bar to the logo.
	internal static let top: CGFloat = 36
	internal static let horizontal: CGFloat = 40

	/// The empty space at the bottom of a scrolling page's header, where its soft edge eases out.
	internal static let edgeRamp: CGFloat = 16
}

/// Page progress: one segment per page, with the current one longer and highlighted.
public struct OnboardingProgress: View {
	public let count: Int
	public let current: Int

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	public init(
		count: Int,
		current: Int
	) {
		self.count = count
		self.current = current
	}

	public var body: some View {
		HStack(spacing: 4) {
			ForEach(0..<count, id: \.self) { index in
				Capsule()
					.fill(index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
					.frame(width: index == current ? 18 : 8, height: 4)
			}
		}
		.animation(reduceMotion ? nil : .smooth(duration: 0.3), value: current)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(localized: .appUI.onboarding.progress(current + 1, count)))
	}
}

/// The bottom bar: Back and progress on the left, Skip and the main action on the right.
///
/// The buttons follow the app's controls (DEV-791): Back is a round raised tile, the
/// main action an accent Arx button showing ↩, and Skip a quiet plain Arx button beside it.
public struct OnboardingFooter: View {
	public let progress: (count: Int, current: Int)?
	public let back: (() -> Void)?
	public let skipTitle: String
	public let skip: (() -> Void)?
	public let primaryTitle: String?
	public let primary: (() -> Void)?
	public let isEnabled: Bool
	public let isPrimaryEnabled: Bool

	/// - Parameters:
	///   - skip: Skip, or `nil` when the page has nothing to skip.
	///   - isEnabled: `false` while the page waits on something, such as a system prompt.
	///   - isPrimaryEnabled: `false` while only the main action can't go ahead yet, such as an
	///     import with nothing to bring; Back and Skip still work.
	public init(
		progress: (count: Int, current: Int)?,
		back: (() -> Void)?,
		skipTitle: String,
		skip: (() -> Void)?,
		primaryTitle: String?,
		primary: (() -> Void)?,
		isEnabled: Bool = true,
		isPrimaryEnabled: Bool = true
	) {
		self.progress = progress
		self.back = back
		self.skipTitle = skipTitle
		self.skip = skip
		self.primaryTitle = primaryTitle
		self.primary = primary
		self.isEnabled = isEnabled
		self.isPrimaryEnabled = isPrimaryEnabled
	}

	public var body: some View {
		HStack(spacing: 12) {
			if let back {
				OnboardingBackButton(action: back)
					.transition(.opacity.combined(with: .scale(scale: 0.8)))
			}

			if let progress {
				OnboardingProgress(count: progress.count, current: progress.current)
			}

			Spacer(minLength: 12)

			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				if let skip {
					OnboardingSecondaryButton(skipTitle, action: skip)
				}

				if let primaryTitle, let primary {
					OnboardingPrimaryButton(primaryTitle, action: primary)
						.disabled(!isPrimaryEnabled)
				}
			}
		}

		// Back leaves once going back no longer makes sense, as after an import.
		.animation(.smooth(duration: 0.3), value: back == nil)
		.disabled(!isEnabled)
		.padding(.horizontal, 20)
		.padding(.vertical, 16)
	}
}

/// The setup guide's main action: an accent Arx button showing ↩, which it answers.
public struct OnboardingPrimaryButton: View {
	private let title: String
	private let action: () -> Void

	public init(
		_ title: String,
		action: @escaping () -> Void
	) {
		self.title = title
		self.action = action
	}

	public var body: some View {
		Button(action: action) {
			ArxButtonLabel(title, keyHint: .return)
		}
		.buttonStyle(.arx(.primary, size: OnboardingButtonMetrics.size))
		.keyboardShortcut(.defaultAction)
	}
}

/// A quiet action beside the main one, such as Skip Setup, Skip Tour or Start Fresh: a plain Arx
/// button with secondary text that only fills while hovered or pressed.
public struct OnboardingSecondaryButton: View {
	private let title: String
	private let action: () -> Void

	public init(
		_ title: String,
		action: @escaping () -> Void
	) {
		self.title = title
		self.action = action
	}

	public var body: some View {
		Button(title, action: action)
			.buttonStyle(.arx(.plain, size: OnboardingButtonMetrics.size))
	}
}

/// Back: a rounded-square raised tile with a chevron, the same tile as a header bar's Back (DEV-790). ⌘[ goes back too.
public struct OnboardingBackButton: View {
	private let action: () -> Void

	public init(action: @escaping () -> Void) {
		self.action = action
	}

	public var body: some View {
		Button(action: action) {
			Image(systemName: "chevron.left")
				.font(.system(size: 13, weight: .medium))
		}
		.buttonStyle(.arxRaised(.square, size: OnboardingButtonMetrics.size))
		.keyboardShortcut("[", modifiers: .command)
		.accessibilityLabel(Text(localized: .appUI.onboarding.back))
		.help(String.localized(.appUI.onboarding.back))
	}
}

internal enum OnboardingButtonMetrics {
	/// The guide's buttons share a modal's larger frame.
	internal static let size: ArxControlSize = ArxModalMetrics.buttonSize
}

// MARK: - Footer edge

/// How strongly the footer's soft edge shows: 0 while nothing scrolls under the footer, 1 once
/// a page's scrolling content reaches a fade's height under it. Set with
/// ``SwiftUI/View/onboardingFooterEdge()``.
public struct OnboardingFooterEdgeKey: PreferenceKey {
	public static let defaultValue: CGFloat = 0

	public static func reduce(
		value: inout CGFloat,
		nextValue: () -> CGFloat
	) {
		value = max(value, nextValue())
	}
}

extension View {
	/// Reports how much of this scroll view's content is under the onboarding footer, so the
	/// footer's soft edge (``OnboardingFooterEdge``) shows over it.
	public func onboardingFooterEdge() -> some View {
		modifier(OnboardingFooterEdgeTracking())
	}
}

private struct OnboardingFooterEdgeTracking: ViewModifier {
	@SwiftUI.State
	private var hiddenBelow: CGFloat = 0

	internal func body(content: Content) -> some View {
		content
			.onScrollGeometryChange(for: CGFloat.self) { geometry in

				// Content past the footer's top edge, which is the scroll view's bottom inset.
				geometry.contentSize.height - (geometry.visibleRect.maxY - geometry.contentInsets.bottom)
			} action: { _, hidden in
				hiddenBelow = hidden
			}
			.preference(key: OnboardingFooterEdgeKey.self, value: ArxScrollEdgeFade.opacity(scrolledBy: hiddenBelow))
	}
}

/// Arx's progressive soft edge behind the onboarding footer, from the window's bottom up past
/// the footer: content scrolling under it is blurred and veiled most at the bottom.
public struct OnboardingFooterEdge: View {
	/// How far above the window's bottom it reaches: the footer (16-point padding around 34-point
	/// buttons) and a short fade just above it, so content further up stays sharp (Maxim, 12 Nov).
	public static let height: CGFloat = 76

	public let reveal: CGFloat

	public init(reveal: CGFloat) {
		self.reveal = reveal
	}

	public var body: some View {
		ArxProgressiveEdge(background: Color(nsColor: .windowBackgroundColor), edge: .bottom, ramp: 14)
			.frame(height: Self.height)
			.opacity(reveal)
	}
}

extension ArxProgressiveEdge.Style {
	/// Under an onboarding page's header: an opaque veil under its text, easing out over the
	/// layout's ramp, with the standard blur where it does (DEV-1300).
	internal static let onboardingHeader: Self = .init(
		radius: 2,
		plateau: 0.55,
		veilTop: 1,
		veilPlateau: 1,
		veilLate: 1,
		translucentVeil: 0.1
	)
}
