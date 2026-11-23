import Foundation

/// The `ARX_SITE_PREVIEW_IMAGES` feature flag (DEV-1142): Settings › General › Previews offers a
/// choice for pages that aren't loaded, and the site's picture and description are requested
/// with the cookies the tab's profile sends the page's own host. Off, the two Previews switches
/// stay and the request carries no cookies (DEV-730).
///
/// On by default (DEV-1143), read through `FeatureFlag`: `1`, `true`, `yes` or `on` turns it on,
/// `0`, `false`, `no` or `off` turns it off, and anything else leaves the default.
public enum SitePreviewImagesFeatureFlag {
	public static let name: String = FeatureFlag.sitePreviewImages.name

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.sitePreviewImages.isOn(environment: environment, defaults: defaults)
	}
}
