import AgentClient
import Foundation

/// A place the profile's chats show (DEV-761). Each keeps its own chat, screen and composer,
/// while the chats, turns and defaults stay the profile's, in one ``ChatFeature``.
public enum ChatSurfaceID: Hashable, Sendable {
	/// A store with no placement, such as in tests and previews.
	case standalone

	/// A window's panel on a tab with no chat pinned to it: the window's global chat.
	case window(UUID)

	/// A window's panel on a tab a chat is pinned to, keyed by the tab.
	case pinned(UUID)

	/// A chat tab, keyed by the tab.
	case tab(UUID)
}

/// What one surface shows: its chat, its screen and its composer.
public struct ChatSurface: Equatable, Sendable {
	/// The chat it shows. `nil` is a new, empty chat.
	public var selectedID: AgentConversation.ID?
	public var screen: ChatFeature.Screen

	/// The composer's text and the context attached to it with the + picker.
	public var draft: String
	public var attachments: [AgentContextAttachment]

	/// Why the last file, image or capture didn't join the message (DEV-798).
	public var attachmentIssue: ChatAttachmentIssue?

	/// The provider and model a new chat starts with, from Settings until changed.
	public var newChatProvider: AgentProvider
	public var newChatModelID: String?

	public var chatsQuery: String
	public var showsUnreadOnly: Bool
	public var showsArchived: Bool

	/// Raised to move focus into the composer.
	public var focusRequest: Int

	public init(
		selectedID: AgentConversation.ID? = nil,
		screen: ChatFeature.Screen = .conversation,
		draft: String = "",
		attachments: [AgentContextAttachment] = [],
		newChatProvider: AgentProvider,
		newChatModelID: String? = nil
	) {
		self.selectedID = selectedID
		self.screen = screen
		self.draft = draft
		self.attachments = attachments
		self.attachmentIssue = nil
		self.newChatProvider = newChatProvider
		self.newChatModelID = newChatModelID
		self.chatsQuery = ""
		self.showsUnreadOnly = false
		self.showsArchived = false
		self.focusRequest = 0
	}
}
