import SwiftUI

// MARK: - 4. Graphite

/// Dark metal with a large etched Arx mark; only the edge highlight moves, following the pointer.
internal struct GraphiteCard: View {
	internal let pointer: UnitPoint?

	internal var body: some View {
		IdentityCardContent(
			wordmark: Color(229, 229, 234, opacity: 0.7),
			subtitle: .init(242, 242, 247, opacity: 0.4),
			blendMode: .plusLighter
		) {
			IdentityCardLogo(fill: Color(229, 229, 234, opacity: 0.7), blendMode: .plusLighter)
		}
		.background {
			ZStack(alignment: .topLeading) {
				cssGradient(143.02, [
					.init(color: .init(58, 58, 63), location: 0.134),
					.init(color: .init(18, 18, 20), location: 0.866),
				])
				ArxLogo()
					.fill(.white.opacity(0.07))
					.frame(width: 300, height: 300 * ArxLogo.designSize.height / ArxLogo.designSize.width)
					.offset(x: 19.2, y: 109.7)
					.accessibilityHidden(true)
			}
			.frame(width: ArxIdentityCard.size.width, height: ArxIdentityCard.size.height, alignment: .topLeading)
		}
		.clipShape(RoundedRectangle(cornerRadius: ArxIdentityCard.cornerRadius, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: ArxIdentityCard.cornerRadius, style: .continuous)
				.strokeBorder(
					AngularGradient(
						stops: [
							.init(color: .white.opacity(0.85), location: 0),
							.init(color: .white.opacity(0.2), location: 0.25),
							.init(color: .white.opacity(0.2), location: 0.75),
							.init(color: .white.opacity(0.85), location: 1),
						],
						center: .center,
						angle: highlightAngle
					),
					lineWidth: 1
				)
		}
		.compositingGroup()
	}

	/// The specular edge faces the pointer; at rest it sits at the top-left corner.
	private var highlightAngle: Angle {
		guard let pointer else { return .degrees(-135) }
		return .radians(atan2(pointer.y - 0.5, pointer.x - 0.5))
	}
}

// MARK: - 4b. Titanium

/// Light brushed titanium with a large engraved Arx mark. A soft streak of light crosses the
/// brushing with the pointer.
internal struct TitaniumCard: View {
	internal let pointer: UnitPoint?

	private static let ink: Color = .init(42, 44, 49)

	internal var body: some View {
		IdentityCardContent(wordmark: Self.ink, subtitle: Self.ink.opacity(0.65)) {
			IdentityCardLogo(fill: Self.ink)
		}
		.background {
			ZStack(alignment: .topLeading) {
				cssGradient(154.6, [
					.init(color: .init(233, 234, 238), location: 0.11),
					.init(color: .init(201, 203, 209), location: 0.461),
					.init(color: .init(217, 218, 223), location: 0.539),
					.init(color: .init(180, 183, 190), location: 0.89),
				])
				TitaniumBrushing()
					.offset(x: -1, y: -1)
				ArxLogo()
					.fill(Color(90, 94, 102, opacity: 0.12))
					.frame(width: 280, height: 280 * ArxLogo.designSize.height / ArxLogo.designSize.width)
					.offset(x: 9.1, y: 109.7)
					.accessibilityHidden(true)
				streak
			}
			.frame(width: ArxIdentityCard.size.width, height: ArxIdentityCard.size.height, alignment: .topLeading)
		}
		.identityCardShape(border: .white.opacity(0.9))
	}

	/// A soft diagonal band of light; it rests off the card and follows the pointer across it.
	private var streak: some View {
		LinearGradient(
			stops: [
				.init(color: .white.opacity(0), location: 0),
				.init(color: .white.opacity(0.55), location: 0.5),
				.init(color: .white.opacity(0), location: 1),
			],
			startPoint: .leading,
			endPoint: .trailing
		)
		.frame(width: 90, height: 420)
		.rotationEffect(.degrees(20))
		.offset(x: streakX, y: -60)
		.blendMode(.softLight)
		.allowsHitTesting(false)
	}

	private var streakX: CGFloat {
		guard let pointer else { return -140 }
		return pointer.x * ArxIdentityCard.size.width - 45
	}
}

/// One-point horizontal lines every two points, each with its own faint white, exactly as
/// the Figma brushing layer draws them.
private struct TitaniumBrushing: View {
	/// Each line's opacity in sixtieths, top to bottom.
	private static let levels: [Double] = Array(
		"8677ACAB69C9C94C88A395BC33437C56A93363B87B945A8B9BAA7576B858553599748C654434A5CB7844B466A683C7968677ACAB69C9C94C88A395BC33437C56A93363B87B945A8B9BAA75"
	).map { Double($0.hexDigitValue ?? 6) / 60 }

	internal var body: some View {
		Canvas { context, _ in
			for (index, level) in Self.levels.enumerated() {
				context.fill(
					Path(CGRect(x: 0, y: CGFloat(index * 2), width: 230, height: 1)),
					with: .color(.white.opacity(level))
				)
			}
		}
		.frame(width: ArxIdentityCard.size.width, height: ArxIdentityCard.size.height)
		.accessibilityHidden(true)
	}
}

// MARK: - 4c. Obsidian & gold

/// A black card with a gold-foil mark and wordmark and hairline gold borders. The foil glints
/// as the card tilts; nothing else moves.
internal struct ObsidianGoldCard: View {
	internal let pointer: UnitPoint?

