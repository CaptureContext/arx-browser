import AppKit
import BrowserCore
import SwiftUI

extension EnvironmentValues {
	/// The chrome's tint: the app-wide one, until a profile's or space's appearance replaces it.
	@Entry
	public var browserChromeTint: ChromeTint = .default

	/// Changing it crossfades the chrome to its new appearance. Edits under one key apply at once,
	/// so a slider never animates behind the pointer.
	@Entry
	public var browserChromeTransitionKey: UUID? = nil

	/// A gradient of the tint and more colors from a profile's or space's appearance (DEV-919), or
	/// nil for the tint's two-tone gradient.
	@Entry
	public var browserChromeGradient: ChromeGradient? = nil

	/// Whether the chrome matches the site (DEV-1101): the app-wide choice, until a profile's or
	/// space's appearance replaces it (DEV-1170).
	@Entry
	public var browserChromeMatchesSite: Bool = false

	/// The color of the page the chrome is around, while the space matches the site (DEV-1101). It
	/// stands in for the tint and gradient; nil keeps them.
	@Entry
	public var browserChromeSiteColor: ChromePalette.RGB? = nil

	/// Whether the translucent chrome draws its behind-window blur (DEV-1286). Offscreen snapshots
	/// turn it off: there the blur has no desktop to show and draws a flat fill instead.
	@Entry
	internal var browserChromeBlursBehindWindow: Bool = true

	/// The accent color the cascade resolved to (DEV-1117), or nil for Automatic.
	@Entry
	public var browserChromeAccent: ChromeAccent? = nil

	/// Whether accents follow the appearance cascade, `ChromeAccent.featureFlag`. Off, Arx's own
	/// accent stays as it was.
	@Entry
	public var browserAccentIsEnabled: Bool = false

	/// A surface's two stops: the site's color adjusted for legibility while the chrome matches the
	/// site, the tint's otherwise.
	internal func browserChromePalette(_ surface: ChromePalette.Surface) -> ChromePalette {
		let isDark = colorScheme == .dark
		guard let site = browserChromeSiteColor else {
			return ChromePalette(tint: browserChromeTint, surface: surface, isDark: isDark)
		}
		return ChromePalette(
			site: site,
			surface: surface,
			isDark: isDark,
			increasedContrast: colorSchemeContrast == .increased
		)
	}
}

extension ChromeGradient {
	/// The gradient for a surface: the tint's top color, a color for each further stop, and the
	/// last stop's darker end, so it keeps the two-tone gradient's depth.
	internal func linearGradient(
		tint: ChromeTint,
		surface: ChromePalette.Surface,
		isDark: Bool
	) -> LinearGradient {
		let base = ChromePalette(tint: tint, surface: surface, isDark: isDark)
		let palettes = stops.map { ChromePalette(tint: $0, surface: surface, isDark: isDark) }
		var colors: [Color] = [Color(base.top)]
		for (index, palette) in palettes.enumerated() {
			colors.append(Color(index == palettes.count - 1 ? palette.bottom : palette.top))
		}
		if palettes.isEmpty { colors.append(Color(base.bottom)) }
		let radians = angle * .pi / 180
		let dx = sin(radians) / 2
		let dy = -cos(radians) / 2
		return LinearGradient(
			colors: colors,
			startPoint: .init(x: 0.5 - dx, y: 0.5 - dy),
			endPoint: .init(x: 0.5 + dx, y: 0.5 + dy)
		)
	}
}

/// The chrome gradient for the tint in the environment, in the current light or dark appearance.
public struct BrowserChromeGradient: ShapeStyle {
	private let surface: ChromePalette.Surface

	public init(_ surface: ChromePalette.Surface) {
		self.surface = surface
	}

	public func resolve(in environment: EnvironmentValues) -> LinearGradient {
		if environment.browserChromeSiteColor == nil, let gradient = environment.browserChromeGradient {
			return gradient.linearGradient(
				tint: environment.browserChromeTint,
				surface: surface,
				isDark: environment.colorScheme == .dark
			)
		}
		let palette = environment.browserChromePalette(surface)
		return LinearGradient(
			colors: [Color(palette.top), Color(palette.bottom)],
			startPoint: .topLeading,
			endPoint: .bottomTrailing
		)
	}
}

