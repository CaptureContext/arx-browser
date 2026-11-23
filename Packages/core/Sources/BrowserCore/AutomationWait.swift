import Foundation

/// Observes loading in one existing native generation. A primary navigation or commit
/// invalidates the wait; this is not a navigation-completion or website-success predicate.
public struct AutomationWaitRequest: Codable, Equatable, Sendable {
	public var targetID: UUID
	public var expectedRevision: String
	public var condition: Condition
	public var timeoutMilliseconds: Int

	public init(
		targetID: UUID,
		expectedRevision: String,
		condition: Condition = .loadingStopped,
		timeoutMilliseconds: Int = 2000
	) {
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.condition = condition
		self.timeoutMilliseconds = timeoutMilliseconds
	}

	public func validate() throws {
		guard
			expectedRevision.utf8.count == 64,
			expectedRevision.allSatisfy(\.isHexDigit),
			(1...10_000).contains(timeoutMilliseconds)
		else { throw AutomationFailure.invalidRequest }
	}

	public enum Condition: String, Codable, Sendable {
		case loadingStopped
	}
}

/// Entry identity captured by the app after checking the requested inventory revision.
/// The session revision is checked at entry, not on subsequent loading/title publications.
public struct PageWaitTarget: Codable, Equatable, Sendable {
	public var tabID: Tab.ID
	public var profileID: Profile.ID
	public var sessionRevision: UInt64
	public var documentRevision: UInt64

	public init(
		tabID: Tab.ID,
		profileID: Profile.ID,
		sessionRevision: UInt64,
		documentRevision: UInt64
	) {
		self.tabID = tabID
		self.profileID = profileID
		self.sessionRevision = sessionRevision
		self.documentRevision = documentRevision
	}
}

/// Trusted service identity; the native page identifier is never accepted from tool input.
public struct PageWaitSource: Codable, Equatable, Sendable {
	public var target: PageWaitTarget
	public var pageID: UInt64

	public init(
		target: PageWaitTarget,
		pageID: UInt64
	) {
		self.target = target
		self.pageID = pageID
	}
}

/// Internal observation used to derive the permitted inventory revision at match time.
public struct PageWaitObservation: Equatable, Sendable {
	public var source: PageWaitSource
	public var snapshot: BrowserSessionSnapshot

	public init(
		source: PageWaitSource,
		snapshot: BrowserSessionSnapshot
	) {
		self.source = source
		self.snapshot = snapshot
	}
}

/// Historical loading metadata only. The observed revision can differ from the entry
/// revision; obtain fresh inventory before issuing a later revision-bound command.
public struct AutomationWaitResult: Codable, Equatable, Sendable {
	public var request: AutomationWaitRequest
	public var source: PageWaitSource
	public var observedRevision: String
	public var sessionRevision: UInt64
	public var errorCode: Int?

	public init(
		request: AutomationWaitRequest,
		source: PageWaitSource,
		observedRevision: String,
		sessionRevision: UInt64,
		errorCode: Int?
	) {
		self.request = request
		self.source = source
		self.observedRevision = observedRevision
		self.sessionRevision = sessionRevision
		self.errorCode = errorCode
	}

	public var status: Status { errorCode == nil ? .stopped : .stoppedWithError }

	public func validate() throws {
		try request.validate()
		guard
			request.targetID == source.target.tabID.rawValue,
			source.pageID > 0,
			source.target.documentRevision > 0,
			sessionRevision >= source.target.sessionRevision,
			observedRevision.utf8.count == 64,
			observedRevision.allSatisfy(\.isHexDigit)
		else { throw AutomationFailure.invalidRequest }
	}

	public enum Status: String, Codable, Sendable {
		case stopped
		case stoppedWithError
	}
}
