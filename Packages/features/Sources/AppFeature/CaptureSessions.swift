import AppUI
import BrowserCaptureClient
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import ChatFeature
import Foundation
import MainFeature
import SwiftUI
import PageCaptureFeature
import ViewerItemFeature
import _ComposableArchitecture

extension AppFeature.State {
	internal func captureSource(for target: AppFeature.CommandTarget) -> CaptureSource? {
		// A page floating in Page PiP (DEV-950) has no place in its window to draw a capture's
		// controls over; it's captured once it's back.
		guard pagePictureInPictureTab(for: target).map({ $0 != pagePictureInPicture?.tabID }) ?? true
		else { return nil }

		switch target {
		case let .window(id, paneID):
			let window = id == main.id && windowIsOpen ? main : windows[id: id]
			let pane = window.flatMap { $0.viewer.panes[id: paneID ?? $0.viewer.activePaneID] }
			let tab = pane?.item.tab

			if let window, let pane, let tab {
				return .init(
					host: .pane(windowID: id, paneID: pane.id),
					tabID: tab.id,
					profileID: tab.profileID,
					spaceID: window.sidebar.spaceID
				)
			}

			if paneID == nil, let little = littleWindows[id: id], let tab = little.viewer.tab {
				return .init(
					host: .little(id),
					tabID: tab.id,
					profileID: tab.profileID,
					spaceID: little.spaceID
				)
			}

		case let .peek(id):
			if let peek = peeks[id: id] {
				return .init(
					host: .peek(id),
					tabID: peek.tab.id,
					profileID: peek.tab.profileID,
					spaceID: peek.source.spaceID
				)
			}

		default: break
		}

		return nil
	}

	internal func captureViewer(for source: CaptureSource) -> ViewerItemFeature.State? {
		guard !shouldQuit, !checkingQuit else { return nil }

		let viewer: ViewerItemFeature.State?

		switch source.host {
		case let .pane(windowID, paneID):
			guard
				!peeks.contains(where: { $0.source.windowID == windowID }),
				let window = windowID == main.id && windowIsOpen ? main : windows[id: windowID],
				window.sidebar.spaceID == source.spaceID,
				window.sidebar.space.profileID == source.profileID,
				!window.isClosing,
				!window.transferInProgress,
				!window.pendingTabCloses.contains(source.tabID)
			else { return nil }

			switch window.sidebar.organization.location(of: source.tabID) {
			case .favorite(source.profileID), .unpinned(source.spaceID), .pinned(source.spaceID, _): break
			default: return nil
			}

			viewer = window.viewer.panes[id: paneID]?.item

		case let .little(id):
			guard
				let little = littleWindows[id: id],
				little.peekID == nil,
				little.spaceID == source.spaceID,
				!little.isClosing,
				!little.isPromoting,
				!little.isSwitchingProfile
			else { return nil }

			viewer = little.viewer

		case let .peek(id):
			guard
				let peek = peeks[id: id],
				peek.source.spaceID == source.spaceID,
				peek.phase == .idle
			else { return nil }

			viewer = peek.viewer
		}

		guard viewer?.tab?.id == source.tabID, viewer?.tab?.profileID == source.profileID
		else { return nil }

		return viewer
	}

	/// The window whose chat a capture of `source` goes to: an ordinary window's page only.
	internal func captureChatWindow(for source: CaptureSource) -> MainFeature.State? {
		guard
			case let .pane(windowID, _) = source.host,
			let window = window(windowID),
			!window.isPrivate,
			window.sidebar.space.profileID == source.profileID
		else { return nil }

		return window
	}

