import BrowserCore
import Foundation
import SwiftUI

/// What a pane with no page shows (the homepage): the Arx mark, a custom pointer, an ink trail, a
/// guide to the shortcuts and a background. `captureContext` is the default; with the
/// Customizable homepage feature flag on, a button in the page's corner edits it.
public struct EmptyPageStyle: Codable, Hashable, Sendable {
	public var logo: Logo
	public var cursor: Cursor
	public var effect: Effect
	public var ink: Ink
	public var guide: Guide

	/// Where the guide sits while no mark is centered above it.
	public var guidePosition: GuidePosition
	public var background: Background
	public var sky: Sky

	public init(
		logo: Logo = .init(),
		cursor: Cursor = .init(),
		effect: Effect = .none,
		ink: Ink = .init(),
		guide: Guide = .none,
		guidePosition: GuidePosition = .center,
		background: Background = .none,
		sky: Sky = .init()
	) {
		self.logo = logo
		self.cursor = cursor
		self.effect = effect
		self.ink = ink
		self.guide = guide
		self.guidePosition = guidePosition
		self.background = background
		self.sky = sky
	}
}

// MARK: - Presets

extension EmptyPageStyle {
	/// Arx's homepage: a large glass and hologram mark over drifting dust and rolling tips. It
	/// leaves the system pointer as it is (DEV-1287); a customized homepage can still choose a shape.
	public static let captureContext: Self = .init(
		logo: .init(
			placement: .centered,
			centered: .init(size: 0.5, opacity: 0.5),
			glass: true,
			hologram: true
		),
		cursor: .init(shape: .regular),
		guide: .hints,
		background: .dust
	)

	/// The page before the homepage could change (DEV-829): the small mark, quiet, and nothing
	/// else.
	public static let classic: Self = .init(
		logo: .init(
			placement: .centered,
			centered: .init(size: 0.094, opacity: 0.31)
		),
		cursor: .init(shape: .regular)
	)

	public struct Preset: Identifiable, Sendable {
		public let id: String
		public let title: String
		public let style: EmptyPageStyle
	}

	public static var presets: [Preset] {
		[
			.init(id: "captureContext", title: String.localized(.appUI.emptyPage.presetCaptureContext), style: .captureContext),
			.init(id: "classic", title: String.localized(.appUI.emptyPage.presetClassic), style: .classic),
		]
	}
}

// MARK: - Logo

extension EmptyPageStyle {
	public enum LogoPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
		case centered
		case watermark
		case off

		public var id: Self { self }

		public var title: String {
			switch self {
			case .centered: String.localized(.appUI.emptyPage.placementCentered)
			case .watermark: String.localized(.appUI.emptyPage.placementWatermark)
			case .off: String.localized(.appUI.emptyPage.placementOff)
			}
		}
	}

	/// How one placement draws the mark. Size runs 0 to 1, from half to two and a half times the
	/// placement's own width, which it has at 0.25.
	public struct LogoAppearance: Codable, Hashable, Sendable {
		public static let defaultSize: Double = 0.25

		public var size: Double
		public var opacity: Double
		public var blend: Blend

		public init(
			size: Double = Self.defaultSize,
			opacity: Double,
			blend: Blend = .normal
		) {
			self.size = size
			self.opacity = opacity
			self.blend = blend
		}

		public var scale: Double { 0.5 + size * 2 }
	}

	public struct Logo: Codable, Hashable, Sendable {
		/// The centered mark's width at scale 1.
		public static let centeredWidth: CGFloat = 64

		/// The watermark's width at scale 1.
		public static let watermarkWidth: CGFloat = 640

		public var placement: LogoPlacement
		public var centered: LogoAppearance
		public var watermark: LogoAppearance
		public var glass: Bool
		public var hologram: Bool

		public init(
			placement: LogoPlacement = .centered,
			centered: LogoAppearance = .init(opacity: 0.32),
			watermark: LogoAppearance = .init(opacity: 0.05),
			glass: Bool = false,
			hologram: Bool = false
		) {
			self.placement = placement
			self.centered = centered
			self.watermark = watermark
			self.glass = glass
			self.hologram = hologram
		}

		/// The current placement's appearance; `off` edits the centered one.
		public var current: LogoAppearance {
			get { placement == .watermark ? watermark : centered }
			set {
				if placement == .watermark {
					watermark = newValue
				} else {
					centered = newValue
				}
			}
		}
	}

	public enum Blend: String, Codable, CaseIterable, Identifiable, Sendable {
		case normal
		case multiply
		case screen
		case overlay
		case softLight
		case hardLight
		case colorDodge
		case colorBurn
		case plusLighter
		case plusDarker
		case difference
		case exclusion
		case luminosity

		public var id: Self { self }

		public var title: String {
			switch self {
			case .normal: String.localized(.appUI.emptyPage.blendNormal)
			case .multiply: String.localized(.appUI.emptyPage.blendMultiply)
			case .screen: String.localized(.appUI.emptyPage.blendScreen)
			case .overlay: String.localized(.appUI.emptyPage.blendOverlay)
			case .softLight: String.localized(.appUI.emptyPage.blendSoftLight)
			case .hardLight: String.localized(.appUI.emptyPage.blendHardLight)
			case .colorDodge: String.localized(.appUI.emptyPage.blendColorDodge)
			case .colorBurn: String.localized(.appUI.emptyPage.blendColorBurn)
			case .plusLighter: String.localized(.appUI.emptyPage.blendPlusLighter)
			case .plusDarker: String.localized(.appUI.emptyPage.blendPlusDarker)
			case .difference: String.localized(.appUI.emptyPage.blendDifference)
			case .exclusion: String.localized(.appUI.emptyPage.blendExclusion)
			case .luminosity: String.localized(.appUI.emptyPage.blendLuminosity)
			}
		}

		public var mode: BlendMode {
			switch self {
			case .normal: .normal
			case .multiply: .multiply
			case .screen: .screen
			case .overlay: .overlay
			case .softLight: .softLight
			case .hardLight: .hardLight
			case .colorDodge: .colorDodge
			case .colorBurn: .colorBurn
			case .plusLighter: .plusLighter
			case .plusDarker: .plusDarker
			case .difference: .difference
			case .exclusion: .exclusion
			case .luminosity: .luminosity
			}
		}
	}
}

