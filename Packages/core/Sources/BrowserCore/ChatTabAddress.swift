import Foundation

/// The address of a chat tab (DEV-761): `arx://chat/<conversation>`, or `arx://chat` for a new
/// chat. A chat tab is an ordinary tab, so it's saved, restored, moved and split like any
/// other, but it shows the profile's chat instead of a page and never reaches the engine.
public struct ChatTabAddress: Equatable, Hashable, Sendable {
	public static let scheme: String = "arx"
	public static let host: String = "chat"

	/// The chat the tab shows, or `nil` for a new chat.
	public var conversationID: UUID?

	public init(conversationID: UUID?) {
		self.conversationID = conversationID
	}

	public init?(url: URL) {
		guard
			url.scheme?.lowercased() == Self.scheme,
			url.host()?.lowercased() == Self.host
		else { return nil }

		let path: String = url.path().trimmingCharacters(in: .init(charactersIn: "/"))
		self.conversationID = path.isEmpty ? nil : UUID(uuidString: path)
	}

	public var url: URL {
		var components = URLComponents()
		components.scheme = Self.scheme
		components.host = Self.host
		if let conversationID {
			components.path = "/" + conversationID.uuidString.lowercased()
		}

		// Built only from a fixed scheme, host and a UUID, so it's always a valid URL.
		return components.url ?? URL(fileURLWithPath: "/")
	}
}

extension Tab {
	/// The chat this tab shows, when it's a chat tab.
	public var chatAddress: ChatTabAddress? {
		ChatTabAddress(url: restoration.url)
	}

	public var isChat: Bool {
		chatAddress != nil
	}
}
