import Foundation

/// The `ARX_TRANSLUCENT_CHROME` feature flag (DEV-1286), on by default, and how see-through the
/// browser window's chrome is:, the tint's intensity sets it, so a pale theme lets the
/// desktop through the sidebar and the window around the page, and a strong one is close to
/// solid. The page itself is never see-through.
public enum TranslucentChrome {
	public static let featureFlag: String = FeatureFlag.translucentChrome.name

	/// The opacity at intensity 0: never clearer, so text stays readable over any desktop.
	public static let minimumOpacity: Double = 0.7

	/// The intensity from which the chrome is solid.
	public static let solidIntensity: Double = 0.6

	/// Read through `FeatureFlag`: `0`, `false`, `no` or `off` turns it off; anything else, or
	/// nothing, leaves it on.
	public static func isEnabled(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.translucentChrome.isOn(environment: environment, defaults: defaults)
	}

	/// The flag as this launch read it. A window is made see-through or not when it opens, so its
	/// chrome reads the same value, and a change in Settings waits for a relaunch.
	public static let isEnabledForThisLaunch: Bool = isEnabled()

	/// The chrome's opacity: from `minimumOpacity` at intensity 0 up to solid at
	/// `solidIntensity` and past it. Solid with the feature flag off, and with Reduce
	/// Transparency or Increase Contrast on.
	public static func opacity(
		intensity: Double,
		isEnabled: Bool,
		reduceTransparency: Bool,
		increaseContrast: Bool
	) -> Double {
		guard
			isEnabled,
			!reduceTransparency,
			!increaseContrast,
			intensity.isFinite
		else { return 1 }

		let progress = min(max(intensity / solidIntensity, 0), 1)
		return minimumOpacity + (1 - minimumOpacity) * progress
	}
}
