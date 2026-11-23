import BrowserCore
import SwiftUI

/// The two spaces a pager's sidebar stands between, and how far it is toward the later one.
///
/// The window's background reads it to turn from one space's appearance to the other's as far
/// as the sidebar has gone (DEV-1310): it followed the selection, which changes
/// only once a slide lands, so a swipe moved the sidebar under one color and the other faded in
/// afterwards. At rest on a space, `lower` is that space and `upper` is nil.
@MainActor
@Observable
public final class SidebarSpaceReveal {
	public private(set) var lower: UUID?
	public private(set) var upper: UUID?
	public private(set) var fraction: CGFloat

	public init() {
		self.lower = nil
		self.upper = nil
		self.fraction = 0
	}

	/// The spaces either side of `position`, a track's position among `spaces`.
	internal static func spaces(
		at position: CGFloat,
		among spaces: [UUID]
	) -> (lower: UUID?, upper: UUID?, fraction: CGFloat) {
		guard !spaces.isEmpty else { return (nil, nil, 0) }
		let last: CGFloat = CGFloat(spaces.count - 1)
		let position: CGFloat = min(max(position, 0), last)
		let lower: Int = Int(position.rounded(.down))
		let fraction: CGFloat = position - CGFloat(lower)
		guard fraction > 0, spaces.indices.contains(lower + 1) else { return (spaces[lower], nil, 0) }
		return (spaces[lower], spaces[lower + 1], fraction)
	}

	internal func show(
		position: CGFloat,
		among spaces: [UUID]
	) {
		let shown = Self.spaces(at: position, among: spaces)
		if lower != shown.lower { lower = shown.lower }
		if upper != shown.upper { upper = shown.upper }
		if fraction != shown.fraction { fraction = shown.fraction }
	}
}

/// What the window's background needs to follow a swipe between spaces: where the sidebar
/// stands, and each space's appearance.
public struct BrowserChromeReveal: Equatable {
	internal let reveal: SidebarSpaceReveal
	internal let appearance: @MainActor (UUID) -> AppearanceOverride?

	/// - Parameters:
	///   - appearance: A space's appearance over its profile's, as the window applies
	///     the selected space's; nil for a space that's gone.
	public init(
		reveal: SidebarSpaceReveal,
		appearance: @escaping @MainActor (UUID) -> AppearanceOverride?
	) {
		self.reveal = reveal
		self.appearance = appearance
	}

	/// The same sidebar's: the window hands a new closure on every pass.
	public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.reveal === rhs.reveal
	}
}

/// The app-wide appearance a profile's or space's override was applied over, so another space's
/// can be worked out from inside the selected one's.
internal struct BrowserChromeInherited: Equatable {
	internal var appearance: ChromeAppearance
	internal var colorScheme: ColorScheme

	internal init(
		appearance: ChromeAppearance,
		colorScheme: ColorScheme
	) {
		self.appearance = appearance
		self.colorScheme = colorScheme
	}

	/// What `override` looks like over it.
	internal func look(of override: AppearanceOverride) -> (appearance: ChromeAppearance, colorScheme: ColorScheme) {
		let scheme: ColorScheme = switch override.theme {
		case .light: .light
		case .dark: .dark
		case nil: colorScheme
		}
		return (override.applied(to: appearance), scheme)
	}
}

extension EnvironmentValues {
	/// Set on a window's background for it to follow a swipe between spaces (DEV-1310).
	@Entry
	public var browserChromeReveal: BrowserChromeReveal? = nil

	/// Set by `appearanceOverride(_:transitionKey:siteColor:)` for what it wraps.
	@Entry
	internal var browserChromeInherited: BrowserChromeInherited? = nil
}

/// Gives one of the pager's pages its own space's appearance while another space is selected,
/// so a space sliding in already has its own light or dark text over the background turning
/// toward it. The selected space's page keeps the window's, which is the same.
///
/// It sets values rather than choosing between two views, so becoming the selected page
/// rebuilds nothing.
internal struct SidebarPageAppearance: ViewModifier {
	private let override: AppearanceOverride?

	@Environment(\.browserChromeInherited)
	private var inherited

	internal init(override: AppearanceOverride?) {
		self.override = override
	}

	internal func body(content: Content) -> some View {
		let look = override.flatMap { override in inherited.map { $0.look(of: override) } }
		content
			.transformEnvironment(\.browserChromeTint) { if let look { $0 = look.appearance.tint } }
			.transformEnvironment(\.browserFilmGrain) { if let look { $0 = .init(look.appearance.grain) } }
			.transformEnvironment(\.browserChromeGradient) { if let look { $0 = look.appearance.gradient } }
			.transformEnvironment(\.browserChromeAccent) { if let look { $0 = look.appearance.accent } }
			.transformEnvironment(\.browserChromeMatchesSite) { if let look { $0 = look.appearance.matchesSite } }
			.transformEnvironment(\.browserChromeSiteColor) { if look != nil { $0 = nil } }
			.transformEnvironment(\.colorScheme) { if let look { $0 = look.colorScheme } }
	}
}
