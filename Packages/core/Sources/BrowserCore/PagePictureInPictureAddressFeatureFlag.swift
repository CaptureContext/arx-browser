import Foundation

/// The `ARX_PAGE_PIP_ADDRESS` feature flag (DEV-1124): clicking Page PiP's address edits it in a
/// command bar over the floating window's URL bar, as the main window's does, and what's chosen
/// opens in the floating page. Off, the address only shows, with Copy.
///
/// On by default, like every feature flag (DEV-1143), and read through the `FeatureFlag`
/// registry: the environment first, then user defaults, where `0`, `false`, `no` or `off` turns
/// it off. The floating window reads it as it draws its header, and the reducer when the address
/// is clicked.
public enum PagePictureInPictureAddressFeatureFlag {
	public static let name: String = FeatureFlag.pagePictureInPictureAddress.name

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.pagePictureInPictureAddress.isOn(environment: environment, defaults: defaults)
	}
}
