import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import Foundation
import LittleArxFeature
import MainFeature
import PeekFeature
import _ComposableArchitecture

/// Owns page transfers; a Peek never becomes a second organization or renderer owner.
@Reducer
internal struct PeekPresentation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.browserSurface)
	private var surface

	@Dependency(\.date.now)
	private var now

	@Dependency(\.uuid)
	private var uuid

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.resetPeekPresentation) { state, value in
			let (id, tabID, generation) = value
			guard
				let peek = state.peeks[id: id],
				!peek.isTemporary,
				peek.tab.id == tabID,
				peek.viewer.generation == generation,
				peek.phase == .idle
			else { return .none }
			return .run { @MainActor [engine] send in
				guard engine.snapshot(tabID) == nil else { return }
				send(.finishResetPeekPresentation(id, tabID: tabID, generation: generation))
			}
		}

		Pullback(\.finishResetPeekPresentation) { state, value in
			let (id, tabID, generation) = value
			guard
				let peek = state.peeks[id: id],
				!peek.isTemporary,
				peek.tab.id == tabID,
				peek.viewer.generation == generation,
				peek.phase == .idle
			else { return .none }
			return .merge(.cancel(id: PeekPromotionID(id: id)), release(id, transition: .dismiss, state: &state))
		}

		Pullback(\.ui.peekURL) { state, value in
			let (url, windowID, paneID) = value
			guard
				let source = state.peekSource(windowID: windowID, paneID: paneID),
				PeekFeature.previewURL(url.absoluteString) != nil
			else { return .none }

			return request(.init(source: source, content: .url(url)), state: &state)
		}

		Pullback(\.ui.peekURLFromSource) { state, value in
			let (url, source, origin) = value
			guard
				state.peekSourceIsAvailable(source),
				PeekFeature.previewURL(url.absoluteString) != nil
			else { return .none }

			return request(.init(source: source, content: .url(url), origin: origin), state: &state)
		}

		Pullback(\.peekNewContents) { state, value in
			let (tab, source, origin) = value
			guard
				state.peekSourceIsAvailable(source),
				tab.profileID == source.profileID,
				!state.containsTab(tab.id),
				PeekFeature.previewURL(tab.restoration.url.absoluteString) != nil
			else { return .none }

			return request(.init(source: source, content: .newContents(tab), origin: origin), state: &state)
		}

		Pullback(\.ui.peekTab) { state, value in
			let (tabID, windowID, paneID) = value
			guard let source = state.peekSource(windowID: windowID, paneID: paneID)
			else { return .none }
			return request(.init(source: source, content: .tab(tabID)), state: &state)
		}

		Pullback(\.ui.dismissPeek) { state, windowID in
			guard let peek = state.peeks.first(where: { $0.source.windowID == windowID })
			else { return .none }
			return .send(.peeks(.element(id: peek.id, action: .ui(.close))))
		}

		Pullback(\.ui.promotePeek) { state, value in
			guard let peek = state.peeks.first(where: { $0.source.windowID == value.0 })
			else { return .none }
			return .send(.peeks(.element(id: peek.id, action: .ui(.promote(value.1)))))
		}

		Pullback(\.peeks) { state, action in
			guard
				case let .element(id, action) = action,
				let peek = state.peeks[id: id]
			else { return .none }

			switch action {
			case .delegate(.close):
				let transition = state.peekReplacements.removeValue(forKey: id).map(PeekTransition.replace) ?? .dismiss
				return release(id, transition: transition, state: &state)

			case let .delegate(.replace(url)):
				let next = PeekRequest(source: peek.source, content: .url(url))
				guard state.peekSourceIsValid(next.source)
				else { return failure(id, state: &state) }
				return release(id, transition: .replace(next), state: &state)

			case let .delegate(.promote(destination)):
				guard
					state.peekSourceIsAvailable(peek.source),
					peek.isTemporary || destination == .tab
				else { return failure(id, state: &state) }
				let requestID = state.automation.hostTransitions[id]
				return .run { [engine, tab = peek.tab] send in
					do {
						try await engine.open(tab)
						try Task.checkCancellation()
						await send(.event(.peekPromotionReady(id, destination, automationRequestID: requestID)))
					} catch is CancellationError {
						return
					} catch {
						guard !Task.isCancelled else { return }
						await send(.event(.peekPromotionFailed(id, String.localized(.appUI.peek.promotionFailed), automationRequestID: requestID)))
					}
				}
				.cancellable(id: PeekPromotionID(id: id))

			case let .delegate(.navigation(tabID, navigation)):
				return .send(.main(.viewer(.item(.delegate(.navigation(tabID, navigation))))))

			case .event(.closeDecision(false)):
				state.peekReplacements[id] = nil
				state.closingPeekHosts.remove(peek.source.windowID)
				return .none

			default: return .none
			}
		}

		Pullback(\.event.peekPromotionFailed) { state, value in
			let (id, message, requestID) = value
			guard state.automationHostCallbackIsCurrent(id, requestID: requestID)
			else { return .none }
			state.failAutomationHostTransition(id, requestID: requestID, failure: .engineFailed)
			return .send(.peeks(.element(id: id, action: .event(.promotionFailed(message)))))
		}

		Pullback(\.event.peekPromotionReady) { state, value in
			let (id, destination, requestID) = value
			guard state.automationHostCallbackIsCurrent(id, requestID: requestID)
			else { return .none }
			guard let peek = state.peeks[id: id], peek.phase == .promoting
			else { return .none }
			if state.automation.hostTransitions[id] != nil {
				let snapshotIDs = state.automationSnapshotTabIDs
				let snapshots = MainActor.assumeIsolated {
					Dictionary(uniqueKeysWithValues: snapshotIDs.compactMap { id in engine.snapshot(id).map { (id, $0) } })
				}
				guard state.automationAllowsHostTransition(id, requestID: requestID, snapshots: snapshots, now: now)
				else { return failure(id, state: &state) }
			}
			guard state.peekSourceIsAvailable(peek.source)
			else { return failure(id, state: &state) }
			return release(id, transition: .promote(destination), state: &state)
		}

		Pullback(\.event.peekReleased) { state, value in
			let (id, requestID) = value
			if case .promote = state.peekTransitions[id] {
				guard state.automationHostCallbackIsCurrent(id, requestID: requestID)
				else { return .none }
			}
			guard
				let peek = state.peeks[id: id],
				let transition = state.peekTransitions.removeValue(forKey: id)
			else { return .none }

			if case let .promote(destination) = transition {
				if state.automation.hostTransitions[id] != nil {
					let snapshotIDs = state.automationSnapshotTabIDs
					let snapshots = MainActor.assumeIsolated {
						Dictionary(uniqueKeysWithValues: snapshotIDs.compactMap { id in engine.snapshot(id).map { (id, $0) } })
					}
					guard state.automationAllowsHostTransition(id, requestID: requestID, snapshots: snapshots, now: now)
					else { return failure(id, state: &state) }
				}
				return completePromotion(peek, destination: destination, requestID: requestID, state: &state)
			}

			state.peeks.remove(id: id)
			state.releaseLittlePeek(peek)
			state.peekReplacements[id] = nil
			let closedHost = state.closingPeekHosts.remove(peek.source.windowID) != nil
			if closedHost { return closeHost(peek.source, state: &state) }
			if case let .replace(request) = transition { return start(request, state: &state) }
			return restoreFocus(peek.source, state: &state)
		}

		// Child reducers have already applied changes. Never bind an orphaned preview to a new pane.
		Pullback(\.main) { state, _ in closeOrphans(state: &state) }
		Pullback(\.windows) { state, _ in closeOrphans(state: &state) }
		Pullback(\.littleWindows) { state, action in
			if case let .element(id, .delegate(.closePeekHost(peekID))) = action {
				guard state.peeks[id: peekID]?.source.windowID == id
				else { return closeOrphans(state: &state) }

				return state.requestPeekHostClose(id) ?? .none
			}

			return closeOrphans(state: &state)
		}
	}

	private func request(
		_ request: PeekRequest,
		state: inout State
	) -> Effect<Action> {
		guard !state.checkingQuit, !state.shouldQuit else { return .none }

		if case let .tab(tabID) = request.content {
			guard state.workspace.tabs[id: tabID]?.profileID == request.source.profileID
			else { return .none }

			let hosts = (state.windowIsOpen ? [state.main] : []) + Array(state.windows)
			let owner = hosts.first {
				$0.id != request.source.windowID
				&& $0.viewer.panes.contains { $0.item.tab?.id == tabID }
			}
			let pane = owner?.viewer.panes.first { $0.item.tab?.id == tabID }

			if let owner, let pane {
				state.focusedWindowID = owner.id
				if let preview = state.peeks.first(where: { $0.source.windowID == owner.id }) {
					return .run { [surface, id = preview.tab.id] _ in await surface.focus(id) }
				}

				return .concatenate(
					hostAction(.viewer(.ui(.focus(pane.id))), id: owner.id, state: state),
					.run { [surface] _ in await surface.focus(tabID) }
				)
			}

			if let owner = state.peeks.first(where: { $0.tab.id == tabID && $0.source.windowID != request.source.windowID }) {
				state.focusedWindowID = owner.source.windowID
				return .run { [surface] _ in await surface.focus(tabID) }
			}
		}

		if let previous = state.peeks.first(where: { $0.source.windowID == request.source.windowID }) {
			guard previous.phase == .idle else { return .none }
			if case let .tab(id) = request.content, previous.tab.id == id { return .none }
			state.peekReplacements[previous.id] = request
			return .send(.peeks(.element(id: previous.id, action: .ui(.close))))
		}

		return start(request, state: &state)
	}

	private func start(
		_ request: PeekRequest,
		state: inout State
	) -> Effect<Action> {
		guard
			state.peekSourceIsValid(request.source),
			!state.peeks.contains(where: { $0.source.windowID == request.source.windowID })
		else { return .none }

		let tab: BrowserCore.Tab
		let isTemporary: Bool

		switch request.content {
		case let .url(url):
			guard PeekFeature.previewURL(url.absoluteString) != nil else { return .none }
			tab = .init(
				id: .init(rawValue: uuid()),
				profileID: request.source.profileID,
				restoration: .init(title: url.host() ?? "", url: url)
			)
			isTemporary = true

		case let .tab(id):
			guard let existing = state.workspace.tabs.first(where: { $0.id == id && $0.profileID == request.source.profileID })
			else { return .none }

			tab = existing
			isTemporary = false

		case let .newContents(page):
			// Shown as the engine made it, never loaded again from its URL. A Peek that had to
			// close first gave Chromium time to drop the page; showing it then loads the URL.
			guard
				page.profileID == request.source.profileID,
				!state.containsTab(page.id)
			else { return .none }

			tab = page
			isTemporary = true
		}

		let id = uuid()
		state.peeks.append(.init(id: id, source: request.source, tab: tab, isTemporary: isTemporary, origin: request.origin))
		state.focusedWindowID = request.source.windowID
		if case .littleArx = request.source.host {
			state.littleWindows[id: request.source.windowID]?.peekID = id
		}

		return .concatenate(
			.run { [surface] _ in await surface.release(tab.id) },
			.send(.peeks(.element(id: id, action: .ui(.task))))
		).cancellable(id: PeekHandoffID(id: id))
	}

	private func release(
		_ id: UUID,
		transition: PeekTransition,
		state: inout State
	) -> Effect<Action> {
		guard let peek = state.peeks[id: id], peek.phase != .releasing
		else { return .none }
		state.peeks[id: id]?.phase = .releasing
		state.peekTransitions[id] = transition
		let closesTemporary: Bool
		if case .promote = transition { closesTemporary = false } else { closesTemporary = peek.isTemporary }
		let requestID = state.automation.hostTransitions[id]
		return .concatenate(
			.send(.peeks(.element(id: id, action: .viewer(.suspend)))),
			.run { [engine, surface, tabID = peek.tab.id] send in
				await surface.release(tabID)
				if closesTemporary { await engine.close(tabID) }
				guard !Task.isCancelled else { return }
				await send(.event(.peekReleased(id, automationRequestID: requestID)))
			}
		).cancellable(id: PeekHandoffID(id: id))
	}

	private func completePromotion(
		_ peek: PeekFeature.State,
		destination: PeekDestination,
		requestID: UUID?,
		state: inout State
	) -> Effect<Action> {
		guard state.peekSourceIsAvailable(peek.source)
		else { return failure(peek.id, state: &state) }

		let borrowedSessionIsMissing = !peek.isTemporary
		&& state.workspace.tabs[id: peek.tab.id]?.profileID != peek.source.profileID

		if borrowedSessionIsMissing {
			return failure(peek.id, state: &state)
		}

		if destination == .littleArx {
			guard peek.isTemporary else { return failure(peek.id, state: &state) }
			let id = uuid()
			state.littleWindows.append(.init(
				id: id,
				spaceID: peek.source.spaceID,
				tab: peek.tab,
				bangs: state.settings.bangs,
				captureAvailable: state.captureAvailable,
				downloadsAvailable: state.downloadsReady,
				mediaAvailable: state.media.isAvailable
			))
			state.peeks.remove(id: peek.id)
			state.releaseLittlePeek(peek)
			state.focusedWindowID = id
			state.completeAutomationHostTransition(peek.id, requestID: requestID)
			return .none
		}

		if case .littleArx = peek.source.host {
			guard
				!state.checkingQuit,
				!state.shouldQuit,
				!state.main.isClosing,
				!state.main.transferInProgress,
				!state.main.archive.isWorking,
				state.main.pendingFolderDeletion == nil,
				state.main.pendingTabCloses.isEmpty,
				!state.peeks.contains(where: { $0.source.windowID == state.main.id })
			else { return failure(peek.id, state: &state) }
		}

		var organization = state.workspace

		if peek.isTemporary {
			// Directly after the tab the Peek was over, or first among the open tabs over a
			// bookmark (DEV-1325).
			do {
				try organization.update {
					guard let index = $0.spaces.firstIndex(where: {
						$0.id == peek.source.spaceID && $0.profileID == peek.tab.profileID
					})
					else { throw TabArchiveError.missingDestination }

					$0.tabs.append(peek.tab)
					$0.placeOpenedTab(peek.tab.id, inSpaceAt: index, opener: peek.source.tabID)
				}
			} catch {
				return failure(peek.id, state: &state)
			}

			// Publish every durable owner before yielding to presentation effects. The tab stays in
			// the window the Peek opened over (DEV-822).
			state.publishAdditiveOrganization(organization, openedIn: peek.source.windowID)
		}

		state.peeks.remove(id: peek.id)
		state.releaseLittlePeek(peek)
		state.completeAutomationHostTransition(peek.id, requestID: requestID)

		if case .littleArx = peek.source.host {
			return .merge(
				OrdinaryTabPresentation().focus(peek.tab, state: &state),
				peek.isTemporary ? .send(.delegate(.save(organization))) : .none
			)
		}

		state.focusedWindowID = peek.source.windowID
		var effects: [Effect<Action>] = []

		if peek.isTemporary {
			effects.append(.send(.delegate(.save(organization))))
		}

		let host = state.peekHost(peek.source.windowID)
		let paneID = host?.viewer.panes.first(where: { $0.item.tab?.id == peek.tab.id })?.id ?? peek.source.paneID
		effects.append(hostAction(.viewer(.ui(.focus(paneID))), id: peek.source.windowID, state: state))
		effects.append(hostAction(.present(peek.tab.id, in: paneID), id: peek.source.windowID, state: state))
		effects.append(.run { [surface, tabID = peek.tab.id] _ in await surface.focus(tabID) })
		return .concatenate(effects)
	}

	private func failure(
		_ id: UUID,
		state: inout State
	) -> Effect<Action> {
		guard state.peeks[id: id] != nil else { return .none }
		state.failAutomationHostTransition(id, requestID: state.automation.hostTransitions[id], failure: .staleTarget)
		state.peekTransitions[id] = nil
		state.peeks[id: id]?.phase = .idle
		state.peeks[id: id]?.error = String.localized(.appUI.peek.originUnavailable)

		// A failed handoff may have suspended observation; resume the same session.
		return .send(.peeks(.element(id: id, action: .ui(.task))))
	}

	private func restoreFocus(
		_ source: PeekFeature.Source,
		state: inout State
	) -> Effect<Action> {
		if case .littleArx = source.host {
			guard state.peekSourceIsValid(source), let tabID = source.tabID
			else { return .none }

			state.focusedWindowID = source.windowID
			return .run { [surface] _ in await surface.focus(tabID) }
		}

		guard let host = state.peekHost(source.windowID) else { return .none }
		state.focusedWindowID = host.id
		let pane = host.viewer.panes[id: source.paneID] ?? host.viewer.panes[id: host.viewer.activePaneID]
		guard let pane else { return .none }
		return .concatenate(
			hostAction(.viewer(.ui(.focus(pane.id))), id: host.id, state: state),
			.run { [surface, tabID = pane.item.tab?.id] _ in if let tabID { await surface.focus(tabID) } }
		)
	}

	private func closeOrphans(state: inout State) -> Effect<Action> {
		var effects: [Effect<Action>] = []

		for peek in state.peeks {
			let isOrphan = !state.peekSourceIsValid(peek.source)
			|| (!peek.isTemporary && !state.workspace.tabs.ids.contains(peek.tab.id))

			if !isOrphan { state.peeks[id: peek.id]?.orphanCloseRequested = false }
			guard isOrphan, peek.phase == .idle, !peek.orphanCloseRequested else { continue }
			state.peeks[id: peek.id]?.orphanCloseRequested = true
			effects.append(.send(.peeks(.element(id: peek.id, action: .ui(.close)))))
		}

		return .merge(effects)
	}

	private func closeHost(
		_ source: PeekFeature.Source,
		state: inout State
	) -> Effect<Action> {
		if case .littleArx = source.host {
			guard
				state.peekSourceIsValid(source),
				var little = state.littleWindows[id: source.windowID]
			else { return .none }

			// Start the original page's approval now, before another action can replace it.
			let effect = LittleArxFeature()._reduce(into: &little, action: .ui(.close))
			state.littleWindows[id: source.windowID] = little
			return effect.map { .littleWindows(.element(id: source.windowID, action: $0)) }
		}

		let action: Action = source.windowID == state.main.id
		? .ui(.closeWindow)
		: .ui(.closeAdditionalWindow(source.windowID))

		return .send(action)
	}

	private func hostAction(
		_ action: MainFeature.Action,
		id: UUID,
		state: State
	) -> Effect<Action> {
		.send(id == state.main.id ? .main(action) : .windows(.element(id: id, action: action)))
	}
}

