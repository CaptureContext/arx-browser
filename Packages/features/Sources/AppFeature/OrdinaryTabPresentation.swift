import BrowserCore
import Foundation
import MainFeature
import PeekFeature
import ViewerFeature
import _ComposableArchitecture

/// Captures host and navigation identity, excluding cosmetic titles, across deferred presentation.
public struct TabPresentationContext: Equatable, Sendable {
	internal var mainIsOpen: Bool
	internal var focusedWindowID: UUID?
	internal var windowActivationRevision: Int
	internal var windows: [Window]
	internal var littleWindows: [LittleWindow]
	internal var settingsIsOpen: Bool
	internal var settingsFocusRequest: Int
	internal var downloadsIsPresented: Bool
	internal var downloadsFocusRequest: Int
	internal var mediaSourceFocusRequest: Int
	internal var captureIDs: [UUID]
	internal var routePreviewID: UUID?
	internal var automationIsPresented: Bool
	internal var peeks: [Peek]
	internal var isQuitting: Bool

	internal struct Window: Equatable, Sendable {
		internal var id: UUID
		internal var spaceID: Space.ID
		internal var profileID: Profile.ID
		internal var selectedTabID: BrowserCore.Tab.ID?
		internal var displayedSpaceID: Space.ID?
		internal var requestedSpaceID: Space.ID?
		internal var activePaneID: UUID
		internal var panes: [Pane]
		internal var commandBarIsPresented: Bool
		internal var commandBarFocusRequest: Int
		internal var commandBarPresentationID: Int?
		internal var archiveIsPresented: Bool
		internal var isBusy: Bool
	}

	internal struct LittleWindow: Equatable, Sendable {
		internal var id: UUID
		internal var spaceID: Space.ID
		internal var profileID: Profile.ID
		internal var tabID: BrowserCore.Tab.ID
		internal var viewerTabID: BrowserCore.Tab.ID?
		internal var viewerProfileID: Profile.ID?
		internal var generation: Int
		internal var navigation: Navigation
		internal var commandBarIsPresented: Bool
		internal var commandBarFocusRequest: Int
		internal var commandBarPresentationID: Int?
		internal var isBusy: Bool
	}

	internal struct Pane: Equatable, Sendable {
		internal var id: UUID
		internal var tabID: BrowserCore.Tab.ID?
		internal var profileID: Profile.ID?
		internal var generation: Int
		internal var navigation: Navigation
	}

	internal struct Navigation: Equatable, Sendable {
		internal var url: URL?
		internal var currentEntryID: Int?
		internal var currentEntryURL: URL?
		internal var isLoading: Bool
		internal var errorCode: Int?

		internal init(_ navigation: BrowserNavigation) {
			self.url = navigation.url

			let current = navigation.history.first(where: \.isCurrent)
			self.currentEntryID = current?.id
			self.currentEntryURL = current?.url
			self.isLoading = navigation.isLoading
			self.errorCode = navigation.errorCode
		}
	}

	internal struct Peek: Equatable, Sendable {
		internal var id: UUID
		internal var windowID: UUID
		internal var paneID: UUID
		internal var sourceTabID: BrowserCore.Tab.ID?
		internal var spaceID: Space.ID
		internal var profileID: Profile.ID
		internal var tabID: BrowserCore.Tab.ID
		internal var tabProfileID: Profile.ID
		internal var viewerTabID: BrowserCore.Tab.ID?
		internal var viewerProfileID: Profile.ID?
		internal var generation: Int
		internal var navigation: Navigation
		internal var phase: PeekFeature.Phase
		internal var isTemporary: Bool
		internal var replacementURL: URL?
		internal var orphanCloseRequested: Bool
		internal var hostIsClosing: Bool
		internal var hasPendingTransition: Bool
	}

