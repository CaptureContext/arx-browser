import AppFeature
import AppRelocationClient
import Darwin
import _Dependencies

public enum Application {
	@MainActor
	public static func run() {
		// First, while the main thread is the only one: prepareDependencies below starts
		// dispatch's worker threads, and the allocator refuses to start after that.
		BrowserApplication.prepareAllocator()

		// The move-to-Applications prompts speak the interface's language (DEV-1291); services
		// can't read AppUI's catalog, so the app hands them their text.
		prepareDependencies {
			$0.appRelocation = .live(texts: .localized)
		}
		guard AppRelocationLauncher.relocateBeforeLaunch()
		else { exit(0) }

		BrowserApplication.main()
	}
}
