import BrowserCore
import BrowserMediaClient
import CustomDump
import Foundation
import MediaFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// When automatic Picture in Picture starts, what floats, and each tab's own choice (DEV-1246).
@Suite(.dependencies)
@MainActor
internal struct AutomaticTriggerTests {
	// MARK: - When it starts

	@Test
	internal func losingFocusWithTheWindowOnScreenFloatsNothing() async {
		let video = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(state(video), requests: requests)

		await store.send(.ui(.sourceBecameVisible(video.id)))
		await store.send(.event(.applicationActivityChanged(isActive: false)))
		await store.send(.event(.applicationActivityChanged(isActive: true)))
		await store.finish()
		#expect(requests.value.isEmpty)
		#expect(store.state.automaticEntry.owed.isEmpty)
	}

	@Test
	internal func theWindowsOSWorkspaceLeavingTheDisplayFloatsTheVideo() async {
		let video = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(state(video), requests: requests)

		// Arx leaves the front, then the person moves to another OS workspace: the composing
		// feature reports the page hidden once its window is off the display.
		await store.send(.ui(.sourceBecameVisible(video.id)))
		await store.send(.event(.applicationActivityChanged(isActive: false)))
		#expect(requests.value.isEmpty)
		await store.send(.ui(.sourceBecameHidden(video.id)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.enterAutomaticPictureInPicture])
	}

	@Test
	internal func switchingTabsFloatsTheVideo() async {
		let video = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(state(video), requests: requests)

		await store.send(.ui(.sourceBecameVisible(video.id)))
		await store.send(.ui(.sourceBecameHidden(video.id)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.enterAutomaticPictureInPicture])
	}

	// MARK: - What floats

	@Test
	internal func aCallFloatsItsWholePageOnATabSwitch() async {
		let call = callSource()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(state(call), requests: requests)

		await store.send(.ui(.sourceBecameVisible(call.id)))
		await store.send(.ui(.sourceBecameHidden(call.id)))
		await store.receive(\.delegate.presentPagePictureInPicture, call.id)
		await store.finish()

		// Page PiP takes the live tab; no media request goes to the site.
		#expect(requests.value.isEmpty)
		#expect(store.state.automaticEntry.owed.isEmpty)
		#expect(store.state.automaticAttempts == [call.id])

		// Back on its tab, a later switch may float it again.
		await store.send(.ui(.sourceBecameVisible(call.id)))
		#expect(store.state.automaticAttempts.isEmpty)
	}

	@Test
	internal func aCallsPagePictureInPictureIsAskedForOnce() async {
		let call = callSource()
		let store = makeStore(state(call), requests: .init([]))

		await store.send(.ui(.sourceBecameVisible(call.id)))
		await store.send(.ui(.sourceBecameHidden(call.id)))
		await store.receive(\.delegate.presentPagePictureInPicture, call.id)

		// Later snapshots owe it nothing more while it stays off view.
		await store.send(.event(.changed(.init(revision: 2, sources: [call]), observationID: 1)))
		await store.finish()
	}

