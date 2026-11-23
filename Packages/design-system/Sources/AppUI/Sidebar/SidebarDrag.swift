import SwiftUI
import UniformTypeIdentifiers

extension UTType {
	internal static let sidebarItem: UTType = .init(
		exportedAs: "dev.capturecontext.arx.sidebar-item",
		conformingTo: .data
	)
}

/// Transfers identity only. The receiving feature retains ownership of the model.
internal struct SidebarTransfer: Identifiable, Codable, Transferable {
	internal let id: SidebarItem.ID
	internal var selection: [SidebarItem.ID]?

	/// The Split View row a segment belongs to, which moves whole in the sidebar's lists
	/// (DEV-1006). Not a selection: onto the page or Favorites the segment is its own tab.
	internal var group: [SidebarItem.ID]?

	internal init(
		id: SidebarItem.ID,
		selection: [SidebarItem.ID] = [],
		group: [SidebarItem.ID]? = nil
	) {
		self.id = id
		self.selection = selection.contains(id) ? selection : nil
		self.group = self.selection == nil && group?.contains(id) == true ? group : nil
	}

	/// What a drop on the sidebar's lists moves: the selection, or a segment's whole split.
	internal static func orderedIDs(_ transfers: [Self]) -> [SidebarItem.ID] {
		ids(transfers) { $0.selection ?? $0.group ?? [$0.id] }
	}

	/// What a drop that takes tabs one by one gets, the page's or Favorites': the selection, or
	/// the tab dragged.
	internal static func itemIDs(_ transfers: [Self]) -> [SidebarItem.ID] {
		ids(transfers) { $0.selection ?? [$0.id] }
	}

	private static func ids(
		_ transfers: [Self],
		of transfer: (Self) -> [SidebarItem.ID]
	) -> [SidebarItem.ID] {
		var result: [SidebarItem.ID] = []
		for item in transfers {
			for id in transfer(item) where !result.contains(id) {
				result.append(id)
			}
		}
		return result
	}

	internal static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation(contentType: .sidebarItem)
	}
}

extension EnvironmentValues {
	/// Whether this sidebar's drop destinations take drops (DEV-793). A space the pager isn't
	/// showing, a pinned header of another group, and a hidden or suspended sidebar all sit
	/// somewhere in the window, often over the page, and SwiftUI registers their destinations
	/// there even with hit-testing off. Only the sidebar on screen may take a drop.
	@Entry
	internal var sidebarAcceptsDrops: Bool = true

	/// Which of the pager's spaces this sidebar is, for its drop destinations to ask whether it's
	/// the one on screen. Nil outside the pager, where `sidebarAcceptsDrops` says it all.
	@Entry
	internal var sidebarDropGate: SidebarDropGate? = nil
}

/// The space the pager shows and takes drops in, or none while the Library or the Create a
/// Space page covers the spaces.
@MainActor
@Observable
internal final class SidebarActiveSpace {
	internal var id: UUID?

	internal init(id: UUID?) {
		self.id = id
	}
}

/// Whether one of the pager's spaces is the one on screen, which only its drop destinations ask.
///
/// The pager used to tell each space through `sidebarAcceptsDrops`. An environment value that
/// changes reaches every view under it, so selecting a space ran SwiftUI over all the rows of
/// the space left and the space arrived at, in the frame a swipe lands on (DEV-1235). The gate
/// a space is given never changes; what it reads does, and only the stand-ins read it.
internal struct SidebarDropGate: Equatable {
	private let active: SidebarActiveSpace
	private let spaceID: UUID

	internal init(
		active: SidebarActiveSpace,
		spaceID: UUID
	) {
		self.active = active
		self.spaceID = spaceID
	}

	@MainActor
	internal var isOpen: Bool { active.id == spaceID }

	internal nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.active === rhs.active && lhs.spaceID == rhs.spaceID
	}
}

extension View {
	/// Puts a sidebar drop destination on a stand-in behind this view, with the same frame, that
	/// shrinks to nothing while the sidebar doesn't take drops (DEV-793). SwiftUI keeps a disabled
	/// destination, or one in a view that isn't hit-testable, registered over its frame, so turning
	/// it off isn't enough: it has to stop covering anything. The view itself keeps its identity, so
	/// switching spaces rebuilds no rows.
	internal func sidebarDropArea(
		isEnabled: Bool,
		@ViewBuilder destination: (SidebarDropStandIn) -> some View
	) -> some View {
		background { destination(SidebarDropStandIn(isEnabled: isEnabled)) }
	}
}

/// The view a sidebar drop destination is attached to: the host view's frame while drops are on,
/// a point while they're off, or while its space isn't the one the pager shows.
internal struct SidebarDropStandIn: View {
	internal let isEnabled: Bool

	@Environment(\.sidebarDropGate)
	private var gate

	internal init(isEnabled: Bool) {
		self.isEnabled = isEnabled
	}

	internal var body: some View {
		let takesDrops: Bool = isEnabled && gate?.isOpen != false
		Color.clear
			.frame(width: takesDrops ? nil : 0, height: takesDrops ? nil : 0)
	}
}
