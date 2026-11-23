import Foundation

/// The `ARX_RECENT_TAB_SWITCHER` feature flag (DEV-544): ⌃Tab switches among the window's tabs in
/// the order they were last shown. A quick ⌃Tab goes straight back to the previous tab;
/// holding ⌃ shows the switcher, and letting go of ⌃ picks. Off, ⌃Tab and ⌃⇧Tab are Next Tab and
/// Previous Tab in the sidebar's order, as before (DEV-795).
///
/// On by default, like every feature flag (DEV-1143), and read through the `FeatureFlag`
/// registry: the environment first, then user defaults, where `0`, `false`, `no` or `off` turns
/// it off. Each window reads it when it opens.
public enum RecentTabSwitcherFeatureFlag {
	public static let name: String = FeatureFlag.recentTabSwitcher.name

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.recentTabSwitcher.isOn(environment: environment, defaults: defaults)
	}
}