/// The accent color (DEV-1117): the cascade's choice, or Automatic's from the tint, checked for
/// contrast against the sidebar the accent sits on, its site color included. With the feature
/// flag off, Arx's own accent.
public struct BrowserAccent: ShapeStyle {
	public init() {}

	public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
		guard environment.browserAccentIsEnabled else {
			return Color.resource(.browser.accent).resolve(in: environment)
		}
		let palette = environment.browserChromePalette(.sidebar)
		let accent = ChromeAccent.resolve(
			environment.browserChromeAccent,
			tint: environment.browserChromeTint,
			background: palette.top.mixed(with: palette.bottom),
			isDark: environment.colorScheme == .dark
		)
		return Color(accent).resolve(in: environment)
	}

	/// The accent mixed toward another color, as `Color.mix(with:by:)` does.
	public func mixed(
		with other: Color,
		by fraction: Double
	) -> BrowserAccentMix {
		.init(other: other, fraction: fraction)
	}
}

/// Text and symbols on an accent fill (DEV-1117): Arx's own with the feature flag off, otherwise
/// white or near black, whichever reads better on the accent the environment resolves, as a pale
/// custom or yellow accent needs dark text.
public struct BrowserOnAccent: ShapeStyle {
	public init() {}

	public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
		guard environment.browserAccentIsEnabled else {
			return Color.resource(.browser.onAccent).resolve(in: environment)
		}
		let accent = BrowserAccent().resolve(in: environment)
		let fill = ChromePalette.RGB(red: Double(accent.red), green: Double(accent.green), blue: Double(accent.blue))
		let dark = ChromePalette.RGB(red: 0.08, green: 0.08, blue: 0.1)
		let white = ChromePalette.RGB(red: 1, green: 1, blue: 1)
		let text = fill.contrast(with: white) >= fill.contrast(with: dark) ? white : dark
		return Color(text).resolve(in: environment)
	}
}

/// `BrowserAccent` mixed toward another color, resolved in the same environment.
public struct BrowserAccentMix: ShapeStyle {
	private let other: Color
	private let fraction: Double

	fileprivate init(
		other: Color,
		fraction: Double
	) {
		self.other = other
		self.fraction = fraction
	}

	public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
		Color(BrowserAccent().resolve(in: environment))
			.mix(with: other, by: fraction)
			.resolve(in: environment)
	}
}

/// `BrowserTheme.selection` composited over the middle of the sidebar's gradient into one opaque
/// color, as the translucent fill reads over the chrome, without the chrome's grain behind it.
public struct BrowserSelectionFill: ShapeStyle {
	public init() {}

	public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
		let palette = environment.browserChromePalette(.sidebar)
		let selection = BrowserTheme.selection.resolve(in: environment)
		let alpha = Double(selection.opacity)

		// Blended in gamma-encoded sRGB, as the window composites the translucent fill.
		func over(
			_ top: Double,
			_ bottom: Double,
			_ fill: Float
		) -> Float {
			let base = (top + bottom) / 2
			return Float(base * (1 - alpha) + Double(fill) * alpha)
		}
		return .init(
			colorSpace: .sRGB,
			red: over(palette.top.red, palette.bottom.red, selection.red),
			green: over(palette.top.green, palette.bottom.green, selection.green),
			blue: over(palette.top.blue, palette.bottom.blue, selection.blue)
		)
	}
}

extension BrowserChromeGradient: View {
	public var body: some View {
		Rectangle().fill(self)
	}
}

extension Color {
	public init(_ rgb: ChromePalette.RGB) {
		self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
	}
}

extension FilmGrainStyle {
	public init(_ grain: ChromeGrain) {
		self.init(
			isEnabled: grain.isEnabled,
			intensity: grain.intensity,
			size: grain.size,
			texture: grain.texture
		)
	}
}

extension ChromeGrain {
	public init(_ style: FilmGrainStyle) {
		self.init(
			isEnabled: style.isEnabled,
			intensity: style.intensity,
			size: style.size,
			texture: style.texture
		)
	}
}

