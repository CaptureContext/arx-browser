import Foundation

/// The `ARX_NEW_TABS_AT_TOP` feature flag (DEV-1174): Settings › General › Tabs has two rows,
/// New tabs open (`openedTabPlacement`, at the top by default) for the New Tab button,
/// ⌘T and ⌘K, and Tabs from links open (`newTabPlacement`, the choice saved before) for links.
/// Off, the one New tabs open row places both from `newTabPlacement`, as before.
///
/// On by default, like every feature flag (DEV-1143), and read through the `FeatureFlag`
/// registry: the environment first, then user defaults, where `0`, `false`, `no` or `off` turns
/// it off. Arx reads it once, at launch (`atLaunch`).
public enum NewTabsAtTopFeatureFlag {
	public static let name: String = FeatureFlag.newTabsAtTop.name

	/// The value Arx launched with, read once. Every window and Settings take this one, so a
	/// change waiting for a relaunch doesn't give a new window other rules than Settings shows.
	public static let atLaunch: Bool = isOn()

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.newTabsAtTop.isOn(environment: environment, defaults: defaults)
	}
}
