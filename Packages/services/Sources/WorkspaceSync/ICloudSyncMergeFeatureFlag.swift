import BrowserCore
import Foundation

/// The `ARX_ICLOUD_SYNC_MERGE` feature flag (DEV-1216), on by default.
///
/// On, a Mac that turns sync on with its own workspace merges what matches iCloud's after a preview,
/// before any of its rows upload, and Settings offers to merge two synced profiles of the same name.
/// Off, the first sync copies everything, as before, and only an untouched starter profile is folded
/// into iCloud's (`WorkspaceRepair`). It reads through the `FeatureFlag` registry.
public enum ICloudSyncMergeFeatureFlag {
	public static let name: String = FeatureFlag.iCloudSyncMerge.name

	public static func isOn(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.iCloudSyncMerge.isOn(environment: environment, defaults: defaults)
	}
}
