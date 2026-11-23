import Foundation

/// The `ARX_PAGE_PIP_SPACES` feature flag (DEV-1184): Page PiP's header has a space picker
/// instead of the profile picker, showing the floating tab's space as its Switch to Space
/// shortcut (⌃1, ⌃2…) with the space's name on hover. Choosing a space there, or pressing ⌘1–9
/// while Page PiP is the key window, moves the tab to that space. Moving a tab to a space of
/// another profile asks first, from Page PiP, from Little Arx's "Open in" and from a window's
/// sidebar, and says plainly that the page reloads in that profile and its sign-ins don't carry
/// over. Off, Page PiP keeps its profile picker and the questions keep their old words.
///
/// On by default, like every feature flag (DEV-1143), and read through the `FeatureFlag`
/// registry: the environment first, then user defaults, where `0`, `false`, `no` or `off` turns
/// it off. Windows read it as they draw, and the reducers as a move is asked for.
public enum PagePictureInPictureSpacesFeatureFlag {
	public static let name: String = FeatureFlag.pagePictureInPictureSpaces.name

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.pagePictureInPictureSpaces.isOn(environment: environment, defaults: defaults)
	}
}