extension View {
	/// Sets the app-wide chrome appearance that profile and space overrides build on.
	public func browserChromeAppearance(_ appearance: ChromeAppearance) -> some View {
		self
			.environment(\.browserChromeTint, appearance.tint)
			.environment(\.browserFilmGrain, .init(appearance.grain))
			.environment(\.browserChromeGradient, appearance.gradient)
			.environment(\.browserChromeAccent, appearance.accent)
			.environment(\.browserChromeMatchesSite, appearance.matchesSite)
	}
}

/// The sidebar gradient, behind the sidebar and around the page card, with the space's texture
/// where it's a window's background.
///
/// Translucent, only the browser window's own chrome lets the desktop through (DEV-1286): as
/// much as `TranslucentChrome.opacity` gives the tint's intensity, over a behind-window blur.
/// Every other place it's drawn (previews, panels, Little Arx, Page PiP) stays solid.
public struct BrowserChromeBackground: View {
	/// Whether it draws the texture. A window's background does, and so does a picture of one; a
	/// surface over a window, such as a hover preview or the command bar, keeps plain glass, so the
	/// texture stays on the window background (DEV-1286).
	private let isTextured: Bool

	@Environment(\.browserFilmGrain)
	private var grain

	@Environment(\.browserChromeTint)
	private var tint

	@Environment(\.browserChromeGradient)
	private var gradient

	@Environment(\.browserChromeTransitionKey)
	private var transitionKey

	@Environment(\.browserChromeSiteColor)
	private var siteColor

	@Environment(\.colorScheme)
	private var colorScheme

	@Environment(\.colorSchemeContrast)
	private var contrast

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@Environment(\.accessibilityReduceTransparency)
	private var reduceTransparency

	@Environment(\.browserChromeBlursBehindWindow)
	private var blursBehindWindow

	@Environment(\.browserChromeReveal)
	private var chromeReveal

	@Environment(\.browserChromeInherited)
	private var inherited

	@State
	private var isFullScreen: Bool = false

	private let isTranslucent: Bool

	/// - Parameters:
	///   - textured: True for a window's background or a picture of one; false for a surface
	///     drawn over a window.
	///   - isTranslucent: Whether it lets what's behind the window through, as the browser
	///     window's own chrome does with `TranslucentChrome`'s feature flag on. Off, it's solid, as
	///     it always was.
	public init(
		textured: Bool,
		isTranslucent: Bool = false
	) {
		self.isTextured = textured
		self.isTranslucent = isTranslucent
	}

	public var body: some View {
		let _ = RenderTrace.body("BrowserChromeBackground.body")
		if isTranslucent {
			ZStack {
				// Always solid and interpolated, so a crossfade between two spaces' layers never
				// dips to the desktop: the chrome is only ever as clear as `opacity` says.
				ChromeGradientLayer(stops: .init(palette))
				fill
			}
				.overlay {
					if isTextured { FilmGrain(style: grain) }
				}
				.overlay { revealLayers }
				.compositingGroup()
				.modifier(ChromeRevealOpacity(
					selected: opacity,
					reveal: revealSpaces,
					selectedSpace: transitionKey,
					opacity: revealOpacity
				))
				.background {
					if blursBehindWindow { ChromeBehindWindowBlur() }
				}
				.background {
					BrowserFullScreenObserver { isFullScreen in
						guard self.isFullScreen != isFullScreen else { return }
						self.isFullScreen = isFullScreen
					}
				}
				.animation(spaceTransition, value: transitionKey)
				.animation(transition, value: siteColor)
		} else {
			fill
				.overlay {
					if isTextured { FilmGrain(style: grain) }
				}
				.overlay { revealLayers }
				.animation(spaceTransition, value: transitionKey)
				.animation(transition, value: siteColor)
		}
	}

	/// The spaces a swipe has the sidebar between, drawn over the selected space's chrome as far
	/// as it has gone (DEV-1310).
	@ViewBuilder
	private var revealLayers: some View {
		if let chromeReveal, let inherited {
			ChromeRevealLayers(
				chrome: chromeReveal,
				inherited: inherited,
				selectedSpace: transitionKey,
				isTextured: isTextured
			)
		}
	}

