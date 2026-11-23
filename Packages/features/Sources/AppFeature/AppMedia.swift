import BrowserCore
import BrowserMediaClient
import Foundation
import MainFeature
import MediaFeature
import _ComposableArchitecture

internal struct MediaReturnIntent: Equatable {
	internal var sourceID: BrowserMediaSource.ID
	internal var context: TabPresentationContext

	internal init(
		sourceID: BrowserMediaSource.ID,
		context: TabPresentationContext
	) {
		self.sourceID = sourceID
		self.context = context
	}
}

/// The wait after a window's full-screen transition before its pages' visibility counts again.
private struct FullScreenSettling: Hashable {
	internal static let duration: Duration = .milliseconds(500)

	internal let windowID: UUID
}

internal enum MediaReturnFailure: Equatable {
	case previewOpen
	case missingSpace
}

@Reducer
internal struct AppMedia {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserMedia)
	private var client

	@Dependency(\.continuousClock)
	private var clock

	internal var body: some ReducerOf<Self> {
		Pullback(\.media) { state, action in
			switch action {
			case let .ui(.returnToTab(id)):
				guard
					state.media.pending == nil,
					let source = state.media.visibleSources.first(where: { $0.id == id }),
					!source.isInPictureInPicture || source.supports(.exitPictureInPicture)
				else { return .none }

				state.mediaReturnFailure = nil
				state.pendingMediaReturn = .init(sourceID: id, context: TabPresentationContext(state))

			case let .event(.activated(id, observationID)):
				guard
					state.media.isObserving,
					observationID == state.media.observationID,
					state.media.visibleSources.contains(where: { $0.id == id })
				else { return .none }

				state.mediaReturnFailure = nil
				state.pendingMediaReturn = .init(sourceID: id, context: TabPresentationContext(state))

			case let .event(.finished(id, failure)) where id == state.media.pending?.id && failure != nil:
				state.pendingMediaReturn = nil

			case let .event(.observationEnded(id)) where id == state.media.observationID:
				state.pendingMediaReturn = nil

			case .ui(.dismissed), .ui(.scopeChanged):
				state.pendingMediaReturn = nil

			default: break
			}

			return .none
		}

		Scope(state: \.media, action: \.media) {
			MediaFeature()
		}

		Pullback(\.media.delegate.automaticPreferencesChanged) { state, preferences in
			let profiles = Set(state.workspace.profiles.map(\.id))
			var ordinary = preferences
			ordinary.enabledSites = ordinary.enabledSites.filter { profiles.contains($0.profileID) }
			ordinary.disabledSites = ordinary.disabledSites.filter { profiles.contains($0.profileID) }

			// A closed tab's choice goes with it.
			ordinary.tabs = ordinary.tabs.filter { state.containsTab($0.key) }
			state.media.automatic = ordinary
			guard state.settings.automaticPictureInPicture != ordinary
			else { return .none }

			// A shared key: AppFeature saves the edit.
			state.settings.$automaticPictureInPicture.withLock { $0 = ordinary }
			return .none
		}

		Pullback(\.event.windowsOnDisplayChanged) { state, ids in
			state.windowsOnDisplay = ids
			return .none
		}

		Pullback(\.media.delegate.presentPagePictureInPicture) { state, id in

			// Little Arx turns into Page PiP itself (DEV-1112).
			if let little = state.littleWindows.first(where: { $0.tab.id == id.tabID }) {
				guard !little.isPictureInPicture else { return .none }
				return .send(.littleWindows(.element(id: little.id, action: .ui(.setPictureInPicture(true)))))
			}

			// One page floats at a time, and an automatic entry never replaces it.
			guard state.pagePictureInPicture == nil else { return .none }

			let open: Action
			if state.pagePictureInPictureSource(of: id.tabID) != nil {
				// Its window still shows the tab, minimised, hidden or full screen on another OS
				// workspace: the page moves from there.
				open = .ui(.openPagePictureInPicture(id.tabID))
			} else if let windowID = state.mediaHostWindows[id.tabID]
				.flatMap({ state.pagePictureInPictureBackgroundTab(id.tabID, in: $0) != nil ? $0 : nil })
				?? state.pagePictureInPictureHome(of: id.tabID)
			{
				// The person switched tabs: the page floats from the window that last showed it.
				open = .ui(.presentTabInPictureInPicture(id.tabID, windowID: windowID))
			} else {
				return .none
			}
			return .concatenate(
				.send(open),
				.send(.event(.automaticPagePictureInPictureRequested(id.tabID)))
			)
		}

		Pullback(\.event.automaticPagePictureInPictureRequested) { state, tabID in

			// Only a Page PiP that started for this request is Arx's to return.
			if state.pagePictureInPicture?.tabID == tabID { state.automaticPagePictureInPicture = tabID }
			return .none
		}

		Pullback(\.event.mediaSurfaceVisibility) { state, value in
			let (windowID, report) = value
			guard state.hasMediaHost(windowID) else { return .none }
			if report.isVisible == nil {
				state.mediaSurfaces[report.hostID] = nil
			} else {
				state.mediaSurfaces[report.hostID] = .init(windowID: windowID, report: report)
			}
			return .none
		}

		Pullback(\.ui.closeWindow) { state in
			state.mediaRehostingSources.formUnion(state.main.viewer.panes.compactMap { $0.item.tab?.id })
			return .none
		}

		Pullback(\.ui.closeAdditionalWindow) { state, id in
			if let window = state.windows[id: id] {
				state.mediaRehostingSources.formUnion(window.viewer.panes.compactMap { $0.item.tab?.id })
			}
			return .none
		}

		Pullback(\.event.browserActivityChanged) { state, isActive in

			// Quitting closes windows, which must not look like leaving the video.
			guard isActive || (!state.shouldQuit && !state.checkingQuit)
			else { return .none }

			return .send(.media(.event(.applicationActivityChanged(isActive: isActive))))
		}

		// A window going in or out of macOS full screen can read as covered while its Space
		// moves, which would float the video a page just put in full screen (DEV-991). Its pages'
		// visibility waits until the transition ends and their reports have caught up.
		Pullback(\.event.windowFullScreenTransition) { state, value in
			let (id, isTransitioning) = value
			if isTransitioning {
				state.fullScreenTransitionWindows.insert(id)
				return .cancel(id: FullScreenSettling(windowID: id))
			}
			guard state.fullScreenTransitionWindows.contains(id) else { return .none }

			return .concatenate(
				.cancel(id: FullScreenSettling(windowID: id)),
				.run { [clock] send in
					try await clock.sleep(for: FullScreenSettling.duration)
					await send(.event(.windowFullScreenTransitionSettled(id)))
				}
				.cancellable(id: FullScreenSettling(windowID: id))
			)
		}

		Pullback(\.event.windowFullScreenTransitionSettled) { state, id in
			state.fullScreenTransitionWindows.remove(id)
			return .none
		}

		Pullback(\.configureMedia) { _ in
			.send(.media(.ui(.appeared)))
		}

		Pullback(\.media) { state, _ in
			let available = state.media.isAvailable
			state.main.mediaAvailable = available

			for id in state.windows.ids {
				let isPrivate = state.windows[id: id]?.isPrivate == true
				state.windows[id: id]?.mediaAvailable = available && !isPrivate
			}

			for id in state.littleWindows.ids {
				state.littleWindows[id: id]?.mediaAvailable = available
			}

			if let intent = state.pendingMediaReturn {
				let sourceIsVisible = state.media.visibleSources.contains { $0.id == intent.sourceID }
				if !sourceIsVisible { state.pendingMediaReturn = nil }
			}

			return .none
		}

		Pullback(\.media.event.changed) { state, _ in

			// Mute isn't part of a media snapshot, so the Media page reads it when the sources change.
			let sources = state.media.visibleSources
			let previous = state.mutedMedia
			state.mutedMedia = MainActor.assumeIsolated { [client] in
				var muted: [BrowserCore.Tab.ID: BrowserMediaSource] = [:]
				for source in sources where client.position(source.id.tabID)?.isMuted == true {
					muted[source.id.tabID] = source
				}

				// A muted page that left its session keeps its row while its tab stays muted.
				for (tabID, source) in previous where muted[tabID] == nil {
					if client.position(tabID)?.isMuted == true { muted[tabID] = source }
				}
				return muted
			}
			state.updateMediaStackOrder()
			return .none
		}

		Pullback(\.ui.openMediaLibrary) { state, sourceID in
			guard
				state.media.isAvailable,
				!state.shouldQuit,
				!state.checkingQuit
			else { return .none }

			state.openMediaLibrary(near: sourceID)
			return .none
		}

		Pullback(\.ui.toggleMediaMute) { state, tabID in
			let isVisible = state.media.visibleSources.contains { $0.id.tabID == tabID }
			guard isVisible || state.mutedMedia[tabID] != nil
			else { return .none }

			let isMuted = state.mutedMedia[tabID] != nil
			return .run { @MainActor [client] send in
				let requested = !isMuted
				let succeeded = (try? client.setMuted(tabID, requested)) != nil
				let fallback = succeeded ? requested : isMuted
				send(.event(.mediaMuteChanged(tabID, client.position(tabID)?.isMuted ?? fallback)))
			}
		}

		Pullback(\.event.mediaMuteChanged) { state, value in
			let (tabID, isMuted) = value
			if isMuted {
				let source = state.media.visibleSources.first { $0.id.tabID == tabID } ?? state.mutedMedia[tabID]
				state.mutedMedia[tabID] = source
			} else {
				state.mutedMedia[tabID] = nil
			}
			state.updateMediaStackOrder()
			return .none
		}

		Pullback(\.ui.returnToMutedMedia) { state, tabID in
			guard
				state.mutedMedia[tabID] != nil,
				!state.media.visibleSources.contains(where: { $0.id.tabID == tabID }),
				!state.shouldQuit,
				!state.checkingQuit,
				let tab = state.workspace.tabs.first(where: { $0.id == tabID }),
				OrdinaryTabPresentation().canFocus(tab, state: state)
			else { return .none }

			state.mediaSourceFocusRequest += 1
			return OrdinaryTabPresentation().focus(tab, state: &state)
		}

		Pullback(\.media.delegate.returnToSource) { state, id in
			let intent = state.pendingMediaReturn
			state.pendingMediaReturn = nil

			guard
				intent?.sourceID == id,
				intent?.context == TabPresentationContext(state),
				!state.shouldQuit,
				!state.checkingQuit,
				state.workspace.profiles.ids.contains(id.profileID),
				state.media.visibleSources.contains(where: { $0.id == id && !$0.isPrivate })
			else { return .none }

			let peek = state.peeks.first { $0.tab.id == id.tabID && $0.tab.profileID == id.profileID }

			if let peek {
				guard
					peek.phase == .idle,
					peek.viewer.tab?.id == id.tabID,
					!state.closingPeekHosts.contains(peek.source.windowID),
					state.hasMediaHost(peek.source.windowID)
				else { return .none }

				guard MainActor.assumeIsolated({ client.isSourceCurrent(id) })
				else { return .none }

				state.focusedWindowID = peek.source.windowID
				state.mediaSourceFocusRequest += 1

				return .none
			}

			let little = state.littleWindows.first { $0.tab.id == id.tabID && $0.tab.profileID == id.profileID }

			if let little {
				guard
					!little.isClosing,
					!little.isPromoting,
					!little.isSwitchingProfile,
					little.viewer.tab?.id == id.tabID
				else { return .none }

				guard !state.peeks.contains(where: { $0.source.windowID == little.id }) else {
					state.showMediaReturnFailure(.previewOpen)
					return .none
				}

				guard MainActor.assumeIsolated({ client.isSourceCurrent(id) })
				else { return .none }

				state.focusedWindowID = little.id
				state.mediaSourceFocusRequest += 1

				return .none
			}

			guard
				let tab = state.workspace.tabs.first(where: { $0.id == id.tabID && $0.profileID == id.profileID }),
				state.workspace.profiles.ids.contains(id.profileID),
				!state.main.isClosing,
				!state.main.transferInProgress,
				([state.main] + Array(state.windows)).allSatisfy({
					!$0.pendingTabCloses.contains(id.tabID)
					&& !$0.transferInProgress
					&& !$0.archive.isWorking
				})
			else { return .none }

			let ownerCandidates: [MainFeature.State] = (state.windowIsOpen ? [state.main] : [])
			+ state.windows.filter { !$0.isPrivate }
			let owner = ownerCandidates.first { $0.viewer.panes.contains { $0.item.tab?.id == id.tabID } }

			guard owner?.isClosing != true else { return .none }

			let ownerID = owner?.id ?? state.main.id
			guard !state.peeks.contains(where: { $0.source.windowID == ownerID }) else {
				state.showMediaReturnFailure(.previewOpen)
				return .none
			}

			let hasPresentationTarget = owner != nil
			|| state.workspace.spaces.contains { space in
				space.profileID == id.profileID
				&& state.workspace.canPresent(id.tabID, in: space.id)
			}

			guard hasPresentationTarget else {
				state.showMediaReturnFailure(.missingSpace)
				return .none
			}

			guard OrdinaryTabPresentation().canFocus(tab, state: state)
			else { return .none }

			// Store reduction and the native read share the main thread without an actor hop.
			// Same-URL reloads may invalidate native identity before Swift events arrive.
			guard MainActor.assumeIsolated({ client.isSourceCurrent(id) })
			else { return .none }

			state.mediaSourceFocusRequest += 1

			return OrdinaryTabPresentation().focus(tab, state: &state)
		}
	}
}

