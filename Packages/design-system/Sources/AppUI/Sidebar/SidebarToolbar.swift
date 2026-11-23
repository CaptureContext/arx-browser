import AppKit
import SwiftUI

/// One fixed toolbar shared by every space, with AppKit's real window controls.
internal struct SidebarToolbar: View {
	/// Read only by the navigation buttons, so a page's loads re-render nothing else.
	private let navigation: () -> SidebarNavigation
	private let libraryProgress: CGFloat
	private let isLibraryOpen: Bool
	private let profileName: String?
	private let profileMenu: (() -> AnyView)?
	private let toggleSidebar: () -> Void

	/// The toolbar's own width, which decides whether the profile badge fits.
	@SwiftUI.State
	private var rowWidth: CGFloat?

	internal init(
		navigation: @escaping () -> SidebarNavigation,
		libraryProgress: CGFloat = 0,
		isLibraryOpen: Bool = false,
		profileName: String? = nil,
		profileMenu: (() -> AnyView)? = nil,
		toggleSidebar: @escaping () -> Void
	) {
		self.navigation = navigation
		self.libraryProgress = libraryProgress
		self.isLibraryOpen = isLibraryOpen
		self.profileName = profileName
		self.profileMenu = profileMenu
		self.toggleSidebar = toggleSidebar
		self._rowWidth = .init(initialValue: nil)
	}

	@Environment(\.browserWindowIsFullScreen)
	private var isFullScreen

	internal var body: some View {
		HStack(spacing: BrowserMetrics.Toolbar.spacing) {
			// In full screen the controls go back to the title bar macOS reveals at the top edge, over
			// the page, and their space closes (DEV-912).
			if !isFullScreen {
				BrowserWindowControls()
					.frame(width: BrowserMetrics.Toolbar.windowControlsWidth, height: BrowserMetrics.Toolbar.height)
					.offset(y: BrowserMetrics.Library.windowControlsDrop * libraryProgress)
					.transition(.opacity)
			}
			controls
		}
		.font(.system(size: BrowserMetrics.Toolbar.symbolSize, weight: .regular))
		.foregroundStyle(BrowserTheme.secondary)
		.buttonStyle(BrowserToolbarButtonStyle())
		.padding(.leading, BrowserMetrics.Toolbar.leadingPadding)
		.padding(.trailing, BrowserMetrics.Toolbar.trailingPadding)

		// Leading, so a row too wide for the sidebar overflows past the trailing edge, never moving the window controls.
		.frame(maxWidth: .infinity, alignment: .leading)
		.frame(height: BrowserMetrics.Toolbar.height)
		.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
		.background(alignment: .leading) {
			Color.clear
				.contentShape(.rect)
				.gesture(WindowDragGesture())

				// The Library's search field sits right of the rail, under this toolbar.
				.frame(width: isLibraryOpen ? BrowserMetrics.Library.railWidth : nil)
		}
	}

	/// Everything but the window controls, which stay put while the Library replaces the spaces.
	private var controls: some View {
		HStack(spacing: BrowserMetrics.Toolbar.spacing) {
			Button(action: toggleSidebar) { Image(systemName: "sidebar.left") }
				.help(String.localized(.appUI.sidebar.toggleHelp))
			if let profileName, let badgeWidth {
				SidebarProfileCapsule(name: profileName, menu: profileMenu)
					.frame(maxWidth: badgeWidth, alignment: .leading)
					.padding(.leading, BrowserMetrics.Toolbar.profileBadgeGap)
			}
			Spacer(minLength: 0)
			SidebarNavigationControls(navigation: navigation)
		}
		.modifier(SidebarLibraryTransition(
			progress: libraryProgress,
			range: 0...0.3,
			travel: 0,
			isOutgoing: true
		))
		.allowsHitTesting(!isLibraryOpen)
		.accessibilityHidden(isLibraryOpen)
	}

	/// Before the first layout pass, the badge assumes it fits.
	private var badgeWidth: CGFloat? {
		guard let rowWidth else { return BrowserMetrics.Toolbar.profileBadgeMaximumWidth }
		return SidebarToolbarFit.profileBadgeWidth(rowWidth: rowWidth)
	}
}

/// Back, forward and reload. The only part of the sidebar that reads the page's navigation, which
/// changes with every load, title and address of the active tab.
private struct SidebarNavigationControls: View {
	private let navigation: () -> SidebarNavigation

	fileprivate init(navigation: @escaping () -> SidebarNavigation) {
		self.navigation = navigation
	}

	fileprivate var body: some View {
		let navigation = navigation()
		BrowserHistoryControl(
			navigation: navigation.history,
			direction: .back,
			navigate: navigation.back,
			select: navigation.selectHistory
		)
		BrowserHistoryControl(
			navigation: navigation.history,
			direction: .forward,
			navigate: navigation.forward,
			select: navigation.selectHistory
		)
		Button(action: navigation.reloadOrStop) {
			Image(systemName: navigation.isLoading ? "xmark" : "arrow.clockwise")
		}
		.disabled(!navigation.isAvailable)
		.help(String.localized(navigation.isLoading ? .appUI.navigation.stop : .appUI.menu.reload))
	}
}

/// What fits in the sidebar's header row. The window controls and the toolbar buttons keep their size;
/// the profile badge truncates to make room, and hides once it can't show its face and a few letters.
internal enum SidebarToolbarFit {
	/// The width of the window controls, the sidebar toggle, back, forward and reload, with their gaps
	/// and the row's padding: everything but the badge and the flexible gap before back.
	internal static var fixedWidth: CGFloat {
		let metrics = BrowserMetrics.Toolbar.self
		let buttons: CGFloat = 4

		// Window controls, toggle, spacer, back, forward and reload.
		let gaps: CGFloat = 5
		return metrics.leadingPadding + metrics.windowControlsWidth + buttons * metrics.buttonSize
			+ gaps * metrics.spacing + metrics.trailingPadding
	}

	/// The room left for the badge, with its own gaps, in a row `rowWidth` wide; `nil` hides it.
	internal static func profileBadgeWidth(rowWidth: CGFloat) -> CGFloat? {
		let metrics = BrowserMetrics.Toolbar.self
		let room = rowWidth - fixedWidth - metrics.spacing - metrics.profileBadgeGap
		guard room >= metrics.profileBadgeMinimumWidth else { return nil }
		return min(room, metrics.profileBadgeMaximumWidth)
	}
}
