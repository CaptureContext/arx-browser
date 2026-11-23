import Foundation

/// The `ARX_INDEPENDENT_WINDOWS` feature flag (DEV-822): each browser window keeps its own open
/// tabs, while spaces, Favorites and pinned tabs stay shared. On by default, as every beta flag
/// (DEV-1143); `0`, `false`, `no` or `off` brings back windows that share every open tab.
public enum IndependentWindowsFeatureFlag {
	public static let name: String = FeatureFlag.independentWindows.name

	/// Read through `FeatureFlag`: the environment first, then user defaults.
	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.independentWindows.isOn(environment: environment, defaults: defaults)
	}
}
