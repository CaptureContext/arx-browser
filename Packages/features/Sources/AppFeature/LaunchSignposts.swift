import os

/// Launch milestones as signpost events (subsystem `dev.capturecontext.arx`, category `Launch`),
/// read by `make benchmark` and visible in Instruments. The engine emits the third,
/// `FirstPagePainted`, when the first page paints something (DEV-939).
internal enum LaunchSignposts {
	private static let signposter: OSSignposter = .init(subsystem: "dev.capturecontext.arx", category: "Launch")

	@MainActor
	private static var windowWasShown: Bool = false

	/// The app's own code starts running, after dyld and before the engine loads.
	internal static func processStarted() {
		signposter.emitEvent("ProcessStart")
	}

	/// The main browser window was ordered on screen for the first time.
	@MainActor
	internal static func windowShown() {
		guard !windowWasShown else { return }
		windowWasShown = true
		signposter.emitEvent("WindowShown")
	}
}
