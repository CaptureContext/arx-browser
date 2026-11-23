import SwiftUI

// MARK: - Frosted glass

/// A card with shapes behind a frosted panel inset 12 points. The backdrop is drawn twice:
/// lightly blurred behind the panel and blurred harder inside it, which stands in for a
/// backdrop blur. `drifts` runs the backdrop's clock, which pauses while the window isn't key
/// and never runs with Reduce Motion.
internal struct FrostedGlassCard<Backdrop: View, Mark: View>: View {
	private let background: Color
	private let backdropBlur: CGFloat
	private let panelFill: Color
	private let panelBorder: AnyShapeStyle
	private let panelBorderWidth: CGFloat
	private let wordmark: Color
	private let subtitle: Color
	private let lifts: Bool
	private let drifts: Bool
	private let backdrop: (TimeInterval) -> Backdrop
	private let mark: Mark

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@Environment(\.controlActiveState)
	private var activeState

	@SwiftUI.State
	private var isHovered: Bool = false

	internal static var panelInset: CGFloat { 12 }

	internal init(
		background: Color,
		backdropBlur: CGFloat,
		panelFill: Color,
		panelBorder: some ShapeStyle,
		panelBorderWidth: CGFloat = 1,
		wordmark: Color,
		subtitle: Color,
		lifts: Bool = false,
		drifts: Bool = false,
		@ViewBuilder backdrop: @escaping (TimeInterval) -> Backdrop,
		@ViewBuilder mark: () -> Mark
	) {
		self.background = background
		self.backdropBlur = backdropBlur
		self.panelFill = panelFill
		self.panelBorder = AnyShapeStyle(panelBorder)
		self.panelBorderWidth = panelBorderWidth
		self.wordmark = wordmark
		self.subtitle = subtitle
		self.lifts = lifts
		self.drifts = drifts
		self.backdrop = backdrop
		self.mark = mark()
	}

	internal var body: some View {
		IdentityCardContent(wordmark: wordmark, subtitle: subtitle) { mark }
			.background {
				TimelineView(
					.animation(
						minimumInterval: 1 / 30,
						paused: !drifts || reduceMotion || activeState != .key
					)
				) { context in
					let time = drifts && !reduceMotion ? context.date.timeIntervalSinceReferenceDate : 0
					ZStack {
						background
						layer(time: time, blur: backdropBlur)
						panel(time: time)
					}
				}
			}
			.onHover { isHovered = $0 }
			.identityCardShape()
	}

	private func layer(
		time: TimeInterval,
		blur: CGFloat
	) -> some View {
		backdrop(time)
			.frame(width: ArxIdentityCard.size.width, height: ArxIdentityCard.size.height, alignment: .topLeading)
			.blur(radius: blur)
	}

	private func panel(time: TimeInterval) -> some View {
		let shape = RoundedRectangle(cornerRadius: 10, style: .continuous).inset(by: Self.panelInset)
		let isLifted = lifts && isHovered && !reduceMotion
		return ZStack {
			layer(time: time, blur: backdropBlur + 12)
			panelFill
		}
		.clipShape(shape)
		.overlay { shape.strokeBorder(panelBorder, lineWidth: panelBorderWidth) }
		.scaleEffect(isLifted ? 1.02 : 1)
		.shadow(color: .black.opacity(isLifted ? 0.12 : 0), radius: 10, y: 4)
		.animation(.smooth(duration: 0.35), value: isLifted)
	}
}

/// A shape placed at a design position, by its top-left corner in card points.
private struct Placed<Content: View>: View {
	internal let origin: CGPoint
	internal let size: CGSize
	internal var rotation: Angle

	@ViewBuilder
	internal let content: Content

	internal init(
		origin: CGPoint,
		size: CGSize,
		rotation: Angle = .zero,
		@ViewBuilder content: () -> Content
	) {
		self.origin = origin
		self.size = size
		self.rotation = rotation
		self.content = content()
	}

	internal var body: some View {
		content
			.frame(width: size.width, height: size.height)
			.rotationEffect(rotation)
			.offset(x: origin.x, y: origin.y)
	}
}

