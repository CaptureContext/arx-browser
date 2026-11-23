import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import LittleArxFeature
import MainFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct RoutePreviewTests {
	@Test
	internal func explicitCommandPreviewsWithoutOpeningAndCancelLeavesQueueUntouched() async throws {
		let initial = fixture()
		let store = Store(initialState: initial) { AppFeature() } withDependencies: { $0.uuid = .incrementing }
		let target = AppFeature.CommandTarget.window(initial.main.id, paneID: initial.main.viewer.activePaneID)
		await store.send(.ui(.command(.routeCurrentURL, target))).finish()
		let preview = try #require(store.routePreview)
		expectNoDifference(preview.candidate.url, initial.main.viewer.item.navigation.url)
		expectNoDifference(preview.candidate.source.target, target)
		expectNoDifference(store.routingInbox, initial.routingInbox)
		expectNoDifference(store.workspace, initial.workspace)
		await store.send(.routePreview(.ui(.cancel(preview.id)))).finish()
		expectNoDifference(store.routePreview, nil)
		expectNoDifference(store.routingInbox, initial.routingInbox)
	}

	@Test
	internal func candidateAndSelectedDestinationStayFrozenAcrossFocusAndNavigationChanges() async throws {
		var initial = fixture()
		let candidate = try #require(initial.routePreviewCandidate(for: .window(initial.main.id)))
		initial.main.viewer.item.navigation.url = URL(string: "https://changed.example")!
		let other = MainFeature.State(
			organization: initial.workspace,
			spaceID: initial.workspace.spaces[1].id,
			id: UUID(50)
		)
		initial.windows.append(other)
		initial.focusedWindowID = other.id
		let store = Store(initialState: initial) { AppFeature() } withDependencies: { $0.uuid = .incrementing }
		await store.send(.routePreview(.ui(.present(candidate)))).finish()
		let preview = try #require(store.routePreview)
		let destination = RoutingDestination(scope: .space(initial.workspace.spaces[1].id), mode: .mainBrowser)
		await store.send(.routePreview(.ui(.choose(preview.id, destination)))).finish()
		await store.send(.routePreview(.ui(.confirm(preview.id)))).finish()
		let request = try #require(store.routingInbox.requests.first)
		expectNoDifference(request.url, candidate.url)
		expectNoDifference(request.currentSpaceID, candidate.source.spaceID)
		expectNoDifference(
			request.expectedTarget,
			.init(
				profileID: initial.workspace.spaces[1].profileID,
				spaceID: initial.workspace.spaces[1].id,
				mode: .mainBrowser
			)
		)
		expectNoDifference(store.focusedWindowID, other.id)
		expectNoDifference(store.routePreview, nil)
	}

	@Test(arguments: ["tab", "pane", "profile", "window"])
	internal func changedOriginCannotConfirmAnOldPreview(change: String) async throws {
		var initial = try previewFixture()
		let id = try #require(initial.routePreview?.id)
		switch change {
		case "tab": initial.main.viewer.item.tab = initial.workspace.tabs[1]
		case "pane": initial.main.viewer.panes = [.init(id: UUID(99))]
		case "profile": initial.workspace.profiles.removeAll()
		default: initial.windowIsOpen = false
		}
		let store = TestStore(initialState: initial) { AppFeature() }
		await store.send(.routePreview(.ui(.confirm(id)))) { $0.routePreview?.failure = .sourceChanged }
		await store.finish()
		expectNoDifference(store.state.routingInbox.requests, [])
	}

	@Test
	internal func sourceChangedBeforePresentationShowsFailureInTheOriginalHost() async throws {
		var initial = fixture()
		let candidate = try #require(initial.routePreviewCandidate(for: .window(initial.main.id)))
		initial.main.viewer.item.tab = initial.workspace.tabs[1]
		let store = Store(initialState: initial) { AppFeature() } withDependencies: { $0.uuid = .incrementing }
		await store.send(.routePreview(.ui(.present(candidate)))).finish()
		let preview = try #require(store.routePreview)
		expectNoDifference(preview.candidate, candidate)
		expectNoDifference(preview.failure, .sourceChanged)
		await store.send(.routePreview(.ui(.confirm(preview.id)))).finish()
		expectNoDifference(store.routingInbox.requests, [])
	}

	@Test
	internal func changedDestinationRequiresRefreshAndMissingDestinationCanBeRepaired() async throws {
		var initial = fixture()
		let profileID = initial.workspace.profiles[0].id
		initial.settings.$routingPreferences.withLock {
			$0.fallback = .init(scope: .space(initial.workspace.spaces[0].id))
		}
		initial = try previewFixture(initial)
		let id = try #require(initial.routePreview?.id)
		let sameProfileSpace = Space(id: .init(rawValue: UUID(70)), profileID: profileID, name: "New default")
		initial.workspace.spaces.append(sameProfileSpace)
		initial.settings.$routingPreferences.withLock { $0.fallback = .init(scope: .space(sameProfileSpace.id)) }
		let store = Store(initialState: initial) { AppFeature() } withDependencies: { $0.uuid = .incrementing }
		await store.send(.routePreview(.ui(.confirm(id)))).finish()
		expectNoDifference(store.routePreview?.failure, .destinationChanged)
		expectNoDifference(store.routingInbox.requests, [])
		await store.send(.routePreview(.ui(.refresh(id)))).finish()
		expectNoDifference(
			store.routePreview?.decision.result,
			.success(.init(profileID: profileID, spaceID: sameProfileSpace.id, mode: .littleArx))
		)
		await store.send(.routePreview(.ui(.choose(id, .init(scope: .space(.init(rawValue: UUID(999)))))))).finish()
		expectNoDifference(store.routePreview?.decision.result, .failure(.missingSpace))
		await store.send(.routePreview(.ui(.confirm(id)))).finish()
		expectNoDifference(store.routingInbox.requests, [])
		await store.send(.routePreview(.ui(.choose(id, .init(scope: .space(sameProfileSpace.id)))))).finish()
		await store.send(.routePreview(.ui(.confirm(id)))).finish()
		expectNoDifference(store.routingInbox.requests.first?.expectedTarget?.spaceID, sameProfileSpace.id)
	}

	@Test
	internal func previewIsHostScopedAndStaleDismissalCannotClearItsReplacement() async throws {
		var initial = try previewFixture()
		let original = try #require(initial.routePreview)
		let otherTab = initial.workspace.tabs[1]
		var other = MainFeature.State(
			organization: initial.workspace,
			spaceID: initial.workspace.spaces[0].id,
			id: UUID(50)
		)
		other.viewer.item = .init(tab: otherTab)
		initial.windows.append(other)
		let otherCandidate = try #require(initial.routePreviewCandidate(for: .window(other.id)))
		let store = Store(initialState: initial) { AppFeature() } withDependencies: { $0.uuid = .incrementing }
		await store.send(.ui(.focusWindow(other.id))).finish()
		await store.send(.routePreview(.ui(.present(otherCandidate)))).finish()
		expectNoDifference(store.routePreview, original)
		await store.send(.ui(.closeWindow)).finish()
		expectNoDifference(store.routePreview, nil)
		await store.send(.routePreview(.ui(.present(otherCandidate)))).finish()
		let replacement = try #require(store.routePreview)
		await store.send(.routePreview(.ui(.presentationChanged(.init(id: original.id, value: nil))))).finish()
		expectNoDifference(store.routePreview, replacement)
		await store.send(.ui(.closeAdditionalWindow(other.id))).finish()
		expectNoDifference(store.routePreview, nil)
		expectNoDifference(store.routingInbox.requests, [])
	}

	@Test(arguments: [RoutingWindowMode.mainBrowser, .littleArx])
	internal func confirmedOverrideOpensTheChosenProfileAndMode(mode: RoutingWindowMode) async throws {
		var initial = try previewFixture()
		initial.routingInbox.isReady = true
		let id = try #require(initial.routePreview?.id)
		let destination = initial.workspace.spaces[1]
		var opened: [BrowserCore.Tab] = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.prepareProfile = { profile in expectNoDifference(profile, destination.profileID) }
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.routePreview(.ui(.choose(id, .init(scope: .space(destination.id), mode: mode))))).finish()
		expectNoDifference(opened, [])
		await store.send(.routePreview(.ui(.confirm(id)))).finish()
		#expect(!opened.isEmpty)
		#expect(opened.allSatisfy {
			$0.profileID == destination.profileID
			&& $0.restoration.url == initial.routePreview?.candidate.url
		})
		expectNoDifference(store.routingInbox.requests, [])
		if mode == .littleArx {
			expectNoDifference(store.littleWindows.first?.spaceID, destination.id)
			expectNoDifference(store.workspace, initial.workspace)

		} else {
			expectNoDifference(store.main.sidebar.spaceID, destination.id)
			expectNoDifference(store.workspace.tabs.count, initial.workspace.tabs.count + 1)
		}
	}

	@Test
	internal func queuedConfirmedDestinationCannotSilentlyChangeProfile() async throws {
		var initial = try previewFixture()
		let preview = try #require(initial.routePreview)
		let space = initial.workspace.spaces[1]
		let expected = RoutingTarget(profileID: space.profileID, spaceID: space.id, mode: .littleArx)
		initial.routePreview = nil
		initial.routingInbox.requests = [
			.init(
				id: UUID(80),
				url: preview.candidate.url,
				currentSpaceID: preview.candidate.source.spaceID,
				override: .init(scope: .space(space.id)),
				expectedTarget: expected
			),
		]
		initial.workspace.spaces[1] = .init(
			id: space.id,
			profileID: initial.workspace.profiles[0].id,
			name: "Reassigned"
		)
		var opened: [BrowserCore.Tab] = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = { opened.append($0) }
		}
		await store.send(.event(.routingReady)).finish()
		expectNoDifference(opened, [])
		guard case .failed = store.routingInbox.requests.first?.status else {
			Issue.record("Changed destination must remain retryable")
			return
		}
		await store.send(.ui(.retryRoute(UUID(80)))).finish()
		expectNoDifference(opened, [])
		await store.send(.ui(.chooseRouteDestination(UUID(80), .init(scope: .space(space.id))))).finish()
		expectNoDifference(opened.first?.profileID, initial.workspace.profiles[0].id)
		expectNoDifference(store.routingInbox.requests, [])
	}

	@Test
	internal func destinationChangedWhileOpeningClosesTheUncommittedSession() async throws {
		var initial = fixture()
		let space = initial.workspace.spaces[1]
		let target = RoutingTarget(profileID: space.profileID, spaceID: space.id, mode: .littleArx)
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(81)),
			profileID: space.profileID,
			restoration: .init(title: "Opening", url: URL(string: "https://exact.example/a?b=%2f#hash")!)
		)
		initial.routingInbox = .init(
			isReady: true,
			requests: [
				.init(
					id: UUID(80),
					url: tab.restoration.url,
					currentSpaceID: initial.main.sidebar.spaceID,
					override: .init(scope: .space(space.id)),
					status: .opening(target, tab.id),
					expectedTarget: target
				),
			]
		)
		initial.workspace.spaces[1] = .init(
			id: space.id,
			profileID: initial.workspace.profiles[0].id,
			name: "Reassigned"
		)
		var closed: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.close = { closed.append($0) }
		}
		await store.send(.event(.routedSessionReady(UUID(80), target, tab))).finish()
		expectNoDifference(closed, [tab.id])
		expectNoDifference(store.littleWindows, [])
		expectNoDifference(store.workspace, initial.workspace)
		expectNoDifference(store.routingInbox.requests.first?.url, tab.restoration.url)
		expectNoDifference(store.routingInbox.requests.first?.expectedTarget, target)
		expectNoDifference(store.routingInbox.requests.first?.status, .needsDestination(.missingDestination))
	}

	@Test
	internal func confirmedEngineFailureKeepsExactURLAndRetryUsesSameApprovedDestination() async throws {
		var initial = try previewFixture()
		initial.routingInbox.isReady = true
		let preview = try #require(initial.routePreview)
		var opens = 0
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = { _ in
				opens += 1
				if opens == 1 { throw BrowserEngineClient.Failure.unavailable }
			}
			$0.browserEngine.close = { _ in }
		}
		await store.send(.routePreview(.ui(.confirm(preview.id)))).finish()
		let pending = try #require(store.routingInbox.requests.first)
		expectNoDifference(pending.url, preview.candidate.url)
		guard case .failed = pending.status else {
			Issue.record("Failure must preserve the request")
			return
		}
		await store.send(.ui(.retryRoute(pending.id))).finish()
		expectNoDifference(opens, 2)
		expectNoDifference(store.littleWindows.first?.tab.restoration.url, preview.candidate.url)
		expectNoDifference(store.littleWindows.first?.spaceID, pending.expectedTarget?.spaceID)
	}

	@Test
	internal func littleAndPeekUseTheirOwnURLAndPrivateOriginIsRejected() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0]
		let little = LittleArxFeature.State(id: UUID(60), spaceID: state.main.sidebar.spaceID, tab: tab)
		state.littleWindows.append(little)
		expectNoDifference(state.routePreviewCandidate(for: .window(little.id))?.source.windowID, little.id)
		var peek = PeekFeature.State(
			id: UUID(61),
			source: .init(
				windowID: state.main.id,
				paneID: state.main.viewer.activePaneID,
				tabID: tab.id,
				spaceID: state.main.sidebar.spaceID,
				profileID: tab.profileID,
				identity: "Peek"
			),
			tab: tab,
			isTemporary: false
		)
		peek.viewer.navigation.url = URL(string: "https://peek.example/current")!
		state.peeks.append(peek)
		expectNoDifference(state.routePreviewCandidate(for: .peek(peek.id))?.url, peek.viewer.navigation.url)
		expectNoDifference(state.routePreviewCandidate(for: .window(state.main.id)), nil)
		var privateWindow = MainFeature.State(
			organization: state.workspace,
			spaceID: state.main.sidebar.spaceID,
			isPrivate: true,
			id: UUID(62)
		)
		privateWindow.viewer.item = .init(tab: tab)
		state.windows.append(privateWindow)
		expectNoDifference(state.routePreviewCandidate(for: .window(privateWindow.id)), nil)
		state.windowIsOpen = false
		expectNoDifference(state.routePreviewCandidate(for: .peek(peek.id)), nil)
	}

	private func fixture() -> AppFeature.State {
		var organization = IntegrationFeatureTests().fixture()
		let profile = Profile(id: .init(rawValue: UUID(30)), name: "Other profile")
		organization.profiles.append(profile)
		organization.spaces[1] = .init(id: organization.spaces[1].id, profileID: profile.id, name: "Other space")
		var state = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id,
			id: UUID(10)
		))
		state.main.viewer.item = .init(
			tab: organization.tabs[0],
			navigation: .init(url: URL(string: "https://source.example/a?exact=%2f#hash")!, title: "Source")
		)
		return state
	}

	private func previewFixture(_ state: AppFeature.State? = nil) throws -> AppFeature.State {
		var state = state ?? fixture()
		let candidate = try #require(state.routePreviewCandidate(for: .window(state.main.id)))
		state.routePreview = .init(
			id: UUID(90),
			candidate: candidate,
			decision: URLRouter.decide(
				candidate.url,
				preferences: state.settings.routingPreferences,
				organization: state.workspace,
				currentSpaceID: candidate.source.spaceID
			)
		)
		return state
	}
}
