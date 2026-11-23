import BrowserCore
import BrowserDownloadsClient
import BrowserMediaClient
import CustomDump
import Foundation
import SoundFeedbackClient
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// AppFeature's part of sound feedback (DEV-1256): it reports what tabs do with sound, and starts
/// the downloads' outcome watch once downloads are ready.
@Suite(.dependencies)
@MainActor
internal struct AppSoundFeedbackTests {
	private let reports: LockIsolated<[SoundFeedbackClient.PageActivity]> = .init([])
	private let sounds: LockIsolated<[SoundFeedback]> = .init([])

	private var recording: SoundFeedbackClient {
		.init(
			play: { [sounds] sound in sounds.withValue { $0.append(sound) } },
			pagesChanged: { [reports] activity, _ in reports.withValue { $0.append(activity) } }
		)
	}

	/// Private windows count, though the Media page and the sidebars never see their media.
	@Test
	internal func tabsPlayingSoundOrInACallAreReportedPrivateOnesIncluded() async throws {
		let state = fixture()
		let tab = state.workspace.tabs[0]
		let ordinary = source(tab: tab.id, profile: tab.profileID, playback: .playing)
		var paused = ordinary
		paused.playback = .paused
		let privateCall = source(tab: .init(rawValue: UUID(81)), isPrivate: true, call: .init(isMicrophoneOn: true))
		let privatePlaying = source(tab: .init(rawValue: UUID(82)), isPrivate: true, playback: .playing)
		let snapshots: [[BrowserMediaSource]] = [
			[ordinary],
			[privateCall],
			[paused, privatePlaying],
		]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.soundFeedback = recording
			$0.browserMedia = media(snapshots: snapshots, finishes: false)
		}

		let watch = store.send(.configureMedia)
		try await until { reports.value.count == 3 && store.media.snapshot.revision == 3 }
		expectNoDifference(reports.value, [
			.init(playsSound: true),
			.init(usesMicrophone: true),
			.init(playsSound: true),
		])
		expectNoDifference(store.tabsMakingSound.playing, [privatePlaying.id.tabID])
		expectNoDifference(store.tabsMakingSound.inCall, [])

		// The Media page and the sidebars still see only the ordinary tab.
		expectNoDifference(store.media.snapshot.sources.map(\.id), [paused.id])
		#expect(store.media.snapshot.sources.allSatisfy { !$0.isPrivate })

		watch.cancel()
		await store.send(.media(.ui(.dismissed))).finish()
	}

	@Test
	internal func theEngineStoppingLeavesNothingPlaying() async throws {
		let state = fixture()
		let tab = state.workspace.tabs[0]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.soundFeedback = recording
			$0.browserMedia = media(snapshots: [[source(tab: tab.id, profile: tab.profileID, playback: .playing)]])
		}

		await store.send(.configureMedia).finish()
		expectNoDifference(reports.value, [.init(playsSound: true), .init()])
		expectNoDifference(store.tabsMakingSound.playing, [])
		expectNoDifference(store.tabsMakingSound.inCall, [])
	}

	/// An observation the app already replaced can still report its end; the tab that is playing
	/// under the current one keeps the sounds silent.
	@Test
	internal func theEndOfAnOlderObservationLeavesThePlayingTab() async throws {
		let state = fixture()
		let tab = state.workspace.tabs[0]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.soundFeedback = recording
			$0.browserMedia = media(
				snapshots: [[source(tab: tab.id, profile: tab.profileID, playback: .playing)]],
				finishes: false
			)
		}

		let observing = store.send(.configureMedia)

		// The report leaves in an effect of its own, so wait for it too.
		try await until { reports.value == [.init(playsSound: true)] }
		await store.send(.media(.event(.observationEnded(store.media.observationID - 1)))).finish()
		expectNoDifference(store.tabsMakingSound.playing, [tab.id])
		expectNoDifference(reports.value, [.init(playsSound: true)])
		await observing.cancel()
	}

	@Test
	internal func aTabTurnedDownToNothingIsQuiet() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0]
		state.tabVolumes = [tab.id: 0]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.soundFeedback = recording
			$0.browserMedia = media(snapshots: [[source(tab: tab.id, profile: tab.profileID, playback: .playing)]])
		}

		await store.send(.configureMedia).finish()
		expectNoDifference(reports.value, [])
	}

	@Test
	internal func aMutedTabPlayingIsQuiet() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0]
		state.mutedTabs = [tab.id]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.soundFeedback = recording
			$0.browserMedia = media(snapshots: [[source(tab: tab.id, profile: tab.profileID, playback: .playing)]])
			$0.browserMedia.position = { _ in .init(sourceID: nil, isMuted: true) }
		}

		await store.send(.configureMedia).finish()
		expectNoDifference(reports.value, [])
	}

	@Test
	internal func aDownloadThatFinishesPlaysDoneOnceDownloadsAreReady() async throws {
		let (stream, continuation) = AsyncStream<DownloadQueue>.makeStream()
		let started = Date(timeIntervalSince1970: 1_000)
		var download = BrowserDownload(
			id: .init(profileID: .init(rawValue: UUID(1)), guid: "a"),
			profileName: "Work",
			filename: "a.zip",
			status: .inProgress,
			startedAt: started.addingTimeInterval(1)
		)
		let store = Store(initialState: fixture()) { AppFeature() } withDependencies: {
			$0.soundFeedback = recording
			$0.date.now = started
			$0.browserDownloads.events = { stream }
		}

		let ready = store.send(.event(.downloadsReady))
		continuation.yield(.init(downloads: [download]))
		download.status = .complete
		continuation.yield(.init(downloads: [download]))
		continuation.finish()
		await ready.finish()
		expectNoDifference(sounds.value, [.done])
	}

	/// Every subscriber gets these snapshots, then the end of the stream unless `finishes` is false.
	private func media(
		snapshots: [[BrowserMediaSource]],
		finishes: Bool = true
	) -> BrowserMediaClient {
		.init(
			isAvailable: true,
			events: {
				AsyncStream { continuation in
					for (index, sources) in snapshots.enumerated() {
						continuation.yield(.init(revision: UInt64(index + 1), sources: sources))
					}
					if finishes { continuation.finish() }
				}
			}
		)
	}

	/// Waits for effects that never end on their own, for at most a few seconds.
	private func until(
		_ condition: () -> Bool
	) async throws {
		for _ in 0..<500 {
			if condition() { return }
			try await Task.sleep(for: .milliseconds(10))
		}
		Issue.record("Timed out waiting")
	}

	private func source(
		tab: BrowserCore.Tab.ID,
		profile: Profile.ID = .init(rawValue: UUID(80)),
		isPrivate: Bool = false,
		playback: BrowserMediaSource.Playback = .inactive,
		call: BrowserMediaSource.Call? = nil
	) -> BrowserMediaSource {
		.init(
			id: .init(tabID: tab, profileID: profile, generation: 3),
			revision: 1,
			title: "Media",
			site: nil,
			isPrivate: isPrivate,
			playback: playback,
			call: call
		)
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)))
		state.media.isAvailable = true
		state.main.mediaAvailable = true
		return state
	}
}
