import Foundation
import SwiftUI

/// Hands a row's actions to its sidebar's current handlers.
///
/// The window builds a new action closure on every pass, and closures never compare equal, so a
/// row holding one directly looked changed every time and ran its body again. Rows hold the
/// sidebar's relay instead, which keeps its identity while the sidebar refreshes its handler.
@MainActor
internal final class SidebarActionRelay {
	internal var handler: (SidebarAction) -> Void

	/// The window's `sidebarTabHoverChanged`, read by `SidebarRelayEnvironment` so neither rows
	/// nor the sidebar depend on it.
	internal var tabHoverChanged: (@MainActor (UUID?) -> Void)?

	/// The window's `browserLinkActions`, for Split View rows' menus.
	internal var linkActions: BrowserLinkActions?

	internal init(_ handler: @escaping (SidebarAction) -> Void = { _ in }) {
		self.handler = handler
	}

	internal func send(_ action: SidebarAction) {
		handler(action)
	}
}

/// Hands a sidebar's relay the window's hover and link handlers. The window sets new closures on
/// every pass, and a view reading them runs its body each time, so only this empty view reads
/// them, not the sidebar, whose body then runs only when what it shows changes (DEV-937).
internal struct SidebarRelayEnvironment: View {
	private let relay: SidebarActionRelay

	@Environment(\.sidebarTabHoverChanged)
	private var tabHoverChanged

	@Environment(\.browserLinkActions)
	private var linkActions

	internal init(relay: SidebarActionRelay) {
		self.relay = relay
	}

	internal var body: some View {
		let _ = relay.tabHoverChanged = tabHoverChanged
		let _ = relay.linkActions = linkActions
		Color.clear
			.allowsHitTesting(false)
			.accessibilityHidden(true)
	}
}