	/// Send to Chat (DEV-798): opens the window's chat and attaches the capture to its composer.
	internal mutating func sendCaptureToChat(
		_ id: UUID,
		image: PageCaptureImage,
		title: String
	) -> Effect<AppFeature.Action> {
		guard
			let session = captureSessions[id: id],
			let window = captureChatWindow(for: session.source)
		else { return .none }

		let profileID: Profile.ID = session.source.profileID
		prepareChat(profileID)
		guard chats[id: profileID] != nil
		else { return .none }

		let pageURL: String? = captureViewer(for: session.source)?.navigation.url?.absoluteString
		let attach: AppFeature.Action = .chats(.element(id: profileID, action: .surfaces(.element(
			id: window.chatSurfaceID,
			action: .ui(.imageAdded(image.png, name: ChatAttachmentNames.capture(title: title), pageURL: pageURL))
		))))
		return .concatenate(
			window.isChatOpen ? .none : send(.ui(.chatOpenChanged(true)), to: window.id),
			.send(attach)
		)
	}

	/// Pixels and node bounds are read only for a live session whose page is still the
	/// one it was prepared for, in the same place, at the same revision.
	internal func captureCanExecute(
		_ id: UUID,
		request: PageCaptureRequest,
		snapshot: BrowserSessionSnapshot?
	) -> Bool {
		guard
			captureAvailable,
			let session = captureSessions[id: id],
			session.preparation == nil,
			session.request == request,
			let viewer = captureViewer(for: session.source),
			viewer.generation == session.sourceGeneration,
			snapshot?.revision == request.revision
		else { return false }

		return true
	}
}

