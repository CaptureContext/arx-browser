import Foundation

/// An ordered list of operations a client asks the user to approve once.
///
/// Approval covers exactly these operations, matched by their mutation binding and in
/// order, for one connection and grant revision. Each step still runs as its own
/// request with its own operation ID, receipt and authorization, so a plan can never
/// widen scope or replay a step.
public struct AutomationBatchPlan: Codable, Equatable, Sendable {
	public static let maximumSteps: Int = 16

	/// How long an approved batch waits for its steps, from the user's approval (DEV-1072: the
	/// MCP helper asks again for the steps left once it has passed).
	public static let approvalWindow: TimeInterval = 120

	public var batchID: UUID
	public var steps: [AutomationOperation]

	public init(
		batchID: UUID,
		steps: [AutomationOperation]
	) {
		self.batchID = batchID
		self.steps = steps
	}

	public var requiredCapabilities: Set<AutomationCapability> {
		steps.reduce(into: [.read]) { $0.formUnion($1.requiredCapabilities) }
	}

	public var riskTier: AutomationRiskTier {
		steps.map(\.riskTier).max() ?? .read
	}

	public func validate() throws {
		guard (1...Self.maximumSteps).contains(steps.count)
		else { throw AutomationFailure.invalidRequest }

		var operationIDs: Set<UUID> = []
		for step in steps {
			switch step {
			case .batch, .signIn, .load, .pdf, .findInPage, .dialog, .media, .settings, .script, .logs, .passwordSignIn:
				throw AutomationFailure.invalidRequest

			case let .command(command):
				try command.validate()

			case .inventory, .capture, .inspect, .wait, .click, .form, .scroll, .data, .link:
				break
			}

			// A step that asks the user every time can't ride on a batch approval.
			if step.alwaysAsks || step.ignoresTemporaryGrant { throw AutomationFailure.invalidRequest }
			if let id = step.mutationID {
				guard operationIDs.insert(id).inserted
				else { throw AutomationFailure.invalidRequest }
			}
		}
	}
}

/// The user's answer to a batch plan.
public struct AutomationBatchApproval: Codable, Equatable, Sendable {
	public var batchID: UUID

	/// The number of mutating steps the approval covers.
	public var approvedSteps: Int

	/// When the approval lapses, from the user's answer: a client that collects it later knows
	/// how long it has left (DEV-1072). Nil when no step needed it, or from an older Arx.
	public var expiresAt: Date?

	public init(
		batchID: UUID,
		approvedSteps: Int,
		expiresAt: Date? = nil
	) {
		self.batchID = batchID
		self.approvedSteps = approvedSteps
		self.expiresAt = expiresAt
	}
}

/// A granted profile, as automation sees it.
public struct AutomationProfileItem: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var name: String

	/// The profile's own appearance override, when it has one.
	public var appearance: AppearanceOverride?

	public init(
		id: UUID,
		name: String,
		appearance: AppearanceOverride? = nil
	) {
		self.id = id
		self.name = name
		self.appearance = appearance
	}
}

/// An ordinary window showing a granted space. Tab IDs appear only for granted tabs.
public struct AutomationWindowItem: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var spaceID: UUID
	public var selectedTabID: UUID?

	/// The tabs in its panes, left to right, when Split View is open.
	public var paneTabIDs: [UUID]
	public var isFocused: Bool

	/// The main window, which keeps every open tab no other window does (DEV-1157).
	public var isMain: Bool
	public var revision: String

	public init(
		id: UUID,
		spaceID: UUID,
		selectedTabID: UUID? = nil,
		paneTabIDs: [UUID] = [],
		isFocused: Bool = false,
		isMain: Bool = false,
		revision: String
	) {
		self.id = id
		self.spaceID = spaceID
		self.selectedTabID = selectedTabID
		self.paneTabIDs = paneTabIDs
		self.isFocused = isFocused
		self.isMain = isMain
		self.revision = revision
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try values.decode(UUID.self, forKey: .id)
		self.spaceID = try values.decode(UUID.self, forKey: .spaceID)
		self.selectedTabID = try values.decodeIfPresent(UUID.self, forKey: .selectedTabID)
		self.paneTabIDs = try values.decodeIfPresent([UUID].self, forKey: .paneTabIDs) ?? []
		self.isFocused = try values.decodeIfPresent(Bool.self, forKey: .isFocused) ?? false
		self.isMain = try values.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
		self.revision = try values.decode(String.self, forKey: .revision)
	}

	private enum CodingKeys: String, CodingKey {
		case id, spaceID, selectedTabID, paneTabIDs, isFocused, isMain, revision
	}
}

/// The current inventory revision of every granted tab. The MCP helper diffs these to
/// tell subscribed clients about tab and navigation changes; ungranted tabs never appear.
public struct AutomationChangeDigest: Codable, Equatable, Sendable {
	public static let maximumTabs: Int = 1024

	public var tabs: [UUID: String]

	/// A revision of the granted downloads, present only with the downloads class.
	public var downloads: String?

	/// What the helper turns into `arx://events` (DEV-924), for the same granted tabs only.
	public var signals: [UUID: AutomationTabSignal]

	public init(
		tabs: [UUID: String] = [:],
		downloads: String? = nil,
		signals: [UUID: AutomationTabSignal] = [:]
	) {
		self.tabs = tabs
		self.downloads = downloads
		self.signals = signals
	}

	private enum CodingKeys: String, CodingKey {
		case tabs, downloads, signals
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			tabs: try values.decode([UUID: String].self, forKey: .tabs),
			downloads: try values.decodeIfPresent(String.self, forKey: .downloads),
			signals: try values.decodeIfPresent([UUID: AutomationTabSignal].self, forKey: .signals) ?? [:]
		)
	}
}

extension AutomationOperation {
	public var isBatch: Bool {
		guard case .batch = self else { return false }
		return true
	}
}
