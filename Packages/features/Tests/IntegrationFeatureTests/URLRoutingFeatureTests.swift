import AppFeature
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func incomingURLsWaitForReadinessAndOpenIndependentSessionsInOrder() async throws {
		let organization = fixture()
		let urls = ["https://first.example/a?code=auth#x", "https://second.example/b"].map { URL(string: $0)! }
		var opened: [BrowserCore.Tab] = []
		var prepared: [Profile.ID] = []
		let ids = LockIsolated(20)
		let initialState = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: initialState) { AppFeature() } withDependencies: {
			$0.uuid = .init {
				ids.withValue {
					defer { $0 += 1 }
					return UUID($0)
				}
			}
			$0.browserEngine.prepareProfile = { prepared.append($0) }
			$0.browserEngine.open = { opened.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.routeURLs(urls)))
		await store.receive(\.processRouteQueue)
		expectNoDifference(opened, [])
		expectNoDifference(store.state.routingInbox.requests.map(\.url), urls)
		await store.send(.event(.routingReady))
		await store.receive(\.event.routedSessionReady)
		await store.receive(\.event.routedSessionReady)
		await store.finish()
		expectNoDifference(opened.map(\.restoration.url), urls)
		expectNoDifference(prepared, [organization.profiles[0].id, organization.profiles[0].id])
		expectNoDifference(store.state.littleWindows.map(\.tab.restoration.url), urls)
		#expect(Set(opened.map(\.id)).count == 2)
		#expect(store.state.routingInbox.requests.isEmpty)
		expectNoDifference(store.state.workspace, organization)
	}

	@Test
	internal func queuedRoutingCapturesExplicitSourceSpaceBeforeFocusChanges() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(10)))
		state.windows.append(.init(organization: organization, spaceID: organization.spaces[1].id, id: UUID(11)))
		state.focusedWindowID = UUID(11)
		let ids = LockIsolated(20)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .init {
				ids.withValue {
					defer { $0 += 1 }
					return UUID($0)
				}
			}
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.routeURLs([URL(string: "https://capturecontext.dev")!], sourceWindowID: UUID(10))))
		await store.receive(\.processRouteQueue)
		expectNoDifference(store.state.routingInbox.requests.first?.currentSpaceID, organization.spaces[0].id)
		await store.send(.event(.routingReady))
		await store.receive(\.event.routedSessionReady)
		await store.finish()
		expectNoDifference(store.state.littleWindows.first?.spaceID, organization.spaces[0].id)
	}

	@Test
	internal func missingTargetRetainsItsLinkWithoutBlockingLaterRequestsAndOverrideRecoversIt() async throws {
		let organization = fixture()
		let missingID = Space.ID(rawValue: UUID(99))
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.routingInbox.isReady = true
		state.settings.$routingPreferences.withLock { $0.rules = [.init(
			id: UUID(90),
			name: "Missing",
			host: "missing.example",
			destination: .init(scope: .space(missingID))
		)] }
		let ids = LockIsolated(20)
		var opened: [URL] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .init {
				ids.withValue {
					defer { $0 += 1 }
					return UUID($0)
				}
			}
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = { opened.append($0.restoration.url) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let urls = ["https://missing.example/a", "https://good.example/b"].map { URL(string: $0)! }
		await store.send(.ui(.routeURLs(urls)))
		await store.receive(\.event.routedSessionReady)
		await store.finish()
		let pending = try #require(store.state.routingInbox.requests.first)
		expectNoDifference(pending.url, urls[0])
		expectNoDifference(pending.status, .needsDestination(.missingSpace))
		expectNoDifference(pending.matchedRuleID, UUID(90))
		expectNoDifference(opened, [urls[1]])
		await store.send(.ui(.chooseRouteDestination(pending.id, .init(scope: .space(organization.spaces[1].id)))))
		await store.receive(\.event.routedSessionReady)
		await store.finish()
		expectNoDifference(opened, [urls[1], urls[0]])
		expectNoDifference(store.state.littleWindows.last?.spaceID, organization.spaces[1].id)
		#expect(store.state.routingInbox.requests.isEmpty)
	}

	@Test
	internal func manualCurrentSpaceOverrideRefreshesAStaleCapturedSpace() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[1].id))
		state.routingInbox.requests = [.init(
			id: UUID(20),
			url: URL(string: "https://capturecontext.dev")!,
			currentSpaceID: .init(rawValue: UUID(99)),
			status: .needsDestination(.missingSpace)
		)]
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.chooseRouteDestination(UUID(20), .init(scope: .currentSpace))))
		await store.receive(\.processRouteQueue)
		expectNoDifference(store.state.routingInbox.requests.first?.currentSpaceID, organization.spaces[1].id)
		expectNoDifference(store.state.routingInbox.requests.first?.status, .queued)
	}

	@Test
	internal func failedEngineOpenKeepsTheOriginalAndRetryCreatesAFreshSession() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.routingInbox.isReady = true
		let ids = LockIsolated(20)
		var opened: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .init {
				ids.withValue {
					defer { $0 += 1 }
					return UUID($0)
				}
			}
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = {
				opened.append($0.id)
				if opened.count == 1 { throw BrowserEngineClient.Failure.unavailable }
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let url = URL(string: "https://capturecontext.dev/a?exact=%2f#hash")!
		await store.send(.ui(.routeURLs([url])))
		await store.receive(\.event.routedSessionFailed)
		await store.finish()
		let pending = try #require(store.state.routingInbox.requests.first)
		expectNoDifference(pending.url, url)
		guard case .failed = pending.status else {
			Issue.record("Failed open must remain retryable")
			return
		}
		expectNoDifference(closed, [opened[0]])
		await store.send(.ui(.retryRoute(pending.id)))
		await store.receive(\.event.routedSessionReady)
		await store.finish()
		#expect(opened.count == 2 && opened[0] != opened[1])
		expectNoDifference(store.state.littleWindows.first?.tab.restoration.url, url)
		#expect(store.state.routingInbox.requests.isEmpty)
	}

	@Test(arguments: [true, false])
	internal func routingRevalidatesTheDestinationBeforeCommittingAnOpenedSession(deletedSpace: Bool) async throws {
		let organization = fixture()
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(21)),
			profileID: organization.profiles[0].id,
			restoration: .init(title: "Incoming", url: URL(string: "https://capturecontext.dev")!)
		)
		let target = RoutingTarget(profileID: tab.profileID, spaceID: organization.spaces[0].id, mode: .littleArx)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: target.spaceID))
		state.routingInbox = .init(
			isReady: true,
			requests: [.init(
				id: UUID(20),
				url: tab.restoration.url,
				currentSpaceID: target.spaceID,
				override: .init(scope: .space(organization.spaces[1].id)),
				status: .opening(target, tab.id)
			)]
		)
		if deletedSpace { state.workspace.spaces.removeLast() }
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.routedSessionReady(UUID(20), target, tab)))
		await store.finish()
		expectNoDifference(closed, [tab.id])
		expectNoDifference(
			store.state.routingInbox.requests.first?.status,
			.needsDestination(deletedSpace ? .missingSpace : .missingDestination)
		)
		#expect(store.state.littleWindows.isEmpty)
		expectNoDifference(store.state.workspace, state.workspace)
	}

	@Test
	internal func cancelledRoutingClosesAnInFlightSessionAndLateCompletionCannotOpenAWindow() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.routingInbox.isReady = true
		let clock = TestClock()
		let ids = LockIsolated(20)
		var opened: [BrowserCore.Tab] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .init {
				ids.withValue {
					defer { $0 += 1 }
					return UUID($0)
				}
			}
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = {
				opened.append($0)
				try await clock.sleep(for: .seconds(60))
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.routeURLs([URL(string: "https://capturecontext.dev")!])))
		await store.receive(\.processRouteQueue)
		await Task.yield()
		let request = try #require(store.state.routingInbox.requests.first)
		await store.send(.ui(.cancelRoute(request.id)))
		await store.finish()
		#expect(store.state.routingInbox.requests.isEmpty)
		#expect(store.state.littleWindows.isEmpty)
		let tab = try #require(opened.first)
		expectNoDifference(closed, [tab.id])
		let lateTarget = RoutingTarget(profileID: tab.profileID, spaceID: organization.spaces[0].id, mode: .littleArx)
		await store.send(.event(.routedSessionReady(request.id, lateTarget, tab)))
		await store.finish()
		expectNoDifference(closed, [tab.id, tab.id])
		#expect(store.state.littleWindows.isEmpty)
	}

	@Test
	internal func mainBrowserRoutesAppendInOrderAndOpenInSpaceBypassesRules() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.panes.append(.init(id: UUID(40), item: .init(tab: organization.tabs[1])))
		state.main.viewer.preservesPresentation = true
		let originalLayout = state.main.viewer.currentPresentation
		state.routingInbox.isReady = true
		state.settings.$routingPreferences.withLock { $0.fallback = nil }
		let ids = LockIsolated(20)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .init {
				ids.withValue {
					defer { $0 += 1 }
					return UUID($0)
				}
			}
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		let urls = ["https://first.example", "https://second.example"].map { URL(string: $0)! }
		await store.send(.ui(.openURLInSpace(urls[0], organization.spaces[1].id, .mainBrowser))).finish()
		await store.send(.ui(.openURLInSpace(urls[1], organization.spaces[1].id, .mainBrowser))).finish()
		expectNoDifference(store.state.workspace.tabs.suffix(2).map(\.restoration.url), urls)
		expectNoDifference(store.state.workspace.spaces[1].unpinnedTabs, store.state.workspace.tabs.suffix(2).map(\.id))
		expectNoDifference(store.state.main.sidebar.spaceID, organization.spaces[1].id)
		expectNoDifference(store.state.unsavedOrganization, store.state.workspace)
		#expect(store.state.routingInbox.requests.isEmpty)
		expectNoDifference(store.state.main.viewer.panes.compactMap { $0.item.tab?.id }, [store.state.workspace.tabs.last!.id])
		await store.send(.main(.sidebar(.ui(.spaceSelected(organization.spaces[0].id))))).finish()
		expectNoDifference(store.state.main.viewer.currentPresentation, originalLayout)
	}

	@Test
	internal func routingSettingsPersistOrderDefaultsAndRejectCrossProfileDefault() async throws {
		let organization = fixture()
		let ids = LockIsolated(20)
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
			$0.uuid = .init {
				ids.withValue {
					defer { $0 += 1 }
					return UUID($0)
				}
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.routing(.changed(.init(name: "One", host: "capturecontext.dev")))))
		await store.send(.ui(.routing(.save(organization))))
		await store.send(.ui(.routing(.changed(.init(name: "Two", host: "other.example")))))
		await store.send(.ui(.routing(.save(organization))))
		await store.send(.ui(.routing(.move(UUID(21), -1))))
		expectNoDifference(store.state.routingPreferences.rules.map(\.name), ["Two", "One"])
		await store.send(.ui(.routing(.toggle(UUID(21)))))
		#expect(!store.state.routingPreferences.rules[0].isEnabled)
		await store.send(.ui(.routing(.delete(UUID(21)))))
		expectNoDifference(store.state.routingPreferences.rules.map(\.name), ["One"])
	}

	/// Ask holds a link before anything loads: no profile is prepared and no tab opens, so a
	/// sign-in link never runs in the wrong profile. The choice then opens it once, there.
	@Test(arguments: [true, false])
	internal func askingOpensNothingUntilADestinationIsChosen(byRoute: Bool) async throws {
		let organization = fixture()
		let work = Profile(id: .init(rawValue: UUID(80)), name: "Work")
		let workSpace = Space(id: .init(rawValue: UUID(81)), profileID: work.id, name: "Work")
		var workspace = organization
		workspace.profiles.append(work)
		workspace.spaces.append(workSpace)
		var state = AppFeature.State(main: .init(organization: workspace, spaceID: organization.spaces[0].id))
		state.routingInbox.isReady = true
		state.settings.$routingPreferences.withLock {
			if byRoute {
				$0.rules = [.init(id: UUID(90), name: "Google", host: "accounts.google.com", destination: .init(scope: .ask))]
			} else {
				$0.fallback = nil
			}
		}
		let url = URL(string: "https://accounts.google.com/o/oauth2/auth?state=once")!
		let prepared = LockIsolated<[Profile.ID]>([])
		let opened = LockIsolated<[BrowserCore.Tab]>([])
		let ids = LockIsolated(20)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .init {
				ids.withValue {
					defer { $0 += 1 }
					return UUID($0)
				}
			}
			$0.browserEngine.prepareProfile = { id in prepared.withValue { $0.append(id) } }
			$0.browserEngine.open = { tab in opened.withValue { $0.append(tab) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.routeURLs([url])))
		await store.receive(\.processRouteQueue)
		await store.finish()
		let request = try #require(store.state.routingInbox.requests.first)
		expectNoDifference(request.status, .needsDestination(.missingDestination))
		expectNoDifference(prepared.value, [])
		expectNoDifference(opened.value, [])

		await store.send(.ui(.chooseRouteDestination(request.id, .init(scope: .space(workSpace.id), mode: .mainBrowser))))
		await store.receive(\.event.routedSessionReady)
		await store.finish()

		// Routing prepares the chosen profile, and the window then showing its space prepares it
		// again (DEV-880): only that profile.
		expectNoDifference(Set(prepared.value), [work.id])

		// One tab, in the chosen profile. The window showing it opens it again, which attaches
		// to the page routing already loaded: the engine ignores `open` for a tab with a page.
		let tabs = Set(opened.value.map(\.id))
		#expect(tabs.count == 1)
		expectNoDifference(Set(opened.value.map(\.restoration.url)), [url])
		expectNoDifference(Set(opened.value.map(\.profileID)), [work.id])
		#expect(store.state.routingInbox.requests.isEmpty)
		expectNoDifference(store.state.workspace.spaces[id: workSpace.id].map { Set($0.unpinnedTabs) }, tabs)
	}
}
