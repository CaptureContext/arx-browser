import AppUI
import BrowserCore
import BrowserCaptureClient
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import LittleArxFeature
import PageCaptureFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct CaptureSessionTests {
	@Test
	internal func unavailableCaptureIsAbsentFromCommandsAndDoesNotPrepare() async throws {
		var state = fixture()
		state.captureAvailable = false
		state.main.captureAvailable = false
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in
				Issue.record("Unavailable capture must not inspect a page")
				return nil
			}
		}
		#expect(!state.main.commandCandidates.contains { $0.intent == .command(.captureViewport) })
		await store.send(.ui(.command(.captureViewport, .window(state.main.id))))
		await store.send(.ui(.capturePage(.window(state.main.id), region: false)))
		await store.finish()
	}

	@Test
	internal func queuedCommandCannotCaptureAReplacementTabInTheSamePane() async throws {
		var state = fixture()
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		state.main.viewer.item.tab = state.workspace.tabs[1]
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in
				Issue.record("Replaced origin must not inspect the new tab")
				return nil
			}
		}
		await store.send(.ui(.capturePage(.window(state.main.id), source: source, region: false)))
		await store.finish()
	}

	@Test
	internal func preparationRetainsOriginWhenFocusChangesDuringSnapshot() async throws {
		let state = fixture()
		let tabID = try #require(state.main.viewer.item.tab?.id)
		let origin = state.main.viewer.activePaneID
		let context = CaptureStoreContext()
		var queried: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { id in
				queried.append(id)
				context.store?.send(.main(.viewer(.ui(.focus(UUID(20))))))
				return .init(navigation: .init(), revision: 7)
			}
		}
		context.store = store
		await store.send(.ui(.command(.captureRegion, .window(state.main.id, paneID: origin)))).finish()
		let session = try #require(store.captureSessions.first)
		expectNoDifference(session.source.host, .pane(windowID: state.main.id, paneID: origin))
		expectNoDifference(session.request, .init(tabID: tabID, revision: 7))
		expectNoDifference(session.mode, .area)
		expectNoDifference(session.phase, .selecting)
		expectNoDifference(store.main.viewer.activePaneID, UUID(20))
		expectNoDifference(queried, [tabID])
	}

	/// Max (18 Nov): Capture the Page took only the viewport. It now asks for the whole document.
	@Test
	internal func capturePageAsksTheEngineForTheWholeDocument() async throws {
		let state = fixture()
		let tabID = try #require(state.main.viewer.item.tab?.id)
		let requests = LockIsolated<[PageCaptureRequest]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 7) }
			$0.browserCapture.fullDocumentIsAvailable = { true }
			$0.browserCapture.captureAuthorized = { request, _ in
				requests.withValue { $0.append(request) }
				throw PageCaptureFailure.busy
			}
		}

		await store.send(.ui(.command(.captureViewport, .window(state.main.id)))).finish()

		let session = try #require(store.captureSessions.first)
		expectNoDifference(session.mode, .page)
		expectNoDifference(requests.value, [.init(tabID: tabID, revision: 7, mode: .fullDocument)])
	}

	@Test
	internal func removalDuringPreparationRejectsTheOriginalPaneWithoutRetargeting() async throws {
		let state = fixture()
		let origin = state.main.viewer.activePaneID
		let context = CaptureStoreContext()
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in
				context.store?.send(.main(.viewer(.ui(.closePane(origin)))))
				return .init(navigation: .init(), revision: 7)
			}
		}
		context.store = store
		await store.send(.ui(.capturePage(.window(state.main.id, paneID: origin), region: false))).finish()

		// The page it was for is gone, so the capture ends rather than moving to another page.
		#expect(store.captureSessions.isEmpty)
		expectNoDifference(store.main.viewer.panes.count, 1)
	}

	@Test
	internal func supersededAndDismissedPreparationCannotReopenCapture() async throws {
		var state = fixture()
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		let id = UUID(80), token = UUID(81)
		state.captureSessions.append(.init(id: id, source: source, title: "Page", mode: .visible, sourceGeneration: 0, preparation: token))
		let store = TestStore(initialState: state) { AppFeature() }
		await store.send(.event(.capturePrepared(id, UUID(82), .init(navigation: .init(), revision: 7))))
		await store.send(.ui(.closeCapture(id))) { $0.captureSessions = [] }
		await store.send(.event(.capturePrepared(id, token, .init(navigation: .init(), revision: 7))))
		await store.finish()
	}

	/// Back-to-back preparations race to register their snapshot effects off the main actor.
	/// The newest preparation must open the capture whichever effect registers first.
	@Test
	internal func backToBackPreparationsOpenTheNewestCapture() async throws {
		var state = fixture()
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		let id = UUID(80)
		state.captureSessions.append(.init(id: id, source: source, title: "Page", mode: .area, sourceGeneration: 0))
		var lost = 0

		for _ in 0..<200 {
			let store = Store(initialState: state) { AppFeature() } withDependencies: {
				$0.uuid = .incrementing
				$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 7) }
			}
			let older = store.send(.prepareCapture(id))
			let newer = store.send(.prepareCapture(id))
			await older.finish()
			await newer.finish()

			let session = store.captureSessions[id: id]
			if session?.preparation != nil || session?.request != .init(tabID: source.tabID, revision: 7) { lost += 1 }
		}

		#expect(lost == 0)
	}

	@Test
	internal func liveAuthorizationRequiresExactPlacementProfileGenerationAndRevision() throws {
		var state = try capturedFixture()
		let id = UUID(80)
		let request = try #require(state.captureSessions[id: id]?.request)
		let snapshot = BrowserSessionSnapshot(navigation: .init(), revision: 7)
		#expect(state.captureCanExecute(id, request: request, snapshot: snapshot))
		let staleSnapshot = BrowserSessionSnapshot(navigation: .init(), revision: 8)
		expectNoDifference(state.captureCanExecute(id, request: request, snapshot: staleSnapshot), false)
		#expect(!state.captureCanExecute(UUID(81), request: request, snapshot: snapshot))
		state.main.viewer.item.generation += 1
		#expect(!state.captureCanExecute(id, request: request, snapshot: snapshot))
		state.main.viewer.item.generation -= 1
		let tab = try #require(state.main.viewer.item.tab)
		state.main.viewer.item.tab = .init(id: tab.id, profileID: .init(rawValue: UUID(90)), restoration: tab.restoration)
		#expect(!state.captureCanExecute(id, request: request, snapshot: snapshot))
	}

	@Test
	internal func capturedFrameSurvivesSourceCloseAndRetakeEndsTheCapture() async throws {
		let state = try capturedFixture()
		let frozen = state.captureSessions[id: UUID(80)]
		var queried = 0
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in
				queried += 1
				return nil
			}
		}
		await store.send(.ui(.closeWindow)).finish()
		expectNoDifference(store.captureSessions[id: UUID(80)], frozen)
		await store.send(.captureSessions(.element(id: UUID(80), action: .ui(.retake)))).finish()
		#expect(store.captureSessions.isEmpty)
		expectNoDifference(queried, 0)
	}

	@Test
	internal func escapeEndsTheCaptureAndLeavesTheBrowserIntact() async throws {
		let state = try capturedFixture()
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.close = { _ in Issue.record("Ending a capture cannot close its tab") }
		}
		await store.send(.captureSessions(.element(id: UUID(80), action: .ui(.cancel)))).finish()
		#expect(store.captureSessions.isEmpty && store.windowIsOpen)
		expectNoDifference(store.main, state.main)
		expectNoDifference(store.workspace, state.workspace)
	}

	@Test
	internal func capturingAgainReplacesTheSessionOnThatPage() async throws {
		let state = try capturedFixture()
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 7, documentRevision: 3) }
		}
		await store.send(.ui(.capturePage(.window(state.main.id), region: true))).finish()
		let session = try #require(store.captureSessions.first)
		#expect(store.captureSessions.count == 1 && session.id != UUID(80))
		expectNoDifference(session.mode, .area)
		expectNoDifference(session.inspection?.documentRevision, 3)
		expectNoDifference(session.inspection?.sessionRevision, 7)
		expectNoDifference(session.inspection?.tabID, session.source.tabID)
	}

	@Test
	internal func privateLittleAndPeekSourcesRetainTheirOwnSessionIdentity() throws {
		var state = fixture()
		let tab = state.workspace.tabs[0]
		var privateWindow = MainFeature.State(
			organization: state.workspace,
			spaceID: state.main.sidebar.spaceID,
			isPrivate: true,
			id: UUID(31)
		)
		privateWindow.viewer.item = .init(tab: tab)
		state.windows.append(privateWindow)
		let privateSource = try #require(state.captureSource(for: .window(privateWindow.id)))
		#expect(state.captureViewer(for: privateSource)?.tab?.id == tab.id)
		var little = LittleArxFeature.State(id: UUID(32), spaceID: state.main.sidebar.spaceID, tab: tab)
		little.viewer = .init(tab: tab)
		state.littleWindows.append(little)
		let littleSource = try #require(state.captureSource(for: .window(little.id)))
		expectNoDifference(littleSource.host, .little(little.id))
		#expect(state.captureViewer(for: littleSource)?.tab?.id == tab.id)
		var peek = PeekFeature.State(
			id: UUID(33),
			source: .init(
				windowID: state.main.id,
				paneID: state.main.viewer.activePaneID,
				tabID: tab.id,
				spaceID: state.main.sidebar.spaceID,
				profileID: tab.profileID,
				identity: "Capture"
			),
			tab: tab,
			isTemporary: true
		)
		peek.viewer = .init(tab: tab)
		state.peeks.append(peek)
		let peekSource = try #require(state.captureSource(for: .peek(peek.id)))
		expectNoDifference(peekSource.host, .peek(peek.id))
		#expect(state.captureViewer(for: peekSource)?.tab?.id == tab.id)
		let underlying = try #require(state.captureSource(for: .window(state.main.id)))
		#expect(state.captureViewer(for: underlying) == nil)
		state.peeks.removeAll()
		#expect(state.captureViewer(for: peekSource) == nil)
	}

	/// DEV-757: the developer header's device capture does nothing with its feature flag off.
	@Test
	internal func deviceCaptureNeedsItsFeatureFlag() async throws {
		var state = fixture()
		state.settings.$general.withLock {
			$0.developerModeEnabled = true
			$0.developerHeaderEnabled = true
		}
		state.main.showsDeveloperHeader = true
		let paneID = state.main.viewer.activePaneID
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.snapshot = { _ in
				Issue.record("A device capture with the flag off must not prepare")
				return nil
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let style = DeviceCaptureStyle(isPortrait: true, gradient: 0.3)
		await store.send(.ui(.captureDevice(.window(state.main.id, paneID: paneID), style)))
		await store.send(.main(.ui(.developerHeader(.captureDevice(style), paneID))))
		await store.finish()

		#expect(store.state.captureSessions.isEmpty)
		expectNoDifference(store.state.main.deviceCaptureStyle, .default)
	}

	/// DEV-757: with the flag on, the header's Capture starts a framed capture of its pane's
	/// page, and the window remembers the style for the popover's next opening.
	@Test
	internal func theDeveloperHeaderStartsAFramedCaptureWithTheFlagOn() async throws {
		var state = fixture()
		state.settings.$general.withLock {
			$0.developerModeEnabled = true
			$0.developerHeaderEnabled = true
		}
		state.deviceCaptureEnabled = true
		state.main.showsDeveloperHeader = true
		state.main.deviceCaptureEnabled = true
		let paneID = state.main.viewer.activePaneID
		let tabID = try #require(state.main.viewer.item.tab?.id)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 7) }
		}

		let style = DeviceCaptureStyle(isPortrait: true, gradient: 0.3, isDark: true)
		await store.send(.main(.ui(.developerHeader(.captureDevice(style), paneID)))).finish()

		let session = try #require(store.captureSessions.first)
		expectNoDifference(session.framing, style)
		expectNoDifference(session.mode, .visible)
		expectNoDifference(session.source.tabID, tabID)
		expectNoDifference(store.main.deviceCaptureStyle, style)
	}

	/// DEV-757: every window takes the app's feature flag, as it takes developer mode.
	@Test
	internal func windowsFollowTheDeviceCaptureFeatureFlag() async throws {
		var state = fixture()
		state.deviceCaptureEnabled = true
		let store = Store(initialState: state) { AppFeature() }
		await store.send(.configureCapture).finish()
		#expect(store.main.deviceCaptureEnabled)
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.captureAvailable = true
		state.main.captureAvailable = true
		state.main.viewer.item = .init(tab: organization.tabs[0])
		state.main.viewer.panes.append(.init(id: UUID(20), item: .init(tab: organization.tabs[1])))
		return state
	}

	private func capturedFixture() throws -> AppFeature.State {
		var state = fixture()
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		state.captureSessions.append(.init(
			id: UUID(80),
			source: source,
			title: "Frozen",
			mode: .visible,
			sourceGeneration: 0,
			phase: .captured,
			request: .init(tabID: source.tabID, revision: 7),
			selection: .init(x: 0, y: 0, width: 10, height: 10),
			image: .init(png: Data([1, 2, 3]), width: 1, height: 1)
		))
		return state
	}
}

@MainActor
private final class CaptureStoreContext {
	weak var store: StoreOf<AppFeature>?
}
