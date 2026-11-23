import BrowserCore
import SwiftUI

/// A pane with no page, drawn from a style, back to front: the background, a watermark, the
/// ink, the centered mark with its guide, and the pointer. With hints showing, ← and → step
/// through them once the page has the keyboard, which a click gives it.
public struct EmptyPageView: View {
	public let style: EmptyPageStyle

	@Environment(\.colorScheme)
	private var colorScheme

	@Environment(\.browserChromeTint)
	private var tint

	@Environment(\.browserShortcuts)
	private var shortcuts

	@Environment(\.emptyPageScriptedPointer)
	private var scriptedPointer

	@Environment(\.emptyPageFixedTime)
	private var fixedTime

	@SwiftUI.State
	private var hintCursor: EmptyPageHintCursor = .init()

	@FocusState
	private var isFocused: Bool

	public init(style: EmptyPageStyle) {
		self.style = style
	}

	public var body: some View {
		let colors: EmptyPageColors = .init(tint: tint, isDark: colorScheme == .dark)
		let hints: [String] = EmptyPageHints.texts(bindings: shortcuts)
		let style: EmptyPageStyle = style
		let hintCursor: EmptyPageHintCursor = hintCursor

		// Snapshots have no system pointer, so they draw the shape where the scripted one is.
		let drawsCursor: Bool = scriptedPointer != nil
		EmptyPagePointerTracking { pointer, time in
			ZStack {
				EmptyPageBackground(style: style, colors: colors, pointer: pointer, time: time)
				if style.logo.placement == .watermark {
					watermark(time: time, dark: colors.dark)
				}
				if style.effect == .inkTrail {
					ink(pointer: pointer, time: time)
				}
				column(time: time, dark: colors.dark, hints: hints, cursor: hintCursor)
				if drawsCursor, style.cursor.shape != .regular, let location = pointer.location {
					EmptyPageCursor(cursor: style.cursor)
						.position(location)
						.allowsHitTesting(false)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.pointerStyle(drawsCursor ? nil : EmptyPageCursor.pointerStyle(style.cursor, colorScheme: colorScheme))
		.focusable(style.guide == .hints)
		.focused($isFocused)
		.focusEffectDisabled()
		.simultaneousGesture(TapGesture().onEnded { isFocused = true })
		.onKeyPress(.leftArrow) { stepHint(by: -1, count: hints.count) }
		.onKeyPress(.rightArrow) { stepHint(by: 1, count: hints.count) }
	}

	private func stepHint(by offset: Int, count: Int) -> KeyPress.Result {
		guard style.guide == .hints, count > 0 else { return .ignored }

		hintCursor.step(by: offset, at: fixedTime ?? EmptyPageClock.now, count: count)
		return .handled
	}

	// MARK: Logo

	private func mark(
		width: CGFloat,
		appearance: EmptyPageStyle.LogoAppearance,
		time: Double,
		dark: Float
	) -> some View {
		let padding: CGFloat = 12
		let height: CGFloat = width * ArxLogo.designSize.height / ArxLogo.designSize.width
		let size: CGSize = .init(width: width + padding * 2, height: height + padding * 2)
		return ArxLogo()
			.fill(BrowserTheme.text)
			.frame(width: width, height: height)
			.padding(padding)
			.layerEffect(
				emptyPageShader("emptyPageHologram", [.float(time), .color(SidebarTint.lavender.color), .float(dark)]),
				maxSampleOffset: .init(width: 6, height: 0),
				isEnabled: style.logo.hologram
			)
			.layerEffect(
				emptyPageShader("emptyPageGlass", [.float2(size), .float(time), .float(dark)]),
				maxSampleOffset: .init(width: 2, height: 2),
				isEnabled: style.logo.glass
			)
			.opacity(appearance.opacity)
			.blendMode(appearance.blend.mode)
			.accessibilityHidden(true)
	}

	private func watermark(time: Double, dark: Float) -> some View {
		let appearance: EmptyPageStyle.LogoAppearance = style.logo.watermark
		let width: CGFloat = EmptyPageStyle.Logo.watermarkWidth * appearance.scale
		return Color.clear
			.overlay(alignment: .bottomTrailing) {
				mark(width: width, appearance: appearance, time: time, dark: dark)
					.offset(x: width * 170 / 640, y: width * 150 / 640)
			}
			.clipped()
			.allowsHitTesting(false)
	}

	@ViewBuilder
	private func column(
		time: Double,
		dark: Float,
		hints: [String],
		cursor: EmptyPageHintCursor
	) -> some View {
		let showsMark: Bool = style.logo.placement == .centered
		if !showsMark, style.guide != .none, style.guidePosition == .bottomLeft {
			guide(time: time, hints: hints, cursor: cursor, alignment: .leading)
				.padding(28)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
		} else if showsMark || style.guide != .none {
			VStack(spacing: 22) {
				if showsMark {
					mark(
						width: EmptyPageStyle.Logo.centeredWidth * style.logo.centered.scale,
						appearance: style.logo.centered,
						time: time,
						dark: dark
					)
				}
				guide(time: time, hints: hints, cursor: cursor, alignment: .center)
			}
		}
	}

	@ViewBuilder
	private func guide(
		time: Double,
		hints: [String],
		cursor: EmptyPageHintCursor,
		alignment: HorizontalAlignment
	) -> some View {
		switch style.guide {
		case .none:
			EmptyView()
		case .shortcuts:
			EmptyPageShortcuts(bindings: shortcuts)
		case .hints:
			EmptyPageRollingHint(texts: hints, time: time, cursor: cursor, alignment: alignment)
		}
	}

	// MARK: Ink

	private func ink(pointer: EmptyPagePointer, time: Double) -> some View {
		let ink: EmptyPageStyle.Ink = style.ink
		let first: Color = ink.color.color
		let second: Color = ink.coloring == .shifting ? ink.secondColor.color : first
		let coloring: Float = switch ink.coloring {
		case .solid: 0
		case .shifting: 1
		case .rainbow: 2
		}
		let trail: [Float] = pointer.trailArgument
		return EmptyPageShaderFill { _ in
			emptyPageShader(
				"emptyPageInk",
				[
					.float(time),
					.floatArray(trail),
					.color(first),
					.color(second),
					.float(coloring),
					.float(ink.width),
					.float(ink.drying),
					.float(ink.softness),
					.float(ink.tapers ? 1 : 0),
					.float(ink.opacity),
				]
			)
		}
		.allowsHitTesting(false)
	}
}

/// The page gradient's two stops for the tint and appearance, and Arx's lavender, as shaders
/// take them.
internal struct EmptyPageColors: Sendable {
	internal let top: Color
	internal let bottom: Color
	internal let tint: Color
	internal let dark: Float

	@MainActor
	internal init(tint: ChromeTint, isDark: Bool) {
		let page: ChromePalette = .init(tint: tint, surface: .page, isDark: isDark)
		self.top = Color(page.top)
		self.bottom = Color(page.bottom)
		self.tint = SidebarTint.lavender.color
		self.dark = isDark ? 1 : 0
	}

	internal var pageArguments: [Shader.Argument] {
		[.color(top), .color(bottom), .color(tint), .float(dark)]
	}
}

// MARK: - Background

private struct EmptyPageBackground: View {
	let style: EmptyPageStyle
	let colors: EmptyPageColors
	let pointer: EmptyPagePointer
	let time: Double

	var body: some View {
		let time: Double = time
		let pointer: EmptyPagePointer = pointer
		let colors: EmptyPageColors = colors
		let page: [Shader.Argument] = colors.pageArguments
		switch style.background {
		case .none:
			Color.clear
		case .sky:
			let stars: Float = style.sky.stars ? 1 : 0
			let clouds: Float = style.sky.clouds ? 1 : 0
			EmptyPageShaderFill { size in
				emptyPageShader(
					"emptyPageSky",
					[.float2(size), .float(time), .color(colors.top), .color(colors.bottom), .float(colors.dark), .float(stars), .float(clouds)]
				)
			}
		case .sparkles:
			EmptyPageShaderFill { size in
				emptyPageShader("emptyPageSparkles", [.float2(size), .float(time), .color(colors.tint), .float(colors.dark)])
			}
		case .dots:
			EmptyPageGrid(style: .dots, spacing: 22)
				.distortionEffect(
					emptyPageShader(
						"emptyPageMagnet",
						[.float2(pointer.point), .float(pointer.isInside ? 1 : 0), .float(pointer.isPressed ? 1 : 0)]
					),
					maxSampleOffset: .init(width: 120, height: 120)
				)
		case .grid:
			EmptyPageGrid(style: .lines, spacing: 28)
				.distortionEffect(
					emptyPageShader(
						"emptyPagePond",
						[.float(time), .float2(pointer.point), .float(pointer.isInside ? 1 : 0), pointer.clickArgument]
					),
					maxSampleOffset: .init(width: 16, height: 16)
				)
		case .warp:
			EmptyPageShaderFill { size in emptyPageShader("emptyPageWarp", [.float2(size), .float(time)] + page) }
		case .film:
			EmptyPageShaderFill { size in emptyPageShader("emptyPageFilm", [.float2(size), .float(time)] + page) }
		case .silk:
			EmptyPageShaderFill { size in emptyPageShader("emptyPageSilk", [.float2(size), .float(time)] + page) }
		case .topography:
			EmptyPageShaderFill { size in emptyPageShader("emptyPageTopography", [.float2(size), .float(time)] + page) }
		case .dust:
			EmptyPageDust(time: time)
		}
	}
}
