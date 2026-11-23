import Foundation

/// A historical semantic read of an existing page. It never loads or focuses a tab.
public struct AutomationInspectionRequest: Codable, Equatable, Sendable {
	public var targetID: UUID
	public var expectedRevision: String
	public var maximumNodes: Int
	public var maximumTextBytes: Int

	/// A child frame from a node's `frame`; nil reads the main frame.
	public var frameID: String?

	/// The first projected node to return. Windows of one DOM version concatenate.
	public var windowStart: Int

	/// Values of eligible form controls; password ancestry stays omitted.
	public var includesFormValues: Bool

	/// Element bounds in viewport points, for region captures.
	public var includesBounds: Bool

	/// A document projects at most this many nodes across all windows.
	public static let maximumTreeNodes: Int = 16_384

	public init(
		targetID: UUID,
		expectedRevision: String,
		maximumNodes: Int = 256,
		maximumTextBytes: Int = 32_768,
		frameID: String? = nil,
		windowStart: Int = 0,
		includesFormValues: Bool = false,
		includesBounds: Bool = false
	) {
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.maximumNodes = maximumNodes
		self.maximumTextBytes = maximumTextBytes
		self.frameID = frameID
		self.windowStart = windowStart
		self.includesFormValues = includesFormValues
		self.includesBounds = includesBounds
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.targetID = try container.decode(UUID.self, forKey: .targetID)
		self.expectedRevision = try container.decode(String.self, forKey: .expectedRevision)
		self.maximumNodes = try container.decode(Int.self, forKey: .maximumNodes)
		self.maximumTextBytes = try container.decode(Int.self, forKey: .maximumTextBytes)
		self.frameID = try container.decodeIfPresent(String.self, forKey: .frameID)
		self.windowStart = try container.decodeIfPresent(Int.self, forKey: .windowStart) ?? 0
		self.includesFormValues = try container.decodeIfPresent(Bool.self, forKey: .includesFormValues) ?? false
		self.includesBounds = try container.decodeIfPresent(Bool.self, forKey: .includesBounds) ?? false
	}

	/// Whether this is the original whole-document main-frame read.
	public var isPlain: Bool { frameID == nil && windowStart == 0 && !includesFormValues && !includesBounds }

	public func validate() throws {
		let hasValidFrame = frameID.map { $0.utf8.count == 32 && $0.allSatisfy(\.isHexDigit) } ?? true
		guard
			expectedRevision.utf8.count == 64,
			expectedRevision.allSatisfy(\.isHexDigit),
			(1...512).contains(maximumNodes),
			(1...65_536).contains(maximumTextBytes),
			(0..<Self.maximumTreeNodes).contains(windowStart),
			hasValidFrame
		else { throw AutomationFailure.invalidRequest }
	}
}

/// Trusted identity captured by the app, never supplied by an MCP client.
public struct PageInspectionSource: Codable, Equatable, Sendable {
	public var tabID: Tab.ID
	public var profileID: Profile.ID
	public var sessionRevision: UInt64
	public var documentRevision: UInt64
	public var scopeID: UUID

	public init(
		tabID: Tab.ID,
		profileID: Profile.ID,
		sessionRevision: UInt64,
		documentRevision: UInt64,
		scopeID: UUID
	) {
		self.tabID = tabID
		self.profileID = profileID
		self.sessionRevision = sessionRevision
		self.documentRevision = documentRevision
		self.scopeID = scopeID
	}
}

public struct PageInspectionNode: Codable, Equatable, Sendable {
	public var index: Int
	public var parent: Int?
	public var role: String
	public var name: String?
	public var text: String?
	public var reference: String?

	/// An eligible control's value, only when form values were requested.
	public var value: String?

	/// A checkbox or radio button's state, only when form values were requested.
	public var checked: Bool?

	/// Viewport points of the main frame, only when bounds were requested.
	public var bounds: PageCaptureRegion?

	/// The child frame an iframe shows, readable with `frameID`.
	public var frame: String?

	public init(
		index: Int,
		parent: Int? = nil,
		role: String,
		name: String? = nil,
		text: String? = nil,
		reference: String? = nil,
		value: String? = nil,
		checked: Bool? = nil,
		bounds: PageCaptureRegion? = nil,
		frame: String? = nil
	) {
		self.index = index
		self.parent = parent
		self.role = role
		self.name = name
		self.text = text
		self.reference = reference
		self.value = value
		self.checked = checked
		self.bounds = bounds
		self.frame = frame
	}
}