	internal init(_ state: AppFeature.State) {
		self.mainIsOpen = state.windowIsOpen
		self.focusedWindowID = state.focusedWindowID
		self.windowActivationRevision = state.windowActivationRevision
		self.windows = ([state.main] + Array(state.windows)).map { window in
			.init(
				id: window.id,
				spaceID: window.sidebar.spaceID,
				profileID: window.sidebar.space.profileID,
				selectedTabID: window.sidebar.selectedTab?.id,
				displayedSpaceID: window.viewer.spaceID,
				requestedSpaceID: window.viewer.requestedSpaceID,
				activePaneID: window.viewer.activePaneID,
				panes: window.viewer.panes.map {
					.init(
						id: $0.id,
						tabID: $0.item.tab?.id,
						profileID: $0.item.tab?.profileID,
						generation: $0.item.generation,
						navigation: .init($0.item.navigation)
					)
				},
				commandBarIsPresented: window.commandBar.isPresented,
				commandBarFocusRequest: window.commandBar.focusRequest,
				commandBarPresentationID: window.commandBarContext?.presentationID,
				archiveIsPresented: window.archive.isPresented,
				isBusy: window.isClosing
				|| window.transferInProgress
				|| window.archive.isWorking
				|| window.pendingFolderDeletion != nil
				|| !window.pendingTabCloses.isEmpty
			)
		}
		self.littleWindows = state.littleWindows.map { window in
			.init(
				id: window.id,
				spaceID: window.spaceID,
				profileID: window.tab.profileID,
				tabID: window.tab.id,
				viewerTabID: window.viewer.tab?.id,
				viewerProfileID: window.viewer.tab?.profileID,
				generation: window.viewer.generation,
				navigation: .init(window.viewer.navigation),
				commandBarIsPresented: window.commandBar.isPresented,
				commandBarFocusRequest: window.commandBar.focusRequest,
				commandBarPresentationID: window.commandBarContext?.presentationID,
				isBusy: window.isClosing || window.isPromoting || window.isSwitchingProfile
			)
		}
		self.settingsIsOpen = state.settingsIsOpen
		self.settingsFocusRequest = state.settingsFocusRequest
		self.downloadsIsPresented = state.downloads.isPresented
		self.downloadsFocusRequest = state.downloadsFocusRequest
		self.mediaSourceFocusRequest = state.mediaSourceFocusRequest
		self.captureIDs = state.captureSessions.map(\.id)
		self.routePreviewID = state.routePreview?.id
		self.automationIsPresented = state.automation.isPresented
		self.peeks = state.peeks.map { peek in
			.init(
				id: peek.id,
				windowID: peek.source.windowID,
				paneID: peek.source.paneID,
				sourceTabID: peek.source.tabID,
				spaceID: peek.source.spaceID,
				profileID: peek.source.profileID,
				tabID: peek.tab.id,
				tabProfileID: peek.tab.profileID,
				viewerTabID: peek.viewer.tab?.id,
				viewerProfileID: peek.viewer.tab?.profileID,
				generation: peek.viewer.generation,
				navigation: .init(peek.viewer.navigation),
				phase: peek.phase,
				isTemporary: peek.isTemporary,
				replacementURL: peek.replacementURL,
				orphanCloseRequested: peek.orphanCloseRequested,
				hostIsClosing: state.closingPeekHosts.contains(peek.source.windowID),
				hasPendingTransition: state.peekTransitions[peek.id] != nil
			)
		}
		self.isQuitting = state.checkingQuit || state.shouldQuit
	}

	/// The context without any page's load progress (``Navigation/isLoading`` and
	/// ``Navigation/errorCode``), which a page changes on its own, such as a subframe loading in a
	/// background page, without anyone asking for it (DEV-1078). A new address or history entry
	/// still counts.
	internal var ignoringLoadProgress: Self {
		var context = self
		for window in context.windows.indices {
			for pane in context.windows[window].panes.indices {
				context.windows[window].panes[pane].navigation.ignoreLoadProgress()
			}
		}
		for little in context.littleWindows.indices {
			context.littleWindows[little].navigation.ignoreLoadProgress()
		}
		for peek in context.peeks.indices {
			context.peeks[peek].navigation.ignoreLoadProgress()
		}
		return context
	}
}

extension TabPresentationContext.Navigation {
	fileprivate mutating func ignoreLoadProgress() {
		isLoading = false
		errorCode = nil
	}
}

@Reducer
internal struct OrdinaryTabPresentation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.resumeTabPresentation) { state, context in
			var current = TabPresentationContext(state)

			// Native activation can acknowledge the focus this layout already committed.
			// Resuming attaches those panes without taking focus again; all other identity
			// checks remain strict, as does activation for precommit callers.
			current.windowActivationRevision = context.windowActivationRevision

			guard context == current else { return .none }