	private var revealSpaces: SidebarSpaceReveal? {
		inherited == nil ? nil : chromeReveal?.reveal
	}

	/// How solid a space's chrome is, for the translucent chrome to follow a swipe too.
	private var revealOpacity: (UUID) -> Double? {
		{ [chromeReveal, inherited, isTranslucent, isFullScreen, reduceTransparency, contrast] space in
			guard
				let inherited,
				let override = chromeReveal?.appearance(space)
			else { return nil }
			return TranslucentChrome.opacity(
				intensity: inherited.look(of: override).appearance.tint.intensity,
				isEnabled: isTranslucent && !isFullScreen,
				reduceTransparency: reduceTransparency,
				increaseContrast: contrast == .increased
			)
		}
	}

	/// A space selected as the sidebar lands on it is already drawn, by the layers that
	/// followed the slide there: easing the chrome over to it again would show the space it
	/// left for a moment. Any other change of space eases over as before.
	private var spaceTransition: Animation? {
		if let transitionKey, chromeReveal?.reveal.lower == transitionKey { return nil }
		return transition
	}

	@ViewBuilder
	private var fill: some View {
		if siteColor == nil, let gradient {
			// Several colors at an angle (DEV-919). It changes with a crossfade of the whole layer.
			Rectangle().fill(gradient.linearGradient(tint: tint, surface: .sidebar, isDark: colorScheme == .dark))
		} else {
			// The tint's stops, or the page's color (DEV-1101): one layer, so a change between them
			// interpolates from wherever the last one caught it.
			ChromeGradientLayer(stops: .init(palette))
		}
	}

	/// How solid the chrome is: the tint's, while it's translucent. Matching the site keeps it
	/// solid, as the page's color stands for the page; so does full screen, with nothing behind
	/// the window but the OS workspace's black.
	private var opacity: Double {
		TranslucentChrome.opacity(
			intensity: tint.intensity,
			isEnabled: isTranslucent && siteColor == nil && !isFullScreen,
			reduceTransparency: reduceTransparency,
			increaseContrast: contrast == .increased
		)
	}

	/// A space switch and a site's color ease over alike; Reduce Motion switches at once.
	private var transition: Animation? {
		reduceMotion ? nil : BrowserChromeTransition.animation
	}

	private var palette: ChromePalette {
		guard let siteColor else {
			return ChromePalette(tint: tint, surface: .sidebar, isDark: colorScheme == .dark)
		}
		return ChromePalette(
			site: siteColor,
			surface: .sidebar,
			isDark: colorScheme == .dark,
			increasedContrast: contrast == .increased
		)
	}
}

/// The chrome of the spaces the sidebar stands between: the earlier one whole, unless it's the
/// selected space, whose chrome is under these layers already, and the later one over it as
/// far as the sidebar has gone toward it. It reads the swipe itself, so a frame of one runs
/// this body and no other.
private struct ChromeRevealLayers: View {
	private let chrome: BrowserChromeReveal
	private let inherited: BrowserChromeInherited
	private let selectedSpace: UUID?
	private let isTextured: Bool

	fileprivate init(
		chrome: BrowserChromeReveal,
		inherited: BrowserChromeInherited,
		selectedSpace: UUID?,
		isTextured: Bool
	) {
		self.chrome = chrome
		self.inherited = inherited
		self.selectedSpace = selectedSpace
		self.isTextured = isTextured
	}

	fileprivate var body: some View {
		let reveal: SidebarSpaceReveal = chrome.reveal
		ZStack {
			if let lower = reveal.lower, lower != selectedSpace {
				layer(of: lower)
			}
			if let upper = reveal.upper {
				layer(of: upper).opacity(reveal.fraction)
			}
		}
		.allowsHitTesting(false)
	}

	@ViewBuilder
	private func layer(of space: UUID) -> some View {
		if let override = chrome.appearance(space) {
			let look = inherited.look(of: override)
			let isDark: Bool = look.colorScheme == .dark
			Group {
				if let gradient = look.appearance.gradient {
					Rectangle().fill(gradient.linearGradient(tint: look.appearance.tint, surface: .sidebar, isDark: isDark))
				} else {
					ChromeGradientLayer(stops: .init(.init(tint: look.appearance.tint, surface: .sidebar, isDark: isDark)))
				}
			}
			.overlay {
				if isTextured { FilmGrain(style: .init(look.appearance.grain)) }
			}
		}
	}
}