// MARK: - Colors

extension EmptyPageStyle {
	public enum Hue: String, Codable, CaseIterable, Identifiable, Sendable {
		case text
		case lavender
		case blue
		case pink
		case green
		case orange
		case white
		case black

		public var id: Self { self }

		public var title: String {
			switch self {
			case .text: String.localized(.appUI.emptyPage.colorText)
			case .lavender: String.localized(.appUI.emptyPage.colorLavender)
			case .blue: String.localized(.appUI.emptyPage.colorBlue)
			case .pink: String.localized(.appUI.emptyPage.colorPink)
			case .green: String.localized(.appUI.emptyPage.colorGreen)
			case .orange: String.localized(.appUI.emptyPage.colorOrange)
			case .white: String.localized(.appUI.emptyPage.colorWhite)
			case .black: String.localized(.appUI.emptyPage.colorBlack)
			}
		}

		public var color: Color {
			switch self {
			case .text: BrowserTheme.text
			case .lavender: SidebarTint.lavender.color
			case .blue: SidebarTint.blue.color
			case .pink: SidebarTint.pink.color
			case .green: SidebarTint.green.color
			case .orange: SidebarTint.orange.color
			case .white: .white
			case .black: .black
			}
		}
	}

	/// A color at an opacity; at zero it draws nothing.
	public struct Paint: Codable, Hashable, Sendable {
		public var color: Hue
		public var opacity: Double

		public init(
			color: Hue,
			opacity: Double
		) {
			self.color = color
			self.opacity = opacity
		}

		public var style: Color { color.color.opacity(opacity) }
	}
}

// MARK: - Cursor

extension EmptyPageStyle {
	public enum CursorShape: String, Codable, CaseIterable, Identifiable, Sendable {
		case regular
		case circle
		case square
		case triangle

		public var id: Self { self }

		public var title: String {
			switch self {
			case .regular: String.localized(.appUI.emptyPage.cursorRegular)
			case .circle: String.localized(.appUI.emptyPage.cursorCircle)
			case .square: String.localized(.appUI.emptyPage.cursorSquare)
			case .triangle: String.localized(.appUI.emptyPage.cursorTriangle)
			}
		}
	}

	public struct Cursor: Codable, Hashable, Sendable {
		public static let sizeRange: ClosedRange<Double> = 6...64
		public static let strokeRange: ClosedRange<Double> = 0...6

		public var shape: CursorShape
		public var size: Double
		public var fill: Paint
		public var stroke: Paint
		public var strokeWidth: Double

		public init(
			shape: CursorShape = .regular,
			size: Double = 22,
			fill: Paint = .init(color: .lavender, opacity: 0.25),
			stroke: Paint = .init(color: .text, opacity: 0.7),
			strokeWidth: Double = 1.5
		) {
			self.shape = shape
			self.size = size
			self.fill = fill
			self.stroke = stroke
			self.strokeWidth = strokeWidth
		}
	}
}

// MARK: - Effect

extension EmptyPageStyle {
	public enum Effect: String, Codable, CaseIterable, Identifiable, Sendable {
		case none
		case inkTrail

		public var id: Self { self }

		public var title: String {
			switch self {
			case .none: String.localized(.appUI.emptyPage.effectNone)
			case .inkTrail: String.localized(.appUI.emptyPage.effectInkTrail)
			}
		}
	}

	public enum InkColoring: String, Codable, CaseIterable, Identifiable, Sendable {
		case solid
		case shifting
		case rainbow

		public var id: Self { self }

		public var title: String {
			switch self {
			case .solid: String.localized(.appUI.emptyPage.coloringSolid)
			case .shifting: String.localized(.appUI.emptyPage.coloringShifting)
			case .rainbow: String.localized(.appUI.emptyPage.coloringRainbow)
			}
		}
	}

