import BrowserCore
import SwiftUI

/// A hand-drawn soft edge under an opaque bar that content scrolls beneath (DEV-782): content
/// scrolling up fades into the bar's background instead of meeting it at a hard line. It hangs
/// below the view it's attached to and takes no clicks.
///
/// Header bars use the system's soft scroll edge since DEV-807 (``SwiftUI/View/arxScrollBar(background:bar:)``);
/// this stays for a bar that has to be opaque.
///
/// It grows in over the first ``height`` points of scrolling (``opacity(scrolledBy:)``), so
/// content at rest is never drawn faded.
public struct ArxScrollEdgeFade: View {
	/// How far the fade reaches below the bar.
	public static let height: CGFloat = 14

	/// How strong the edge is once content has scrolled `offset` points under it: 0 at rest,
	/// 1 once a whole fade's height has passed.
	public static func opacity(scrolledBy offset: CGFloat) -> CGFloat {
		min(max(offset / height, 0), 1)
	}

	private let background: Color

	public init(background: Color = ArxModalMetrics.background) {
		self.background = background
	}

	public var body: some View {
		LinearGradient(
			colors: [background, background.opacity(0)],
			startPoint: .top,
			endPoint: .bottom
		)
		.frame(height: Self.height)
		.offset(y: Self.height)
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}

extension View {
	/// Draws the view as a bar that content scrolls under: on an opaque `background`, so nothing
	/// shows through its title, with the soft edge hanging below it.
	///
	/// `fade` scales the soft edge: 0 at rest, so nothing under the bar is faded before it
	/// scrolls, 1 once content passes under it.
	public func arxBarBackground(
		_ background: Color = ArxModalMetrics.background,
		fade: CGFloat
	) -> some View {
		self.background(background)
			.overlay(alignment: .bottom) {
				// A solid sliver across the bar's lower edge, at rest too, so the scroll view's
				// own divider under the bar never shows.
				background
					.frame(height: 4)
					.offset(y: 2)
					.allowsHitTesting(false)
			}
			.overlay(alignment: .bottom) {
				ArxScrollEdgeFade(background: background).opacity(fade)
			}
	}

	/// Pins `bar` over the top of a scroll view, which scrolls edge to edge under it with a
	/// progressive edge (DEV-807, DEV-808): content passing under the bar is blurred and veiled
	/// most at the top, easing out to nothing at the bar's lower edge, with no opaque band and no
	/// line, and only once content scrolls under it (``ArxProgressiveEdge``).
	/// A footer's safe-area bar gets the system's soft edge. The bar draws no background of its own; `background` is the surface behind the
	/// scroll view, or nil for a translucent surface, such as the chat panel or the Library. Apply
	/// it to the `ScrollView` itself.
	///
	/// The bar is a safe-area bar, which is what gives AppKit's scroll view a pocket on that edge;
	/// a safe-area inset or an overlay gets none. AppKit's soft pocket also draws a 0.5-point
	/// separator along its lower edge, which ``ArxScrollPocketSeparator`` turns off, so the soft
	/// edge shows alone; on top it hides the pocket, which the progressive edge replaces.
	///
	/// ```swift
	/// ScrollView {
	///     content.padding(24)
	/// }
	/// .arxScrollBar {
	///     ArxHeaderBar(.close { dismiss() }, title: "Extensions")
	/// }
	/// ```
	public func arxScrollBar<Bar: View>(
		background: Color? = ArxModalMetrics.background,
		@ViewBuilder bar: () -> Bar
	) -> some View {
		modifier(ArxScrollBar(background: background, bar: bar(), footer: EmptyView?.none))
	}

	/// ``arxScrollBar(background:bar:)`` with the progressive edge's `style` and `ramp` set
	/// (see ``ArxProgressiveEdge``), for a bar taller than a header bar, such as an onboarding
	/// page's title (DEV-1300): at full strength under the bar's text, easing out over `ramp`
	/// points at its lower edge.
	internal func arxScrollBar<Bar: View>(
		background: Color?,
		edgeStyle: ArxProgressiveEdge.Style,
		ramp: CGFloat?,
		@ViewBuilder bar: () -> Bar
	) -> some View {
		modifier(ArxScrollBar(
			background: background,
			bar: bar(),
			footer: EmptyView?.none,
			edgeStyle: edgeStyle,
			ramp: ramp
		))
	}

