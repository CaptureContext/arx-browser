import SwiftUI

/// What the command bar needs to show a profile picker at its bottom-left corner, the twin of
/// Actions ⌘K (DEV-1331). Only Little Arx's launcher has one: the profile its page will open in.
public struct CommandBarProfilePickerContent {
	/// The chosen profile's name, which the button shows.
	public var title: String

	/// The key that opens and closes the list, such as ⌘I; nil when a command has it.
	public var key: String?

	/// The button: opens the list, or closes it while it's open.
	public var onToggle: () -> Void

	/// The open list of profiles, as ⌘K's panel draws its actions; nil while closed.
	public var panel: CommandBarActionsContent?

	public init(
		title: String,
		key: String?,
		onToggle: @escaping () -> Void,
		panel: CommandBarActionsContent? = nil
	) {
		self.title = title
		self.key = key
		self.onToggle = onToggle
		self.panel = panel
	}
}
