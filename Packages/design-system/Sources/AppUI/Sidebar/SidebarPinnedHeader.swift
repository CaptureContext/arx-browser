import SwiftUI

/// Neighbouring spaces of one profile, which share a URL bar and Favorites that stay still between them.
public struct SidebarPinnedGroup: Identifiable, Equatable, Sendable {
	public let id: UUID
	public let spaces: ClosedRange<Int>

	internal init(
		id: UUID,
		spaces: ClosedRange<Int>
	) {
		self.id = id
		self.spaces = spaces
	}

	public static func groups(of spaces: [SidebarSpace]) -> [SidebarPinnedGroup] {
		groups(ids: spaces.map(\.id), profileIDs: spaces.map(\.profileID))
	}

	public static func groups(of spaces: [SidebarSpaceSummary]) -> [SidebarPinnedGroup] {
		groups(ids: spaces.map(\.id), profileIDs: spaces.map(\.profileID))
	}

	private static func groups(
		ids: [UUID],
		profileIDs: [UUID?]
	) -> [SidebarPinnedGroup] {
		var groups: [SidebarPinnedGroup] = []
		for (index, id) in ids.enumerated() {
			let profileID: UUID? = profileIDs[index]
			let previousProfileID: UUID? = groups.last.flatMap { profileIDs[$0.spaces.upperBound] }
			if let last = groups.last, profileID != nil, profileID == previousProfileID {
				groups[groups.count - 1] = .init(id: last.id, spaces: last.spaces.lowerBound...index)
			} else {
				groups.append(.init(id: id, spaces: index...index))
			}
		}
		return groups
	}

	/// In pages: nothing while the track is within the group, and otherwise the distance to it.
	public func offset(at position: CGFloat) -> CGFloat {
		CGFloat(spaces.lowerBound) - min(position, CGFloat(spaces.lowerBound))
		+ CGFloat(spaces.upperBound) - max(position, CGFloat(spaces.upperBound))
	}
}

/// Favorites fetch their missing icons only while the track shows one of the group's spaces;
/// every group's header stays mounted. Reads the spaces the track shows, which change only as it
/// crosses a space, not every frame.
internal struct SidebarPinnedIconsShown: ViewModifier {
	private let driver: SidebarTrackDriver
	private let group: SidebarPinnedGroup

	internal init(
		driver: SidebarTrackDriver,
		group: SidebarPinnedGroup
	) {
		self.driver = driver
		self.group = group
	}

	internal func body(content: Content) -> some View {
		content.siteIconsShown(driver.visibleSpaces.overlaps(group.spaces))
	}
}

/// The URL bar and Favorites, which belong to a profile rather than to any one of its spaces.
internal struct SidebarPinnedHeader: View {
	private let url: URL?
	private let favorites: [SidebarItem]
	private let profileID: UUID?
	private let selectedID: SidebarItem.ID?
	private let splitIDs: Set<SidebarItem.ID>
	private let availableHeight: CGFloat
	private let onAction: (SidebarAction) -> Void
	private let onCopyURL: () -> Void

	internal init(
		url: URL?,
		favorites: [SidebarItem],
		profileID: UUID? = nil,
		selectedID: SidebarItem.ID?,
		splitIDs: Set<SidebarItem.ID>,
		availableHeight: CGFloat,
		onAction: @escaping (SidebarAction) -> Void,
		onCopyURL: @escaping () -> Void
	) {
		self.url = url
		self.favorites = favorites
		self.profileID = profileID
		self.selectedID = selectedID
		self.splitIDs = splitIDs
		self.availableHeight = availableHeight
		self.onAction = onAction
		self.onCopyURL = onCopyURL
	}

	internal var body: some View {
		VStack(spacing: 0) {
			URLBar(
				url: url,
				onActivate: { onAction(.openCommandBar) },
				onCopy: onCopyURL
			)
				.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
				.padding(.bottom, BrowserMetrics.Sidebar.sectionSpacing)

			FavoritesGrid(
				items: favorites,
				profileID: profileID,
				selectedID: selectedID,
				splitIDs: splitIDs,
				availableHeight: availableHeight,
				onAction: onAction
			)
			.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
			.padding(.bottom, BrowserMetrics.Section.dividerSpacing)
		}
	}
}
