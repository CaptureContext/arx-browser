import Foundation

public enum ChromiumReferenceScrollAxis: Equatable, Sendable {
	case horizontal
	case vertical
}

/// Scrolls the nearest native user-scrollable container of this explicit
/// reference on one physical axis. It never chains residual movement to an
/// outer container or consults the focused element. Deltas are CSS pixels.
public struct ChromiumReferenceScrollRequest: Equatable, Sendable {
	public let operationID: UUID
	public let snapshot: ChromiumInspectionSnapshot
	public let reference: String
	public let axis: ChromiumReferenceScrollAxis
	public let deltaCSSPixels: Double
	public let timeoutMilliseconds: Int

	public init(
		operationID: UUID,
		snapshot: ChromiumInspectionSnapshot,
		reference: String,
		axis: ChromiumReferenceScrollAxis,
		deltaCSSPixels: Double,
		timeoutMilliseconds: Int = 2_000
	) {
		self.operationID = operationID
		self.snapshot = snapshot
		self.reference = reference
		self.axis = axis
		self.deltaCSSPixels = deltaCSSPixels
		self.timeoutMilliseconds = timeoutMilliseconds
	}
}

/// A dispatched receipt acknowledges a bounded, instant native offset request,
/// not wheel input, snap completion, lazy loading, or website success. Unchanged
/// means authority passed and native clamping required no setter invocation.
public enum ChromiumReferenceScrollDisposition: Equatable, Sendable {
	case notDispatched
	case dispatched
	case possiblyDispatched
	case unchanged
}

public enum ChromiumReferenceScrollFailure: Error, Equatable, Sendable {
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
	case noScrollableContainer
	case invalidDelta
}

/// Clicks, forms, and scrolls share the same lifetime receipts and physical
/// admission limits. Cancellation cannot undo an already-issued scroll.
public struct ChromiumReferenceScrollResult: Equatable, Sendable {
	public let operationID: UUID
	public let disposition: ChromiumReferenceScrollDisposition
	public let failure: ChromiumReferenceScrollFailure?

	public init(
		operationID: UUID,
		disposition: ChromiumReferenceScrollDisposition,
		failure: ChromiumReferenceScrollFailure? = nil
	) {
		self.operationID = operationID
		self.disposition = disposition
		self.failure = failure
	}
}
