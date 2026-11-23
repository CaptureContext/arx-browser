import AppKit
import BrowserCore
import SwiftUI

/// The identity card at the top of Settings › Arx, in one of five styles from the Arx Browser
/// Figma file, with a control that moves to the next style.
///
/// Pointer movement, tilt, hover and the flip live in this view's own state; nothing per frame
/// leaves it. With Reduce Motion on, every style is a still frame and changes crossfade.
public struct ArxIdentityCard: View {
	/// Local counts shown on the back of the member pass.
	public struct Stats: Equatable, Sendable {
		public var profiles: Int
		public var spaces: Int
		public var tabs: Int

		public init(
			profiles: Int,
			spaces: Int,
			tabs: Int
		) {
			self.profiles = profiles
			self.spaces = spaces
			self.tabs = tabs
		}
	}

	/// The current space's colour and the other spaces' colours, for the space tint.
	/// Spaces have no colour today, so callers pass `nil` and the style uses its neutral set.
	public struct SpaceColors: Equatable, Sendable {
		public var current: Color
		public var others: [Color]

		public init(
			current: Color,
			others: [Color]
		) {
			self.current = current
			self.others = others
		}
	}

	public static let size: CGSize = .init(width: 230, height: 300)
	public static let cornerRadius: CGFloat = 14

	private let style: IdentityCardStyle
	private let stats: Stats
	private let spaceColors: SpaceColors?
	private let member: MemberNumber?
	private let memberSince: Date?
	private let cycle: () -> Void
	private let share: (() -> Void)?

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var pointer: UnitPoint?

	public init(
		style: IdentityCardStyle,
		stats: Stats,
		spaceColors: SpaceColors? = nil,
		member: MemberNumber? = nil,
		memberSince: Date? = nil,
		cycle: @escaping () -> Void,
		share: (() -> Void)? = nil
	) {
		self.style = style
		self.stats = stats
		self.spaceColors = spaceColors
		self.member = member
		self.memberSince = memberSince
		self.cycle = cycle
		self.share = share
	}

	/// The card's face as a still image, without tilt or glare, to share or save.
	@MainActor
	public static func image(
		style: IdentityCardStyle,
		stats: Stats,
		spaceColors: SpaceColors? = nil,
		member: MemberNumber? = nil,
		memberSince: Date? = nil,
		scale: CGFloat = 3
	) -> NSImage? {
		let renderer = ImageRenderer(
			content: IdentityCardFace(style: style, stats: stats, spaceColors: spaceColors, pointer: nil)
				.environment(\.identityCardMember, member)
				.environment(\.identityCardMemberSince, memberSince)
				.frame(width: size.width, height: size.height)
				.clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
		)
		renderer.scale = scale
		renderer.isOpaque = false
		return renderer.nsImage
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			ZStack {
				IdentityCardFace(
					style: style,
					stats: stats,
					spaceColors: spaceColors,
					pointer: reduceMotion ? nil : pointer
				)
					.environment(\.identityCardMember, member)
					.environment(\.identityCardMemberSince, memberSince)
					.id(style)
					.transition(changeTransition)
			}
			.frame(width: Self.size.width, height: Self.size.height)
			.shadow(color: .black.opacity(0.14), radius: 14, y: 8)
			.shadow(color: .black.opacity(0.08), radius: 2, y: 1)
			.rotation3DEffect(tilt.x, axis: (x: 0, y: 1, z: 0), perspective: 0.6)
			.rotation3DEffect(tilt.y, axis: (x: 1, y: 0, z: 0), perspective: 0.6)
			.animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.2), value: pointer)
			.animation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.55), value: style)
			.onContinuousHover(coordinateSpace: .local) { phase in
				switch phase {
				case let .active(location):
					pointer = UnitPoint(
						x: min(max(location.x / Self.size.width, 0), 1),
						y: min(max(location.y / Self.size.height, 0), 1)
					)

				case .ended:
					pointer = nil
				}
			}

			HStack(spacing: 6) {
				Text(localized: style.title)
					.font(.caption)
					.foregroundStyle(.secondary)
				Spacer(minLength: 0)
				if let share {
					Button(action: share) {
						Image(systemName: "square.and.arrow.up")
							.font(.caption.weight(.semibold))
							.frame(width: 22, height: 22)
							.contentShape(.circle)
					}
					.buttonStyle(.borderless)
					.help(String.localized(.appUI.settings.identity.share))
					.accessibilityLabel(Text(localized: .appUI.settings.identity.share))
				}
				Button(action: cycle) {
					Image(systemName: "arrow.trianglehead.2.clockwise")
						.font(.caption.weight(.semibold))
						.frame(width: 22, height: 22)
						.contentShape(.circle)
				}
				.buttonStyle(.borderless)
				.help(String.localized(.appUI.settings.identity.nextStyle))
				.accessibilityLabel(Text(localized: .appUI.settings.identity.nextStyle))
				.accessibilityValue(Text(localized: style.title))
			}
			.frame(width: Self.size.width)
		}
	}

	/// A few degrees toward the pointer, flat when it leaves.
	private var tilt: (x: Angle, y: Angle) {
		guard let pointer, !reduceMotion else { return (.zero, .zero) }
		return (.degrees((pointer.x - 0.5) * 10), .degrees((0.5 - pointer.y) * 10))
	}

	private var changeTransition: AnyTransition {
		reduceMotion
		? .opacity
		: .asymmetric(
			insertion: .opacity.combined(with: .scale(scale: 0.96)),
			removal: .opacity.combined(with: .scale(scale: 1.02))
		)
	}
}

