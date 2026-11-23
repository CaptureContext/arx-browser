import WorkspaceDatabase

/// A toggle of Settings › iCloud Sync (ADR 0001, decision 3, DEV-982). Each is a per-Mac choice: it
/// stays on this Mac and never syncs, and each is kept with what it decides about. A category's is in
/// ``SyncSettings``; a Preferences group's is its override row in the preferences file, which the
/// store's saves read under its locks. A profile's own "Sync with iCloud" (DEV-981) is a third kind,
/// in that profile's settings: it moves the profile's rows to the local organization file.
public enum SyncToggle: Hashable, Sendable {
	/// A whole ``SyncCategory``, with its own engine and zone.
	case category(SyncCategory)

	/// A part of the Preferences category. Kept on this Mac, its values are this Mac's own, and other
	/// Macs' changes to it still arrive but don't show until it syncs again.
	case preferenceGroup(PreferenceGroup)
}
