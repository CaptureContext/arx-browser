import Foundation

/// A single accessibility-style activation of an inspected element. The trusted
/// scope and page are supplied separately; neither is inferred from page focus.
public struct ChromiumReferenceClickRequest: Equatable, Sendable {
	public let operationID: UUID
	public let snapshot: ChromiumInspectionSnapshot
	public let reference: String
	public let timeoutMilliseconds: Int

	public init(
		operationID: UUID,
		snapshot: ChromiumInspectionSnapshot,
		reference: String,
		timeoutMilliseconds: Int = 2_000
	) {
		self.operationID = operationID
		self.snapshot = snapshot
		self.reference = reference
		self.timeoutMilliseconds = timeoutMilliseconds
	}
}

/// Dispatch is distinct from a website accepting the click or completing a
/// resulting navigation. Cancellation cannot undo events already dispatched.
public enum ChromiumReferenceClickDisposition: Equatable, Sendable {
	case notDispatched
	case dispatched
	case possiblyDispatched
}

public enum ChromiumReferenceClickFailure: Error, Equatable, Sendable {
	case unavailable
	case notReady
	case unsupportedDocument
	case staleReference
	case notInteractable
	case notAuthorized
	case busy
	case limitExceeded
	case duplicateOperation
	case cancelled
	case timedOut
	case invalidResponse
}

/// A bounded receipt for one operation. A duplicate returns the recorded
/// disposition, or uncertainty, without dispatching another event sequence.
public struct ChromiumReferenceClickResult: Equatable, Sendable {
	public let operationID: UUID
	public let disposition: ChromiumReferenceClickDisposition
	public let failure: ChromiumReferenceClickFailure?

	public init(
		operationID: UUID,
		disposition: ChromiumReferenceClickDisposition,
		failure: ChromiumReferenceClickFailure? = nil
	) {
		self.operationID = operationID
		self.disposition = disposition
		self.failure = failure
	}
}
