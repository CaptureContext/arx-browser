import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

/// A browser window closed in this session, kept so Reopen Closed Window can bring it back
/// (DEV-908). Spaces and their tabs outlive their windows, so a window is its space and the
/// tab it showed; a Split View that tab belongs to comes back with it.
public struct RecentlyClosedWindow: Equatable, Identifiable, Sendable {
	public var id: UUID
	public var spaceID: Space.ID
	public var tabID: BrowserCore.Tab.ID?

	/// The main window opens again as itself; other windows open as new windows.
	public var isMain: Bool

	/// The open tabs the window kept while windows are independent (DEV-822). They go to the main
	/// window when it closes, and reopening it takes back those still there.
	public var openTabs: [BrowserCore.Tab.ID]

	public init(
		id: UUID,
		spaceID: Space.ID,
		tabID: BrowserCore.Tab.ID?,
		isMain: Bool,
		openTabs: [BrowserCore.Tab.ID] = []
	) {
		self.id = id
		self.spaceID = spaceID
		self.tabID = tabID
		self.isMain = isMain
		self.openTabs = openTabs
	}
}

/// Archive ▸ Recently Closed (DEV-908): the windows closed in this session, newest last.
@Reducer
internal struct RecentlyClosed {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	/// How many closed windows the menu offers.
	internal static let windowLimit: Int = 10

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		// Runs before the window-lifecycle reducers remove the window. A window with a Peek
		// open closes the Peek first and is asked to close again afterwards.
		Pullback(\.ui.closeWindow) { state in
			guard
				state.windowIsOpen,
				!state.peeks.contains(where: { $0.source.windowID == state.main.id })
			else { return .none }

			state.rememberClosedWindow(state.main, isMain: true)
			return .none
		}

		Pullback(\.ui.closeAdditionalWindow) { state, id in
			guard
				let window = state.windows[id: id],
				!window.isPrivate,
				!state.peeks.contains(where: { $0.source.windowID == id })
			else { return .none }

			state.rememberClosedWindow(window, isMain: false)
			return .none
		}

		Pullback(\.ui.reopenClosedWindow) { state, id in
			guard
				!state.shouldQuit,
				!state.checkingQuit,
				!state.mainWindowWaitsForOnboarding,
				let closed = state.reopenableClosedWindow(id)
			else { return .none }

			state.recentlyClosedWindows.removeAll { $0.id == closed.id }

			if closed.isMain {
				guard state.openMainWindow() else { return .none }
				state.focusedWindowID = state.main.id
				return .send(.main(.ui(.task)))
			}

			let windowID = uuid()
			state.appendBrowserWindow(windowID, spaceID: closed.spaceID)

			// Its open tabs the main window still has come back to it; one moved elsewhere since
			// stays where it is (DEV-822).
			// One the main window shows or has selected stays there.
			state.giveOpenTabs(
				closed.openTabs.filter { state.windowTabOwners[$0] == nil && !state.isInUse($0, excluding: windowID) },
				to: windowID
			)
			guard
				let tabID = closed.tabID,
				state.workspace.canPresent(tabID, in: closed.spaceID),
				let window = state.windows[id: windowID],
				window.sidebar.windowShows(tabID)
			else { return .none }

			return .send(.windows(.element(
				id: windowID,
				action: .present(tabID, in: window.viewer.activePaneID)
			)))
		}

		Pullback(\.ui.reopenArchivedTab) { state, id in
			guard
				!state.shouldQuit,
				!state.checkingQuit,
				let target = state.recentlyClosedTabTarget
			else { return .none }

			let action = MainFeature.Action.ui(.reopenArchivedTab(id))
			return target == state.main.id
			? .send(.main(action))
			: .send(.windows(.element(id: target, action: action)))
		}
	}
}

extension AppFeature.State {
	fileprivate mutating func rememberClosedWindow(
		_ window: MainFeature.State,
		isMain: Bool
	) {
		guard workspace.spaces[id: window.sidebar.spaceID] != nil else { return }

		recentlyClosedWindows.removeAll { $0.id == window.id }
		recentlyClosedWindows.append(.init(
			id: window.id,
			spaceID: window.sidebar.spaceID,
			tabID: window.viewer.item.tab?.id,
			isMain: isMain,
			openTabs: isMain ? [] : openTabs(ownedBy: window.id)
		))
		if recentlyClosedWindows.count > RecentlyClosed.windowLimit {
			recentlyClosedWindows.removeFirst(recentlyClosedWindows.count - RecentlyClosed.windowLimit)
		}
	}

	/// The closed window `id` names, or the newest when nil, while it can still open: its space
	/// still exists and, for the main window, the main window is closed.
	internal func reopenableClosedWindow(_ id: UUID?) -> RecentlyClosedWindow? {
		recentlyClosedWindows.last { closed in
			(id == nil || closed.id == id)
			&& workspace.spaces[id: closed.spaceID] != nil
			&& (!closed.isMain || !windowIsOpen)
		}
	}

	/// Whether Reopen Closed Window can open one now.
	internal var canReopenClosedWindow: Bool { reopenableClosedWindow(nil) != nil }

	/// The ordinary window whose profile's archive Recently Closed lists: the focused one, else
	/// the main window while it's open.
	internal var recentlyClosedTabTarget: UUID? {
		if let id = focusedWindowID, let window = windows[id: id], !window.isPrivate { return id }
		if let id = focusedWindowID, id == main.id, windowIsOpen { return id }
		return windowIsOpen ? main.id : nil
	}

	/// Recently Closed's tabs: the newest archived tabs of `recentlyClosedTabTarget`'s profile,
	/// newest first.
	internal func recentlyClosedTabs(limit: Int = 15) -> [ArchivedTab] {
		guard
			let id = recentlyClosedTabTarget,
			let window = id == main.id ? main : windows[id: id]
		else { return [] }

		let profileID = window.sidebar.space.profileID
		return Array(
			workspace.archive
				.filter { $0.tab.profileID == profileID }
				.sorted { $0.closedAt > $1.closedAt }
				.prefix(limit)
		)
	}
}
