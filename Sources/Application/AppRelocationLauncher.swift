import AppFeature
import AppRelocationClient
import Foundation
import _Dependencies

/// Runs `AppRelocationClient` before anything else starts, since the engine locks its
/// profile folders once it's running.
@MainActor
internal enum AppRelocationLauncher {
	/// Returns `false` when this process should quit instead of starting the browser:
	/// Arx was moved and relaunches from Applications, or a copy there is already running.
	internal static func relocateBeforeLaunch() -> Bool {
		#if DEBUG
		return true
		#else
		let process: ProcessInfo = .processInfo
		guard AppRelocationClient.isEnabled(
			environment: process.environment,
			arguments: process.arguments
		) else { return true }

		@Dependency(\.appRelocation)
		var relocation

		switch relocation.relocate() {
		case .moved, .activatedRunningCopy:
			return false

		case .failed:
			// AppFeature adds Move to Applications… to the Arx menu.
			RelocationRetry.isOffered = true
			return true

		case .notNeeded, .declined:
			return true
		}
		#endif
	}
}