/// How solid the translucent chrome is while a swipe has the sidebar between two spaces:
/// between theirs, as far as it has gone.
private struct ChromeRevealOpacity: ViewModifier {
	private let selected: Double
	private let reveal: SidebarSpaceReveal?
	private let selectedSpace: UUID?
	private let opacity: (UUID) -> Double?

	fileprivate init(
		selected: Double,
		reveal: SidebarSpaceReveal?,
		selectedSpace: UUID?,
		opacity: @escaping (UUID) -> Double?
	) {
		self.selected = selected
		self.reveal = reveal
		self.selectedSpace = selectedSpace
		self.opacity = opacity
	}

	fileprivate func body(content: Content) -> some View {
		content.opacity(value)
	}

	private var value: Double {
		guard let reveal else { return selected }
		func solid(_ space: UUID?) -> Double {
			guard let space, space != selectedSpace else { return selected }
			return opacity(space) ?? selected
		}
		let lower: Double = solid(reveal.lower)
		guard reveal.upper != nil else { return lower }
		return lower + (solid(reveal.upper) - lower) * Double(reveal.fraction)
	}
}

/// What's behind the window, blurred, under the translucent chrome (DEV-1286), so text on it
/// stays readable over a busy desktop. It follows the window's active state, as AppKit's own
/// window backgrounds do.
private struct ChromeBehindWindowBlur: NSViewRepresentable {
	fileprivate func makeNSView(context: Context) -> BlurView {
		let view = BlurView()
		view.blendingMode = .behindWindow
		view.material = .underWindowBackground
		view.state = .followsWindowActiveState
		return view
	}

	fileprivate func updateNSView(
		_ view: BlurView,
		context: Context
	) {}

	/// Never takes a click or a window drag, as the solid chrome it stands behind doesn't.
	fileprivate final class BlurView: NSVisualEffectView {
		fileprivate override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}
}

/// How the chrome eases to a new appearance: a space's, or the page's color while it matches the
/// site (DEV-1101).
public enum BrowserChromeTransition {
	public static let animation: Animation = .easeInOut(duration: 0.3)
}

/// Interpolates the stops' components, so a crossfade never shows what's behind the window.
private struct ChromeGradientLayer: View, Animatable {
	fileprivate var stops: ChromeStops

	fileprivate init(stops: ChromeStops) {
		self.stops = stops
	}

	nonisolated fileprivate var animatableData: ChromeStops {
		get { stops }
		set { stops = newValue }
	}

	fileprivate var body: some View {
		LinearGradient(
			colors: [
				Color(.sRGB, red: stops.values[0], green: stops.values[1], blue: stops.values[2]),
				Color(.sRGB, red: stops.values[3], green: stops.values[4], blue: stops.values[5]),
			],
			startPoint: .topLeading,
			endPoint: .bottomTrailing
		)
	}
}

/// The top and bottom stops' components as one animatable vector.
private struct ChromeStops: VectorArithmetic {
	fileprivate var values: [Double]

	fileprivate init(values: [Double]) {
		self.values = values
	}

	fileprivate init(_ palette: ChromePalette) {
		self.init(values: [
			palette.top.red, palette.top.green, palette.top.blue,
			palette.bottom.red, palette.bottom.green, palette.bottom.blue,
		])
	}

	fileprivate static var zero: Self { .init(values: .init(repeating: 0, count: 6)) }

	fileprivate var magnitudeSquared: Double {
		values.reduce(0) { $0 + $1 * $1 }
	}

	fileprivate mutating func scale(by rhs: Double) {
		values = values.map { $0 * rhs }
	}

	fileprivate static func + (lhs: Self, rhs: Self) -> Self {
		.init(values: zip(lhs.values, rhs.values).map(+))
	}

	fileprivate static func - (lhs: Self, rhs: Self) -> Self {
		.init(values: zip(lhs.values, rhs.values).map(-))
	}
}
