import AgentClient
import Foundation

/// Where a chat view shows and what it may do about it (DEV-761). The app fills in the actions
/// its window and tab allow; a missing one hides its menu item.
public struct ChatPlacement {
	public enum Kind: Equatable, Sendable {
		/// A window's panel showing its global chat.
		case panel

		/// A window's panel on a tab the chat is pinned to.
		case pinned

		/// A chat tab, full pane width.
		case tab
	}

	public var kind: Kind

	/// Pin to This Tab: ties the shown chat to the window's current tab.
	public var pinToTab: (@MainActor (AgentConversation.ID) -> Void)?

	/// Unpin from This Tab, in the ⋯ menu and the header's pin button.
	public var unpin: (@MainActor () -> Void)?

	/// Open in Tab: the shown chat, or a new one, becomes a chat tab.
	public var openInTab: (@MainActor (AgentConversation.ID?) -> Void)?

	/// Move to Sidebar: a chat tab goes back to the window's panel.
	public var moveToSidebar: (@MainActor (AgentConversation.ID?) -> Void)?

	/// Capture Visible Area (`false`) or Capture Area… (`true`) in the + menu: captures the
	/// window's page and sends it to this chat (DEV-798). `nil` where there's no page to capture.
	public var capture: (@MainActor (_ area: Bool) -> Void)?

	public init(
		kind: Kind,
		pinToTab: (@MainActor (AgentConversation.ID) -> Void)? = nil,
		unpin: (@MainActor () -> Void)? = nil,
		openInTab: (@MainActor (AgentConversation.ID?) -> Void)? = nil,
		moveToSidebar: (@MainActor (AgentConversation.ID?) -> Void)? = nil,
		capture: (@MainActor (_ area: Bool) -> Void)? = nil
	) {
		self.kind = kind
		self.pinToTab = pinToTab
		self.unpin = unpin
		self.openInTab = openInTab
		self.moveToSidebar = moveToSidebar
		self.capture = capture
	}

	/// A panel with no placement actions, such as in previews.
	public static var panel: Self {
		.init(kind: .panel)
	}
}
