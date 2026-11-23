import Foundation

/// Loads a permitted, saved tab in the background so its page can be read.
/// Arx never focuses the tab, selects it or changes any window's presentation.
public struct AutomationLoadRequest: Codable, Equatable, Sendable {
	public var targetID: UUID
	public var expectedRevision: String

	public init(
		targetID: UUID,
		expectedRevision: String
	) {
		self.targetID = targetID
		self.expectedRevision = expectedRevision
	}

	public func validate() throws {
		guard
			expectedRevision.utf8.count == 64,
			expectedRevision.allSatisfy(\.isHexDigit)
		else { throw AutomationFailure.invalidRequest }
	}
}

public struct AutomationLoadResult: Codable, Equatable, Sendable {
	public var targetID: UUID
	public var status: Status

	public init(
		targetID: UUID,
		status: Status
	) {
		self.targetID = targetID
		self.status = status
	}

	public enum Status: String, Codable, Sendable {
		/// The tab already had a page; nothing was loaded.
		case alreadyLoaded

		/// A background page was created and started loading the saved URL.
		case loading
	}
}
