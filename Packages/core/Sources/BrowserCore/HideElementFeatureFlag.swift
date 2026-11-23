import Foundation

/// The `ARX_HIDE_ELEMENT` feature flag (DEV-1019): View › Hide Element…, its ⇧⌘H shortcut and
/// command bar entry, and the site menu's Hidden Elements. On by default (DEV-1143). Read through
/// the `FeatureFlag` registry: the environment first, then user defaults.
public enum HideElementFeatureFlag {
	public static let name: String = FeatureFlag.hideElement.name

	public static func isOn(
		environment: [String: String],
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.hideElement.isOn(environment: environment, defaults: defaults)
	}
}
