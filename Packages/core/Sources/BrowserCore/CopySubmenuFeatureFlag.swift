import Foundation

/// The `ARX_COPY_SUBMENU` feature flag (DEV-1162): a tab's, a link's and the Tab menu's copy and
/// share items sit in a Copy submenu (`LinkCopyMenu`) rather than at the top of the menu. Off,
/// they stay where they were.
///
/// On by default, like every feature flag (DEV-1143), and read through the `FeatureFlag`
/// registry: the environment first, then user defaults, where `0`, `false`, `no` or `off` turns
/// it off. The menu bar reads it at launch; the other menus each time they open.
public enum CopySubmenuFeatureFlag {
	public static let name: String = FeatureFlag.copySubmenu.name

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.copySubmenu.isOn(environment: environment, defaults: defaults)
	}
}
