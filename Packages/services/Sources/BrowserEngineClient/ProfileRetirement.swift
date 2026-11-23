import BrowserCore
import Foundation

/// Explicit consent for one permanent ordinary profile. No caller-provided path.
public struct ProfileRetirementRequest: Equatable, Sendable {
	public let profileID: Profile.ID
	public let requestID: UUID
	public let expectedRevision: UInt64

	public init(
		profileID: Profile.ID,
		requestID: UUID,
		expectedRevision: UInt64
	) {
		self.profileID = profileID
		self.requestID = requestID
		self.expectedRevision = expectedRevision
	}
}

public struct ProfileRetirementRecord: Equatable, Sendable {
	public enum State: Equatable, Sendable {
		case active
		case awaitingStartup
		case quarantinePending
		case restartRequired
		case verificationPending
		case erased
		case blocked
	}

	public let profileID: Profile.ID
	public let requestID: UUID?
	public let state: State

	public init(
		profileID: Profile.ID,
		requestID: UUID?,
		state: State
	) {
		self.profileID = profileID
		self.requestID = requestID
		self.state = state
	}
}

public struct ProfileRetirementSnapshot: Equatable, Sendable {
	public let revision: UInt64
	public let isDurable: Bool
	public let records: [ProfileRetirementRecord]

	public init(
		revision: UInt64,
		isDurable: Bool,
		records: [ProfileRetirementRecord]
	) {
		self.revision = revision
		self.isDurable = isDurable
		self.records = records
	}

	/// Acknowledges only durable retirement; the record's state describes cleanup.
	/// A blocked cleanup still carries an irrevocable same-request tombstone.
	/// Failed queue persistence is not durable and a rejected request stays active.
	public func acknowledges(_ request: ProfileRetirementRequest) -> Bool {
		let isRecorded: Bool = records.contains {
			$0.profileID == request.profileID
			&& $0.requestID == request.requestID
			&& $0.state != .active
		}
		return isDurable
		&& revision > request.expectedRevision
		&& isRecorded
	}
}

public enum ProfileRetirementFailure: Error, Equatable, Sendable {
	case unavailable
	case busy
	case stale
	case invalid
	case corrupt
	case ownershipChanged
	case limit
	case io
}
