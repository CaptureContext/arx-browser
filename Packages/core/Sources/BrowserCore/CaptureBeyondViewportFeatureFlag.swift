import Foundation

/// The `ARX_CAPTURE_BEYOND_VIEWPORT` feature flag (DEV-1208): Capture Page's frame shows the whole
/// page it took, scaled to fit the viewport, and Capture Area scrolls the page while an area is
/// drawn toward its edge, taking the area beyond the viewport in one image. Off, the frame wraps
/// the viewport and an area stops at its edge.
///
/// On by default, like every feature flag (DEV-1143), and read through the `FeatureFlag`
/// registry: the environment first, then user defaults, where `0`, `false`, `no` or `off` turns
/// it off. Arx reads it at launch.
public enum CaptureBeyondViewportFeatureFlag {
	public static let name: String = FeatureFlag.captureBeyondViewport.name

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.captureBeyondViewport.isOn(environment: environment, defaults: defaults)
	}
}
