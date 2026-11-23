import SwiftUI

/// The tab under the pointer in the sidebar, so a press on it can get its page ready before
/// the click ends. The window owns it as view state; the store never sees the hover.
private enum SidebarTabHoverKey: EnvironmentKey {
	internal static var defaultValue: (@MainActor (UUID?) -> Void)? { nil }
}

extension EnvironmentValues {
	public var sidebarTabHoverChanged: (@MainActor (UUID?) -> Void)? {
		get { self[SidebarTabHoverKey.self] }
		set { self[SidebarTabHoverKey.self] = newValue }
	}
}

extension SidebarItem {
	/// Reports a hover over this item's tab, if it has one.
	@MainActor
	internal func reportHover(
		_ isHovered: Bool,
		to handler: (@MainActor (UUID?) -> Void)?
	) {
		guard let handler, case let .tab(id) = self.id else { return }
		handler(isHovered ? id : nil)
	}
}
