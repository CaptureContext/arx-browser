import SwiftUI

/// Another browser window a tab menu's Move to Window can send tabs to (DEV-883).
public struct SidebarWindowTarget: Identifiable, Equatable, Sendable {
	public let id: UUID

	/// The window's space and the page it shows, such as "Work — Inbox".
	public var title: String

	public init(
		id: UUID,
		title: String
	) {
		self.id = id
		self.title = title
	}
}

/// The other windows a tab menu lists, kept by the window. Menus read it in views of their own, so a
/// window opening or its page changing renders those menus, never the rows (DEV-883).
@MainActor
@Observable
public final class SidebarWindowTargets {
	public var targets: [SidebarWindowTarget]

	public init(targets: [SidebarWindowTarget] = []) {
		self.targets = targets
	}
}

extension EnvironmentValues {
	/// The other windows for Move to Window. Without it, as in private windows, the tab menu
	/// offers neither Move to Window nor Open in New Window (DEV-883).
	@Entry
	public var sidebarWindowTargets: SidebarWindowTargets? = nil
}

/// Open in New Window and Move to Window ▸ for one tab, or Move N Tabs to Window ▸ for a selection.
internal struct SidebarWindowMenu: View {
	private let ids: [SidebarItem.ID]
	private let offersNewWindow: Bool
	private let onAction: (SidebarAction) -> Void

	@Environment(\.sidebarWindowTargets)
	private var windowTargets

	internal init(
		ids: [SidebarItem.ID],
		offersNewWindow: Bool,
		onAction: @escaping (SidebarAction) -> Void
	) {
		self.ids = ids
		self.offersNewWindow = offersNewWindow
		self.onAction = onAction
	}

	internal var body: some View {
		if let windowTargets {
			if offersNewWindow {
				Button(String.localized(.appUI.sidebar.openInNewWindow)) { onAction(.moveToWindow(ids, nil)) }
			}
			Menu(title) {
				Button(String.localized(.appUI.sidebar.newWindow)) { onAction(.moveToWindow(ids, nil)) }
				let targets = windowTargets.targets
				if !targets.isEmpty { Divider() }
				ForEach(targets) { target in
					Button(target.title) { onAction(.moveToWindow(ids, target.id)) }
				}
			}
		}
	}

	private var title: String {
		ids.count > 1
		? String.localized(.appUI.sidebar.moveTabsToWindow(ids.count))
		: String.localized(.appUI.sidebar.moveToWindow)
	}
}