/// Coverage policy, not an indication that omitted content exists in this page.
public enum PageInspectionOmission: String, Codable, CaseIterable, Hashable, Sendable {
	case subframes
	case crossOriginFrames
	case fencedFrames
	case canvasPixels
	case generatedText
	case computedNames
	case formValues
	case passwordSubtrees
}

/// Renderer-produced historical data at `domVersion`, not proof of the current DOM.
/// References carry identity only and cannot by themselves authorize any subsequent action.
public struct PageInspectionSnapshot: Codable, Equatable, Sendable {
	public var snapshotID: String
	public var documentID: String
	public var frameID: String
	public var domVersion: String
	public var nodes: [PageInspectionNode]
	public var omissions: [PageInspectionOmission]

	/// The index of the first node in `nodes`.
	public var windowStart: Int

	/// Every node the document projects, across all windows.
	public var totalNodes: Int

	public init(
		snapshotID: String,
		documentID: String,
		frameID: String,
		domVersion: String,
		nodes: [PageInspectionNode],
		omissions: [PageInspectionOmission],
		windowStart: Int = 0,
		totalNodes: Int? = nil
	) {
		self.snapshotID = snapshotID
		self.documentID = documentID
		self.frameID = frameID
		self.domVersion = domVersion
		self.nodes = nodes
		self.omissions = omissions
		self.windowStart = windowStart
		self.totalNodes = totalNodes ?? windowStart + nodes.count
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let nodes = try container.decode([PageInspectionNode].self, forKey: .nodes)
		let windowStart = try container.decodeIfPresent(Int.self, forKey: .windowStart) ?? 0
		self.init(
			snapshotID: try container.decode(String.self, forKey: .snapshotID),
			documentID: try container.decode(String.self, forKey: .documentID),
			frameID: try container.decode(String.self, forKey: .frameID),
			domVersion: try container.decode(String.self, forKey: .domVersion),
			nodes: nodes,
			omissions: try container.decode([PageInspectionOmission].self, forKey: .omissions),
			windowStart: windowStart,
			totalNodes: try container.decodeIfPresent(Int.self, forKey: .totalNodes)
		)
	}

	public func validate(for request: AutomationInspectionRequest) throws {
		try request.validate()
		guard nodes.count <= request.maximumNodes
		else { throw AutomationFailure.limitExceeded }
		var coverage = Set(PageInspectionOmission.allCases)
		if request.includesFormValues { coverage.remove(.formValues) }
		guard
			[snapshotID, documentID, frameID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
			UInt64(domVersion).map(String.init) == domVersion,
			Set(omissions) == coverage,
			omissions.count == coverage.count,
			windowStart == request.windowStart,
			totalNodes >= windowStart + nodes.count,
			totalNodes <= AutomationInspectionRequest.maximumTreeNodes,
			request.frameID.map({ $0 == frameID }) ?? true
		else { throw AutomationFailure.invalidRequest }

		var indices: Set<Int> = []
		var references: Set<String> = []
		var textBytes = 0
		for (offset, node) in nodes.enumerated() {
			let index = windowStart + offset

			// A parent from an earlier window is never in this one.
			let hasKnownParent = node.parent.map { indices.contains($0) || $0 < windowStart } ?? true
			guard
				node.index == index,
				hasKnownParent,
				!node.role.isEmpty,
				node.role.utf8.count <= 128,
				request.includesFormValues || (node.value == nil && node.checked == nil),
				request.includesBounds || node.bounds == nil,
				node.frame.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true
			else { throw AutomationFailure.invalidRequest }
			indices.insert(node.index)

			for value in [node.name, node.text, node.value].compactMap({ $0 }) {
				guard
					value.utf8.count <= 4096,
					value.utf8.count <= request.maximumTextBytes - textBytes
				else { throw AutomationFailure.limitExceeded }
				textBytes += value.utf8.count
			}

			if let reference = node.reference {
				guard
					!reference.isEmpty,
					reference.utf8.count <= 128,
					references.insert(reference).inserted
				else { throw AutomationFailure.invalidRequest }
				guard references.count <= 256
				else { throw AutomationFailure.limitExceeded }
			}
		}
	}
}

public struct AutomationInspectionResult: Codable, Equatable, Sendable {
	public var request: AutomationInspectionRequest
	public var source: PageInspectionSource
	public var snapshot: PageInspectionSnapshot

	public init(
		request: AutomationInspectionRequest,
		source: PageInspectionSource,
		snapshot: PageInspectionSnapshot
	) {
		self.request = request
		self.source = source
		self.snapshot = snapshot
	}

	public func validate() throws {
		guard
			request.targetID == source.tabID.rawValue,
			source.documentRevision > 0
		else { throw AutomationFailure.invalidRequest }
		try snapshot.validate(for: request)
	}
}