	@Test
	internal func aTabSetToVideoFloatsACallThroughTheSitesOwnHandler() async {
		let call = callSource()
		var initial = state(call)
		initial.automatic.setChoice(.init(kind: .video), for: call.id.tabID)
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.sourceBecameVisible(call.id)))
		await store.send(.ui(.sourceBecameHidden(call.id)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.enterAutomaticPictureInPicture])
	}

	@Test
	internal func aTabSetToPageFloatsAVideosWholePage() async {
		let video = source()
		var initial = state(video)
		initial.automatic.setChoice(.init(kind: .page), for: video.id.tabID)
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.sourceBecameVisible(video.id)))
		await store.send(.ui(.sourceBecameHidden(video.id)))
		await store.receive(\.delegate.presentPagePictureInPicture, video.id)
		await store.finish()
		#expect(requests.value.isEmpty)
	}

	// MARK: - A tab's own choice

	@Test
	internal func aTabTurnedOffKeepsItsVideoInPlace() async {
		let video = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(state(video), requests: requests)

		await store.send(.ui(.setTabChoice(video.id.tabID, .init(isAutomatic: false))))
		await store.receive(\.delegate.automaticPreferencesChanged)
		await store.send(.ui(.sourceBecameVisible(video.id)))
		await store.send(.ui(.sourceBecameHidden(video.id)))
		await store.finish()
		#expect(requests.value.isEmpty)
	}

	@Test
	internal func aTabTurnedOnFloatsEvenWhenItsSiteIsOff() async {
		let video = source()
		var initial = state(video)
		initial.automatic.setEnabled(false, for: video)
		initial.automatic.setChoice(.init(isAutomatic: true), for: video.id.tabID)
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.sourceBecameVisible(video.id)))
		await store.send(.ui(.sourceBecameHidden(video.id)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.enterAutomaticPictureInPicture])
	}

	@Test
	internal func turningATabOffDropsWhatItWasOwed() async {
		let video = source()
		var initial = state(video)
		initial.automaticEntry.owed = [video.id: .hidden]
		initial.automaticEntry.failures = [video.id: 1]
		let store = makeStore(initial, requests: .init([]))

		await store.send(.ui(.setTabChoice(video.id.tabID, .init(isAutomatic: false))))
		await store.receive(\.delegate.automaticPreferencesChanged)
		#expect(store.state.automaticEntry.owed.isEmpty)
		#expect(store.state.automaticEntry.failures.isEmpty)
	}

	@Test
	internal func theDefaultChoiceIsForgottenAndAnUnchangedOneSavesNothing() async {
		let video = source()
		var initial = state(video)
		initial.automatic.setChoice(.init(kind: .page), for: video.id.tabID)
		let store = makeStore(initial, requests: .init([]))

		await store.send(.ui(.setTabChoice(video.id.tabID, .init(kind: .page))))
		await store.send(.ui(.setTabChoice(video.id.tabID, .init())))
		await store.receive(\.delegate.automaticPreferencesChanged)
		#expect(store.state.automatic.tabs.isEmpty)
		await store.finish()
	}

	@Test
	internal func preferencesSavedBeforeTabChoicesStillDecode() throws {
		let json = Data(#"{"isEnabled":true,"closesOnReturn":false}"#.utf8)
		let decoded = try JSONDecoder().decode(AutomaticPiPPreferences.self, from: json)
		expectNoDifference(decoded, .init(closesOnReturn: false))

		var preferences = AutomaticPiPPreferences()
		preferences.setChoice(.init(isAutomatic: false, kind: .page), for: source().id.tabID)
		let roundTrip = try JSONDecoder().decode(
			AutomaticPiPPreferences.self,
			from: JSONEncoder().encode(preferences)
		)
		expectNoDifference(roundTrip, preferences)
	}

	// MARK: - Helpers

	private func makeStore(
		_ initial: MediaFeature.State,
		requests: LockIsolated<[BrowserMediaRequest]>
	) -> TestStoreOf<MediaFeature> {
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in requests.withValue { $0.append(request) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	private func source() -> BrowserMediaSource {
		.init(
			id: .init(
				tabID: .init(rawValue: UUID(1)),
				profileID: .init(rawValue: UUID(10)),
				generation: 1
			),
			revision: 1,
			title: "Video",
			site: MediaSite(url: URL(string: "https://capturecontext.dev/video")!),
			hasVideo: true,
			playback: .playing,
			actions: [
				.play,
				.pause,
				.enterPictureInPicture,
				.exitPictureInPicture,
				.enterAutomaticPictureInPicture,
			]
		)
	}

	private func callSource() -> BrowserMediaSource {
		.init(
			id: .init(
				tabID: .init(rawValue: UUID(2)),
				profileID: .init(rawValue: UUID(10)),
				generation: 1
			),
			revision: 1,
			title: "Meet",
			site: MediaSite(url: URL(string: "https://meet.google.com")!),
			hasVideo: false,
			playback: .playing,
			actions: [
				.enterAutomaticPictureInPicture,
				.exitPictureInPicture,
				.toggleMicrophone,
				.toggleCamera,
				.hangUp,
			],
			call: .init(isMicrophoneOn: true, isCameraOn: false)
		)
	}

	private func state(_ source: BrowserMediaSource) -> MediaFeature.State {
		var state = MediaFeature.State(profileID: source.id.profileID)
		state.isAvailable = true
		state.isObserving = true
		state.observationID = 1
		state.snapshot = .init(revision: 1, sources: [source])
		return state
	}
}
