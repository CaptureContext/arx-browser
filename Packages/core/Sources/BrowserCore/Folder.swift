import Foundation

public struct Folder: Identifiable, Equatable, Codable, Sendable {
	public let id: ID
	public var spaceID: Space.ID
	public var name: String
	public var children: [SavedItem]
	public var isExpanded: Bool

	public init(
		id: ID,
		spaceID: Space.ID,
		name: String,
		children: [SavedItem] = [],
		isExpanded: Bool = true
	) {
		self.id = id
		self.spaceID = spaceID
		self.name = name
		self.children = children
		self.isExpanded = isExpanded
	}
}

extension Folder {
	public typealias ID = BrowserID<Self>
}

/// The implicit space root and folders share one ordered collection shape.
public enum SavedItem: Equatable, Hashable, Codable, Sendable {
	case tab(Tab.ID)
	case folder(Folder.ID)
}