/// Where the pointer is from the card's centre, -0.5 to 0.5 on each axis; zero at rest.
private func pointerOffset(_ pointer: UnitPoint?) -> CGSize {
	guard let pointer else { return .zero }
	return .init(width: pointer.x - 0.5, height: pointer.y - 0.5)
}

// MARK: - 3. Liquid glass

/// Coloured shapes orbit slowly behind a frosted panel; the panel lifts on hover and its
/// edge brightens near the pointer.
internal struct LiquidGlassCard: View {
	internal let pointer: UnitPoint?

	internal var body: some View {
		FrostedGlassCard(
			background: .init(220, 227, 245),
			backdropBlur: 5,
			panelFill: .white.opacity(0.28),
			panelBorder: edgeHighlight,
			wordmark: .ink.opacity(0.7),
			subtitle: .ink.opacity(0.4),
			lifts: true,
			drifts: true,
			backdrop: { time in
				ZStack(alignment: .topLeading) {
					orb(.init(61, 123, 255), diameter: 150, at: .init(x: -30, y: 20), phase: 0, time: time)
					orb(.init(255, 138, 61), diameter: 120, at: .init(x: 130, y: 120), phase: 2.1, time: time)
					orb(.init(162, 61, 255), diameter: 100, at: .init(x: 20, y: 200), phase: 4.2, time: time)
				}
			},
			mark: { IdentityCardLogo(fill: Color.white.opacity(0.9), blendMode: .screen) }
		)
	}

	/// Each shape circles its design position: one turn every 24 seconds.
	private func orb(
		_ color: Color,
		diameter: CGFloat,
		at origin: CGPoint,
		phase: Double,
		time: TimeInterval
	) -> some View {
		let angle = time * 2 * .pi / 24 + phase
		return Placed(
			origin: .init(x: origin.x + cos(angle) * 14, y: origin.y + sin(angle) * 14),
			size: .init(width: diameter, height: diameter)
		) {
			Circle().fill(color)
		}
	}

	private var edgeHighlight: AnyShapeStyle {
		guard let pointer else { return AnyShapeStyle(Color.white.opacity(0.7)) }
		return AnyShapeStyle(RadialGradient(
			colors: [.white, .white.opacity(0.45)],
			center: pointer,
			startRadius: 0,
			endRadius: 160
		))
	}
}

// MARK: - 3b. Smoked glass

/// Dark tinted glass over glowing teal, magenta and indigo shapes that drift toward the pointer.
internal struct SmokedGlassCard: View {
	internal let pointer: UnitPoint?

	internal var body: some View {
		let drift = pointerOffset(pointer)
		FrostedGlassCard(
			background: .init(14, 16, 22),
			backdropBlur: 6,
			panelFill: .init(11, 12, 16, opacity: 0.45),
			panelBorder: Color.white.opacity(0.18),
			wordmark: .white,
			subtitle: .white.opacity(0.72),
			backdrop: { _ in
				ZStack(alignment: .topLeading) {
					orb(.init(22, 199, 183), diameter: 160, at: .init(x: -40, y: 30), pull: 34, drift: drift)
					orb(.init(224, 55, 155), diameter: 130, at: .init(x: 120, y: 140), pull: 26, drift: drift)
					orb(.init(91, 91, 255), diameter: 90, at: .init(x: 30, y: 200), pull: 18, drift: drift)
				}
			},
			mark: { IdentityCardLogo(fill: Color.white) }
		)
	}

	/// Larger shapes sit nearer the glass and follow the pointer further.
	private func orb(
		_ color: Color,
		diameter: CGFloat,
		at origin: CGPoint,
		pull: CGFloat,
		drift: CGSize
	) -> some View {
		Placed(
			origin: .init(x: origin.x + drift.width * pull, y: origin.y + drift.height * pull),
			size: .init(width: diameter, height: diameter)
		) {
			Circle().fill(color)
		}
	}
}

// MARK: - 3c. Prism glass

/// Clear glass over large coloured Arx marks. The glass edge is a thin spectrum that turns
/// with the tilt, and the marks slide in parallax.
internal struct PrismGlassCard: View {
	internal let pointer: UnitPoint?

