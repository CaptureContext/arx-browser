import Foundation

/// The `ARX_PIN_RESET_SHAKE` feature flag (DEV-1225), on by default: a reset pin's sidebar row
/// shakes briefly, or highlights with Reduce Motion on.
public enum PinResetShakeFeatureFlag {
	public static let name: String = FeatureFlag.pinResetShake.name

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.pinResetShake.isOn(environment: environment, defaults: defaults)
	}
}