	private static let foil: [Gradient.Stop] = [
		.init(color: .init(247, 227, 163), location: 0),
		.init(color: .init(201, 154, 59), location: 0.45),
		.init(color: .init(242, 211, 126), location: 0.7),
		.init(color: .init(156, 116, 38), location: 1),
	]

	internal var body: some View {
		IdentityCardContent(
			// The Figma wordmark gradient runs at 159° across the text.
			wordmark: foil(start: .init(x: 0.32, y: 0.03), end: .init(x: 0.68, y: 0.97)),
			subtitle: .init(232, 215, 168, opacity: 0.6),
			mark: {
				// The Figma gradient runs from the mark's top edge, a quarter in, to its bottom edge,
				// two thirds across: (13, 3.2) to (35.3, 45.9) in the first mark's 52 × 47 box, kept
				// as fractions so the three-blade mark's 52 × 50 box takes the same sweep.
				IdentityCardLogo(fill: foil(
					start: .init(x: 0.25, y: 0.067),
					end: .init(x: 0.679, y: 0.974)
				))
			}
		)
		.background {
			cssGradient(216.98, [
				.init(color: .init(23, 23, 26), location: 0.134),
				.init(color: .init(5, 5, 6), location: 0.866),
			])
		}
		.overlay {
			RoundedRectangle(cornerRadius: 9, style: .continuous)
				.inset(by: 11)
				.strokeBorder(Color(201, 164, 77, opacity: 0.35), lineWidth: 0.5)
		}
		.identityCardShape(border: .init(233, 201, 119))
	}

	/// The foil's direction shifts with the tilt, so the gold glints as the pointer moves.
	private func foil(
		start: UnitPoint,
		end: UnitPoint
	) -> LinearGradient {
		let shift = pointer.map { CGSize(width: ($0.x - 0.5) * 0.5, height: ($0.y - 0.5) * 0.5) } ?? .zero
		return LinearGradient(
			stops: Self.foil,
			startPoint: .init(x: start.x - shift.width, y: start.y - shift.height),
			endPoint: .init(x: end.x + shift.width, y: end.y + shift.height)
		)
	}
}

// MARK: - 4d. Carbon

/// Deep navy carbon weave with a glowing bottom edge in the app's accent colour. The weave
/// shimmers diagonally with the pointer.
internal struct CarbonCard: View {
	internal let pointer: UnitPoint?

	private static let ink: Color = .init(242, 244, 248)

	internal var body: some View {
		IdentityCardContent(wordmark: Self.ink, subtitle: Self.ink.opacity(0.6)) {
			IdentityCardLogo(fill: Self.ink)
		}
		.background {
			ZStack(alignment: .topLeading) {
				cssGradient(192.95, [
					.init(color: .init(20, 26, 38), location: 0.068),
					.init(color: .init(10, 13, 20), location: 0.932),
				])
				CarbonWeave()
					.offset(x: -16, y: -16)
				shimmer
				accentEdge
			}
			.frame(width: ArxIdentityCard.size.width, height: ArxIdentityCard.size.height, alignment: .topLeading)
		}
		.identityCardShape(border: .white.opacity(0.08))
	}

	/// A faint diagonal band that slides along the weave with the pointer.
	private var shimmer: some View {
		LinearGradient(
			stops: [
				.init(color: .white.opacity(0), location: 0),
				.init(color: .white.opacity(0.08), location: 0.5),
				.init(color: .white.opacity(0), location: 1),
			],
			startPoint: .leading,
			endPoint: .trailing
		)
		.frame(width: 120, height: 520)
		.rotationEffect(.degrees(45))
		.offset(x: shimmerX, y: -110)
		.blendMode(.plusLighter)
		.opacity(pointer == nil ? 0 : 1)
		.allowsHitTesting(false)
	}

	private var shimmerX: CGFloat {
		guard let pointer else { return -200 }
		return (pointer.x + pointer.y) / 2 * 360 - 180
	}

	/// A 3-point line along the bottom, brightest in the middle, glowing in the accent colour.
	private var accentEdge: some View {
		LinearGradient(
			stops: [
				.init(color: .accentColor.opacity(0), location: 0),
				.init(color: .accentColor, location: 0.5),
				.init(color: .accentColor.opacity(0), location: 1),
			],
			startPoint: .leading,
			endPoint: .trailing
		)
		.frame(width: ArxIdentityCard.size.width, height: 3)
		.shadow(color: .accentColor.opacity(0.9), radius: 10)
		.offset(x: -1, y: 296)
	}
}

/// The Figma weave: light diagonals every 6 points one way and dark ones every 12 the other,
/// both 2 points wide, in a 260 × 330 tile.
private struct CarbonWeave: View {
	internal var body: some View {
		Canvas { context, _ in
			var light = Path()
			for x in stride(from: -330, through: 258, by: 6) {
				light.move(to: .init(x: x, y: 330))
				light.addLine(to: .init(x: x + 330, y: 0))
			}
			context.stroke(light, with: .color(.white.opacity(0.05)), lineWidth: 2)

			var dark = Path()
			for x in stride(from: -330, through: 258, by: 12) {
				dark.move(to: .init(x: x, y: 0))
				dark.addLine(to: .init(x: x + 330, y: 330))
			}
			context.stroke(dark, with: .color(.black.opacity(0.25)), lineWidth: 2)
		}
		.frame(width: 260, height: 330)
		.accessibilityHidden(true)
	}
}