	public struct Ink: Codable, Hashable, Sendable {
		public static let widthRange: ClosedRange<Double> = 1...32
		public static let dryingRange: ClosedRange<Double> = 0.2...4

		public var coloring: InkColoring
		public var color: Hue
		public var secondColor: Hue
		public var width: Double

		/// Seconds until the ink has mostly faded.
		public var drying: Double

		/// 0 draws a crisp line, 1 a soft glow.
		public var softness: Double

		/// Whether the line narrows as it dries.
		public var tapers: Bool
		public var opacity: Double

		public init(
			coloring: InkColoring = .shifting,
			color: Hue = .lavender,
			secondColor: Hue = .pink,
			width: Double = 12,
			drying: Double = 1.4,
			softness: Double = 0.5,
			tapers: Bool = true,
			opacity: Double = 0.65
		) {
			self.coloring = coloring
			self.color = color
			self.secondColor = secondColor
			self.width = width
			self.drying = drying
			self.softness = softness
			self.tapers = tapers
			self.opacity = opacity
		}
	}
}

// MARK: - Guide

extension EmptyPageStyle {
	public enum Guide: String, Codable, CaseIterable, Identifiable, Sendable {
		case none
		case shortcuts
		case hints

		public var id: Self { self }

		public var title: String {
			switch self {
			case .none: String.localized(.appUI.emptyPage.guideNone)
			case .shortcuts: String.localized(.appUI.emptyPage.guideShortcuts)
			case .hints: String.localized(.appUI.emptyPage.guideHints)
			}
		}
	}

	public enum GuidePosition: String, Codable, CaseIterable, Identifiable, Sendable {
		case center
		case bottomLeft

		public var id: Self { self }

		public var title: String {
			switch self {
			case .center: String.localized(.appUI.emptyPage.positionCenter)
			case .bottomLeft: String.localized(.appUI.emptyPage.positionBottomLeft)
			}
		}
	}
}

// MARK: - Background

extension EmptyPageStyle {
	public enum Background: String, Codable, CaseIterable, Identifiable, Sendable {
		case none
		case sky
		case sparkles
		case dots
		case grid
		case warp
		case film
		case silk
		case topography
		case dust

		public var id: Self { self }

		/// Whether it paints no ground of its own, only marks over whatever is behind it, so the
		/// page card under it can let the window's background through.
		public var isClear: Bool {
			switch self {
			case .none, .dots, .grid, .dust: true
			case .sky, .sparkles, .warp, .film, .silk, .topography: false
			}
		}

		public var title: String {
			switch self {
			case .none: String.localized(.appUI.emptyPage.backgroundNone)
			case .sky: String.localized(.appUI.emptyPage.backgroundSky)
			case .sparkles: String.localized(.appUI.emptyPage.backgroundSparkles)
			case .dots: String.localized(.appUI.emptyPage.backgroundDots)
			case .grid: String.localized(.appUI.emptyPage.backgroundGrid)
			case .warp: String.localized(.appUI.emptyPage.backgroundWarp)
			case .film: String.localized(.appUI.emptyPage.backgroundFilm)
			case .silk: String.localized(.appUI.emptyPage.backgroundSilk)
			case .topography: String.localized(.appUI.emptyPage.backgroundTopography)
			case .dust: String.localized(.appUI.emptyPage.backgroundDust)
			}
		}
	}

	public struct Sky: Codable, Hashable, Sendable {
		public var stars: Bool
		public var clouds: Bool

		public init(
			stars: Bool = true,
			clouds: Bool = true
		) {
			self.stars = stars
			self.clouds = clouds
		}
	}
}

// MARK: - Storage

extension EmptyPageStyle {
	/// The user defaults key the customized homepage is kept under.
	public static let storageKey: String = "ArxEmptyPageStyle"

	/// The style as JSON for `@AppStorage`. It's its own type: `RawRepresentable` on a `Codable`
	/// type would encode through `rawValue` and recurse. Anything unreadable falls back to the
	/// default.
	public struct Stored: RawRepresentable, Hashable, Sendable {
		public var style: EmptyPageStyle

		public init(_ style: EmptyPageStyle = .captureContext) {
			self.style = style
		}

		public init?(rawValue: String) {
			guard let style = try? JSONDecoder().decode(EmptyPageStyle.self, from: Data(rawValue.utf8)) else { return nil }

			self.style = style
		}

		public var rawValue: String {
			let encoder: JSONEncoder = .init()
			encoder.outputFormatting = .sortedKeys
			let data: Data = (try? encoder.encode(style)) ?? Data()
			return String(decoding: data, as: UTF8.self)
		}

		/// By the style, never by `rawValue`.
		public static func == (lhs: Self, rhs: Self) -> Bool {
			lhs.style == rhs.style
		}

		public func hash(into hasher: inout Hasher) {
			hasher.combine(style)
		}
	}
}
