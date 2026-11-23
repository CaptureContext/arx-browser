import Foundation

/// The `ARX_WINDOW_UNDO` feature flag (DEV-1030): one ⌘Z per window. Each window keeps steps that
/// take back only what they changed (`OrganizationUndo`), so a change made since in another
/// window, by an agent or by ⇧⌘T stays. Moves between spaces and windows, a deleted space for
/// `OrganizationUndo.deletedSpaceGracePeriod`, closed tabs and agents' changes are steps, and a
/// focused page field or editor gets ⌘Z first.
///
/// Off, Undo Organization Change restores the window's own last edit whole, a change from outside
/// the window clears its history, and Move to Window is undone only from the window the tabs left,
/// as before.
///
/// On by default, like every feature flag (DEV-1143), and read through the `FeatureFlag`
/// registry. Arx reads it once, at launch (`atLaunch`).
public enum WindowUndoFeatureFlag {
	public static let name: String = FeatureFlag.windowUndo.name

	/// The value Arx launched with, read once, so every window keeps the same rules.
	public static let atLaunch: Bool = isOn()

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.windowUndo.isOn(environment: environment, defaults: defaults)
	}
}
