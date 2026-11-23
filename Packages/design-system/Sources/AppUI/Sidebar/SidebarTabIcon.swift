import BrowserCore
import SwiftUI

extension View {
	/// The tab's chosen icon in place of this site icon, when it has one (DEV-1251), and its icon
	/// picker, which Change Icon… opens here.
	///
	/// - Parameters:
	///   - item: The tab's row or Favorite.
	///   - size: The site icon's side; the chosen icon fills the same square.
	///   - onAction: Gets the picker's choice, its reset and its dismissal.
	public func sidebarTabIcon(
		_ item: SidebarItem,
		size: CGFloat,
		onAction: @escaping (SidebarAction) -> Void
	) -> some View {
		modifier(SidebarTabIcon(item: item, size: size, onAction: onAction))
	}
}

extension EnvironmentValues {
	/// Whether this copy of a tab presents its icon picker. The pager keeps the same tab mounted
	/// more than once: a pinned header for each profile group, each with the same Favorites, and
	/// the Library's Spaces page beside the sidebar's. Only the surface on screen presents it, so
	/// one Change Icon… opens one picker.
	@Entry
	internal var sidebarPresentsTabIconPicker: Bool = true
}

private struct SidebarTabIcon: ViewModifier {
	internal let item: SidebarItem
	internal let size: CGFloat
	internal let onAction: (SidebarAction) -> Void

	@Environment(\.sidebarPresentsTabIconPicker)
	private var presentsPicker

	internal func body(content: Content) -> some View {
		Group {
			if let icon = item.customIcon {
				SpaceIconImage(icon)
					.font(.system(size: size - 2, weight: .medium))
					.frame(width: size, height: size)
					.accessibilityHidden(true)
			} else {
				content
			}
		}
		.spaceIconPicker(
			isPresented: Binding(
				get: { presentsPicker && item.isPickingIcon },
				set: { isPresented in
					if !isPresented, presentsPicker, item.isPickingIcon { onAction(.dismissIconPicker) }
				}
			),
			selection: item.customIcon,
			edge: .bottom,
			onReset: { onAction(.setIcon(item.id, nil)) },
			onSelect: { onAction(.setIcon(item.id, $0)) }
		)
	}
}
