import BrowserCore
import Foundation

/// The `ARX_ICLOUD_SYNC` feature flag (DEV-560, phase 2), on by default (DEV-1143).
///
/// Off, Arx creates no `SyncEngine` and never touches the CloudKit container: ``WorkspaceSync`` isn't
/// made, and Settings doesn't show iCloud Sync. It reads through the `FeatureFlag` registry: the
/// environment first, then user defaults. `0`, `false`, `no` or `off` turns it off.
public enum ICloudSyncFeatureFlag {
	public static let name: String = FeatureFlag.iCloudSync.name

	public static func isOn(
		environment: [String: String],
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.iCloudSync.isOn(environment: environment, defaults: defaults)
	}
}
