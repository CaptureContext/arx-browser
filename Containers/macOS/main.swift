import AppIntents
import Application

/// The app target's App Intents metadata takes Arx's Shortcuts actions from its packages
/// (DEV-929).
struct ArxAppIntents: AppIntentsPackage {
	static var includedPackages: [any AppIntentsPackage.Type] { [ApplicationIntents.self] }
}

Application.run()
