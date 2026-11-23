import BrowserCore
import CommandBarFeature
import Foundation

extension LittleArxFeature {
	/// The launcher's open profile list (DEV-1331): what's typed into its field and the profile
	/// the arrows highlight.
	public struct ProfilePicker: Equatable, Sendable {
		public var query: String
		public var selectedID: Profile.ID?

		public init(
			query: String = "",
			selectedID: Profile.ID? = nil
		) {
			self.query = query
			self.selectedID = selectedID
		}
	}

	/// What the launcher needs to list another profile's pages (DEV-1331).
	public struct LauncherProfile: Equatable, Sendable {
		public var profileID: Profile.ID

		/// The space the page opens in: the profile's space the main window shows, else its first.
		public var spaceID: Space.ID
		public var searchEngine: SearchEngine

		/// That profile's recent history, open tabs and favorites, and nothing else.
		public var suggestions: [CommandBarFeature.Entry]

		public init(
			profileID: Profile.ID,
			spaceID: Space.ID,
			searchEngine: SearchEngine,
			suggestions: [CommandBarFeature.Entry]
		) {
			self.profileID = profileID
			self.spaceID = spaceID
			self.searchEngine = searchEngine
			self.suggestions = suggestions
		}
	}
}

extension LittleArxFeature.State {
	/// Whether the launcher's bar shows its profile picker (DEV-1331): an open bar in a launcher
	/// that hasn't opened a page, with more than one profile to choose from. Never in a private
	/// Little Arx, whose profile is its own (DEV-1323), nor over Peek.
	public var offersProfilePicker: Bool {
		isCommandOnly
		&& !isPrivate
		&& peekID == nil
		&& !isClosing
		&& commandBar.isPresented
		&& launcherProfileIDs.count > 1
		&& launcherProfileIDs.contains(tab.profileID)
	}
}

extension LittleArxFeature.State {
	/// The key that opens and closes the launcher's profile list (DEV-1331), as the bar's keys
	/// name it. A command bound to it keeps it, as with the bar's result actions, and the picker
	/// then shows no key.
	public static let profilePickerShortcut: String = "⌘I"

	public var profilePickerKey: String? {
		commandBar.reservedShortcuts.contains(Self.profilePickerShortcut) ? nil : Self.profilePickerShortcut
	}
}
