import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

@Reducer
internal struct IncomingURLRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.routeURLs) { state, value in
			let (urls, override, sourceWindowID) = value
			let spaceID = state.incomingSpaceID(in: sourceWindowID)
			for url in urls {
				state.routingInbox.requests.append(.init(id: uuid(), url: url, currentSpaceID: spaceID, override: override))
			}

			// Links wait while launch onboarding holds the main window back, then open (DEV-838).
			if state.mainWindowWaitsForOnboarding { state.bringOnboardingForward() }
			return .send(.processRouteQueue)
		}

		Pullback(\.ui.openURLInSpace) { _, value in
			let (url, spaceID, mode) = value
			return .send(.ui(.routeURLs([url], override: .init(scope: .space(spaceID), mode: mode))))
		}

		Pullback(\.event.routingReady) { state in
			state.routingInbox.isReady = true
			return .send(.processRouteQueue)
		}

		Pullback(\.ui.cancelRoute) { state, id in
			state.routingInbox.requests.removeAll { $0.id == id }
			if state.routingInbox.picker?.requestID == id { state.routingInbox.picker = nil }
			return .merge(.cancel(id: id), .send(.processRouteQueue))
		}

		Pullback(\.ui.retryRoute) { state, id in
			guard let index = state.routingInbox.requests.firstIndex(where: { $0.id == id })
			else { return .none }
			switch state.routingInbox.requests[index].status {
			case .opening, .choosingProfile: return .none
			default: break
			}
			state.routingInbox.requests[index].status = .queued
			return .send(.processRouteQueue)
		}

		Pullback(\.ui.chooseRouteDestination) { state, value in
			let (id, destination) = value
			guard let index = state.routingInbox.requests.firstIndex(where: { $0.id == id })
			else { return .none }
			switch state.routingInbox.requests[index].status {
			case .opening, .choosingProfile: return .none
			default: break
			}
			state.routingInbox.requests[index].override = destination
			if destination.scope == .currentSpace, state.routingInbox.requests[index].expectedTarget == nil {
				state.routingInbox.requests[index].currentSpaceID = state.incomingSpaceID()
			}
			if state.routingInbox.requests[index].expectedTarget != nil {
				let target = try? URLRouter.resolve(
					destination,
					preferences: state.settings.routingPreferences,
					organization: state.workspace,
					currentSpaceID: state.routingInbox.requests[index].currentSpaceID,
					recentSpaceIDs: state.recentSpaceIDs
				)
				if let target { state.routingInbox.requests[index].expectedTarget = target }
			}
			state.routingInbox.requests[index].status = .queued
			return .send(.processRouteQueue)
		}

		Pullback(\.processRouteQueue) { state in
			guard
				state.routingInbox.isReady,
				!state.mainWindowWaitsForOnboarding,
				!state.shouldQuit,
				!state.checkingQuit
			else { return .none }

			// One link at a time: the picker asks about one, and later links wait behind it.
			guard !state.routingInbox.requests.contains(where: {
				switch $0.status {
				case .opening, .choosingProfile: true
				default: false
				}
			}) else { return .none }
			guard let index = state.routingInbox.requests.firstIndex(where: { $0.status == .queued })
			else { return .none }
			let request = state.routingInbox.requests[index]
			let decision = URLRouter.decide(
				request.url, preferences: state.settings.routingPreferences, organization: state.workspace,
				currentSpaceID: request.currentSpaceID, recentSpaceIDs: state.recentSpaceIDs, override: request.override
			)
			state.routingInbox.requests[index].matchedRuleID = decision.matchedRuleID
			if let expected = request.expectedTarget, decision.result != .success(expected) {
				state.routingInbox.requests[index].status = .failed(String.localized(.appUI.routing.destinationChanged))
				state.showRoutingInbox()
				return .send(.processRouteQueue)
			}
			if state.asksForProfileAtPointer(request, decision: decision) {
				// Nothing loads until a profile is chosen, so a sign-in link starts where it ends.
				state.routingInbox.requests[index].status = .choosingProfile
				state.routingInbox.picker = .init(
					requestID: request.id,
					url: request.url,
					options: RoutingProfilePicker.options(
						organization: state.workspace,
						currentSpaceID: request.currentSpaceID,
						recentSpaceIDs: state.recentSpaceIDs
					)
				)
				return .none
			}
			switch decision.result {
			case let .failure(error):
				state.routingInbox.requests[index].status = .needsDestination(error)
				state.showRoutingInbox()
				return .send(.processRouteQueue)

			case let .success(target):
				let tab = BrowserCore.Tab(
					id: .init(rawValue: uuid()), profileID: target.profileID,
					restoration: .init(title: request.url.host() ?? request.url.absoluteString, url: request.url)
				)
				state.routingInbox.requests[index].status = .opening(target, tab.id)
				return .run { [engine] send in
					do {
						try await engine.prepareProfile(target.profileID)
						try Task.checkCancellation()
						try await engine.open(tab)
						try Task.checkCancellation()
						await send(.event(.routedSessionReady(request.id, target, tab)))
					} catch is CancellationError {
						await engine.close(tab.id)
					} catch {
						await engine.close(tab.id)
						await send(.event(.routedSessionFailed(request.id, tab.id, error.localizedDescription)))
					}
				}.cancellable(id: request.id)
			}
		}

		Pullback(\.event.routedSessionFailed) { state, value in
			let (id, tabID, message) = value
			guard
				let index = state.routingInbox.requests.firstIndex(where: { $0.id == id }),
				case let .opening(_, expectedID) = state.routingInbox.requests[index].status,
				expectedID == tabID
			else { return .none }
			state.routingInbox.requests[index].status = .failed(message)
			state.showRoutingInbox()
			return .send(.processRouteQueue)
		}

		Pullback(\.event.routedSessionReady) { state, value in
			let (id, target, tab) = value
			guard
				let index = state.routingInbox.requests.firstIndex(where: { $0.id == id }),
				state.routingInbox.requests[index].status == .opening(target, tab.id)
			else { return .run { [engine] _ in await engine.close(tab.id) } }
			let pending = state.routingInbox.requests[index]
			let currentDecision = URLRouter.decide(
				pending.url, preferences: state.settings.routingPreferences, organization: state.workspace,
				currentSpaceID: pending.currentSpaceID, recentSpaceIDs: state.recentSpaceIDs, override: pending.override
			)
			guard
				!state.shouldQuit, !state.checkingQuit,
				currentDecision.result == .success(target),
				pending.expectedTarget == nil || pending.expectedTarget == target,
				let space = state.workspace.spaces[id: target.spaceID],
				space.profileID == target.profileID,
				state.workspace.profiles.ids.contains(target.profileID)
			else {
				let error: URLRoutingError
				if case let .failure(failure) = currentDecision.result { error = failure }
				else { error = .missingDestination }
				state.routingInbox.requests[index].status = .needsDestination(error)
				state.showRoutingInbox()
				return .concatenate(
					.run { [engine] _ in await engine.close(tab.id) },
					.send(.processRouteQueue)
				)
			}
			let request = state.routingInbox.requests.remove(at: index)
			switch target.mode {
			case .littleArx:
				// Always a new Little Arx (DEV-931). It opens on the macOS desktop
				// Space where the link was clicked; one already open, maybe on another Space,
				// is neither reused nor moved.
				let windowID = uuid()
				state.littleWindows.append(.init(
					id: windowID,
					spaceID: space.id,
					tab: tab,
					bangs: state.settings.bangs,
					captureAvailable: state.captureAvailable,
					downloadsAvailable: state.downloadsReady,
					mediaAvailable: state.media.isAvailable
				))
				state.focusedWindowID = windowID
				return .send(.processRouteQueue)

			case .mainBrowser:
				var organization = state.workspace
				do {
					try organization.update { organization in
						guard let spaceIndex = organization.spaces.index(id: space.id)
						else { throw URLRoutingError.missingSpace }
						organization.tabs.append(tab)
						organization.spaces[spaceIndex].unpinnedTabs.append(tab.id)
						organization.spaces[spaceIndex].selectedTabID = tab.id
					}
				} catch {
					var failed = request
					failed.status = .failed(error.localizedDescription)
					state.routingInbox.requests.insert(failed, at: index)
					state.showRoutingInbox()
					return .concatenate(
						.run { [engine] _ in await engine.close(tab.id) },
						.send(.processRouteQueue)
					)
				}
				state.main.sidebar.organization = organization
				state.main.sidebar.selectSpace(space.id)
				state.main.sidebar.select(tab.id)
				state.main.knownTabIDs = Set(organization.tabs.map(\.id))
				state.workspace = organization
				state.unsavedOrganization = organization
				if state.openMainWindow() { state.focusedWindowID = state.main.id }
				return .merge([
					.send(.main(.present(tab.id, in: state.main.viewer.activePaneID))),
					.send(.delegate(.save(organization))),
					.send(.processRouteQueue),
				] + state.windows.filter { !$0.isPrivate }.map { window in
					.send(.windows(.element(id: window.id, action: .reconcile(organization))))
				})
			}
		}
	}
}