	private static let spectrum: [Color] = [
		.init(255, 122, 198), .init(255, 197, 61), .init(122, 230, 160),
		.init(61, 139, 255), .init(176, 124, 242), .init(255, 122, 198),
	]

	internal var body: some View {
		let parallax = pointerOffset(pointer)
		FrostedGlassCard(
			background: .init(238, 240, 246),
			backdropBlur: 3,
			panelFill: .white.opacity(0.32),
			panelBorder: AngularGradient(colors: Self.spectrum, center: .center, angle: spectrumAngle),
			panelBorderWidth: 1.5,
			wordmark: .ink,
			subtitle: .ink.opacity(0.7),
			backdrop: { _ in
				ZStack(alignment: .topLeading) {
					mark(.init(255, 92, 138), width: 170, at: .init(x: -40, y: 10), rotation: 0, depth: 22, parallax: parallax)
					mark(.init(61, 139, 255), width: 150, at: .init(x: 117, y: 83), rotation: -18, depth: 14, parallax: parallax)
					mark(.init(255, 197, 61), width: 110, at: .init(x: -22, y: 200), rotation: 12, depth: 8, parallax: parallax)
				}
			},
			mark: { IdentityCardLogo(fill: Color.ink) }
		)
	}

	/// The colours split along the edge as the card tilts.
	private var spectrumAngle: Angle {
		let offset = pointerOffset(pointer)
		return .degrees(Double(offset.width * 120 + offset.height * 60))
	}

	private func mark(
		_ color: Color,
		width: CGFloat,
		at origin: CGPoint,
		rotation: Double,
		depth: CGFloat,
		parallax: CGSize
	) -> some View {
		Placed(
			origin: .init(x: origin.x - parallax.width * depth, y: origin.y - parallax.height * depth),
			size: .init(width: width, height: width * ArxLogo.designSize.height / ArxLogo.designSize.width),
			rotation: .degrees(rotation)
		) {
			ArxLogo().fill(color.opacity(0.9))
		}
	}
}

// MARK: - 3d. Space tint

/// Frosted glass tinted with the current space's colour over soft bands of the other spaces'
/// colours, breathing slowly while idle. Spaces have no colour yet, so without `colors` it
/// uses a neutral set.
internal struct SpaceTintCard: View {
	internal let pointer: UnitPoint?
	internal let colors: ArxIdentityCard.SpaceColors?

	private static let neutralBands: [Color] = [
		.init(60, 203, 127), .init(54, 179, 224), .init(242, 179, 61), .init(176, 124, 242),
	]

	internal var body: some View {
		let bands = bandColors
		FrostedGlassCard(
			background: colors.map { $0.current.opacity(0.15) } ?? .init(228, 242, 234),
			backdropBlur: 9,
			panelFill: colors.map { $0.current.opacity(0.18) } ?? .init(233, 255, 242, opacity: 0.4),
			panelBorder: Color.white.opacity(0.75),
			wordmark: .init(15, 42, 28),
			subtitle: .init(15, 42, 28, opacity: 0.7),
			drifts: true,
			backdrop: { time in
				ZStack(alignment: .topLeading) {
					ForEach(Array(bands.enumerated()), id: \.offset) { index, color in
						band(color, index: index, time: time)
					}
				}
			},
			mark: { IdentityCardLogo(fill: Color(15, 42, 28)) }
		)
		.animation(.easeInOut(duration: 1), value: colors)
	}

	private var bandColors: [Color] {
		guard let others = colors?.others, !others.isEmpty else { return Self.neutralBands }
		return (0..<4).map { others[$0 % others.count] }
	}

	/// A 320 × 70 capsule at 20°, every 70 points down the card, swelling gently over 12 seconds.
	private func band(
		_ color: Color,
		index: Int,
		time: TimeInterval
	) -> some View {
		let breath = sin(time * 2 * .pi / 12 + Double(index) * 1.3)
		return Placed(
			origin: .init(x: -81.6, y: 62.6 + CGFloat(index) * 70 + breath * 4),
			size: .init(width: 320, height: 70 + breath * 6),
			rotation: .degrees(20)
		) {
			Capsule().fill(color)
		}
	}
}