extension AppFeature.State {
	/// Lists every tab with media now, a muted page that left its session included, so the stack
	/// keeps their places and forgets the rest (DEV-1245). Media that went inactive is gone from
	/// the page, so it starts again at the end.
	internal mutating func updateMediaStackOrder() {
		let active = media.visibleSources.lazy
			.filter { $0.playback != .inactive }
			.map(\.id.tabID)
		let muted = mutedMedia.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
		mediaStackOrder.update(listing: Array(active) + muted)
	}

	/// A profile's ordinary media in stack order, muted pages that left their session included:
	/// what the sidebar's stack and the Media page list.
	internal func mediaStack(of profileID: Profile.ID) -> [BrowserMediaSource] {
		let visible = media.visibleSources.filter { $0.id.profileID == profileID && !$0.isPrivate }
		let visibleTabs = Set(visible.map(\.id.tabID))
		let muted = mutedMedia.values.filter {
			$0.id.profileID == profileID && !$0.isPrivate && !visibleTabs.contains($0.id.tabID)
		}
		return mediaStackOrder.sorted(visible + muted.sorted { $0.title < $1.title })
	}

	fileprivate mutating func showMediaReturnFailure(_ failure: MediaReturnFailure) {
		mediaReturnFailure = failure
		openMediaLibrary(near: focusedWindowID)
	}

