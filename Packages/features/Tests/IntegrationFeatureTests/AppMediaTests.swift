import BrowserCore
import BrowserMediaClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct AppMediaTests {
	@Test
	internal func unavailableMediaHasNoCommandOrLibraryPage() async {
		var state = fixture()
		state.media.isAvailable = false
		let store = Store(initialState: state) { AppFeature() }
		await store.send(.configureMedia).finish()
		await store.send(.ui(.openMediaLibrary(nil))).finish()
		#expect(!store.main.isLibraryOpen)
		#expect(!store.main.librarySections.contains(.media))
		#expect(!store.main.commandCandidates.contains { $0.intent == .command(.media) })
		#expect(!BrowserCommand.media.isEnabled(in: .init(host: .main, isPrivate: true, mediaAvailable: true)))
	}

	@Test
	internal func mediaCommandOpensTheLibraryPageWithoutTouchingPlayback() async {
		var state = fixture()
		state.main.sidebar.sidebarIsVisible = false
		let source = state.media.snapshot.sources[0]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.isSourceCurrent = { _ in true }
			$0.browserMedia.perform = { _ in Issue.record("Opening Media must not change playback") }
			$0.browserEngine.close = { _ in Issue.record("Opening Media must not close a page") }
		}
		await store.send(.ui(.command(.media, .window(state.main.id)))).finish()
		#expect(store.main.isLibraryOpen && store.main.sidebar.sidebarIsVisible)
		expectNoDifference(store.main.libraryPanel, .media)
		#expect(store.media.isObserving)
		expectNoDifference(store.media.snapshot.sources, [source])
		expectNoDifference(store.main.viewer.item.tab?.id, source.id.tabID)
	}

	@Test
	internal func mediaCommandFromLittleArxOrAPrivateWindowUsesAnOrdinaryWindow() async {
		var state = fixture()
		let organization = state.workspace
		let privateID = UUID(73)
		var privateWindow = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true,
			id: privateID
		)
		privateWindow.mediaAvailable = true
		state.windows.append(privateWindow)
		let store = Store(initialState: state) { AppFeature() }
		await store.send(.ui(.openMediaLibrary(privateID))).finish()
		#expect(store.windows[id: privateID]?.isLibraryOpen == false)
		#expect(store.main.isLibraryOpen)
		expectNoDifference(store.main.libraryPanel, .media)
		expectNoDifference(store.focusedWindowID, state.main.id)
	}

	@Test
	internal func muteFlipsTheTabAndTheRowFollowsTheEngine() async {
		let state = fixture()
		let source = state.media.snapshot.sources[0]
		let muted = LockIsolated<Set<BrowserCore.Tab.ID>>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.setMuted = { id, isMuted in
				muted.withValue { if isMuted { $0.insert(id) } else { $0.remove(id) } }
			}
			$0.browserMedia.position = { id in .init(sourceID: nil, isMuted: muted.value.contains(id)) }
		}
		await store.send(.ui(.toggleMediaMute(source.id.tabID))).finish()
		#expect(muted.value == [source.id.tabID])
		expectNoDifference(store.mutedMedia, [source.id.tabID: source])

		await store.send(.ui(.toggleMediaMute(source.id.tabID))).finish()
		#expect(muted.value.isEmpty)
		expectNoDifference(store.mutedMedia, [:])
	}

	@Test
	internal func aMutedPageThatLeavesItsSessionKeepsItsRowUntilUnmuted() async {
		var state = fixture()
		let source = state.media.snapshot.sources[0]
		state.mutedMedia = [source.id.tabID: source]
		let isMuted = LockIsolated(true)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.position = { _ in .init(sourceID: nil, isMuted: isMuted.value) }
		}
		await store.send(.media(.event(.changed(.init(revision: 2), observationID: 1)))).finish()
		#expect(store.media.visibleSources.isEmpty)
		expectNoDifference(store.mutedMedia, [source.id.tabID: source])

		isMuted.setValue(false)
		await store.send(.media(.event(.changed(.init(revision: 3), observationID: 1)))).finish()
		expectNoDifference(store.mutedMedia, [:])
	}

	/// The sidebar's stack and the Media page keep the order media was opened in (DEV-1245). On
	/// `main`, a muted page that left its session moved to the end, and the engine's order of the
	/// sources was the stack's.
	@Test
	internal func theMediaStackKeepsTheOrderMediaWasOpenedThroughMutePauseAndResume() async {
		let state = fixture()
		let profileID = state.main.sidebar.space.profileID
		let first = state.media.snapshot.sources[0]
		let second = stackSource(2, profileID: profileID)
		let third = stackSource(3, profileID: profileID)
		let muted = LockIsolated<Set<BrowserCore.Tab.ID>>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.position = { id in .init(sourceID: nil, isMuted: muted.value.contains(id)) }
		}
		let order = { store.state.mediaStack(of: profileID).map(\.id.tabID) }
		let expected = [first, second, third].map(\.id.tabID)

		// Opened one after another; the engine lists them in its own order.
		await store.send(.media(.event(.changed(.init(revision: 2, sources: [first]), observationID: 1)))).finish()
		await store.send(.media(.event(.changed(.init(revision: 3, sources: [second, first]), observationID: 1)))).finish()
		await store.send(.media(.event(.changed(.init(revision: 4, sources: [third, second, first]), observationID: 1)))).finish()
		expectNoDifference(order(), expected)

		// Pausing the first doesn't move it.
		var paused = first
		paused.playback = .paused
		await store.send(.media(.event(.changed(.init(revision: 5, sources: [third, second, paused]), observationID: 1)))).finish()
		expectNoDifference(order(), expected)

		// Muting the second, which then leaves its media session, keeps its place.
		muted.withValue { _ = $0.insert(second.id.tabID) }
		await store.send(.event(.mediaMuteChanged(second.id.tabID, true))).finish()
		await store.send(.media(.event(.changed(.init(revision: 6, sources: [third, paused]), observationID: 1)))).finish()
		expectNoDifference(order(), expected)

		// Resuming the first and unmuting the second, back as a new source of its tab, keeps them.
		var resumed = second
		resumed.id.generation += 1
		muted.withValue { _ = $0.remove(second.id.tabID) }
		await store.send(.media(.event(.changed(.init(revision: 7, sources: [resumed, third, first]), observationID: 1)))).finish()
		await store.send(.event(.mediaMuteChanged(second.id.tabID, false))).finish()
		expectNoDifference(order(), expected)

		// Media that leaves its page goes to the end when it comes back.
		await store.send(.media(.event(.changed(.init(revision: 8, sources: [resumed, third]), observationID: 1)))).finish()
		await store.send(.media(.event(.changed(.init(revision: 9, sources: [resumed, third, first]), observationID: 1)))).finish()
		expectNoDifference(order(), [second, third, first].map(\.id.tabID))
	}

	@Test
	internal func aMutedRowWithoutASessionStillReturnsToItsTab() async {
		var state = fixture()
		let tab = state.workspace.tabs[1]
		let source = media(tab)
		state.media.snapshot.sources = []
		state.mutedMedia = [tab.id: source]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			$0.browserSurface.focus = { _ in }
		}
		await store.send(.ui(.returnToMutedMedia(tab.id))).finish()
		expectNoDifference(store.main.viewer.item.tab?.id, tab.id)
		#expect(store.mediaSourceFocusRequest == 1)
	}

	@Test(arguments: [false, true])
	internal func returnFocusesTheExistingSplitPaneWithoutReopening(additional: Bool) async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0]
		state.main.viewer.item = .init(tab: state.workspace.tabs[1])
		state.main.viewer.panes.append(.init(id: UUID(71), item: .init(tab: tab, generation: 9)))
		let hostID = additional ? UUID(72) : state.main.id
		if additional {
			var host = MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: hostID)
			host.viewer = state.main.viewer
			state.windows.append(host)
			state.main.viewer.panes.removeAll { $0.id == UUID(71) }
		}
		let source = state.media.snapshot.sources[0]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.isSourceCurrent = { _ in true }
			$0.browserEngine.open = { _ in Issue.record("Returning to a mounted source must not reopen it") }
			$0.browserEngine.close = { _ in Issue.record("Returning to a mounted source must not close it") }
			$0.browserSurface.focus = { _ in }
		}
		await store.send(.media(.ui(.returnToTab(source.id)))).finish()
		let host = try #require(additional ? store.windows[id: hostID] : store.main)
		expectNoDifference(store.focusedWindowID, hostID)
		expectNoDifference(host.viewer.activePaneID, UUID(71))
		expectNoDifference(host.viewer.item.generation, 9)
		#expect(store.mediaSourceFocusRequest == 1)
	}

	@Test(arguments: ["generation", "profile", "private", "closing", "removed", "quit"])
	internal func staleOrClosingSourcesDoNotTakeFocus(reason: String) async {
		var state = fixture()
		var source = state.media.snapshot.sources[0].id
		switch reason {
		case "generation": source.generation += 1
		case "profile": source.profileID = .init(rawValue: UUID(99))
		case "private": state.media.snapshot.sources[0].isPrivate = true
		case "closing": state.main.pendingTabCloses.insert(source.tabID)
		case "removed": state.workspace.tabs.removeAll { $0.id == source.tabID }
		default: state.checkingQuit = true
		}
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.isSourceCurrent = { _ in true }
			$0.browserEngine.open = { _ in Issue.record("Rejected media return must not open a page") }
		}
		await store.send(.media(.ui(.returnToTab(source)))).finish()
		#expect(store.mediaSourceFocusRequest == 0)
	}

	@Test(arguments: [false, true], [false, true])
	internal func temporarySourceReturnsToItsOwningLittleOrPeekWithoutPromotion(
		peek: Bool,
		current: Bool
	) async throws {
		var state = fixture()
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "Temporary media", url: URL(string: "https://capturecontext.dev/video")!)
		)
		let source = media(tab)
		state.media.snapshot.sources = [source]
		if peek {
			state.peeks.append(.init(
				id: UUID(81),
				source: .init(
					windowID: state.main.id,
					paneID: state.main.viewer.activePaneID,
					tabID: state.workspace.tabs[0].id,
					spaceID: state.main.sidebar.spaceID,
					profileID: tab.profileID,
					identity: "Fixture"
				),
				tab: tab,
				isTemporary: true
			))
			state.peeks[id: UUID(81)]?.viewer = .init(tab: tab)
		} else {
			state.littleWindows.append(.init(id: UUID(82), spaceID: state.main.sidebar.spaceID, tab: tab))
			state.littleWindows[id: UUID(82)]?.viewer = .init(tab: tab)
		}
		let workspace = state.workspace
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.isSourceCurrent = { _ in current }
			$0.browserEngine.open = { _ in Issue.record("A temporary source must keep its existing host") }
		}
		await store.send(.media(.ui(.returnToTab(source.id)))).finish()
		expectNoDifference(store.focusedWindowID, current ? (peek ? state.main.id : UUID(82)) : state.focusedWindowID)
		expectNoDifference(store.workspace, workspace)
		#expect(store.mediaSourceFocusRequest == (current ? 1 : 0))
	}

	@Test
	internal func sourceFromAnotherProfileRestoresItsOwnSpace() async throws {
		var state = fixture()
		let profile = Profile.ID(rawValue: UUID(90))
		let space = Space.ID(rawValue: UUID(91))
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(92)),
			profileID: profile,
			restoration: .init(title: "Work video", url: URL(string: "https://capturecontext.dev/video")!)
		)
		state.workspace.profiles.append(.init(id: profile, name: "Work"))
		state.workspace.spaces.append(.init(id: space, profileID: profile, name: "Video", unpinnedTabs: [tab.id]))
		state.workspace.tabs.append(tab)
		state.main.sidebar.organization = state.workspace
		state.media.snapshot.sources = [media(tab)]
		let source = state.media.snapshot.sources[0]
		var opened: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.isSourceCurrent = { _ in true }
			$0.browserEngine.open = { opened.append($0.id) }
			$0.browserEngine.events = { _ in .finished }
		}
		await store.send(.media(.ui(.returnToTab(source.id)))).finish()
		expectNoDifference(store.main.sidebar.spaceID, space)
		expectNoDifference(store.main.viewer.item.tab?.id, tab.id)
		expectNoDifference(store.main.viewer.item.tab?.profileID, profile)
		#expect(opened.allSatisfy { $0 == tab.id })
		#expect(store.mediaSourceFocusRequest == 1)
	}

	@Test(arguments: ["unchanged", "staleObservation", "settings", "existingUtility", "navigation", "nativeInvalidated"])
	internal func delayedReturnDoesNotOverrideANewerPresentation(change: String) async throws {
		var state = fixture()
		if change == "existingUtility" { state.settingsIsOpen = true }
		state.media.snapshot.sources[0].isInPictureInPicture = true
		state.media.snapshot.sources[0].actions = [.exitPictureInPicture]
		let source = state.media.snapshot.sources[0]
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		var nativeCurrent = true
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.isSourceCurrent = { _ in true }
			$0.uuid = .incrementing
			$0.browserMedia = .init(isAvailable: true, isSourceCurrent: { _ in nativeCurrent }, perform: { request in
				expectNoDifference(request.sourceID, source.id)
				expectNoDifference(request.action, .exitPictureInPicture)
				started.continuation.yield(())
				for await _ in release.stream { break }
			})
			$0.browserSurface.focus = { _ in }
			$0.browserEngine.open = { _ in Issue.record("Returning to a mounted source must not reopen it") }
		}
		let task = store.send(.media(.ui(.returnToTab(source.id))))
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)
		switch change {
		case "settings":
			await store.send(.ui(.openSettings)).finish()

		case "existingUtility":
			await store.send(.ui(.windowBecameKey)).finish()

		case "staleObservation":
			await store.send(.media(.event(.observationEnded(0)))).finish()

		case "nativeInvalidated":
			nativeCurrent = false

		case "navigation":
			let item = store.main.viewer.item
			await store.send(.main(.viewer(.panes(.element(
				id: store.main.viewer.activePaneID,
				action: .item(.event(.navigation(
					source.id.tabID,
					item.generation,
					.init(url: URL(string: "https://capturecontext.dev/replacement")!, isLoading: true)
				)))
			))))).finish()

		default:
			break
		}
		let expectedFocus = store.focusedWindowID
		release.continuation.yield(())
		release.continuation.finish()
		await task.finish()
		#expect(store.mediaSourceFocusRequest == (["unchanged", "staleObservation"].contains(change) ? 1 : 0))
		expectNoDifference(store.focusedWindowID, expectedFocus)
		#expect(store.pendingMediaReturn == nil)
	}

	@Test(arguments: [false, true])
	internal func anotherPeekKeepsItsOwnershipAndExplainsWhyReturnIsBlocked(little: Bool) async {
		var state = fixture()
		let source = state.media.snapshot.sources[0]
		let hostID = little ? UUID(82) : state.main.id
		if little {
			let tab = state.workspace.tabs[0]
			state.workspace.tabs.removeAll { $0.id == tab.id }
			state.littleWindows.append(.init(id: hostID, spaceID: state.main.sidebar.spaceID, tab: tab))
			state.littleWindows[id: hostID]?.viewer = .init(tab: tab)
		}
		let preview = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: source.id.profileID,
			restoration: .init(title: "Preview", url: URL(string: "https://capturecontext.dev/preview")!)
		)
		state.peeks.append(.init(
			id: UUID(81),
			source: .init(
				windowID: hostID,
				paneID: state.main.viewer.activePaneID,
				tabID: source.id.tabID,
				spaceID: state.main.sidebar.spaceID,
				profileID: source.id.profileID,
				identity: "Fixture"
			),
			tab: preview,
			isTemporary: true
		))
		state.peeks[id: UUID(81)]?.viewer = .init(tab: preview)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.isSourceCurrent = { _ in true }
			$0.browserEngine.close = { _ in Issue.record("Return must not silently close another preview") }
			$0.browserEngine.open = { _ in Issue.record("Return must not mount a covered source") }
		}
		await store.send(.media(.ui(.returnToTab(source.id)))).finish()
		expectNoDifference(store.peeks, state.peeks)
		expectNoDifference(store.mediaReturnFailure, .previewOpen)
		#expect(store.main.isLibraryOpen && store.mediaSourceFocusRequest == 0)
		expectNoDifference(store.main.libraryPanel, .media)
	}

	@Test(arguments: [false, true], [false, true])
	internal func nativeActivationRequiresTheCurrentObservation(
		stale: Bool,
		current: Bool
	) async throws {
		let state = fixture()
		let source = state.media.snapshot.sources[0]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.isSourceCurrent = { _ in current }
			$0.browserSurface.focus = { _ in }
			$0.browserEngine.open = { _ in Issue.record("Native Return to Tab must keep its session") }
		}
		await store.send(.media(.event(.activated(source.id, observationID: stale ? 0 : 1)))).finish()
		#expect(store.mediaSourceFocusRequest == (!stale && current ? 1 : 0))
	}

	@Test
	internal func missingCurrentSourceCapabilityCannotTakeFocus() async throws {
		let state = fixture()
		let store = Store(initialState: state) { AppFeature() }
		await store.send(.media(.ui(.returnToTab(state.media.snapshot.sources[0].id)))).finish()
		expectNoDifference(store.mediaSourceFocusRequest, 0)
		expectNoDifference(store.focusedWindowID, state.focusedWindowID)
		#expect(store.pendingMediaReturn == nil)
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)))
		state.main.viewer.item = .init(tab: organization.tabs[0])
		state.main.viewer.spaceID = organization.spaces[0].id
		state.media.isAvailable = true
		state.main.mediaAvailable = true
		state.media.isObserving = true
		state.media.observationID = 1
		state.media.snapshot = .init(revision: 1, sources: [media(organization.tabs[0])])
		return state
	}

	private func stackSource(_ number: Int, profileID: Profile.ID) -> BrowserMediaSource {
		.init(
			id: .init(tabID: .init(rawValue: UUID(number + 100)), profileID: profileID, generation: 1),
			revision: 1,
			title: "Media \(number)",
			site: nil,
			playback: .playing,
			actions: [.pause]
		)
	}

	private func media(_ tab: BrowserCore.Tab) -> BrowserMediaSource {
		.init(
			id: .init(tabID: tab.id, profileID: tab.profileID, generation: 3),
			revision: 1,
			title: tab.displayTitle,
			site: .init(url: tab.reopeningURL),
			hasVideo: true,
			playback: .playing,
			actions: [.pause, .enterPictureInPicture]
		)
	}
}
