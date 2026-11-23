import SwiftUI

/// A profile's name behind a smiley.
/// Hovering raises a pill and tilts the smile.
/// Purely a label: callers wrap it in a menu or button.
public struct ProfileBadge: View {
	/// How loud the badge is at rest.
	public enum Style: Sendable {
		/// Semibold text on a faint pill, for Little Arx's address row.
		case standard

		/// Secondary text, a smaller face and no pill until hovered, for the sidebar header.
		case quiet
	}

	private let name: String
	private let showsName: Bool
	private let height: CGFloat
	private let style: Style
	private let cornerRadius: CGFloat?
	private let highlight: Bool?

	@SwiftUI.State
	private var hovered: Bool

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	/// `isHighlighted` pins the hovered or resting look; `nil` follows the pointer. Without
	/// `showsName`, the badge is the face alone in its pill, where there's no room for the name.
	/// `cornerRadius` rounds the pill's corners continuously, such as concentric with a field it
	/// sits in; `nil` draws a capsule.
	public init(
		name: String,
		showsName: Bool = true,
		height: CGFloat = 24,
		cornerRadius: CGFloat? = nil,
		style: Style = .standard,
		isHighlighted: Bool? = nil
	) {
		self.name = name
		self.showsName = showsName
		self.height = height
		self.cornerRadius = cornerRadius
		self.style = style
		self.highlight = isHighlighted
		self._hovered = .init(initialValue: false)
	}

	private var isHighlighted: Bool { highlight ?? hovered }

	public var body: some View {
		HStack(spacing: metrics.spacing) {
			ProfileSmiley()
				.frame(width: metrics.faceSize, height: metrics.faceSize)
				.rotationEffect(.degrees(isHighlighted && !reduceMotion ? -18 : 0))
			if showsName {
				Text(name)
					.font(.system(size: metrics.fontSize, weight: metrics.weight))
					.lineLimit(1)
					.truncationMode(.tail)
			}
		}
		.foregroundStyle(foreground)
		.padding(.leading, metrics.leadingPadding)

		// The face alone sits in the middle of its pill.
		.padding(.trailing, showsName ? metrics.trailingPadding : metrics.leadingPadding)
		.frame(height: height)
		.background(fill, in: shape)
		.contentShape(shape)
		.animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHighlighted)
		.onHover { hovered = $0 }
	}

	private var shape: AnyShape {
		guard let cornerRadius else { return AnyShape(.capsule) }
		return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
	}

	private var metrics: ProfileBadgeMetrics {
		switch style {
		case .standard: .standard
		case .quiet: .quiet
		}
	}

	private var foreground: Color {
		switch style {
		case .standard: BrowserTheme.text.opacity(isHighlighted ? 0.9 : 0.62)
		case .quiet: isHighlighted ? BrowserTheme.text.opacity(0.8) : BrowserTheme.secondary
		}
	}

	private var fill: Color {
		switch style {
		case .standard: .black.opacity(isHighlighted ? 0.28 : 0.06)
		case .quiet: isHighlighted ? BrowserTheme.hover : .clear
		}
	}
}

/// The badge's measurements in each style.
internal struct ProfileBadgeMetrics: Equatable {
	internal var faceSize: CGFloat
	internal var spacing: CGFloat
	internal var fontSize: CGFloat
	internal var weight: Font.Weight
	internal var leadingPadding: CGFloat
	internal var trailingPadding: CGFloat

	internal static let standard: Self = .init(
		faceSize: 14,
		spacing: 5,
		fontSize: 13,
		weight: .semibold,
		leadingPadding: 7,
		trailingPadding: 9
	)

	internal static let quiet: Self = .init(
		faceSize: 12,
		spacing: 4,
		fontSize: 12,
		weight: .regular,
		leadingPadding: 6,
		trailingPadding: 8
	)
}

/// The face Arx draws for profiles and the assistant: two upright eyes and a shallow smile,
/// in a unit square. Every face shares it, so they change together.
public enum ArxFace {
	/// An eye's size, as a fraction of the face.
	public static let eyeSize: CGSize = .init(width: 0.12, height: 0.28)

	/// The eyes' centers.
	public static let eyeCenters: [CGPoint] = [.init(x: 0.36, y: 0.36), .init(x: 0.64, y: 0.36)]

	/// The smile's stroke width, as a fraction of the face.
	public static let smileWidth: CGFloat = 0.11

	/// The eyes inside `rect`, as rounded rectangles.
	public static func eyes(in rect: CGRect) -> Path {
		var path = Path()
		let size = CGSize(width: eyeSize.width * rect.width, height: eyeSize.height * rect.height)
		for center in eyeCenters {
			let eye = CGRect(
				x: rect.minX + center.x * rect.width - size.width / 2,
				y: rect.minY + center.y * rect.height - size.height / 2,
				width: size.width,
				height: size.height
			)
			path.addRoundedRect(in: eye, cornerSize: .init(width: size.width / 2, height: size.width / 2))
		}
		return path
	}

	/// The smile's center line inside `rect`: an arc whose corners sit at 0.66 and whose lowest
	/// point sits at 0.75 of the face, so it reads as a gentle curve.
	public static func smile(in rect: CGRect) -> Path {
		var path = Path()
		path.addArc(
			center: .init(x: rect.midX, y: rect.minY + 0.436 * rect.height),
			radius: 0.314 * rect.width,
			startAngle: .degrees(45.5),
			endAngle: .degrees(134.5),
			clockwise: false
		)
		return path
	}
}

/// A profile face: a filled disc with the eyes and smile cut out, so the pill shows through.
public struct ProfileSmiley: View {
	public init() {}

	public var body: some View {
		Canvas { context, size in
			let side = min(size.width, size.height)
			let face = CGRect(
				x: (size.width - side) / 2,
				y: (size.height - side) / 2,
				width: side,
				height: side
			)

			context.fill(Path(ellipseIn: face), with: .foreground)
			context.blendMode = .destinationOut
			context.fill(ArxFace.eyes(in: face), with: .color(.black))
			context.stroke(
				ArxFace.smile(in: face),
				with: .color(.black),
				style: .init(lineWidth: side * ArxFace.smileWidth, lineCap: .round)
			)
		}
		.compositingGroup()
		.accessibilityHidden(true)
	}
}
