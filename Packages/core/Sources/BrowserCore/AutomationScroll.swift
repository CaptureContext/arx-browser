import Foundation

/// A bounded instant offset request on the nearest native user-scrollable container
/// of an explicit reference. No focused target, residual chaining or wheel input.
public struct AutomationScrollRequest: Codable, Equatable, Sendable {
	public enum Axis: String, Codable, CaseIterable, Sendable {
		case horizontal
		case vertical
	}

	public var target: AutomationClickRequest
	public var axis: Axis
	public var deltaCSSPixels: Double

	public init(
		target: AutomationClickRequest,
		axis: Axis,
		deltaCSSPixels: Double
	) {
		self.target = target
		self.axis = axis
		self.deltaCSSPixels = deltaCSSPixels == 0 ? 0 : deltaCSSPixels
	}

	public var operationID: UUID { target.operationID }
	public var canonicalDelta: Double { deltaCSSPixels == 0 ? 0 : deltaCSSPixels }

	public func validate() throws {
		try target.validate()
		guard deltaCSSPixels.isFinite, abs(deltaCSSPixels) <= 8192
		else { throw AutomationFailure.invalidDelta }
	}
}

public enum AutomationScrollDisposition: String, Codable, Equatable, Sendable {
	case notDispatched
	case dispatched
	case possiblyDispatched

	/// Authority passed and clamping required no setter. The operation ID is consumed.
	case unchanged
}

/// No offsets, page content, lazy-load completion or website-success claim.
public struct AutomationScrollResult: Codable, Equatable, Sendable {
	public var operationID: UUID
	public var disposition: AutomationScrollDisposition
	public var failure: AutomationFailure?

	public init(
		operationID: UUID,
		disposition: AutomationScrollDisposition,
		failure: AutomationFailure? = nil
	) {
		self.operationID = operationID
		self.disposition = disposition
		self.failure = failure
	}
}
