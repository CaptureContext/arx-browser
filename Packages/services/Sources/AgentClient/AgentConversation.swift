import BrowserCore
import Foundation

/// A chat in one profile. Saved only in that profile's folder, until the person deletes it.
public struct AgentConversation: Identifiable, Equatable, Codable, Sendable {
	public typealias ID = BrowserID<Self>

	public var id: ID
	public var profileID: Profile.ID
	public var provider: AgentProvider
	public var modelID: String?
	public var title: String
	public var createdAt: Date
	public var updatedAt: Date

	/// The provider's handle, set once the first turn has started.
	public var resumeToken: String?

	/// Set when the chat starts, from the profile's ``AgentProfileSettings/retention``.
	/// Only persistent chats are saved.
	public var retention: AgentRetention

	/// When a person archived a kept chat. Archived chats leave Your Chats' main list.
	public var archivedAt: Date?

	public var messages: [AgentMessage]

	public init(
		id: ID,
		profileID: Profile.ID,
		provider: AgentProvider,
		modelID: String? = nil,
		title: String,
		createdAt: Date,
		updatedAt: Date,
		resumeToken: String? = nil,
		retention: AgentRetention = .ephemeral,
		archivedAt: Date? = nil,
		messages: [AgentMessage] = []
	) {
		self.id = id
		self.profileID = profileID
		self.provider = provider
		self.modelID = modelID
		self.title = title
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.resumeToken = resumeToken
		self.retention = retention
		self.archivedAt = archivedAt
		self.messages = messages
	}
}

extension AgentConversation {
	/// When an ephemeral chat disappears; `nil` for a persistent one.
	public var expiresAt: Date? {
		guard retention == .ephemeral
		else { return nil }

		return updatedAt.addingTimeInterval(AgentRetention.ephemeralLifetime)
	}

	public func isExpired(at now: Date) -> Bool {
		expiresAt.map { now >= $0 } ?? false
	}
}

public struct AgentMessage: Identifiable, Equatable, Codable, Sendable {
	public var id: UUID
	public var role: Role
	public var text: String
	public var attachments: [AgentContextAttachment]
	public var tools: [AgentToolActivity]
	public var createdAt: Date

	public init(
		id: UUID,
		role: Role,
		text: String,
		attachments: [AgentContextAttachment] = [],
		tools: [AgentToolActivity] = [],
		createdAt: Date
	) {
		self.id = id
		self.role = role
		self.text = text
		self.attachments = attachments
		self.tools = tools
		self.createdAt = createdAt
	}

	public enum Role: String, Codable, Sendable {
		case user
		case assistant
	}
}