	/// ``arxScrollBar(background:bar:)`` with `footer` floating over the bottom of the scroll
	/// view (DEV-826), as a chat's composer: content scrolls and overscrolls under it, with no
	/// edge and no line there, so it stays visible through the footer, which draws its own
	/// see-through surface, such as a material.
	///
	/// AppKit gives the scroll view a pocket on that edge too, which blurs the footer's whole
	/// height with a hard cut along its top even with the edge effect hidden, so it's hidden.
	public func arxScrollBar<Bar: View, Footer: View>(
		background: Color? = ArxModalMetrics.background,
		@ViewBuilder bar: () -> Bar,
		@ViewBuilder footer: () -> Footer
	) -> some View {
		modifier(ArxScrollBar(background: background, bar: bar(), footer: footer()))
	}
}

private struct ArxScrollBar<Bar: View, Footer: View>: ViewModifier {
	internal let background: Color?
	internal let bar: Bar

	/// Floats over the bottom with no edge, or nil for none.
	internal let footer: Footer?
	internal var edgeStyle: ArxProgressiveEdge.Style = .standard

	/// How many points the progressive edge eases out over, or nil for the style's share.
	internal var ramp: CGFloat?

	/// How tall the progressive edge is and how far it has come in: 0 at rest, so nothing below
	/// the bar is blurred or veiled before content scrolls under it, and 1 once it has scrolled
	/// ``ArxVariableBlur/revealDistance``.
	@SwiftUI.State
	private var edge: ProgressiveEdgeGeometry = .init()

	@Environment(\.arxScrollEdgeOptions)
	private var options

	internal func body(content: Content) -> some View {
		let options = options
		return floatingFooter(over: content)
			.overlay(alignment: .top) {
				if options.isProgressive {
					// Over the scroll view's top, from its top edge down to its top inset, which is
					// the bar's lower edge, as AppKit's own pocket: the blur has eased out there, so
					// nothing below the bar is touched. Under the bar, which is drawn over it.
					ArxProgressiveEdge(background: background, ramp: ramp, style: edgeStyle)
						.frame(height: edge.height)
						.opacity(edge.reveal)
						.ignoresSafeArea()
				}
			}
			.safeAreaBar(edge: .top, spacing: 0) {
				// The bar takes clicks across its width, rather than the rows under it.
				bar.contentShape(.rect)
			}
			.onScrollGeometryChange(for: ProgressiveEdgeGeometry.self) { geometry in
				guard options.isProgressive else { return .init() }
				return .init(
					height: geometry.contentInsets.top.rounded(),
					reveal: ArxProgressiveEdge.reveal(scrolledBy: geometry.contentOffset.y + geometry.contentInsets.top)
				)
			} action: { _, geometry in
				edge = geometry
			}

			// Reaches the scroll view from here as from anywhere above it: the style is an
			// environment value. A footer's safe-area bar gets the system's soft edge, also with
			// the progressive edge, which only replaces the top one.
			.scrollEdgeEffectStyle(options.style, for: .all)
			.scrollEdgeEffectHidden(options.isHidden, for: options.hiddenEdges)
			.scrollEdgeEffectHidden(footer != nil, for: .bottom)
			.background {
				if options.hidesSeparator || options.isHidden || footer != nil {
					ArxScrollPocketSeparator.Hider(
						adaptive: options.isAdaptive,
						hiddenPockets: hiddenPockets(options)
					)
				}
			}
			.background(background ?? .clear)
			.onAppear {
				if options.showsTuner { ArxProgressiveEdgeTuner.show() }
			}
	}
}

extension ArxScrollBar {
	/// The content with the footer floating over its bottom, which it scrolls under. An inset
	/// rather than a safe-area bar, which would bring the system's soft edge with it.
	@ViewBuilder
	fileprivate func floatingFooter(over content: Content) -> some View {
		if let footer {
			content.safeAreaInset(edge: .bottom, spacing: 0) { footer }
		} else {
			content
		}
	}

