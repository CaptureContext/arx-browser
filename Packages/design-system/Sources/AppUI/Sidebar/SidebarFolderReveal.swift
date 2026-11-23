import BrowserCore
import Foundation

/// A collapsed folder keeps showing its selected tab beneath it, and selecting a tab
/// inside one leaves the folder collapsed (DEV-1110). On by default.
/// `ARX_COLLAPSED_FOLDER_SHOWS_SELECTION` set to `0`, `false`, `no` or `off` turns it off; then
/// selecting a tab expands its folders again and a collapsed folder hides all of its tabs.
public enum SidebarFolderReveal {
	public static let featureFlag: String = FeatureFlag.collapsedFolderShowsSelection.name

	/// Whether a collapsed folder shows its selected tab. Read once, through the `FeatureFlag`
	/// registry: the environment, then Arx's defaults under the flag's name.
	public static let isEnabled: Bool = FeatureFlag.collapsedFolderShowsSelection.isOn()

	/// The tabs to keep showing a moment after the selection moved away from them: those it no
	/// longer reveals, while the pointer is in the sidebar, where its press may be the first click
	/// of a double-click on a row below them. Nothing otherwise.
	internal static func lingering(
		after old: Set<SidebarItem.ID>,
		now new: Set<SidebarItem.ID>,
		pointerInSidebar: Bool
	) -> Set<SidebarItem.ID> {
		guard pointerInSidebar else { return [] }
		return old.subtracting(new)
	}

	/// What one value turns it to.
	internal static func isOn(read: (String) -> String?) -> Bool {
		read(featureFlag).flatMap(FeatureFlag.parse) ?? FeatureFlag.collapsedFolderShowsSelection.isOnByDefault
	}
}
