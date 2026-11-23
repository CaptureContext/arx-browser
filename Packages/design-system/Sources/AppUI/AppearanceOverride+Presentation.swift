import BrowserCore
import SwiftUI

extension View {
	/// Applies a profile's or space's appearance over the app-wide one, to Arx's own chrome.
	///
	/// A new `transitionKey`, such as the selected space, crossfades the chrome to the new appearance.
	/// While the override, or the app-wide appearance it inherits, matches the site, `siteColor`,
	/// the shown page's, stands in for its tint (DEV-1101, DEV-1170); without one the tint stays.
	public func appearanceOverride(
		_ override: AppearanceOverride,
		transitionKey: UUID? = nil,
		siteColor: ChromePalette.RGB? = nil
	) -> some View {
		modifier(AppearanceOverrideModifier(override: override, transitionKey: transitionKey, siteColor: siteColor))
	}
}

private struct AppearanceOverrideModifier: ViewModifier {
	private let override: AppearanceOverride
	private let transitionKey: UUID?
	private let siteColor: ChromePalette.RGB?

	@Environment(\.browserFilmGrain)
	private var grain

	@Environment(\.browserChromeTint)
	private var tint

	@Environment(\.browserChromeGradient)
	private var gradient

	@Environment(\.browserChromeAccent)
	private var accent

	@Environment(\.browserChromeMatchesSite)
	private var matchesSite

	@Environment(\.colorScheme)
	private var colorScheme

	fileprivate init(
		override: AppearanceOverride,
		transitionKey: UUID?,
		siteColor: ChromePalette.RGB?
	) {
		self.override = override
		self.transitionKey = transitionKey
		self.siteColor = siteColor
	}

	fileprivate func body(content: Content) -> some View {
		let global = ChromeAppearance(
			tint: tint,
			grain: .init(grain),
			gradient: gradient,
			accent: accent,
			matchesSite: matchesSite
		)
		let resolved = override.applied(to: global)
		let scheme: ColorScheme = switch override.theme {
		case .light: .light
		case .dark: .dark
		case nil: colorScheme
		}
		return content
			.browserChromeAppearance(resolved)
			.environment(\.browserChromeInherited, .init(appearance: global, colorScheme: colorScheme))
			.environment(\.colorScheme, scheme)
			.environment(\.browserChromeSiteColor, resolved.matchesSite ? siteColor : nil)
			.transformEnvironment(\.browserChromeTransitionKey) { key in
				if let transitionKey { key = transitionKey }
			}
	}
}

extension AppearanceOverride.Theme {
	public var title: String {
		switch self {
		case .light: String.localized(.appUI.appearance.themeLight)
		case .dark: String.localized(.appUI.appearance.themeDark)
		}
	}
}

/// A small chip of a profile's or space's chrome colors over the app-wide appearance, as in
/// the import preview's list of spaces (DEV-897).
public struct AppearanceSwatch: View {
	private let appearance: AppearanceOverride

	public init(_ appearance: AppearanceOverride) {
		self.appearance = appearance
	}

	public var body: some View {
		RoundedRectangle(cornerRadius: 4, style: .continuous)
			.fill(BrowserChromeGradient(.sidebar))
			.overlay {
				RoundedRectangle(cornerRadius: 4, style: .continuous)
					.strokeBorder(.separator, lineWidth: 0.5)
			}
			.frame(width: 28, height: 16)
			.appearanceOverride(appearance)
			.accessibilityHidden(true)
	}
}
