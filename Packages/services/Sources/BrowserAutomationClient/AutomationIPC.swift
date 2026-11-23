import BrowserCore
import Foundation

public enum AutomationIPC {
	public static let maximumRequestBytes: Int = 65_536
	public static let maximumResponseBytes: Int = 262_144

	/// Replies that carry an image: a capture or a batch with captures.
	public static let maximumImageResponseBytes: Int = 6_291_456

	/// The largest frame either side reads or writes.
	public static let maximumFrameBytes: Int = maximumImageResponseBytes
	public static let maximumConnections: Int = 32
	public static let protocolVersion: Int = 1

	public struct Envelope: Codable, Sendable {
		public var version: Int
		public var clientID: UUID
		public var credential: String
		public var sessionID: UUID
		public var epoch: UUID?
		public var payload: Payload

		public init(
			clientID: UUID,
			credential: String,
			sessionID: UUID,
			epoch: UUID? = nil,
			payload: Payload
		) {
			self.version = AutomationIPC.protocolVersion
			self.clientID = clientID
			self.credential = credential
			self.sessionID = sessionID
			self.epoch = epoch
			self.payload = payload
		}
	}

	/// The bound a reply carrying `result` must fit in.
	public static func maximumResponseBytes(for result: AutomationResult) -> Int {
		switch result {
		case .capture, .pdf: return maximumImageResponseBytes
		default: return maximumResponseBytes
		}
	}

	public enum Payload: Codable, Sendable {
		case hello
		case ping
		case request(UUID, AutomationOperation)
		case cancel(UUID)
		case disconnect

		/// The client's current grant, polled so the helper can follow changes without reconnecting.
		case grants

		/// Resolves the focused-tab alias for a client that opted into it.
		case focusedTab

		/// The granted tabs' current revisions, polled only while the client has resource subscriptions.
		case changes

		/// Waits up to `seconds` (1...20) for a request that went on waiting for the user: its
		/// result, or `waitingForUser` again (DEV-1024).
		case wait(UUID, seconds: Int)
	}

	public enum Reply: Codable, Sendable {
		case hello(UUID)
		case result(AutomationResult)
		case failure(AutomationFailure)
		case acknowledged
		case grants(AutomationGrantSummary)
		case focusedTab(AutomationFocusedTab)
		case changes(AutomationChangeDigest)

		/// The request waits for the user in Arx and stays open; `wait` collects its result.
		case waitingForUser(AutomationUserWait)
	}
}

/// What a request waits for the user to do in Arx, for the agent to tell its user (DEV-1024).
public struct AutomationUserWait: Codable, Equatable, Sendable {
	/// Approving or declining a change, or another answer only the user gives in Arx.
	public enum Kind: String, Codable, Sendable {
		case approval
		case extensionReview
	}

	public var kind: Kind

	/// One short line, as Arx's own prompt names the request.
	public var question: String

	public init(
		kind: Kind,
		question: String
	) {
		self.kind = kind
		self.question = question
	}

	/// How long a request may wait for the user before Arx ends it.
	public static let limit: Duration = .seconds(15 * 60)
}

public enum AutomationHostEvent: Sendable {
	case connected(clientID: UUID, sessionID: UUID)
	case disconnected(sessionID: UUID)
	case request(AutomationRequest)
	case inspectionReleased(AutomationRequest, AutomationInspectionResult, grantRevision: UUID)
	case clickSubmitted(UUID)
	case formSubmitted(UUID)
	case scrollSubmitted(UUID)
	case cancel(UUID)
}
