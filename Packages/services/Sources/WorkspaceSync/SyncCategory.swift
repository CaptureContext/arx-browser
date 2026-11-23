import Foundation

/// A kind of data the person turns iCloud sync on or off for (ADR 0001, section 3). Each category is
/// its own database, `SyncEngine` and record zone, so one can be paused, reviewed or deleted from
/// iCloud without touching another.
///
/// Within Preferences, a ``SyncToggle`` per group keeps part of it on this Mac (decision 3, DEV-982),
/// and a profile can be "this Mac only" (decision 2, DEV-981). Tabs from other devices isn't a
/// category yet.
public enum SyncCategory: String, CaseIterable, Codable, Hashable, Sendable {
	/// Profiles, spaces, folders, pinned tabs and Favorites: `arx-organization.sqlite`.
	case organization

	/// Appearance, links, Little Arx, routing, the command bar, search shortcuts, keyboard shortcuts,
	/// routing rules and Proxy Link rules: `arx-preferences.sqlite`.
	case preferences

	/// Pages visited in the sync window and clears of history: `arx-history.sqlite` (decision 5,
	/// DEV-984). Off by default.
	case history

	/// Tab Archive's entries: `arx-archive.sqlite` (decision 4, DEV-983). Off by default: archives stay
	/// on each Mac until the person turns it on.
	case archive

	/// The record zone in the private database that holds the category's records.
	public var zoneName: String { rawValue }

	/// Whether turning the category off is a leave (DEV-1148): this Mac stops counting among the Macs
	/// that must all delete something in it, and turning it on again merges this Mac's rows with
	/// iCloud's. The categories whose deletions sync by those rules leave: Profiles and spaces, and
	/// Tab Archive. Preferences and History still pause until their own rejoins are built (DEV-1165,
	/// DEV-1166).
	public var leavesWhenTurnedOff: Bool {
		switch self {
		case .organization, .archive: true
		case .preferences, .history: false
		}
	}

	/// Whether the category syncs once sync is on, until the person turns it off. History waits for
	/// the person to turn it on (the 4 November resolution), and so does Tab Archive (decision 4).
	public var isOnByDefault: Bool {
		switch self {
		case .organization, .preferences: true
		case .history, .archive: false
		}
	}
}
