import Foundation

/// Window placement is independent of durable tab ownership and native sessions.
public struct BrowserWindowPresentation: Codable, Equatable, Sendable, Identifiable {
	public var id: UUID
	public var activeSpaceID: Space.ID
	public var spaces: [BrowserSpacePresentation]

	/// Absent in snapshots from before widths were saved.
	public var sidebarWidth: Double?

	/// The chat panel's width. Absent in snapshots from before it could be resized (DEV-761).
	public var chatWidth: Double?

	/// Chats pinned to this window's tabs (DEV-761). Absent in older snapshots.
	public var chatPins: [BrowserChatPin]?

	/// Native window geometry, absent in older snapshots.
	public var geometry: BrowserWindowGeometry?

	/// The open tabs this window keeps as its own while windows are independent (DEV-822).
	/// Absent for the main window, whose open tabs are every one no other window keeps, and in
	/// older snapshots.
	public var openTabs: [Tab.ID]?

	public init(
		id: UUID,
		activeSpaceID: Space.ID,
		spaces: [BrowserSpacePresentation],
		sidebarWidth: Double? = nil,
		chatWidth: Double? = nil,
		chatPins: [BrowserChatPin]? = nil,
		geometry: BrowserWindowGeometry? = nil,
		openTabs: [Tab.ID]? = nil
	) {
		self.id = id
		self.activeSpaceID = activeSpaceID
		self.spaces = spaces
		self.sidebarWidth = sidebarWidth
		self.chatWidth = chatWidth
		self.chatPins = chatPins
		self.geometry = geometry
		self.openTabs = openTabs
	}
}

/// A chat pinned to a tab: the panel on that tab shows the chat (DEV-761).
public struct BrowserChatPin: Codable, Equatable, Sendable {
	public var tabID: Tab.ID
	public var conversationID: UUID

	public init(
		tabID: Tab.ID,
		conversationID: UUID
	) {
		self.tabID = tabID
		self.conversationID = conversationID
	}
}

/// The chat panel's width in points, per window. Saved values are clamped when read.
public enum BrowserChatWidth {
	public static let standard: Double = 360
	public static let range: ClosedRange<Double> = 300 ... 720

	public static func sanitized(_ width: Double?) -> Double {
		guard let width, width.isFinite else { return standard }
		return min(max(width, range.lowerBound), range.upperBound)
	}
}

/// The sidebar's width in points. Saved values are clamped when read, so a bad
/// one never fails loading or reaches a window.
public enum BrowserSidebarWidth {
	public static let standard: Double = 286
	public static let range: ClosedRange<Double> = 216 ... 528

	public static func sanitized(_ width: Double?) -> Double {
		guard let width, width.isFinite else { return standard }
		return min(max(width, range.lowerBound), range.upperBound)
	}
}

public struct BrowserSpacePresentation: Codable, Equatable, Sendable, Identifiable {
	public var id: Space.ID
	public var panes: [BrowserPanePlacement]
	public var activePaneID: UUID
	public var orientation: Orientation

	/// Each pane's share of the split's length, in `panes` order.
	public var fractions: [Double]

	/// The first pane's share, as two-pane snapshots saved it.
	public var proportion: Double { fractions.first ?? 1 }

	public init(
		id: Space.ID,
		panes: [BrowserPanePlacement],
		activePaneID: UUID,
		orientation: Orientation = .horizontal,
		fractions: [Double]? = nil
	) {
		self.id = id
		self.panes = panes
		self.activePaneID = activePaneID
		self.orientation = orientation
		self.fractions = SplitLayout.sanitized(fractions, count: panes.count)
	}

	private enum CodingKeys: String, CodingKey {
		case id, panes, activePaneID, orientation, proportion, fractions
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try values.decode(Space.ID.self, forKey: .id)
		self.panes = try values.decode([BrowserPanePlacement].self, forKey: .panes)
		self.activePaneID = try values.decode(UUID.self, forKey: .activePaneID)
		self.orientation = try values.decode(Orientation.self, forKey: .orientation)

		// Two-pane snapshots saved only the first pane's share.
		let legacy = try values.decodeIfPresent(Double.self, forKey: .proportion).map { [$0, 1 - $0] }
		let fractions = try values.decodeIfPresent([Double].self, forKey: .fractions) ?? legacy
		self.fractions = SplitLayout.sanitized(fractions, count: panes.count)
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(panes, forKey: .panes)
		try container.encode(activePaneID, forKey: .activePaneID)
		try container.encode(orientation, forKey: .orientation)
		try container.encode(fractions, forKey: .fractions)

		// Older builds read only this; a split they restore keeps its first divider.
		try container.encode(proportion, forKey: .proportion)
	}

	public enum Orientation: String, Codable, Equatable, Sendable {
		case horizontal
		case vertical
	}

	/// Restoration is best effort when tabs or spaces have changed since the snapshot.
	public func sanitized(
		in organization: BrowserOrganization,
		excluding claimed: Set<Tab.ID> = []
	) -> Self? {
		guard let space = organization.spaces[id: id] else { return nil }
		var paneIDs: Set<UUID> = []
		var tabIDs = claimed
		var result = self
		result.panes = Array(panes.filter { pane in
			guard paneIDs.insert(pane.id).inserted else { return false }
			guard let tabID = pane.tabID else { return true }
			guard tabIDs.insert(tabID).inserted else { return false }
			switch organization.location(of: tabID) {
			case .favorite(space.profileID), .unpinned(space.id), .pinned(space.id, _): return true
			default: return false
			}
		}.prefix(SplitLayout.maximumPanes))
		if result.panes.isEmpty {
			result.panes = [.init(id: panes.first?.id ?? id.rawValue, tabID: nil)]
		}

		if !result.panes.contains(where: { $0.id == activePaneID }) {
			result.activePaneID = result.panes[0].id
		}

		let kept = result.panes.compactMap { pane in
			panes.firstIndex(where: { $0.id == pane.id }).flatMap {
				fractions.indices.contains($0) ? fractions[$0] : nil
			}
		}
		result.fractions = SplitLayout.sanitized(kept, count: result.panes.count)
		return result
	}
}

public struct BrowserPanePlacement: Codable, Equatable, Sendable, Identifiable {
	public var id: UUID
	public var tabID: Tab.ID?

	public init(
		id: UUID,
		tabID: Tab.ID?
	) {
		self.id = id
		self.tabID = tabID
	}
}