extension EnvironmentValues {
	/// The member number every face writes in its top-right corner, once this Mac has claimed one.
	@Entry
	internal var identityCardMember: MemberNumber?

	/// When this Arx was first installed on this Mac: every face's Member since (DEV-1323).
	@Entry
	internal var identityCardMemberSince: Date?
}

extension MemberNumber {
	/// "Member #42": the Member number section's line once claimed, and what VoiceOver reads for
	/// the card's corner.
	public var claimedText: String {
		String.localized(.appUI.settings.identity.member.claimed(index))
	}

	/// "#42", in the card's top-right corner.
	public var cornerText: String {
		String.localized(.appUI.settings.identity.member.corner(index))
	}
}

extension ArxIdentityCard {
	/// How Member since writes the install date: the month and year in the locale's own order,
	/// "November 2026" in English. A card says how long someone has been a member, not the day.
	public static let memberSinceFormat: Date.FormatStyle = .dateTime.month(.wide).year()
}

extension ArxWordmark {
	/// Every identity card draws "arx" at the face's heaviest weight.
	public static let cardWeight: CGFloat = weights.upperBound
}

extension IdentityCardStyle {
	fileprivate var title: _XCStringResource {
		switch self {
		case .holographicFoil: .appUI.settings.identity.style.holographicFoil
		case .liquidGlass: .appUI.settings.identity.style.liquidGlass
		case .smokedGlass: .appUI.settings.identity.style.smokedGlass
		case .prismGlass: .appUI.settings.identity.style.prismGlass
		case .spaceTint: .appUI.settings.identity.style.spaceTint
		case .graphite: .appUI.settings.identity.style.graphite
		case .titanium: .appUI.settings.identity.style.titanium
		case .obsidianGold: .appUI.settings.identity.style.obsidianGold
		case .carbon: .appUI.settings.identity.style.carbon
		case .sunsetGrain: .appUI.settings.identity.style.sunsetGrain
		case .memberPass: .appUI.settings.identity.style.memberPass
		}
	}
}

private struct IdentityCardFace: View {
	internal let style: IdentityCardStyle
	internal let stats: ArxIdentityCard.Stats
	internal let spaceColors: ArxIdentityCard.SpaceColors?
	internal let pointer: UnitPoint?

	internal var body: some View {
		switch style {
		case .holographicFoil: HolographicFoilCard(pointer: pointer)
		case .liquidGlass: LiquidGlassCard(pointer: pointer)
		case .smokedGlass: SmokedGlassCard(pointer: pointer)
		case .prismGlass: PrismGlassCard(pointer: pointer)
		case .spaceTint: SpaceTintCard(pointer: pointer, colors: spaceColors)
		case .graphite: GraphiteCard(pointer: pointer)
		case .titanium: TitaniumCard(pointer: pointer)
		case .obsidianGold: ObsidianGoldCard(pointer: pointer)
		case .carbon: CarbonCard(pointer: pointer)
		case .sunsetGrain: SunsetGrainCard()
		case .memberPass: MemberPassCard(stats: stats)
		}
	}
}

// MARK: - Shared layout