			let continuing = state.main.viewer.continuingPaneIDs
			state.main.viewer.continuingPaneIDs = []
			return .merge(state.main.viewer.panes.filter { !continuing.contains($0.id) }.map { pane in
				AppFeature()._reduce(
					into: &state,
					action: .main(.viewer(.panes(.element(
						id: pane.id,
						action: .item(.show(pane.item.tab))
					))))
				)
			})
		}
	}

	internal func canFocus(
		_ tab: BrowserCore.Tab,
		state: State
	) -> Bool {
		placement(of: tab, in: state) != nil
	}

	private enum Placement {
		case mounted(windowID: UUID, paneID: UUID)
		case unmounted(Space.ID)
	}

	private func placement(
		of tab: BrowserCore.Tab,
		in state: State
	) -> Placement? {
		// Favorites can outlive their profile's last Space. Resolve a valid placement
		// before touching focus or selection, including when a stale host still owns the page.
		guard
			state.workspace.tabs[id: tab.id]?.profileID == tab.profileID,
			let destination = state.workspace.spaces.first(where: {
				$0.profileID == tab.profileID && state.workspace.canPresent(tab.id, in: $0.id)
			})
		else { return nil }

		let hosts = (state.windowIsOpen ? [state.main] : []) + state.windows.filter { !$0.isPrivate }
		let owner = hosts.first { $0.viewer.panes.contains { $0.item.tab?.id == tab.id } }
		let pane = owner?.viewer.panes.first { $0.item.tab?.id == tab.id }

		if let owner, let pane {
			guard
				state.workspace.canPresent(tab.id, in: owner.sidebar.spaceID),
				owner.sidebar.space.profileID == tab.profileID,
				owner.sidebar.organization.canPresent(tab.id, in: owner.sidebar.spaceID)
			else { return nil }

			return .mounted(windowID: owner.id, paneID: pane.id)
		}

		guard
			state.main.sidebar.organization.spaces.contains(where: {
				$0.id == destination.id && $0.profileID == tab.profileID
			}),
			state.main.sidebar.organization.canPresent(tab.id, in: destination.id)
		else { return nil }

		return .unmounted(destination.id)
	}

	internal func focus(
		_ tab: BrowserCore.Tab,
		state: inout State
	) -> Effect<Action> {
		guard let placement = placement(of: tab, in: state)
		else { return .none }

		switch placement {
		case let .mounted(windowID, paneID):
			state.focusedWindowID = windowID
			let action = MainFeature.Action.viewer(.ui(.focus(paneID)))
			let effect = AppFeature()._reduce(
				into: &state,
				action: windowID == state.main.id ? .main(action) : .windows(.element(id: windowID, action: action))
			)

			return .merge(effect, publishRevealedFolders(from: windowID, state: &state))

		case let .unmounted(spaceID):
			// An open tab another window keeps shows there (DEV-822).
			if
				case .unpinned = state.workspace.location(of: tab.id),
				let windowID = state.windowTabOwners[tab.id],
				state.independentWindows,
				let window = state.windows[id: windowID],
				!window.isClosing
			{
				state.focusedWindowID = windowID
				guard window.sidebar.spaceID != spaceID else { return state.send(.ui(.selectTab(tab.id)), to: windowID) }

				return .concatenate(
					state.send(.sidebar(.ui(.spaceSelected(spaceID))), to: windowID),
					state.send(.ui(.selectTab(tab.id)), to: windowID)
				)
			}
			state.main.sidebar.selectSpace(spaceID)
		}

		state.main.sidebar.select(tab.id)

		// Held back by launch onboarding, the main window still presents the tab, so it shows
		// it once it opens (DEV-838).
		if state.openMainWindow() { state.focusedWindowID = state.main.id }
		let spaceID = state.main.sidebar.spaceID

		guard state.main.viewer.spaceID != spaceID else {
			let effect = AppFeature()._reduce(
				into: &state,
				action: .main(.viewer(.show(tab, in: state.main.viewer.activePaneID)))
			)

			return .merge(effect, publishRevealedFolders(from: state.main.id, state: &state))
		}

		state.main.viewer.requestedSpaceID = spaceID
		let claimed = Set(
			state.windows.flatMap { $0.viewer.panes.compactMap { $0.item.tab?.id } }
			+ state.peeks.map { $0.tab.id }
		)
		.union(state.otherWindowsOpenTabs(for: state.main.id))
		let effect = AppFeature()._reduce(
			into: &state,
			action: .main(.viewer(.selectSpace(
				spaceID,
				state.main.sidebar.organization,
				selected: tab,
				selectRequested: true,
				excluding: claimed
			)))
		)
		let published = publishRevealedFolders(from: state.main.id, state: &state)
		let context = TabPresentationContext(state)

		return .merge(published, effect.map { action in

			// Space restoration emits a resume action. Bind it to the resulting layout,
			// so a close, Peek, pane replacement or newer choice cannot revive old hosts.
			if case .main(.viewer(.resume)) = action {
				return .resumeTabPresentation(context)
			}

			return action
		})
	}

	private func publishRevealedFolders(
		from hostID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard let host = hostID == state.main.id ? state.main : state.windows[id: hostID]
		else { return .none }

		let revealed = Set(host.sidebar.organization.folders.filter(\.isExpanded).map(\.id))

		guard state.workspace.folders.contains(where: { revealed.contains($0.id) && !$0.isExpanded })
		else { return .none }

		// Selecting a pinned page reveals its ancestors. This persisted presentation
		// change must publish too, or the next IPC response sees an unsynchronized host.
		for index in state.workspace.folders.indices
		where revealed.contains(state.workspace.folders[index].id) {
			state.workspace.folders[index].isExpanded = true
		}

		let folders = state.workspace.folders
		state.main.sidebar.organization.folders = folders

		for id in state.windows.filter({ !$0.isPrivate }).map(\.id) {
			state.windows[id: id]?.sidebar.organization.folders = folders
		}

		state.unsavedOrganization = state.workspace

		return .send(.delegate(.save(state.workspace)))
	}
}

extension BrowserOrganization {
	internal func canPresent(
		_ tabID: BrowserCore.Tab.ID,
		in spaceID: Space.ID
	) -> Bool {
		guard let space = spaces.first(where: { $0.id == spaceID })
		else { return false }

		return switch location(of: tabID) {
		case .favorite(space.profileID), .unpinned(spaceID), .pinned(spaceID, _): true
		default: false
		}
	}
}