extension AppFeature.State {
	internal func peekHost(_ id: UUID) -> MainFeature.State? {
		id == main.id ? (windowIsOpen ? main : nil) : windows[id: id]
	}

	internal func peekSource(
		windowID: UUID,
		paneID: UUID,
		requiresIdle: Bool = true
	) -> PeekFeature.Source? {
		if let little = littleWindows[id: windowID] {
			guard
				paneID == windowID,
				!little.isCommandOnly,
				!little.isClosing,
				!little.isPromoting,
				!little.isSwitchingProfile,
				little.pendingDestination == nil,
				little.viewer.tab?.id == little.tab.id,
				little.viewer.tab?.profileID == little.tab.profileID,
				let space = workspace.spaces.first(where: { $0.id == little.spaceID && $0.profileID == little.tab.profileID }),
				let profile = workspace.profiles[id: little.tab.profileID],
				!requiresIdle || !little.commandBar.isPresented
			else { return nil }

			return .init(
				windowID: windowID,
				paneID: windowID,
				tabID: little.tab.id,
				spaceID: space.id,
				profileID: profile.id,
				identity: "\(profile.name) · \(space.name)",
				host: .littleArx(generation: little.viewer.generation)
			)
		}

		guard
			let host = peekHost(windowID),
			!host.isPrivate,
			!host.isClosing,
			let pane = host.viewer.panes[id: paneID]
		else { return nil }

		if requiresIdle {
			let isBusy = host.transferInProgress
			|| host.pendingFolderDeletion != nil
			|| !host.pendingTabCloses.isEmpty
			|| host.archive.isWorking

			if isBusy { return nil }
		}

		let spaceID: Space.ID

		switch pane.item.tab.flatMap({ workspace.location(of: $0.id) }) {
		case let .unpinned(id), let .pinned(id, _): spaceID = id
		default: spaceID = host.sidebar.spaceID
		}
		guard
			let space = workspace.spaces[id: spaceID],
			pane.item.tab == nil || pane.item.tab?.profileID == space.profileID
		else { return nil }

		let profile = workspace.profiles[id: space.profileID]?.name ?? ""
		return .init(
			windowID: windowID,
			paneID: paneID,
			tabID: pane.item.tab?.id,
			spaceID: space.id,
			profileID: space.profileID,
			identity: "\(profile) · \(space.name)"
		)
	}

