import AppUI
import BrowserCore
import BrowserSurfaceClient
import Foundation
import MainFeature
import SwiftUI
import _ComposableArchitecture

/// Shows a window's page in HTML full screen over everything else in it (DEV-949): only the
/// page, filling the window, on black where its aspect leaves room. The window's own copy of the
/// page lets go of it, so the page moves here without reloading, and the rest of the window stays
/// laid out underneath, so leaving returns to the same layout.
///
/// After ⌘S the window's sidebar shows beside the page, which fills the rest of the window
/// (DEV-991).
///
/// Apply it outermost, after Peek's modifier, so a Peek's page fills the whole window too.
internal struct PageFullScreenHostPresentation: ViewModifier {
	internal let store: StoreOf<AppFeature>
	internal let windowID: UUID
	internal let surface: BrowserSurfaceClient

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	internal init(
		store: StoreOf<AppFeature>,
		windowID: UUID,
		surface: BrowserSurfaceClient
	) {
		self.store = store
		self.windowID = windowID
		self.surface = surface
	}

	internal func body(content: Content) -> some View {
		let fullScreen: PageFullScreen? = store.pageFullScreen.flatMap { fullScreen in
			fullScreen.windowID == windowID ? fullScreen : nil
		}
		let tabID: BrowserCore.Tab.ID? = fullScreen?.tabID
		let sidebar: Sidebar? = fullScreen?.showsSidebar == true ? windowSidebar : nil
		content
			.environment(\.showsOnlySidebar, sidebar != nil)
			.transformEnvironment(\.suppressedBrowserTabs) { tabs in
				if let tabID { tabs.insert(tabID) }
			}

			// The sidebar beside the page takes clicks and is read out; the window hides the rest
			// under the page (`showsOnlySidebar`).
			.allowsHitTesting(tabID == nil || sidebar != nil)
			.accessibilityHidden(tabID != nil && sidebar == nil)
			.overlay {
				if let tabID {
					PageFullScreenView(
						tabID: tabID,
						surface: surface,
						// The agent indicator and its Stop, and the link toast, stay on the page.
						notice: pageNotices(store: store, windowID: windowID).content(tabID)
					)

						// The page's media visibility follows it here, so leaving the window's
						// layout for full screen never reads as the video's tab being hidden.
						.environment(\.browserSurfaceVisibilityObserver, .init { [store, windowID] report in
							store.send(.event(.mediaSurfaceVisibility(windowID, report)))
						})
						.padding(sidebar?.edge ?? .leading, sidebar?.width ?? 0)
						.animation(reduceMotion ? nil : .smooth(duration: 0.24), value: sidebar)
				}
			}
	}

	/// The window's sidebar: which side it's on and how wide it is.
	private var windowSidebar: Sidebar {
		let width = windowID == store.main.id ? store.main.sidebarWidth : store.windows[id: windowID]?.sidebarWidth
		return .init(
			edge: store.settings.general.sidebarPosition == .right ? .trailing : .leading,
			width: width ?? BrowserSidebarWidth.standard
		)
	}

	private struct Sidebar: Equatable {
		internal let edge: Edge.Set
		internal let width: CGFloat
	}
}

/// The page alone, filling its window, with a passing hint that Escape leaves.
private struct PageFullScreenView: View {
	internal let tabID: BrowserCore.Tab.ID
	internal let surface: BrowserSurfaceClient
	internal let notice: AnyView?

	@SwiftUI.State
	private var showsHint: Bool = true

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	internal var body: some View {
		ZStack(alignment: .top) {
			Color.black
			BrowserSurface(tabID: tabID, client: surface)
			if showsHint {
				PageFullScreenHint()
					.padding(.top, PageFullScreenHint.topInset)
					.transition(.opacity)
			}
			if let notice {
				notice
			}
		}
		.ignoresSafeArea()
		.task(id: tabID) { await showHint() }
	}

	private func showHint() async {
		showsHint = true
		AccessibilityNotification.Announcement(String.localized(.appUI.viewer.fullScreenExitHint)).post()
		try? await Task.sleep(for: PageFullScreenHint.duration)
		guard !Task.isCancelled else { return }

		withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
			showsHint = false
		}
	}
}

/// "Press Esc to exit full screen", as other browsers show it on entering. It never takes a
/// click or the keyboard, so the page keeps both.
private struct PageFullScreenHint: View {
	internal static let topInset: CGFloat = 28
	internal static let duration: Duration = .seconds(3)

	internal var body: some View {
		Text(localized: .appUI.viewer.fullScreenExitHint)
			.font(.system(size: 13, weight: .medium))
			.foregroundStyle(.white)
			.padding(.horizontal, 16)
			.padding(.vertical, 9)
			.background(.black.opacity(0.72), in: .capsule)
			.overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
			.environment(\.colorScheme, .dark)
			.allowsHitTesting(false)
			.accessibilityAddTraits(.isStaticText)
	}
}
