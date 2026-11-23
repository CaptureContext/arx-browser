import Foundation

/// Metadata for one expiring host handle owned by this exact MCP connection.
/// The handle confers no page-content, screenshot or generic interaction access.
public struct AutomationPresentation: Codable, Equatable, Sendable {
	public let id: UUID
	public let kind: Kind
	public let tabID: UUID
	public let profileID: UUID
	public let sourceTargetID: UUID
	public let revision: String

	public init(
		id: UUID,
		kind: Kind,
		tabID: UUID,
		profileID: UUID,
		sourceTargetID: UUID,
		revision: String
	) {
		self.id = id
		self.kind = kind
		self.tabID = tabID
		self.profileID = profileID
		self.sourceTargetID = sourceTargetID
		self.revision = revision
	}

	public enum Kind: String, Codable, Sendable {
		case peek
		case littleArx
	}
}
