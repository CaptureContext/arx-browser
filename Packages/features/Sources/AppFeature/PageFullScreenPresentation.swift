import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import _ComposableArchitecture

/// A page in HTML full screen (DEV-949), such as a YouTube video after its full-screen button,
/// and the window it fills.
///
/// Only that page shows, filling the window: no sidebar, toolbar, split pane or page card. A
/// browser window that wasn't in macOS full screen enters it and leaves it again afterwards. A
/// Peek's page fills the window it was opened from, and a Little Arx page its own window.
///
/// ⌘S in a browser window shows its sidebar beside the page, which keeps filling the rest of the
/// window, and hides it again (DEV-991). The window's own sidebar setting doesn't change.
public struct PageFullScreen: Equatable, Sendable {
	public var tabID: BrowserCore.Tab.ID
	public var windowID: UUID

	/// Whether the window's sidebar shows beside the page.
	public var showsSidebar: Bool

	public init(
		tabID: BrowserCore.Tab.ID,
		windowID: UUID,
		showsSidebar: Bool = false
	) {
		self.tabID = tabID
		self.windowID = windowID
		self.showsSidebar = showsSidebar
	}
}

/// The engine's page full-screen reports, and the ways out the page doesn't start itself.
/// Escape, `document.exitFullscreen()`, another document and a crash end it in the engine,
/// which reports it here.
@Reducer
internal struct PageFullScreenPresentation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	internal var body: some ReducerOf<Self> {
		Pullback(\.event.pageFullScreenChanged) { state, value in
			let (tabID, isFullScreen) = value
			guard isFullScreen else {
				if state.pageFullScreen?.tabID == tabID { state.pageFullScreen = nil }
				return .none
			}

			// A page that isn't on screen never takes it: a hidden tab's request goes back out,
			// as does every request in a headless run, which has no screen to fill.
			guard
				!state.automation.isUnattended,
				let windowID = state.pageFullScreenWindow(showing: tabID)
			else { return .exitPageFullScreen(tabID, engine: engine) }

			let previous = state.pageFullScreen
			state.pageFullScreen = .init(tabID: tabID, windowID: windowID)
			guard let previous, previous.tabID != tabID else { return .none }

			// One page fills the screen at a time.
			return .exitPageFullScreen(previous.tabID, engine: engine)
		}

		// A browser command brings up the window's own interface (the command bar, a capture,
		// Peek's address, the Library...), which full screen would cover, so it leaves first.
		// Commands that only act on the page keep it, and ⌘S in its window shows or hides the
		// sidebar beside it (DEV-991).
		Pullback(\.ui.command) { state, value in
			let (command, target, _) = value
			guard let current = state.pageFullScreen else { return .none }

			if
				command == .toggleSidebar,
				case let .window(id, _) = target,
				id == current.windowID,
				state.pageFullScreenCanShowSidebar(current)
			{
				state.pageFullScreen?.showsSidebar.toggle()
				return .none
			}
			guard !Self.keepsFullScreen.contains(command) else { return .none }

			state.pageFullScreen = nil
			return .exitPageFullScreen(current.tabID, engine: engine)
		}

		Pullback(\.ui.exitPageFullScreen) { state in
			guard let current = state.pageFullScreen else { return .none }
			state.pageFullScreen = nil
			return .exitPageFullScreen(current.tabID, engine: engine)
		}
	}
}

extension PageFullScreenPresentation {
	/// Commands that act on the page in place, with nothing of the window to show.
	internal static let keepsFullScreen: Set<BrowserCommand> = [
		.zoomIn, .zoomOut, .actualSize, .reload, .stopLoading, .copyURL, .copyCleanLink,
		.copyMarkdownOriginal, .copyProxyLink, .copyMarkdownProxy,
	]
}

