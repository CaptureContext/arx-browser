import Foundation

/// The `ARX_ONBOARDING_ICLOUD` feature flag (DEV-1215). With it on and iCloud sync available, a
/// first launch keeps its Default profile on this Mac and onboarding shows "Sync with iCloud"
/// after the welcome page: it adopts the workspace other Macs synced, or lets Default start
/// iCloud. Off, onboarding starts in Default as before and sync waits for Settings.
///
/// On by default, like every feature flag (DEV-1143), and read through the `FeatureFlag`
/// registry: the environment first, then user defaults, where `0`, `false`, `no` or `off` turns
/// it off. Read at launch.
public enum OnboardingICloudFeatureFlag {
	public static let name: String = FeatureFlag.onboardingICloud.name

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.onboardingICloud.isOn(environment: environment, defaults: defaults)
	}
}
