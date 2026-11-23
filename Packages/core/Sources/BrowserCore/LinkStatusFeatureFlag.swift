import Foundation

/// The `ARX_LINK_STATUS` feature flag (DEV-1111): hovering a page link shows where it goes, and
/// what a click with the held modifier keys will do, at the page's bottom corner. Read through
/// `FeatureFlag`: on by default (DEV-1143), and `0`, `false`, `no` or `off` turns it off. With it
/// on, Settings › Links › Show where links go still turns the status off.
public enum LinkStatusFeatureFlag {
	public static let name: String = FeatureFlag.linkStatus.name

	public static func isOn(
		environment: [String: String],
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.linkStatus.isOn(environment: environment, defaults: defaults)
	}
}
