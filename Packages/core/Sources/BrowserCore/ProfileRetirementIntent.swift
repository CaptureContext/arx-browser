import Foundation

/// Root-local consent. The original journal revision is immutable across retries.
public struct ProfileRetirementIntent: Identifiable, Equatable, Codable, Sendable {
	public let profileID: Profile.ID
	public let profileName: String
	public let requestID: UUID
	public let expectedRevision: UInt64
	public var attemptRevision: UInt64
	public var acknowledged: Bool

	public init(
		profileID: Profile.ID,
		profileName: String,
		requestID: UUID,
		expectedRevision: UInt64,
		attemptRevision: UInt64? = nil,
		acknowledged: Bool = false
	) {
		self.profileID = profileID
		self.profileName = profileName
		self.requestID = requestID
		self.expectedRevision = expectedRevision
		self.attemptRevision = attemptRevision ?? expectedRevision
		self.acknowledged = acknowledged
	}

	public var id: Profile.ID { profileID }
}