/// The logo top left with the member number across from it, and the wordmark with Member since at
/// the bottom, inset 24 points.
internal struct IdentityCardContent<Mark: View, Footer: View>: View {
	private let wordmark: AnyShapeStyle
	private let subtitle: Color
	private let blendMode: BlendMode
	private let mark: Mark
	private let footer: Footer

	@Environment(\.identityCardMember)
	private var member

	@Environment(\.identityCardMemberSince)
	private var memberSince

	internal init(
		wordmark: some ShapeStyle,
		subtitle: Color,
		blendMode: BlendMode = .normal,
		@ViewBuilder mark: () -> Mark,
		@ViewBuilder footer: () -> Footer
	) {
		self.wordmark = AnyShapeStyle(wordmark)
		self.subtitle = subtitle
		self.blendMode = blendMode
		self.mark = mark()
		self.footer = footer()
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(alignment: .top, spacing: 8) {
				mark
				Spacer(minLength: 0)
				// Empty until this Mac claims a number; Settings › Arx's Member number claims it.
				if let member {
					Text(member.cornerText)
						.font(.system(size: 14, weight: .semibold).monospacedDigit())
						.foregroundStyle(subtitle)
						.blendMode(blendMode)
						.lineLimit(1)
						.fixedSize()
						.accessibilityLabel(member.claimedText)
				}
			}
			Spacer(minLength: 0)
			VStack(alignment: .leading, spacing: 4) {
				Text(ArxWordmark.text)
					.font(.arxWordmark(size: 40, weight: ArxWordmark.cardWeight))
					.tracking(-0.8)
					.foregroundStyle(wordmark)
					.blendMode(blendMode)
				if let memberSince {
					// The label and the date apart, so no language has to fit a month into a
					// sentence.
					VStack(alignment: .leading, spacing: 1) {
						Text(localized: .appUI.settings.identity.memberSince)
							.font(.system(size: 10, weight: .semibold))
							.tracking(1.2)
							.textCase(.uppercase)
						Text(memberSince, format: ArxIdentityCard.memberSinceFormat)
							.font(.system(size: 14, weight: .semibold))
					}
					.foregroundStyle(subtitle)
					.blendMode(blendMode)
					.lineLimit(1)
					.minimumScaleFactor(0.7)
					.frame(width: 182, alignment: .leading)
				}
				footer
			}
		}
		.padding(24)
		.frame(width: ArxIdentityCard.size.width, height: ArxIdentityCard.size.height, alignment: .leading)
		.accessibilityElement(children: .combine)
	}
}

extension IdentityCardContent where Footer == EmptyView {
	internal init(
		wordmark: some ShapeStyle,
		subtitle: Color,
		blendMode: BlendMode = .normal,
		@ViewBuilder mark: () -> Mark
	) {
		self.init(wordmark: wordmark, subtitle: subtitle, blendMode: blendMode, mark: mark) { EmptyView() }
	}
}

internal struct IdentityCardLogo<Fill: ShapeStyle>: View {
	internal let fill: Fill
	internal var blendMode: BlendMode

	internal init(
		fill: Fill,
		blendMode: BlendMode = .normal
	) {
		self.fill = fill
		self.blendMode = blendMode
	}

	internal var body: some View {
		ArxLogo()
			.fill(fill)
			.frame(width: ArxLogo.designSize.width, height: ArxLogo.designSize.height)
			.blendMode(blendMode)
			.accessibilityHidden(true)
	}
}

extension View {
	internal func identityCardShape(border: Color? = nil) -> some View {
		let shape = RoundedRectangle(cornerRadius: ArxIdentityCard.cornerRadius, style: .continuous)
		return clipShape(shape)
			.overlay {
				if let border { shape.strokeBorder(border, lineWidth: 1) }
			}
			.compositingGroup()
	}
}

extension Color {
	internal init(
		_ red: Double,
		_ green: Double,
		_ blue: Double,
		opacity: Double = 1
	) {
		self.init(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: opacity)
	}

	internal static let ink: Color = .init(28, 28, 30)
}

/// A linear gradient at a CSS angle (0° points up, clockwise), as Figma exports it.
internal func cssGradient(
	_ degrees: Double,
	_ stops: [Gradient.Stop]
) -> LinearGradient {
	let radians = degrees * .pi / 180
	let dx = sin(radians) / 2
	let dy = -cos(radians) / 2
	return LinearGradient(
		stops: stops,
		startPoint: .init(x: 0.5 - dx, y: 0.5 - dy),
		endPoint: .init(x: 0.5 + dx, y: 0.5 + dy)
	)
}