/// Ends page full screen once its page stops showing where it fills the screen: another tab or
/// space in that window, a closed tab or window, a Peek put away or promoted.
private struct PageFullScreenFollowing<Base: Reducer>: Reducer
where Base.State == AppFeature.State, Base.Action == AppFeature.Action {
	internal let base: Base

	@Dependency(\.browserEngine)
	private var engine

	internal var body: some Reducer<AppFeature.State, AppFeature.Action> {
		base
		Reduce { state, _ in
			guard
				let current = state.pageFullScreen,
				state.pageFullScreenWindow(showing: current.tabID) != current.windowID
			else { return .none }

			state.pageFullScreen = nil
			return .exitPageFullScreen(current.tabID, engine: engine)
		}
	}
}

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	internal func exitingHiddenPageFullScreen() -> some Reducer<State, Action> {
		PageFullScreenFollowing(base: self)
	}
}

extension Effect where Action == AppFeature.Action {
	fileprivate static func exitPageFullScreen(
		_ tabID: BrowserCore.Tab.ID,
		engine: BrowserEngineClient
	) -> Self {
		.run { _ in

			// A page that already left, or an engine without page full screen, has nothing to do.
			try? await engine.command(tabID, .exitFullScreen)
		}
	}
}

extension AppFeature.State {
	/// Whether ⌘S can show a sidebar beside `fullScreen`'s page: a browser window's own page has
	/// one, while a Peek's page and a Little Arx window don't (DEV-991).
	internal func pageFullScreenCanShowSidebar(_ fullScreen: PageFullScreen) -> Bool {
		let isBrowserWindow = (windowIsOpen && main.id == fullScreen.windowID)
		|| windows[id: fullScreen.windowID] != nil
		return isBrowserWindow && !peeks.contains { $0.tab.id == fullScreen.tabID }
	}

	/// The window whose page area shows the tab now, which its full screen fills: the window a
	/// Peek of it was opened from, its Little Arx window, or a browser window with it in a pane.
	/// Nil while the tab isn't on screen, or while its window shows its own controls over it:
	/// the command bar, the find bar, the Library or another Peek, which full screen would cover.
	internal func pageFullScreenWindow(showing tabID: BrowserCore.Tab.ID) -> UUID? {
		// A page floating in Page PiP (DEV-950) isn't in its window to fill it.
		if pagePictureInPicture?.tabID == tabID { return nil }

		// An agent's approval or sign-in prompt shows in the window, under the page.
		let awaitsPerson = automation.pending.values.contains { $0.awaitingApproval && !$0.approved }
		|| automation.signIn.records.values.contains(where: \.isActive)
		if awaitsPerson { return nil }

		if let peek = peeks.first(where: { $0.tab.id == tabID && $0.viewer.tab?.id == tabID }) {
			// A Peek over Little Arx as Page PiP stays in the floating window (DEV-1112).
			let isShown = peek.phase == .idle
			&& peek.viewer.findQuery == nil
			&& littleWindows[id: peek.source.windowID]?.isPictureInPicture != true
			return isShown ? peek.source.windowID : nil
		}

		if let little = littleWindows.first(where: { $0.tab.id == tabID }) {
			// Little Arx as Page PiP floats instead (DEV-1112).
			let isShown = !little.isCommandOnly
			&& !little.isPictureInPicture
			&& !little.isClosing
			&& !little.isPromoting
			&& !little.commandBar.isPresented
			&& little.viewer.tab?.id == tabID
			&& little.viewer.findQuery == nil
			&& !peeks.contains { $0.source.windowID == little.id }
			return isShown ? little.id : nil
		}

		let browserWindows: [MainFeature.State] = (windowIsOpen ? [main] : []) + Array(windows)
		guard
			let window = browserWindows.first(where: { window in
				!window.isClosing && window.viewer.panes.contains { $0.item.tab?.id == tabID }
			}),
			!window.commandBar.isPresented,
			// The Library opens wider than the sidebar beside the page (DEV-991).
			!window.isLibraryOpen,
			!window.viewer.panes.contains(where: { $0.item.tab?.id == tabID && $0.item.findQuery != nil }),
			!peeks.contains(where: { $0.source.windowID == window.id })
		else { return nil }

		return window.id
	}
}