	internal func peekSourceIsValid(_ source: PeekFeature.Source) -> Bool {
		guard let current = peekSource(windowID: source.windowID, paneID: source.paneID, requiresIdle: false)
		else { return false }

		return current.host == source.host
		&& current.tabID == source.tabID
		&& current.spaceID == source.spaceID
		&& current.profileID == source.profileID
	}

	internal func peekSourceIsAvailable(_ source: PeekFeature.Source) -> Bool {
		guard let current = peekSource(windowID: source.windowID, paneID: source.paneID)
		else { return false }

		return current.host == source.host
		&& current.tabID == source.tabID
		&& current.spaceID == source.spaceID
		&& current.profileID == source.profileID
	}

	internal mutating func releaseLittlePeek(_ peek: PeekFeature.State) {
		guard littleWindows[id: peek.source.windowID]?.peekID == peek.id else { return }
		littleWindows[id: peek.source.windowID]?.peekID = nil
	}

	internal mutating func requestPeekHostClose(_ id: UUID) -> Effect<AppFeature.Action>? {
		guard let peek = peeks.first(where: { $0.source.windowID == id })
		else { return nil }
		guard peek.phase == .idle else { return .some(.none) }
		closingPeekHosts.insert(id)
		return .send(.peeks(.element(id: peek.id, action: .ui(.close))))
	}
}

internal struct PeekPromotionID: Hashable {
	internal let id: UUID

	internal init(id: UUID) {
		self.id = id
	}
}

internal struct PeekHandoffID: Hashable {
	internal let id: UUID

	internal init(id: UUID) {
		self.id = id
	}
}