// MARK: - 2. Holographic foil

/// A rainbow foil whose hue shifts with the tilt, and a sheen band that follows the pointer.
private struct HolographicFoilCard: View {
	internal let pointer: UnitPoint?

	internal var body: some View {
		IdentityCardContent(wordmark: Color.ink.opacity(0.7), subtitle: .ink.opacity(0.4)) {
			IdentityCardLogo(fill: Color.ink.opacity(0.1), blendMode: .plusDarker)
		}
		.background {
			ZStack {
				Color(237, 237, 242)
				cssGradient(118.23, [
					.init(color: .init(255, 154, 213, opacity: 0.55), location: 0.141),
					.init(color: .init(154, 208, 255, opacity: 0.55), location: 0.3205),
					.init(color: .init(185, 255, 207, opacity: 0.55), location: 0.5),
					.init(color: .init(255, 231, 154, opacity: 0.55), location: 0.6795),
					.init(color: .init(201, 166, 255, opacity: 0.55), location: 0.859),
				])
				.hueRotation(hueShift)
				sheen
			}
		}
		.identityCardShape(border: .white.opacity(0.8))
	}

	private var hueShift: Angle {
		guard let pointer else { return .zero }
		return .degrees((pointer.x - 0.5) * 50 + (pointer.y - 0.5) * 30)
	}

	/// An 80-point band at 30°, resting just off the left edge and sweeping with the pointer.
	private var sheen: some View {
		LinearGradient(
			stops: [
				.init(color: .white.opacity(0), location: 0),
				.init(color: .white.opacity(0.85), location: 0.5),
				.init(color: .white.opacity(0), location: 1),
			],
			startPoint: .leading,
			endPoint: .trailing
		)
		.frame(width: 80, height: 460)
		.rotationEffect(.degrees(30))
		.offset(x: sheenOffset, y: 8)
		.allowsHitTesting(false)
	}

	private var sheenOffset: CGFloat {
		let width = ArxIdentityCard.size.width
		guard let pointer else { return -width / 2 - 11 }
		return (pointer.x - 0.5) * width * 1.2
	}
}

// MARK: - 6. Sunset grain

/// A grainy gradient that follows the time of day, crossfading slowly between palettes.
private struct SunsetGrainCard: View {
	internal var body: some View {
		IdentityCardContent(wordmark: Color.white, subtitle: .white.opacity(0.85)) {
			IdentityCardLogo(fill: Color.white)
		}
		.background {
			// Palettes change at most every few hours, so a five-minute check is plenty.
			TimelineView(.periodic(from: .now, by: 300)) { context in
				let palette = SunsetPalette(date: context.date)
				ZStack {
					cssGradient(192.95, palette.stops)
						.id(palette)
						.transition(.opacity)
				}
				.animation(.easeInOut(duration: 6), value: palette)
			}
			.overlay { FilmGrain(style: .init(intensity: 0.35)) }
		}
		.identityCardShape()
	}
}

/// Dawn in the morning, a bright day, the Figma dusk in the evening, and night after that.
internal enum SunsetPalette: Hashable, CaseIterable {
	case dawn
	case day
	case dusk
	case night

	internal init(
		date: Date,
		calendar: Calendar = .current
	) {
		switch calendar.component(.hour, from: date) {
		case 5..<10: self = .dawn
		case 10..<16: self = .day
		case 16..<21: self = .dusk
		default: self = .night
		}
	}

	internal var stops: [Gradient.Stop] {
		let colors: [Color] = switch self {
		case .dawn: [.init(255, 214, 165), .init(255, 140, 160), .init(140, 120, 255)]
		case .day: [.init(255, 200, 120), .init(255, 120, 110), .init(120, 90, 255)]
		case .dusk: [.init(255, 179, 107), .init(255, 95, 126), .init(107, 61, 255)]
		case .night: [.init(255, 120, 110), .init(150, 50, 140), .init(40, 30, 110)]
		}
		return zip(colors, [0.068, 0.5, 0.932]).map { .init(color: $0, location: $1) }
	}
}

// MARK: - 8. Member pass

