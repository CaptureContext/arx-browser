import BrowserCore
import SwiftUI

/// A small confirmation over the page, such as "Copied Current URL": a glass pill in the chrome's
/// tint with a title and a few trailing actions. It's for things that are done, so it never asks
/// anything, never takes focus, and goes away by itself.
///
/// Show it with ``SwiftUI/View/arxToast(isPresented:topInset:trailingInset:onHover:content:)``, which places it at
/// the window's top-right corner, animates it in and out (a fade under Reduce Motion) and reports
/// hover, so its owner can pause the timer that dismisses it.
///
/// ```swift
/// ArxToast("Copied Current URL") {
///     ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
///         .buttonStyle(.arxRaised(size: .small))
/// }
/// ```
public struct ArxToast<Actions: View>: View {
	private let title: String
	private let detail: String?
	private let systemImage: String?
	private let actions: Actions

	@Environment(\.browserChromeTint)
	private var tint: ChromeTint

	@Environment(\.colorScheme)
	private var colorScheme: ColorScheme

	@Environment(\.sidebarIsStatic)
	private var isStatic: Bool

	public init(
		_ title: String,
		detail: String? = nil,
		systemImage: String? = nil,
		@ViewBuilder actions: () -> Actions
	) {
		self.title = title
		self.detail = detail
		self.systemImage = systemImage
		self.actions = actions()
	}

	public var body: some View {
		let shape: RoundedRectangle = .init(cornerRadius: ArxToastMetrics.cornerRadius, style: .continuous)
		HStack(spacing: ArxToastMetrics.spacing) {
			if let systemImage {
				Image(systemName: systemImage)
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(BrowserTheme.secondary)
					.accessibilityHidden(true)
			}
			VStack(alignment: .leading, spacing: 1) {
				Text(title)
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(BrowserTheme.text)
				if let detail {
					Text(detail)
						.font(.system(size: 11))
						.foregroundStyle(BrowserTheme.secondary)
						.lineLimit(2)
						.frame(maxWidth: ArxToastMetrics.detailMaximumWidth, alignment: .leading)
				}
			}
			.fixedSize(horizontal: false, vertical: true)
			HStack(spacing: 4) {
				actions
			}
			.controlSize(.small)
		}
		.padding(.leading, ArxToastMetrics.leadingPadding)
		.padding(.trailing, ArxToastMetrics.trailingPadding)
		.frame(minHeight: ArxToastMetrics.minimumHeight)
		.fixedSize(horizontal: false, vertical: true)
		.background { surface(shape) }
		.overlay { shape.strokeBorder(BrowserTheme.pageBorder, lineWidth: 0.5) }
		.browserShadow(ArxToastMetrics.shadow)
		.focusEffectDisabled()
		.accessibilityElement(children: .contain)
		.onAppear { AccessibilityNotification.Announcement(title).post() }
	}

	/// Liquid Glass in the chrome's tint; the tint over a material where glass can't be drawn.
	@ViewBuilder
	private func surface(_ shape: RoundedRectangle) -> some View {
		let color: Color = tintColor
		if isStatic {
			shape
				.fill(.regularMaterial)
				.overlay { shape.fill(color.opacity(ArxToastMetrics.staticTintOpacity)) }
		} else {
			Color.clear.glassEffect(.regular.tint(color.opacity(ArxToastMetrics.glassTintOpacity)), in: shape)
		}
	}

	/// The middle of the sidebar's gradient, so the toast takes the window's hue, a little more
	/// vivid than the chrome so it reads as tinted. A neutral chrome keeps a neutral toast.
	private var tintColor: Color {
		let vivid: ChromeTint = .init(
			hue: tint.hue,
			intensity: min(tint.intensity * ArxToastMetrics.tintBoost, 1)
		)
		let palette: ChromePalette = .init(tint: vivid, surface: .sidebar, isDark: colorScheme == .dark)
		let top: ChromePalette.RGB = palette.top
		let bottom: ChromePalette.RGB = palette.bottom
		return Color(
			.sRGB,
			red: (top.red + bottom.red) / 2,
			green: (top.green + bottom.green) / 2,
			blue: (top.blue + bottom.blue) / 2
		)
	}
}

