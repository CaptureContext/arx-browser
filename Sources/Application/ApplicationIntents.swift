import AppFeature
import AppIntents

/// Arx's Shortcuts actions, which AppFeature defines, for the app target's App Intents
/// metadata (DEV-929). The container's `ArxAppIntents` includes this package.
public struct ApplicationIntents: AppIntentsPackage {
	public static var includedPackages: [any AppIntentsPackage.Type] { [AppFeatureIntents.self] }
}