/// A pass with the Arx mark and a barcode; a click flips it in 3D to local counts.
/// It never animates on its own.
private struct MemberPassCard: View {
	internal let stats: ArxIdentityCard.Stats

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var isFlipped: Bool = false

	internal var body: some View {
		ZStack {
			front
				.opacity(isFlipped ? 0 : 1)
				.accessibilityHidden(isFlipped)
			back
				.rotation3DEffect(reduceMotion ? .zero : .degrees(180), axis: (x: 0, y: 1, z: 0))
				.opacity(isFlipped ? 1 : 0)
				.accessibilityHidden(!isFlipped)
		}
		.rotation3DEffect(reduceMotion || !isFlipped ? .zero : .degrees(180), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
		.animation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.6), value: isFlipped)
		.contentShape(.rect)
		.onTapGesture { isFlipped.toggle() }
		.accessibilityAddTraits(.isButton)
		.accessibilityAction(named: Text(localized: .appUI.settings.identity.flip)) { isFlipped.toggle() }
	}

	private var front: some View {
		IdentityCardContent(
			wordmark: Color.ink,
			subtitle: .ink.opacity(0.7),
			mark: {
				// The app icon: the mark on its dark rounded square.
				ZStack {
					RoundedRectangle(cornerRadius: 9, style: .continuous)
						.fill(Color.ink)
					ArxLogo()
						.fill(.white)
						.frame(width: 24, height: 24 * ArxLogo.designSize.height / ArxLogo.designSize.width)
				}
				.frame(width: 40, height: 40)
				.accessibilityHidden(true)
			},
			footer: {
				IdentityCardBarcode()
					.fill(Color.ink.opacity(0.8))
					.frame(width: 182, height: 22)
					.accessibilityHidden(true)
			}
		)
		.background(Color(250, 247, 240))
		.identityCardShape(border: .ink.opacity(0.1))
	}

	private var back: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(localized: .appUI.settings.identity.stats.title)
				.font(.system(size: 10, weight: .semibold))
				.tracking(1.2)
				.textCase(.uppercase)
				.foregroundStyle(Color.ink.opacity(0.5))
			Spacer(minLength: 0)
			statRow(.appUI.settings.identity.stats.profiles, stats.profiles)
			statRow(.appUI.settings.identity.stats.spaces, stats.spaces)
			statRow(.appUI.settings.identity.stats.tabs, stats.tabs)
			Text(ArxWordmark.text)
				.font(.arxWordmark(size: 24, weight: ArxWordmark.cardWeight))
				.foregroundStyle(Color.ink.opacity(0.4))
				.accessibilityHidden(true)
		}
		.padding(24)
		.frame(width: ArxIdentityCard.size.width, height: ArxIdentityCard.size.height, alignment: .leading)
		.background(Color(250, 247, 240))
		.identityCardShape(border: .ink.opacity(0.1))
		.accessibilityElement(children: .combine)
	}

	private func statRow(
		_ title: _XCStringResource,
		_ value: Int
	) -> some View {
		HStack(alignment: .firstTextBaseline) {
			Text(localized: title)
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(Color.ink.opacity(0.7))
			Spacer(minLength: 8)
			Text(value, format: .number)
				.font(.system(size: 22, weight: .semibold).monospacedDigit())
				.foregroundStyle(Color.ink)
		}
	}
}

/// The pass's decorative barcode: one 36-point pattern of bars, repeated across 182 points,
/// exactly as drawn in Figma.
internal struct IdentityCardBarcode: Shape {
	private static let pattern: [(x: CGFloat, width: CGFloat)] = [
		(0, 3), (4, 1), (6, 2), (11, 2), (14, 2), (19, 3), (23, 2), (26, 1), (30, 1), (32, 1),
	]
	private static let period: CGFloat = 36
	private static let designSize: CGSize = .init(width: 182, height: 22)

	internal func path(in rect: CGRect) -> Path {
		var path = Path()
		let scale = rect.width / Self.designSize.width
		var origin: CGFloat = 0
		while origin < Self.designSize.width {
			for bar in Self.pattern where origin + bar.x < Self.designSize.width {
				let width = min(bar.width, Self.designSize.width - origin - bar.x)
				path.addRect(.init(
					x: rect.minX + (origin + bar.x) * scale,
					y: rect.minY,
					width: width * scale,
					height: rect.height
				))
			}
			origin += Self.period
		}
		return path
	}
}
