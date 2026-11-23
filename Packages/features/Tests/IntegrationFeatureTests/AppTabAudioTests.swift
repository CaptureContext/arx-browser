import AppUI
import BrowserCore
import BrowserMediaClient
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Per-tab mute and volume (DEV-800).
@Suite(.dependencies)
@MainActor
internal struct AppTabAudioTests {
	@Test
	internal func aTabRowMutesAnyTabAndItsSpeakerFollows() async {
		let state = fixture()

		// The second tab plays nothing: its row's menu mutes it all the same.
		let tab = state.workspace.tabs[1]
		let muted = LockIsolated<Set<BrowserCore.Tab.ID>>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.setMuted = { id, isMuted in
				muted.withValue { if isMuted { $0.insert(id) } else { $0.remove(id) } }
			}
			$0.browserMedia.position = { id in .init(sourceID: nil, isMuted: muted.value.contains(id)) }
		}

		await store.send(.main(.sidebar(.ui(.sidebar(.setMuted(.tab(tab.id.rawValue), true)))))).finish()
		#expect(muted.value == [tab.id])
		expectNoDifference(store.mutedTabs, [tab.id])
		expectNoDifference(store.main.sidebar.tabItem(tab.id)?.audio, .init(isMuted: true))

		await store.send(.main(.sidebar(.ui(.sidebar(.setMuted(.tab(tab.id.rawValue), false)))))).finish()
		#expect(muted.value.isEmpty)
		expectNoDifference(store.mutedTabs, [])
		expectNoDifference(store.main.sidebar.tabItem(tab.id)?.audio, .init())
	}

	@Test
	internal func aPlayingTabShowsItsSpeakerAndOthersOnlyTheirMenu() async {
		let state = fixture()
		let store = Store(initialState: state) { AppFeature() }
		await refresh(store, state)

		let playing = state.workspace.tabs[0]
		let quiet = state.workspace.tabs[1]
		expectNoDifference(store.main.sidebar.tabItem(playing.id)?.audio, .init(isPlaying: true))
		#expect(store.main.sidebar.tabItem(playing.id)?.audio?.showsIndicator == true)
		expectNoDifference(store.main.sidebar.tabItem(quiet.id)?.audio, .init())
		#expect(store.main.sidebar.tabItem(quiet.id)?.audio?.showsIndicator == false)
	}

	@Test
	internal func aRefusedMuteLeavesTheSpeakerAsItWas() async {
		let state = fixture()
		let tab = state.workspace.tabs[0]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.setMuted = { _, _ in throw BrowserMediaClient.Failure.staleSource }
		}
		await store.send(.ui(.setTabMuted(tab.id, true))).finish()
		expectNoDifference(store.mutedTabs, [])
	}

	@Test
	internal func volumeIsHiddenOnAnEngineWithoutIt() async {
		let state = fixture()
		let tab = state.workspace.tabs[0]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.setVolume = { _, _ in Issue.record("An older engine has no volume") }
		}
		await refresh(store, state)
		#expect(!store.supportsTabVolume)
		#expect(store.main.sidebar.defaultTabAudio?.volume == nil)

		await store.send(.ui(.setTabVolume(tab.id, 0.4))).finish()
		expectNoDifference(store.tabVolumes, [:])
	}

	@Test
	internal func aTabTurnsDownAndBackUp() async {
		let state = fixture()
		let tab = state.workspace.tabs[0]
		let volumes = LockIsolated<[Double]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.supportsVolume = { true }
			$0.browserMedia.setVolume = { id, volume in
				#expect(id == tab.id)
				volumes.withValue { $0.append(volume) }
			}
		}
		await refresh(store, state)
		#expect(store.supportsTabVolume)
		expectNoDifference(store.main.sidebar.defaultTabAudio, .init(volume: 1))

		await store.send(.main(.sidebar(.ui(.sidebar(.setVolume(.tab(tab.id.rawValue), 0.3)))))).finish()
		expectNoDifference(store.tabVolumes, [tab.id: 0.3])
		expectNoDifference(
			store.main.sidebar.tabItem(tab.id)?.audio,
			.init(isPlaying: true, volume: 0.3)
		)

		// Out of range clamps; the top of the slider is 100% and leaves nothing to keep.
		await store.send(.ui(.setTabVolume(tab.id, -1))).finish()
		expectNoDifference(store.tabVolumes, [tab.id: 0])
		await store.send(.ui(.setTabVolume(tab.id, 0.998))).finish()
		expectNoDifference(store.tabVolumes, [:])
		expectNoDifference(volumes.value, [0.3, 0, 1])

		// The same value doesn't reach the engine again.
		await store.send(.ui(.setTabVolume(tab.id, 1))).finish()
		expectNoDifference(volumes.value, [0.3, 0, 1])
	}

	@Test
	internal func aRefusedVolumePutsTheSliderBack() async {
		var state = fixture()
		let tab = state.workspace.tabs[0]
		state.tabVolumes = [tab.id: 0.5]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.supportsVolume = { true }
			$0.browserMedia.setVolume = { _, _ in throw BrowserMediaClient.Failure.staleSource }
		}
		await refresh(store, state)
		await store.send(.ui(.setTabVolume(tab.id, 0.2))).finish()
		expectNoDifference(store.tabVolumes, [tab.id: 0.5])
	}

	@Test
	internal func turningAMutedTabUpUnmutesIt() async {
		var state = fixture()
		let tab = state.workspace.tabs[0]
		state.mutedTabs = [tab.id]
		let muted = LockIsolated<Set<BrowserCore.Tab.ID>>([tab.id])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.supportsVolume = { true }
			$0.browserMedia.setVolume = { _, _ in }
			$0.browserMedia.setMuted = { id, isMuted in
				muted.withValue { if isMuted { $0.insert(id) } else { $0.remove(id) } }
			}
			$0.browserMedia.position = { id in .init(sourceID: nil, isMuted: muted.value.contains(id)) }
		}
		await refresh(store, state)

		// Turning it all the way down keeps it muted.
		await store.send(.ui(.setTabVolume(tab.id, 0))).finish()
		expectNoDifference(store.mutedTabs, [tab.id])

		await store.send(.ui(.setTabVolume(tab.id, 0.6))).finish()
		expectNoDifference(store.mutedTabs, [])
		#expect(muted.value.isEmpty)
	}

	@Test
	internal func aClosedTabDropsItsVolumeAndARecreatedPageGetsItBack() async {
		var state = fixture()
		let tab = state.workspace.tabs[0]
		let gone = BrowserCore.Tab.ID(rawValue: UUID(99))
		state.tabVolumes = [tab.id: 0.25, gone: 0.5]
		let volumes = LockIsolated<[BrowserCore.Tab.ID: Double]>([:])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserMedia.supportsVolume = { true }
			$0.browserMedia.setVolume = { id, volume in volumes.withValue { $0[id] = volume } }
		}
		await refresh(store, state)
		expectNoDifference(store.tabVolumes, [tab.id: 0.25])
		expectNoDifference(volumes.value, [tab.id: 0.25])
	}

	@Test
	internal func privateWindowsShowNoSpeaker() async {
		var state = fixture()
		let organization = state.workspace
		let privateID = UUID(73)
		state.windows.append(.init(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true,
			id: privateID
		))
		let store = Store(initialState: state) { AppFeature() }
		await refresh(store, state)
		#expect(store.main.sidebar.defaultTabAudio != nil)
		#expect(store.windows[id: privateID]?.sidebar.defaultTabAudio == nil)
		expectNoDifference(store.windows[id: privateID]?.sidebar.tabAudio, [:])
	}

	/// What the engine's next media snapshot does: the app reads mute and support again.
	private func refresh(
		_ store: StoreOf<AppFeature>,
		_ state: AppFeature.State
	) async {
		await store.send(.media(.event(.changed(state.media.snapshot, observationID: 1)))).finish()
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
		let tab = organization.tabs[0]
		state.media.snapshot = .init(revision: 1, sources: [
			.init(
				id: .init(tabID: tab.id, profileID: tab.profileID, generation: 3),
				revision: 1,
				title: tab.displayTitle,
				site: .init(url: tab.reopeningURL),
				hasVideo: true,
				playback: .playing,
				actions: [.pause]
			),
		])
		return state
	}
}