extension AppFeature.State {
	public func incomingSpaceID(in sourceWindowID: UUID? = nil) -> Space.ID? {
		if let sourceWindowID {
			let current = sourceWindowID == main.id
			? main.sidebar.spaceID
			: littleWindows[id: sourceWindowID]?.spaceID ?? windows[id: sourceWindowID]?.sidebar.spaceID
			return workspace.spaces[id: current]?.id
		}
		let current = focusedWindowID.flatMap { id in
			littleWindows[id: id]?.spaceID ?? windows[id: id]?.sidebar.spaceID
		} ?? main.sidebar.spaceID
		return workspace.spaces.ids.contains(current) ? current : workspace.spaces.first?.id
	}

	fileprivate mutating func showRoutingInbox() {
		guard openMainWindow() else { return }

		focusedWindowID = main.id
	}
}

extension Reducer where State == AppFeature.State {
	/// Moves the space in front to the start of `recentSpaceIDs` whenever it changes.
	internal func recordingRecentSpaces() -> some Reducer<State, Action> {
		onChange(of: { $0.incomingSpaceID() }, reduce: { state, previous, space in

			// The space left counts too, such as the one restored at launch before any change.
			if let previous, !state.recentSpaceIDs.contains(previous) {
				state.recentSpaceIDs.insert(previous, at: 0)
			}
			guard let space else { return .none }
			state.recentSpaceIDs.removeAll { $0 == space }
			state.recentSpaceIDs.insert(space, at: 0)
			state.recentSpaceIDs = Array(state.recentSpaceIDs.prefix(32))
			return .none
		})
	}
}
