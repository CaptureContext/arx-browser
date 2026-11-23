import Foundation

/// The `ARX_EXTENSION_UPDATE_REVIEW` feature flag (DEV-1210). The automatic store update check
/// (every five hours) turns down an update that asks for more permissions without asking. With
/// the flag on, it remembers that update per profile and extension, and the Extensions sheet's
/// row, the Settings Extensions entry and the site menu's extension tile say "Update needs
/// review" and open its review. Declining keeps the installed version until a newer one turns
/// up. Off, such an update waits silently for Check for Updates, as before.
///
/// On by default, like every feature flag (DEV-1143), and read through the `FeatureFlag`
/// registry: the environment first, then user defaults, where `0`, `false`, `no` or `off` turns
/// it off. Read at launch.
public enum ExtensionUpdateReviewFeatureFlag {
	public static let name: String = FeatureFlag.extensionUpdateReview.name

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.extensionUpdateReview.isOn(environment: environment, defaults: defaults)
	}
}
