import BrowserCore
import BrowserWorkspaceClient
import BrowserMediaClient
import BrowserSurfaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct AutomaticMediaTests {
	@Test(arguments: [false, true])
	internal func hiddenTransitionRequiresPersistedExactSiteOptIn(enabled: Bool) async throws {
		let state = fixture(enabled: enabled)
		let source = state.media.snapshot.sources[0]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(isAvailable: true, perform: { request in requests.withValue { $0.append(request) } })
		}
		await store.send(report(source, window: state.main.id, visible: true)).finish()
		await store.send(report(source, window: state.main.id, visible: false)).finish()
		await store.send(report(source, window: state.main.id, visible: false)).finish()
		expectNoDifference(requests.value, enabled ? [.init(source: source, action: .enterAutomaticPictureInPicture)] : [])
		expectNoDifference(store.mediaSourceVisibility[source.id], false)
	}

	@Test
	internal func selectionMustWaitForActualOldSurfaceDetachBeforeOneAutomaticAttempt() async throws {
		let state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserSurface.release = { _ in }
			$0.browserSurface.focus = { _ in }
			$0.browserMedia = .init(isAvailable: true, perform: { request in requests.withValue { $0.append(request) } })
		}
		await store.send(report(source, window: state.main.id, visible: true)).finish()
		await store.send(.main(.viewer(.show(state.workspace.tabs[1], in: state.main.viewer.activePaneID)))).finish()
		expectNoDifference(store.main.viewer.item.tab?.id, state.workspace.tabs[1].id)
		expectNoDifference(store.mediaSourceVisibility[source.id], true)
		#expect(requests.value.isEmpty)
		await store.send(report(source, window: state.main.id, visible: nil)).finish()
		expectNoDifference(requests.value, [.init(source: source, action: .enterAutomaticPictureInPicture)])
		await store.send(report(source, window: state.main.id, visible: nil)).finish()
		expectNoDifference(requests.value.count, 1)
	}

	@Test
	internal func sourceVisibleInSplitOrOtherWindowIsNotHiddenByFocusOrAnotherHost() async throws {
		var state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		state.main.viewer.panes.append(.init(id: UUID(71), item: .init(tab: state.workspace.tabs[1])))
		var other = MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: UUID(72))
		other.viewer.item = .init(tab: state.workspace.tabs[0])
		state.windows.append(other)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia.perform = { _ in Issue.record("A still-visible source must not enter automatic PiP") }
			$0.browserSurface.focus = { _ in }
		}
		await store.send(report(source, window: state.main.id, visible: true)).finish()
		await store.send(report(source, window: other.id, visible: true, host: UUID(202))).finish()
		await store.send(.ui(.focusWindow(other.id))).finish()
		await store.send(.main(.viewer(.ui(.focus(UUID(71)))))).finish()
		await store.send(report(source, window: state.main.id, visible: false)).finish()
		expectNoDifference(store.mediaSourceVisibility[source.id], true)
	}

	@Test(arguments: [false, true])
	internal func littleAndPeekUseTheirActualSourceHosts(peek: Bool) async throws {
		var state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		let tab = state.workspace.tabs[0]
		state.main.viewer.item.tab = nil
		let windowID = peek ? state.main.id : UUID(82)
		if peek {
			state.peeks.append(.init(id: UUID(81), source: .init(
				windowID: windowID,
				paneID: state.main.viewer.activePaneID,
				tabID: state.workspace.tabs[1].id,
				spaceID: state.main.sidebar.spaceID,
				profileID: tab.profileID,
				identity: "Fixture"
			), tab: tab, isTemporary: false))
			state.peeks[id: UUID(81)]?.viewer.tab = tab

		} else {
			state.littleWindows.append(.init(id: windowID, spaceID: state.main.sidebar.spaceID, tab: tab))
			state.littleWindows[id: windowID]?.viewer.tab = tab
		}
		state.mediaSurfaces[UUID(200)] = .init(windowID: windowID, report: .init(hostID: UUID(200), tabID: tab.id, isVisible: true))
		expectNoDifference(state.mediaVisibility(of: source), true)
		state.mediaSurfaces[UUID(200)] = .init(windowID: windowID, report: .init(hostID: UUID(200), tabID: tab.id, isVisible: false))
		expectNoDifference(state.mediaVisibility(of: source), false)
	}

	@Test
	internal func attachmentAndPromotionGapsRemainUnknownAndOldHostCannotHideReplacement() async throws {
		var state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		expectNoDifference(state.mediaVisibility(of: source), nil)
		state.mediaSourceVisibility[source.id] = true
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia.perform = { _ in Issue.record("An attachment gap must not enter PiP") }
		}
		await store.send(report(source, window: state.main.id, visible: true, host: UUID(201))).finish()
		await store.send(report(source, window: state.main.id, visible: true, host: UUID(202))).finish()
		await store.send(report(source, window: state.main.id, visible: nil, host: UUID(201))).finish()
		expectNoDifference(store.mediaSourceVisibility[source.id], true)
		await store.send(report(source, window: state.main.id, visible: nil, host: UUID(202))).finish()
		expectNoDifference(store.mediaSourceVisibility[source.id], true)
		state.main.transferInProgress = true
		state.main.viewer.item.tab = nil
		expectNoDifference(state.mediaVisibility(of: source), nil)
	}

	@Test
	internal func littlePromotionKeepsAutoSuppressedUntilTheDestinationActuallyMounts() async throws {
		var state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		let tab = state.workspace.tabs[0]
		let littleID = UUID(82)
		state.workspace.tabs.removeAll { $0.id == tab.id }
		for index in state.workspace.spaces.indices {
			state.workspace.spaces[index].unpinnedTabs.removeAll { $0 == tab.id }
			if state.workspace.spaces[index].selectedTabID == tab.id {
				state.workspace.spaces[index].selectedTabID = nil
			}
		}
		state.main.sidebar.organization = state.workspace
		state.main.viewer.item.tab = nil
		state.littleWindows.append(.init(id: littleID, spaceID: state.main.sidebar.spaceID, tab: tab))
		state.littleWindows[id: littleID]?.viewer.tab = tab
		state.littleWindows[id: littleID]?.isPromoting = true
		state.mediaSourceVisibility[source.id] = true
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserSurface.release = { _ in }
			$0.browserSurface.focus = { _ in }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserMedia.perform = { _ in Issue.record("Promotion must not trigger automatic PiP") }
		}
		await store.send(.ui(.linkFeedbackHovered(false))).finish()
		#expect(store.mediaRehostingSources.contains(tab.id))
		await store.send(.event(.littlePromotionReady(littleID, tab, tab, state.main.sidebar.spaceID))).finish()
		#expect(store.littleWindows.isEmpty)
		#expect(store.mediaRehostingSources.contains(tab.id))
		expectNoDifference(store.mediaSourceVisibility[source.id], true)
		await store.send(report(source, window: state.main.id, visible: true)).finish()
		#expect(!store.mediaRehostingSources.contains(tab.id))
		expectNoDifference(store.mediaSourceVisibility[source.id], true)
	}

	@Test
	internal func optInUsesExistingPreferencesSaveAndRestoresAtStartup() async throws {
		let state = fixture(enabled: false)
		let source = state.media.snapshot.sources[0]
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.media(.ui(.setAutomatic(source.id, enabled: true))))
		await store.receive(\.media.delegate.automaticPreferencesChanged)
		await store.finish()

		// The shared key carries the choice to the workspace document, which AppFeature saves.
		#expect(store.state.settings.automaticPictureInPicture.permits(source))

		@Dependency(\.workspaceDocument)
		var document

		#expect(document.preferences.automaticPictureInPicture.permits(source))
		let restored = AppFeature.State(main: state.main)
		#expect(restored.media.automatic.permits(source))
	}

	@Test
	internal func aNewHiddenGenerationCannotInheritTheOldVisibilityTransition() async throws {
		var state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		state.mediaSourceVisibility[source.id] = true
		state.media.snapshot.sources[0].id.generation += 1
		state.main.viewer.item.tab = nil
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia.perform = { _ in Issue.record("A new hidden generation must first become visible") }
		}
		await store.send(.ui(.linkFeedbackHovered(false))).finish()
		expectNoDifference(store.mediaSourceVisibility[source.id], nil)
		expectNoDifference(store.mediaSourceVisibility[store.media.snapshot.sources[0].id], false)
	}

	@Test
	internal func aTornOffVideoStaysOutOfPictureInPictureUntilLittleArxShowsIt() async throws {
		let state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		let tab = state.workspace.tabs[0]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserSurface.release = { _ in }
			$0.browserSurface.focus = { _ in }
			$0.browserMedia = .init(isAvailable: true, perform: { request in requests.withValue { $0.append(request) } })
		}
		await store.send(report(source, window: state.main.id, visible: true)).finish()

		// DEV-793: the tab leaves for Little Arx, whose page view hasn't run its task yet.
		await store.send(.main(.ui(.dropTabOutsideWindows(tab.id, .init(x: 300, y: 300))))).finish()
		let little = try #require(store.littleWindows.first)
		#expect(little.viewer.tab == nil)
		#expect(store.mediaRehostingSources.contains(tab.id))

		// The old host's detach arrives first: no automatic Picture in Picture.
		await store.send(report(source, window: state.main.id, visible: false)).finish()
		#expect(requests.value.isEmpty)
		expectNoDifference(store.mediaSourceVisibility[source.id], true)

		// Little Arx shows the page and reports it visible: the handoff ends.
		await store.send(.littleWindows(.element(id: little.id, action: .ui(.task)))).finish()
		await store.send(report(source, window: little.id, visible: true, host: UUID(202))).finish()
		#expect(!store.mediaRehostingSources.contains(tab.id))
		#expect(requests.value.isEmpty)
	}

	@Test
	internal func aRefusedTearOffEndsTheMediaHandoff() async throws {
		var state = fixture(enabled: true)
		let tab = state.workspace.tabs[0]
		state.tabsTearingOff = [tab.id]
		state.mediaRehostingSources = [tab.id]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.close = { _ in }
		}

		await store.send(.event(.tabTornOff(tab, Space.ID(rawValue: UUID(99)), .zero))).finish()

		#expect(store.tabsTearingOff.isEmpty)
		#expect(!store.mediaRehostingSources.contains(tab.id))
	}

	@Test(arguments: [false, true])
	internal func arxResigningActiveFloatsNothing(quitting: Bool) async throws {
		var state = fixture(enabled: true)
		state.shouldQuit = quitting
		let source = state.media.snapshot.sources[0]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(isAvailable: true, perform: { request in requests.withValue { $0.append(request) } })
		}
		await store.send(report(source, window: state.main.id, visible: true)).finish()
		await store.send(.event(.browserActivityChanged(isActive: false))).finish()

		// Its window is still on the display, so the video keeps playing in place (DEV-1246).
		#expect(requests.value.isEmpty)
		expectNoDifference(store.media.automaticEntry.isApplicationActive, quitting)
	}

	/// DEV-1246: another app covering the window, as when Arx loses focus to it, isn't leaving the
	/// display. The window leaving it (minimised, hidden, or full screen on another OS workspace)
	/// is, whichever report arrives first.
	@Test(arguments: [false, true])
	internal func onlyTheWindowLeavingTheDisplayFloatsTheVideo(displayReportFirst: Bool) async throws {
		let state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(isAvailable: true, perform: { request in requests.withValue { $0.append(request) } })
		}
		await store.send(.event(.windowsOnDisplayChanged([state.main.id]))).finish()
		await store.send(report(source, window: state.main.id, visible: true)).finish()
		await store.send(.event(.browserActivityChanged(isActive: false))).finish()

		// Covered by the app in front.
		await store.send(report(source, window: state.main.id, visible: false)).finish()
		#expect(requests.value.isEmpty)
		expectNoDifference(store.mediaSourceVisibility[source.id], true)

		// The window leaves the display.
		if displayReportFirst {
			// The page already reads as covered, so leaving the display is enough.
			await store.send(.event(.windowsOnDisplayChanged([]))).finish()
			await store.send(report(source, window: state.main.id, visible: false)).finish()
		} else {
			await store.send(report(source, window: state.main.id, visible: false)).finish()
			#expect(requests.value.isEmpty)
			await store.send(.event(.windowsOnDisplayChanged([]))).finish()
		}
		expectNoDifference(requests.value, [.init(source: source, action: .enterAutomaticPictureInPicture)])
		expectNoDifference(store.mediaSourceVisibility[source.id], false)
	}

	/// DEV-1246: a call's tab floats whole, in Page PiP, when its window leaves the display.
	@Test
	internal func aCallFloatsItsPageWhenItsWindowLeavesTheDisplay() async throws {
		var state = fixture(enabled: true)
		state.media.snapshot.sources[0].hasVideo = false
		state.media.snapshot.sources[0].call = .init(isMicrophoneOn: true, isCameraOn: true)
		let source = state.media.snapshot.sources[0]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserSurface.release = { _ in }
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserMedia = .init(isAvailable: true, perform: { request in requests.withValue { $0.append(request) } })
		}
		await store.send(.event(.windowsOnDisplayChanged([state.main.id]))).finish()
		await store.send(report(source, window: state.main.id, visible: true)).finish()
		await store.send(.event(.windowsOnDisplayChanged([]))).finish()
		await store.send(report(source, window: state.main.id, visible: false)).finish()

		#expect(requests.value.isEmpty)
		expectNoDifference(store.pagePictureInPicture?.tabID, source.id.tabID)
		expectNoDifference(store.pagePictureInPicture?.windowID, state.main.id)
	}

	/// DEV-1246: a call's automatic Page PiP goes back to its tab once the person returns to it,
	/// with its window on the display and Arx in front. One the person opened stays.
	@Test(arguments: [false, true])
	internal func anAutomaticPagePictureInPictureReturnsWithItsTab(manual: Bool) async throws {
		var state = fixture(enabled: true)
		state.media.snapshot.sources[0].hasVideo = false
		state.media.snapshot.sources[0].call = .init(isMicrophoneOn: true, isCameraOn: true)
		let source = state.media.snapshot.sources[0]
		let call = state.workspace.tabs[0]
		let other = state.workspace.tabs[1]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserSurface.release = { _ in }
			$0.browserSurface.focus = { _ in }
			$0.browserMedia = .init(isAvailable: true, perform: { _ in })
		}
		await store.send(.event(.windowsOnDisplayChanged([state.main.id]))).finish()
		await store.send(report(source, window: state.main.id, visible: true)).finish()
		if manual {
			await store.send(.ui(.presentTabInPictureInPicture(call.id, windowID: state.main.id))).finish()
		}
		await store.send(.main(.viewer(.show(other, in: state.main.viewer.activePaneID)))).finish()
		await store.send(report(source, window: state.main.id, visible: nil)).finish()
		expectNoDifference(store.pagePictureInPicture?.tabID, call.id)
		expectNoDifference(store.pagePictureInPicture?.phase, .open)
		expectNoDifference(store.automaticPagePictureInPicture, manual ? nil : call.id)

		await store.send(.main(.viewer(.show(call, in: state.main.viewer.activePaneID)))).finish()
		expectNoDifference(store.pagePictureInPicture?.phase, manual ? .open : .returning(focusesTab: false))
		#expect(store.automaticPagePictureInPicture == nil)
	}

	/// DEV-1246: a call in an additional window floats from that window, and returns there.
	@Test
	internal func anAutomaticPagePictureInPictureKeepsTheWindowThatShowedTheCall() async throws {
		var state = fixture(enabled: true)
		state.media.snapshot.sources[0].hasVideo = false
		state.media.snapshot.sources[0].call = .init(isMicrophoneOn: true, isCameraOn: true)
		let source = state.media.snapshot.sources[0]
		let call = state.workspace.tabs[0]
		let other = state.workspace.tabs[1]
		let windowID = UUID(90)
		state.main.viewer.item = .init(tab: other)
		state.windows.append(.init(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: windowID))
		state.windows[id: windowID]?.viewer.item = .init(tab: call)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserSurface.release = { _ in }
			$0.browserSurface.focus = { _ in }
			$0.browserMedia = .init(isAvailable: true, perform: { _ in })
		}
		let pane = try #require(store.windows[id: windowID]?.viewer.activePaneID)
		await store.send(.event(.windowsOnDisplayChanged([state.main.id, windowID]))).finish()
		await store.send(report(source, window: windowID, visible: true)).finish()
		await store.send(.windows(.element(id: windowID, action: .viewer(.show(other, in: pane))))).finish()
		await store.send(report(source, window: windowID, visible: nil)).finish()
		expectNoDifference(store.pagePictureInPicture?.windowID, windowID)
		expectNoDifference(store.pagePictureInPicture?.phase, .open)

		await store.send(.windows(.element(id: windowID, action: .viewer(.show(call, in: pane))))).finish()
		expectNoDifference(store.pagePictureInPicture?.phase, .returning(focusesTab: false))
	}

	/// DEV-1246: a call in Little Arx turns the Little Arx window into Page PiP.
	@Test
	internal func aCallInLittleArxTurnsItsWindowIntoPagePictureInPicture() async throws {
		var state = fixture(enabled: true)
		state.media.snapshot.sources[0].hasVideo = false
		state.media.snapshot.sources[0].call = .init(isMicrophoneOn: true, isCameraOn: true)
		let source = state.media.snapshot.sources[0]
		let tab = state.workspace.tabs[0]
		state.main.viewer.item.tab = nil
		let littleID = UUID(82)
		state.littleWindows.append(.init(id: littleID, spaceID: state.main.sidebar.spaceID, tab: tab))
		state.littleWindows[id: littleID]?.viewer.tab = tab
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(isAvailable: true, perform: { _ in Issue.record("A call floats its page") })
		}
		await store.send(.event(.windowsOnDisplayChanged([littleID]))).finish()
		await store.send(report(source, window: littleID, visible: true, host: UUID(200))).finish()
		await store.send(.event(.windowsOnDisplayChanged([]))).finish()
		await store.send(report(source, window: littleID, visible: false, host: UUID(200))).finish()
		#expect(store.littleWindows[id: littleID]?.isPictureInPicture == true)
		#expect(store.pagePictureInPicture == nil)
	}

	/// DEV-1246: an automatic Page PiP never replaces a page already floating.
	@Test
	internal func anAutomaticPagePictureInPictureLeavesAFloatingPageAlone() async throws {
		var state = fixture(enabled: true)
		state.media.snapshot.sources[0].hasVideo = false
		state.media.snapshot.sources[0].call = .init(isMicrophoneOn: true, isCameraOn: true)
		let source = state.media.snapshot.sources[0]
		let other = state.workspace.tabs[1].id
		state.pagePictureInPicture = .init(tabID: other, windowID: state.main.id)
		state.pagePictureInPicture?.phase = .open
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserSurface.release = { _ in }
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserMedia = .init(isAvailable: true, perform: { _ in })
		}
		await store.send(report(source, window: state.main.id, visible: true)).finish()
		await store.send(report(source, window: state.main.id, visible: false)).finish()
		expectNoDifference(store.pagePictureInPicture?.tabID, other)
		expectNoDifference(store.pagePictureInPicture?.phase, .open)
	}

	@Test
	internal func reconcilingAfterEachActionLooksUpOnlyTheMediaTabs() async throws {
		let state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(isAvailable: true, perform: { _ in })
		}
		let counts = WorkProbe.Counts()
		await WorkProbe.$counts.withValue(counts) {
			await store.send(report(source, window: state.main.id, visible: true)).finish()
			await store.send(.event(.browserActivityChanged(isActive: true))).finish()
			await store.send(report(source, window: state.main.id, visible: false)).finish()
		}

		// Media visibility is reconciled after every action, engine events included, so it must
		// not list every tab of every window (DEV-945).
		expectNoDifference(counts[.allTabIDs], 0)
		expectNoDifference(store.mediaSourceVisibility[source.id], false)
	}

	/// DEV-991: a window going in or out of macOS full screen can read as covered while its Space
	/// moves. The video stays put until the transition has settled; a real hide after that still
	/// floats it.
	@Test
	internal func aFullScreenTransitionNeverFloatsTheVideo() async throws {
		let state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let clock = TestClock()
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.continuousClock = clock
			$0.browserMedia = .init(isAvailable: true, perform: { request in requests.withValue { $0.append(request) } })
		}
		await store.send(report(source, window: state.main.id, visible: true)).finish()

		await store.send(.event(.windowFullScreenTransition(state.main.id, isTransitioning: true))).finish()
		await store.send(report(source, window: state.main.id, visible: false)).finish()
		#expect(requests.value.isEmpty)
		expectNoDifference(store.mediaSourceVisibility[source.id], true)

		// Its report catches up just after the transition ends, before it has settled.
		let ending = store.send(.event(.windowFullScreenTransition(state.main.id, isTransitioning: false)))
		await store.send(report(source, window: state.main.id, visible: false)).finish()
		await store.send(report(source, window: state.main.id, visible: true)).finish()
		await clock.advance(by: .milliseconds(500))
		await ending.finish()
		#expect(store.fullScreenTransitionWindows.isEmpty)
		#expect(requests.value.isEmpty)
		expectNoDifference(store.mediaSourceVisibility[source.id], true)

		await store.send(report(source, window: state.main.id, visible: false)).finish()
		expectNoDifference(requests.value, [.init(source: source, action: .enterAutomaticPictureInPicture)])
	}

	/// A transition that starts again before the last one settled keeps the window waiting.
	@Test
	internal func aNewTransitionCancelsTheLastOnesSettling() async throws {
		let state = fixture(enabled: true)
		let clock = TestClock()
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.continuousClock = clock
			$0.browserMedia.perform = { _ in Issue.record("Nothing may float during a transition") }
		}
		await store.send(.event(.windowFullScreenTransition(state.main.id, isTransitioning: true))).finish()
		let ended = store.send(.event(.windowFullScreenTransition(state.main.id, isTransitioning: false)))
		await clock.advance(by: .milliseconds(300))
		await store.send(.event(.windowFullScreenTransition(state.main.id, isTransitioning: true))).finish()
		await clock.advance(by: .seconds(1))
		await ended.finish()
		expectNoDifference(store.fullScreenTransitionWindows, [state.main.id])
	}

	/// DEV-1322: an OS workspace switch takes a window off the display only when it's full screen,
	/// alone or tiled beside another app's in Split View (AppKit reports `.fullScreen` for both).
	/// Minimising it or hiding Arx takes any window off.
	@Test(arguments: [
		(WindowDisplay(isShown: true, isFullScreen: false, isOnActiveSpace: true), true),
		(WindowDisplay(isShown: true, isFullScreen: false, isOnActiveSpace: false), true),
		(WindowDisplay(isShown: true, isFullScreen: true, isOnActiveSpace: true), true),
		(WindowDisplay(isShown: true, isFullScreen: true, isOnActiveSpace: false), false),
		(WindowDisplay(isShown: false, isFullScreen: false, isOnActiveSpace: true), false),
		(WindowDisplay(isShown: false, isFullScreen: false, isOnActiveSpace: false), false),
		(WindowDisplay(isShown: false, isFullScreen: true, isOnActiveSpace: true), false),
	])
	internal func anOSWorkspaceSwitchCountsOnlyForAFullScreenWindow(
		window: WindowDisplay,
		isOnDisplay: Bool
	) {
		expectNoDifference(window.isOnDisplay, isOnDisplay)
	}

	/// DEV-1322: the person switches OS workspaces while a video plays in a window. A full-screen
	/// one (alone or tiled, `WindowDisplay` can't tell them apart) floats the video; one that isn't
	/// full screen keeps it playing in place, its page reading as covered. Coming back shows the
	/// video on the page again.
	@Test(arguments: [false, true])
	internal func anOSWorkspaceSwitchFloatsTheVideoOnlyFromAFullScreenWindow(fullScreen: Bool) async throws {
		let state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(isAvailable: true, perform: { request in requests.withValue { $0.append(request) } })
		}
		func osWorkspace(isActive: Bool) -> AppFeature.Action {
			let window = WindowDisplay(isShown: true, isFullScreen: fullScreen, isOnActiveSpace: isActive)
			return .event(.windowsOnDisplayChanged(window.isOnDisplay ? [state.main.id] : []))
		}
		await store.send(osWorkspace(isActive: true)).finish()
		await store.send(report(source, window: state.main.id, visible: true)).finish()

		// Another OS workspace comes forward, with another app in front.
		await store.send(.event(.browserActivityChanged(isActive: false))).finish()
		await store.send(osWorkspace(isActive: false)).finish()
		await store.send(report(source, window: state.main.id, visible: false)).finish()
		if fullScreen {
			expectNoDifference(requests.value, [.init(source: source, action: .enterAutomaticPictureInPicture)])
			expectNoDifference(store.mediaSourceVisibility[source.id], false)
		} else {
			expectNoDifference(requests.value, [])
			expectNoDifference(store.mediaSourceVisibility[source.id], true)
			expectNoDifference(store.media.automaticEntry.owed, [:])
		}

		// Back on Arx's OS workspace.
		await store.send(osWorkspace(isActive: true)).finish()
		await store.send(report(source, window: state.main.id, visible: true)).finish()
		await store.send(.event(.browserActivityChanged(isActive: true))).finish()
		expectNoDifference(store.mediaSourceVisibility[source.id], true)
		expectNoDifference(requests.value.count, fullScreen ? 1 : 0)
	}

	/// DEV-1322: with several windows, the one that shows the video decides. Leaving a full-screen
	/// window's OS workspace floats nothing when the video plays in another that isn't full
	/// screen, and floats the video when it's the full-screen one, though the other stays.
	@Test(arguments: [false, true])
	internal func theWindowShowingTheVideoDecides(videoInFullScreenWindow: Bool) async throws {
		var state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		let video = state.workspace.tabs[0]
		let other = state.workspace.tabs[1]
		let windowID = UUID(90)
		state.windows.append(.init(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: windowID))

		// The full-screen window is the additional one; the main window isn't full screen.
		let videoWindow = videoInFullScreenWindow ? windowID : state.main.id
		state.main.viewer.item = .init(tab: videoInFullScreenWindow ? other : video)
		state.windows[id: windowID]?.viewer.item = .init(tab: videoInFullScreenWindow ? video : other)
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(isAvailable: true, perform: { request in requests.withValue { $0.append(request) } })
		}
		func osWorkspace(onFullScreenWindow: Bool) -> AppFeature.Action {
			let windowed = WindowDisplay(isShown: true, isFullScreen: false, isOnActiveSpace: !onFullScreenWindow)
			let fullScreen = WindowDisplay(isShown: true, isFullScreen: true, isOnActiveSpace: onFullScreenWindow)
			let onDisplay: Set<UUID> = Set([
				windowed.isOnDisplay ? state.main.id : nil,
				fullScreen.isOnDisplay ? windowID : nil,
			].compactMap(\.self))
			return .event(.windowsOnDisplayChanged(onDisplay))
		}
		await store.send(osWorkspace(onFullScreenWindow: true)).finish()
		await store.send(report(source, window: videoWindow, visible: true)).finish()

		// The person leaves the full-screen window's OS workspace for the desktop one.
		await store.send(osWorkspace(onFullScreenWindow: false)).finish()
		await store.send(report(source, window: videoWindow, visible: false)).finish()
		if videoInFullScreenWindow {
			expectNoDifference(requests.value, [.init(source: source, action: .enterAutomaticPictureInPicture)])
		} else {
			expectNoDifference(requests.value, [])
			expectNoDifference(store.mediaSourceVisibility[source.id], true)
		}
	}

	/// DEV-1322: the person presents the video in Picture in Picture themself, then switches OS
	/// workspaces, from a window full screen or not. Their entry goes through as asked, and Arx
	/// adds no automatic one of its own.
	@Test(arguments: [false, true])
	internal func manualPictureInPictureIsLeftAloneByAnOSWorkspaceSwitch(fullScreen: Bool) async throws {
		let state = fixture(enabled: true)
		let source = state.media.snapshot.sources[0]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(isAvailable: true, perform: { request in requests.withValue { $0.append(request) } })
		}
		func osWorkspace(isActive: Bool) -> AppFeature.Action {
			let window = WindowDisplay(isShown: true, isFullScreen: fullScreen, isOnActiveSpace: isActive)
			return .event(.windowsOnDisplayChanged(window.isOnDisplay ? [state.main.id] : []))
		}
		await store.send(osWorkspace(isActive: true)).finish()
		await store.send(report(source, window: state.main.id, visible: true)).finish()

		await store.send(.media(.ui(.perform(source.id, .enterPictureInPicture)))).finish()
		var floating = source
		floating.revision = 2
		floating.isInPictureInPicture = true
		floating.actions = [.exitPictureInPicture]
		await store.send(.media(.event(.changed(.init(revision: 2, sources: [floating]), observationID: 1)))).finish()

		await store.send(.event(.browserActivityChanged(isActive: false))).finish()
		await store.send(osWorkspace(isActive: false)).finish()
		await store.send(report(source, window: state.main.id, visible: false)).finish()
		expectNoDifference(requests.value, [.init(source: source, action: .enterPictureInPicture)])
		expectNoDifference(store.media.automaticEntry.owed, [:])
		expectNoDifference(store.media.automaticEntry.deactivationEntries, [])
	}

	private func report(
		_ source: BrowserMediaSource,
		window: UUID,
		visible: Bool?,
		host: UUID = UUID(201)
	) -> AppFeature.Action {
		.event(.mediaSurfaceVisibility(window, .init(hostID: host, tabID: source.id.tabID, isVisible: visible)))
	}

	private func fixture(enabled: Bool) -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		let source = BrowserMediaSource(
			id: .init(tabID: tab.id, profileID: tab.profileID, generation: 3),
			revision: 1,
			title: "Video",
			site: .init(url: URL(string: "https://capturecontext.dev/video")!),
			hasVideo: true,
			playback: .playing,
			actions: [.enterPictureInPicture, .enterAutomaticPictureInPicture]
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70))
		)
		_ = state.settings.$automaticPictureInPicture.withLock { $0.setEnabled(enabled, for: source) }
		state.media.automatic = state.settings.automaticPictureInPicture
		state.main.viewer.item = .init(tab: tab)
		state.media.isAvailable = true
		state.media.isObserving = true
		state.media.observationID = 1
		state.media.snapshot = .init(revision: 1, sources: [source])
		return state
	}
}
