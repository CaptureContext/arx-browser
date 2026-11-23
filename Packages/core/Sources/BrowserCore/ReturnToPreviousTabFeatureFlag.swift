import Foundation

/// The `ARX_RETURN_TO_PREVIOUS_TAB` feature flag (DEV-1228), on by default: closing the selected tab,
/// or resetting a selected pin or Favorite, selects the tab the window showed before it.
public enum ReturnToPreviousTabFeatureFlag {
	public static let name: String = FeatureFlag.returnToPreviousTab.name

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.returnToPreviousTab.isOn(environment: environment, defaults: defaults)
	}
}
