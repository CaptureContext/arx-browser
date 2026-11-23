import BrowserCore
import Foundation

public struct RoutingInbox: Equatable, Sendable {
	public var isReady: Bool
	public var requests: [RoutingRequest]

	/// A window can show the profile picker at the pointer (DEV-858). Off in headless runs,
	/// where a link that asks waits in this list instead.
	public var picksProfileAtPointer: Bool

	/// The picker on screen, for the one request whose status is `.choosingProfile`.
	public var picker: RoutingProfilePicker?

	public init(
		isReady: Bool = false,
		requests: [RoutingRequest] = [],
		picksProfileAtPointer: Bool = false,
		picker: RoutingProfilePicker? = nil
	) {
		self.isReady = isReady
		self.requests = requests
		self.picksProfileAtPointer = picksProfileAtPointer
		self.picker = picker
	}
}

public struct RoutingRequest: Equatable, Identifiable, Sendable {
	public var id: UUID
	public var url: URL
	public var currentSpaceID: Space.ID?
	public var override: RoutingDestination?
	public var matchedRuleID: UUID?
	public var status: Status
	public var expectedTarget: RoutingTarget?

	public init(
		id: UUID,
		url: URL,
		currentSpaceID: Space.ID?,
		override: RoutingDestination? = nil,
		matchedRuleID: UUID? = nil,
		status: Status = .queued,
		expectedTarget: RoutingTarget? = nil
	) {
		self.id = id
		self.url = url
		self.currentSpaceID = currentSpaceID
		self.override = override
		self.matchedRuleID = matchedRuleID
		self.status = status
		self.expectedTarget = expectedTarget
	}

	public enum Status: Equatable, Sendable {
		case queued

		/// The profile picker asks about it at the pointer; later links wait behind it.
		case choosingProfile
		case opening(RoutingTarget, BrowserCore.Tab.ID)
		case needsDestination(URLRoutingError)
		case failed(String)
	}
}