	/// Shows the Library's Media page in `sourceID`'s window when it's an ordinary one with a sidebar,
	/// otherwise in the main window or another ordinary one, reopening the main window when none is open.
	/// Private windows and Little Arx have no Media page.
	internal mutating func openMediaLibrary(near sourceID: UUID?) {
		func canShow(_ window: MainFeature.State) -> Bool {
			!window.isPrivate && !window.isClosing && window.librarySections.contains(.media)
		}

		let mainCanShow = windowIsOpen && canShow(main)
		let id: UUID? = if let sourceID, sourceID == main.id, mainCanShow {
			sourceID
		} else if let sourceID, let window = windows[id: sourceID], canShow(window) {
			sourceID
		} else if mainCanShow {
			main.id
		} else if let window = windows.first(where: canShow) {
			window.id
		} else if !windowIsOpen, !main.isPrivate, main.librarySections.contains(.media) {
			main.id
		} else {
			nil
		}
		guard let id else { return }

		// Launch onboarding holds the main window back until it ends (DEV-838).
		if id == main.id, !openMainWindow() { return }

		focusedWindowID = id
		if id == main.id {
			main.librarySelection = .media
			main.isLibraryOpen = true
			main.sidebar.sidebarIsVisible = true
		} else {
			windows[id: id]?.librarySelection = .media
			windows[id: id]?.isLibraryOpen = true
			windows[id: id]?.sidebar.sidebarIsVisible = true
		}
	}

	internal func hasMediaHost(_ id: UUID) -> Bool {
		if id == main.id { return windowIsOpen && !main.isClosing }

		if let window = windows[id: id] {
			return !window.isPrivate && !window.isClosing
		}

		if let window = littleWindows[id: id] {
			return !window.isClosing && !window.isPromoting && !window.isSwitchingProfile
		}

		return false
	}
}

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	/// Media reads automatic Picture in Picture from its own copy; this keeps it in step with
	/// Settings, an import or MCP, whichever reducer changed the shared preference.
	internal func followingAutomaticPictureInPicture() -> some Reducer<State, Action> {
		onChange(of: \.settings.automaticPictureInPicture) { _, state in
			state.media.automatic = state.settings.automaticPictureInPicture
			return .none
		}
	}
}