@Reducer
internal struct CaptureSessions {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserCapture)
	private var capture

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	private struct Preparation: Hashable {
		internal var id: UUID

		internal init(id: UUID) { self.id = id }
	}

	/// Starts a capture of `target`'s page. From a chat's + menu (`.chat`), only where that
	/// window's chat can take it (DEV-798).
	private func startCapture(
		target: AppFeature.CommandTarget,
		origin: CaptureSource?,
		mode: PageCaptureFeature.Mode,
		destination: PageCaptureFeature.Destination,
		framing: DeviceCaptureStyle? = nil,
		_ state: inout State
	) -> Effect<Action> {
		guard
			state.captureAvailable,
			let context = state.commandContext(for: target),
			BrowserCommand.captureViewport.isEnabled(in: context),
			let source = origin ?? state.captureSource(for: target),
			let viewer = state.captureViewer(for: source)
		else { return .none }

		let allowsChat: Bool = state.captureChatWindow(for: source) != nil
		guard destination == .menu || allowsChat
		else { return .none }

		// One capture per page: starting again replaces the one already on it.
		let replaced = state.captureSessions.filter { $0.source.tabID == source.tabID }.map(\.id)
		var effects: [Effect<Action>] = replaced.map { .send(.ui(.closeCapture($0))) }

		let id = uuid()
		state.captureSessions.append(.init(
			id: id,
			source: source,
			title: viewer.navigation.title,
			mode: mode,
			sourceGeneration: viewer.generation,
			allowsSendingToChat: allowsChat,
			destination: destination,
			framing: framing,
			capturesBeyondViewport: state.captureBeyondViewportEnabled
		))
		effects.append(.send(.prepareCapture(id)))
		return .concatenate(effects)
	}

	internal var body: some ReducerOf<Self> {
		Pullback(\.configureCapture) { _ in
			.run { [capture] send in
				await send(.event(.captureCapability(capture.isAvailable())))
			}
		}

		Pullback(\.event.captureCapability) { state, available in
			state.captureAvailable = available
			state.main.captureAvailable = available

			for id in state.windows.ids {
				state.windows[id: id]?.captureAvailable = available
			}

			for id in state.littleWindows.ids {
				state.littleWindows[id: id]?.captureAvailable = available
			}

			return .none
		}

		// Capture Page… takes the whole page; Capture Area… picks a block or an area.
		Pullback(\.ui.capturePage) { state, value in
			let (target, origin, region) = value
			return startCapture(
				target: target,
				origin: origin,
				mode: region ? .area : .page,
				destination: .menu,
				&state
			)
		}

		// DEV-757: only with the ARX_DEVICE_CAPTURE feature flag on. A device shows what's on its
		// screen, so it frames the visible area.
		Pullback(\.ui.captureDevice) { state, value in
			let (target, style) = value
			guard state.deviceCaptureEnabled else { return .none }
			return startCapture(
				target: target,
				origin: nil,
				mode: .visible,
				destination: .menu,
				framing: style,
				&state
			)
		}

		// A chat gets the visible area: a model shrinks a whole tall page until it can't be read.
		Pullback(\.ui.capturePageForChat) { state, value in
			let (windowID, region) = value
			return startCapture(
				target: .window(windowID),
				origin: nil,
				mode: region ? .area : .visible,
				destination: .chat,
				&state
			)
		}

		Pullback(\.prepareCapture) { state, id in
			guard var session = state.captureSessions[id: id]
			else { return .none }

			session.reset()
			guard
				state.captureAvailable,
				let viewer = state.captureViewer(for: session.source)
			else {
				state.captureSessions[id: id] = session
				return .merge(.cancel(id: Preparation(id: id)), .send(.ui(.closeCapture(id))))
			}

			let token = uuid()
			session.preparation = token
			session.sourceGeneration = viewer.generation
			session.title = viewer.navigation.title
			state.captureSessions[id: id] = session
			let tabID = session.source.tabID

			let preparation: Effect<Action> = .run { [engine] send in
				let snapshot = await engine.snapshot(tabID)
				try Task.checkCancellation()
				await send(.event(.capturePrepared(id, token, snapshot)))
			}
			.cancellable(id: Preparation(id: id))

			// `cancelInFlight` cancels when the effect's task registers, which happens off the
			// main actor, so an older preparation could cancel this one. Cancel synchronously in
			// reducer order; an older preparation that registers later only reads a snapshot,
			// and its token no longer matches.
			return .concatenate(.cancel(id: Preparation(id: id)), preparation)
		}

		Pullback(\.event.capturePrepared) { state, value in
			let (id, token, snapshot) = value

			guard
				var session = state.captureSessions[id: id],
				session.preparation == token
			else { return .none }

			session.preparation = nil

			guard
				state.captureAvailable,
				let viewer = state.captureViewer(for: session.source),
				viewer.generation == session.sourceGeneration,
				let snapshot
			else {
				state.captureSessions[id: id] = session
				return .send(.ui(.closeCapture(id)))
			}

			session.request = .init(tabID: session.source.tabID, revision: snapshot.revision)
			session.inspection = snapshot.documentRevision.map { documentRevision in
				.init(
					tabID: session.source.tabID,
					profileID: session.source.profileID,
					sessionRevision: snapshot.revision,
					documentRevision: documentRevision,
					scopeID: uuid()
				)
			}
			state.captureSessions[id: id] = session

			return .send(.captureSessions(.element(id: id, action: .prepared)))
		}

		Pullback(\.captureSessions) { state, action in
			switch action {
			case let .element(id, .delegate(.dismiss)): .send(.ui(.closeCapture(id)))
			case let .element(id, .delegate(.retake)): .send(.prepareCapture(id))
			case let .element(id, .delegate(.sendToChat(image, title))): state.sendCaptureToChat(id, image: image, title: title)
			default: .none
			}
		}

		Pullback(\.ui.closeCapture) { state, id in

			// Removing the child cancels its scoped capture, inspection and export effects.
			state.captureSessions.remove(id: id)
			return .cancel(id: Preparation(id: id))
		}
	}
}

/// Draws a page's capture session above its surface, wherever the page is shown.
@MainActor
internal func pageCaptureOverlay(store: StoreOf<AppFeature>) -> BrowserPageOverlay {
	.init { tabID in
		guard
			let id = store.captureSessions.first(where: { $0.source.tabID == tabID })?.id,
			let child = store.scope(state: \.captureSessions[id: id], action: \.captureSessions[id: id])
		else { return nil }

		return AnyView(
			PageCaptureOverlay(store: child)
				.id(id)

				// Switching tabs or closing the window ends the capture.
				.onDisappear {
					guard store.captureSessions[id: id] != nil else { return }
					store.send(.ui(.closeCapture(id)))
				}
		)
	}
}
