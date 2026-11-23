import Foundation

/// A single attempt against a reference from this connection's latest released snapshot.
/// The reference is identity, not authority: interaction permission and approval are separate.
public struct AutomationClickRequest: Codable, Equatable, Sendable {
	public var operationID: UUID
	public var targetID: UUID
	public var expectedRevision: String
	public var snapshotID: String
	public var reference: String

	public init(
		operationID: UUID,
		targetID: UUID,
		expectedRevision: String,
		snapshotID: String,
		reference: String
	) {
		self.operationID = operationID
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.snapshotID = snapshotID
		self.reference = reference
	}

	public func validate() throws {
		guard
			expectedRevision.utf8.count == 64,
			expectedRevision.allSatisfy(\.isHexDigit),
			!snapshotID.isEmpty,
			snapshotID.utf8.count <= 128,
			!reference.isEmpty,
			reference.utf8.count <= 128
		else { throw AutomationFailure.invalidRequest }
	}
}

/// Describes dispatch only. Website success and completed navigation are never implied.
public enum AutomationClickDisposition: String, Codable, Equatable, Sendable {
	case notDispatched
	case dispatched
	case possiblyDispatched
}

/// Contains only the caller's operation identity and outcome, never page content.
/// This minimal acknowledgment can survive revocation; it grants no further authority.
public struct AutomationClickResult: Codable, Equatable, Sendable {
	public var operationID: UUID
	public var disposition: AutomationClickDisposition
	public var failure: AutomationFailure?

	public init(
		operationID: UUID,
		disposition: AutomationClickDisposition,
		failure: AutomationFailure? = nil
	) {
		self.operationID = operationID
		self.disposition = disposition
		self.failure = failure
	}
}

extension AutomationOperation {
	public var mutationID: UUID? {
		switch self {
		case let .command(command): command.operationID
		case let .click(request): request.operationID
		case let .form(request): request.operationID
		case let .scroll(request): request.operationID
		case let .dialog(request): request.operationID
		case let .media(request): request.operationID
		case let .settings(request): request.change?.operationID
		case let .script(request): request.operationID
		case let .passwordSignIn(request): request.operationID
		case .inventory, .capture, .inspect, .wait, .signIn, .batch, .data, .link, .load, .pdf, .findInPage, .logs: nil
		}
	}
}