	/// The pockets the hider hides: the edges the progressive edge replaces, and the bottom
	/// under a floating footer.
	fileprivate func hiddenPockets(_ options: ArxScrollEdgeOptions) -> Edge.Set {
		var edges: Edge.Set = options.isHidden ? options.hiddenEdges : []
		if footer != nil { edges.insert(.bottom) }
		return edges
	}
}

/// Where the progressive edge goes and how far it has come in: the scroll view's top inset, the
/// bar's lower edge, and ``ArxProgressiveEdge/reveal(scrolledBy:)``.
private struct ProgressiveEdgeGeometry: Equatable {
	internal var height: CGFloat
	internal var reveal: CGFloat

	internal init(
		height: CGFloat = 0,
		reveal: CGFloat = 0
	) {
		self.height = height
		self.reveal = reveal
	}
}

/// Feature flags for an A/B check of the scroll edge under bars (DEV-808), read once at launch from
/// the environment or from Arx's defaults, with the same names. Unset, bars get the progressive
/// edge on top, ``ArxProgressiveEdge``, and the system's soft edge, with its separator off, on
/// the bottom, as over a modal's footer.
///
/// - `ARX_SCROLL_EDGE`: `progressive` (the default), or `soft`, `hard` or `automatic` for the
///   system's edge on both, or `off` for no edge.
/// - `ARX_SCROLL_POCKET_HIDER`: `0` leaves AppKit's separator as it is.
/// - `ARX_SCROLL_POCKET_ADAPTIVE`: `0` turns off the pocket's color scheme adaptivity, which
///   tracks the brightness of the content under it.
/// - `ARX_SCROLL_EDGE_TUNER`: `1` turns the progressive edge on and opens
///   ``ArxProgressiveEdgeTuner``, a floating panel to adjust it live.
///
/// ```sh
/// defaults write dev.capturecontext.arx ARX_SCROLL_EDGE -string hard
/// defaults delete dev.capturecontext.arx ARX_SCROLL_EDGE
/// ```
internal struct ArxScrollEdgeOptions: Sendable {
	internal var style: ScrollEdgeEffectStyle
	internal var isHidden: Bool
	internal var hidesSeparator: Bool
	internal var isAdaptive: Bool
	internal var isProgressive: Bool
	internal var showsTuner: Bool

	/// The system's edge alone, with its separator off, as before the progressive edge.
	internal static let soft: Self = .init(read: { $0 == "ARX_SCROLL_EDGE" ? "soft" : nil })

	/// The edges the system's own edge is hidden on: only the top with the progressive edge,
	/// which replaces it there; every edge with no edge.
	internal var hiddenEdges: Edge.Set {
		isProgressive ? .top : .all
	}

	/// A registered feature flag reads through the `FeatureFlag` registry, which falls back from
	/// the environment to user defaults as Settings shows it; the edge's style reads as before.
	internal static let current: Self = .init(read: { name in
		if let flag = FeatureFlag(rawValue: name) { return flag.isOn() ? "on" : "off" }
		return ProcessInfo.processInfo.environment[name] ?? UserDefaults.standard.string(forKey: name)
	})

	internal init() {
		self.style = .soft
		self.isHidden = true
		self.hidesSeparator = true
		self.isAdaptive = true
		self.isProgressive = true
		self.showsTuner = false
	}

	internal init(read: (String) -> String?) {
		self.init()
		switch read("ARX_SCROLL_EDGE")?.lowercased() {
		case "soft": useSystemEdge(.soft)
		case "hard": useSystemEdge(.hard)
		case "automatic": useSystemEdge(.automatic)
		case "off": isProgressive = false
		default: break
		}
		if read("ARX_SCROLL_EDGE_TUNER") == "1" {
			isHidden = true
			isProgressive = true
			showsTuner = true
		}
		hidesSeparator = Self.isOn(.scrollPocketHider, read: read)
		isAdaptive = Self.isOn(.scrollPocketAdaptive, read: read)
	}

	/// A registered feature flag's value, read as the `FeatureFlag` registry reads it.
	private static func isOn(
		_ flag: FeatureFlag,
		read: (String) -> String?
	) -> Bool {
		read(flag.name).flatMap(FeatureFlag.parse) ?? flag.isOnByDefault
	}

	private mutating func useSystemEdge(_ style: ScrollEdgeEffectStyle) {
		self.style = style
		isHidden = false
		isProgressive = false
	}
}

extension EnvironmentValues {
	/// The scroll edge bars get, ``ArxScrollEdgeOptions/current`` unless a test sets it.
	@Entry
	internal var arxScrollEdgeOptions: ArxScrollEdgeOptions = .current
}
