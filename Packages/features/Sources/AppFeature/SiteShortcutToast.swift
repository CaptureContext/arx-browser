import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// "Press ⌘K again to open the command bar", after a site used one of the keys it may take
/// (DEV-1264, DEV-1073). It sits where the Copy Link toast does, at the window's top-right corner,
/// and gives that toast's place up: showing it dismisses the link toast.
internal struct SiteShortcutToast: ViewModifier {
	internal let store: StoreOf<AppFeature>
	internal let windowID: UUID
	internal let topInset: CGFloat
	internal let trailingInset: CGFloat

	internal func body(content: Content) -> some View {
		let notice: SiteShortcutState.Notice? = store.siteShortcuts.notice.flatMap {
			$0.windowID == windowID ? $0 : nil
		}
		content
			.arxToast(
				isPresented: notice != nil,
				topInset: topInset,
				trailingInset: trailingInset
			) {
				if let notice {
					ArxToast(
						Self.title(notice),
						detail: String.localized(.appUI.siteShortcuts.detail),
						systemImage: "keyboard"
					)
				}
			}
	}

	internal static func title(_ notice: SiteShortcutState.Notice) -> String {
		switch notice.action {
		case .command(.commandBar): String.localized(.appUI.siteShortcuts.commandBar(notice.shortcut))
		case .command(.address): String.localized(.appUI.siteShortcuts.address(notice.shortcut))
		case .command(.toggleSidebar): String.localized(.appUI.siteShortcuts.toggleSidebar(notice.shortcut))
		case let .command(command): String.localized(.appUI.siteShortcuts.command(notice.shortcut, command.title))
		case .undo: String.localized(.appUI.siteShortcuts.undo(notice.shortcut))
		case .redo: String.localized(.appUI.siteShortcuts.redo(notice.shortcut))
		}
	}
}
