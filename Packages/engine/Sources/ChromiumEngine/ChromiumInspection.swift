import Foundation

public struct ChromiumInspectionLimits: Equatable, Sendable {
	public var maximumNodes: Int
	public var maximumTextBytes: Int
	public var maximumReferences: Int
	public var maximumOutputBytes: Int
	public var timeoutMilliseconds: Int

	/// The first projected node to emit. A document projects at most
	/// `maximumTreeNodes`; windows of one DOM version concatenate.
	public var windowStart: Int

	/// Opt-in values of eligible form controls; password ancestry stays omitted.
	public var includesFormValues: Bool

	/// Element bounds in the main widget's viewport points.
	public var includesBounds: Bool

	public static let maximumTreeNodes: Int = 16_384

	public init(
		maximumNodes: Int = 512,
		maximumTextBytes: Int = 65_536,
		maximumReferences: Int = 256,
		maximumOutputBytes: Int = 262_144,
		timeoutMilliseconds: Int = 2_000,
		windowStart: Int = 0,
		includesFormValues: Bool = false,
		includesBounds: Bool = false
	) {
		self.maximumNodes = maximumNodes
		self.maximumTextBytes = maximumTextBytes
		self.maximumReferences = maximumReferences
		self.maximumOutputBytes = maximumOutputBytes
		self.timeoutMilliseconds = timeoutMilliseconds
		self.windowStart = windowStart
		self.includesFormValues = includesFormValues
		self.includesBounds = includesBounds
	}
}

/// Historical semantic accessibility data. This is neither a full DOM dump nor
/// proof that the DOM remains unchanged after the renderer produced the reply.
public struct ChromiumInspectionSnapshot: Equatable, Sendable, Decodable {
	public let snapshotID: String
	public let documentID: String
	public let frameID: String
	public let domVersion: String
	public let nodes: [ChromiumInspectionNode]
	public let omissions: [ChromiumInspectionOmission]

	/// The index of the first node in `nodes`.
	public let windowStart: Int

	/// Every node the document projects, across all windows.
	public let totalNodes: Int

	public init(
		snapshotID: String,
		documentID: String,
		frameID: String,
		domVersion: String,
		nodes: [ChromiumInspectionNode],
		omissions: [ChromiumInspectionOmission],
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
		let nodes = try container.decode([ChromiumInspectionNode].self, forKey: .nodes)
		let windowStart = try container.decodeIfPresent(Int.self, forKey: .windowStart) ?? 0
		self.init(
			snapshotID: try container.decode(String.self, forKey: .snapshotID),
			documentID: try container.decode(String.self, forKey: .documentID),
			frameID: try container.decode(String.self, forKey: .frameID),
			domVersion: try container.decode(String.self, forKey: .domVersion),
			nodes: nodes,
			omissions: try container.decode([ChromiumInspectionOmission].self, forKey: .omissions),
			windowStart: windowStart,
			totalNodes: try container.decodeIfPresent(Int.self, forKey: .totalNodes)
		)
	}

	private enum CodingKeys: String, CodingKey {
		case snapshotID
		case documentID
		case frameID
		case domVersion
		case nodes
		case omissions
		case windowStart
		case totalNodes
	}
}

public struct ChromiumInspectionNode: Equatable, Sendable, Decodable {
	public let index: Int
	public let parent: Int?
	public let role: String
	public let name: String?
	public let text: String?

	/// Opaque read-only identity. Never use it as authority for a later action.
	public let reference: String?

	/// An eligible control's value, only when form values were requested.
	public let value: String?

	/// A checkbox or radio button's state, only when form values were requested.
	public let checked: Bool?

	/// Viewport points of the main widget, only when bounds were requested.
	public let bounds: ChromiumInspectionBounds?

	/// The child frame an iframe element shows, inspectable by this ID.
	public let frame: String?

	public init(
		index: Int,
		parent: Int?,
		role: String,
		name: String?,
		text: String?,
		reference: String?,
		value: String? = nil,
		checked: Bool? = nil,
		bounds: ChromiumInspectionBounds? = nil,
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

public struct ChromiumInspectionBounds: Equatable, Sendable, Codable {
	public let x: Int
	public let y: Int
	public let width: Int
	public let height: Int

	public init(
		x: Int,
		y: Int,
		width: Int,
		height: Int
	) {
		self.x = x
		self.y = y
		self.width = width
		self.height = height
	}
}

/// Coverage policy, not a disclosure that excluded content exists or its count.
public enum ChromiumInspectionOmission: String, Equatable, Sendable, Decodable, CaseIterable {
	case subframes
	case crossOriginFrames
	case fencedFrames
	case canvasPixels
	case generatedText
	case computedNames
	case formValues
	case passwordSubtrees
}

public enum ChromiumInspectionFailure: Error, Equatable, Sendable {
	case unavailable
	case notReady
	case unsupportedDocument
	case staleReference
	case limitExceeded
	case timedOut
	case busy
	case invalidResponse
}