extension ArxToast where Actions == EmptyView {
	public init(
		_ title: String,
		detail: String? = nil,
		systemImage: String? = nil
	) {
		self.init(title, detail: detail, systemImage: systemImage) { EmptyView() }
	}
}

extension View {
	/// Shows a toast at the top-right corner, `topInset` below the top edge and `trailingInset` in
	/// from the trailing one, which is over the page's corner in a browser window. Both are
	/// measured from the view's edges, whatever safe area it has, such as a title bar.
	///
	/// It slides down and fades in, or only fades under Reduce Motion, and announces its title to
	/// VoiceOver. `onHover` reports the pointer entering and leaving it: pause the dismissal timer
	/// while it's over the toast.
	public func arxToast<Content: View>(
		isPresented: Bool,
		topInset: CGFloat = ArxToastMetrics.edgeInset,
		trailingInset: CGFloat = ArxToastMetrics.edgeInset,
		onHover: @escaping (Bool) -> Void = { _ in },
		@ViewBuilder content: () -> Content
	) -> some View {
		modifier(ArxToastPlacement(
			isPresented: isPresented,
			topInset: topInset,
			trailingInset: trailingInset,
			onHover: onHover,
			toast: content()
		))
	}
}

extension EnvironmentValues {
	/// How far toasts placed with ``SwiftUI/View/arxToast(isPresented:topInset:trailingInset:onHover:content:)``
	/// move down to sit below another toast at the same corner. The view that shows that toast
	/// sets it on the content under it, with ``ArxToastMetrics/stackOffset(below:)``.
	@Entry
	public var arxToastStackOffset: CGFloat = 0
}

public enum ArxToastMetrics {
	/// Between the toast and the edges it's placed against, by default.
	public static let edgeInset: CGFloat = 14

	/// How long a toast stays when nothing holds it.
	public static let duration: Duration = .seconds(2.5)

	/// How long it stays after the pointer leaves it.
	public static let resumeDuration: Duration = .seconds(1.5)

	/// The height of a one-line toast.
	public static let minimumHeight: CGFloat = 40

	/// The widest a toast of a whole sentence gets before it wraps, such as the sidebar's notice.
	public static let maximumWidth: CGFloat = 360

	/// Between toasts stacked at one corner.
	public static let stackSpacing: CGFloat = 8

	/// The ``SwiftUI/EnvironmentValues/arxToastStackOffset`` for toasts below one this tall.
	public static func stackOffset(below height: CGFloat) -> CGFloat {
		max(height, minimumHeight) + stackSpacing
	}

	internal static let detailMaximumWidth: CGFloat = 280
	internal static let cornerRadius: CGFloat = 12
	internal static let spacing: CGFloat = 10
	internal static let leadingPadding: CGFloat = 14
	internal static let trailingPadding: CGFloat = 6
	internal static let tintBoost: Double = 2.2
	internal static let glassTintOpacity: Double = 0.55
	internal static let staticTintOpacity: Double = 0.6
	internal static let shadow: BrowserShadow = .init(opacity: 0.16, radius: 10, y: 3)
}

private struct ArxToastPlacement<Toast: View>: ViewModifier {
	internal let isPresented: Bool
	internal let topInset: CGFloat
	internal let trailingInset: CGFloat
	internal let onHover: (Bool) -> Void
	internal let toast: Toast

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion: Bool

	@Environment(\.arxToastStackOffset)
	private var stackOffset: CGFloat

	internal func body(content: Content) -> some View {
		content
			.overlay(alignment: .topTrailing) {
				ZStack(alignment: .topTrailing) {
					if isPresented {
						toast
							.onHover(perform: onHover)
							.transition(
								reduceMotion
								? .opacity
								: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top))
							)
					}
				}
				.padding(.top, topInset + stackOffset)
				.padding(.trailing, trailingInset)

				// Measured from the view's own edges, not from its safe area: a browser window's
				// title bar is a safe area its content runs under, and the toast sat that much
				// lower than its trailing inset (DEV-823).
				.ignoresSafeArea()
				.animation(animation, value: isPresented)
				.animation(animation, value: stackOffset)
			}
	}

	private var animation: Animation {
		reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.28)
	}
}
