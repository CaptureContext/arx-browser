import AppKit
import AppRelocationClient
import _Dependencies

/// Offers Move to Applications… in the Arx menu after the move at launch failed.
///
/// The launcher in `Sources/Application` sets `isOffered` before the browser starts;
/// `BrowserCommands` reads it whenever it builds the menu, so a rebuilt menu keeps the item.
@MainActor
public enum RelocationRetry {
	public static var isOffered: Bool = false

	/// Tries the move again without asking first, since choosing the item is the answer.
	internal static func retry() {
		@Dependency(\.appRelocation)
		var relocation

		switch relocation.relocate(askFirst: false) {
		case .moved, .activatedRunningCopy:
			// The relaunch waits for this process to exit before it opens the new copy.
			NSApplication.shared.terminate(nil)

		case .failed, .notNeeded, .declined:
			break
		}
	}
}
