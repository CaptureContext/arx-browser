import BrowserCore
import BrowserMediaClient
import CustomDump
import Foundation
import MediaFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// A call's automatic Picture in Picture and its controls (DEV-948).
@Suite(.dependencies)
@MainActor
internal struct CallPictureInPictureTests {
	@Test
	internal func aHiddenCallSetToVideoFloatsThroughTheSitesOwnHandler() async throws {
		let call = source()
		var initial = state(call)

		// A call floats its page by default (DEV-1246); the tab's choice brings Meet's own back.
		initial.automatic.setChoice(.init(kind: .video), for: call.id.tabID)
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.sourceBecameVisible(call.id)))
		await store.send(.ui(.sourceBecameHidden(call.id)))
		await store.receive(\.event.finished)
		await store.finish()

		// No video plays, and the site opens its own window: only the automatic route works.
		expectNoDifference(requests.value.map(\.action), [.enterAutomaticPictureInPicture])
	}

	@Test
	internal func leavingArxWithACallShowingKeepsItInTheTab() async throws {
		let call = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(state(call), requests: requests)

		// Losing focus with the window on screen floats nothing (DEV-1246).
		await store.send(.ui(.sourceBecameVisible(call.id)))
		await store.send(.event(.applicationActivityChanged(isActive: false)))
		await store.finish()
		#expect(requests.value.isEmpty)
	}

	@Test
	internal func aSiteThatOptedOutKeepsItsCallInTheTab() async throws {
		let call = source()
		var initial = state(call)
		initial.automatic.setEnabled(false, for: call)
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.sourceBecameVisible(call.id)))
		await store.send(.ui(.sourceBecameHidden(call.id)))
		await store.send(.event(.applicationActivityChanged(isActive: false)))
		await store.finish()
		#expect(requests.value.isEmpty)
	}

	@Test
	internal func callControlsReachTheSiteAndKeepTheAutomaticReturn() async throws {
		var call = source()
		call.isInPictureInPicture = true
		var initial = state(call)
		initial.automaticEntry.returns = [call.id]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.perform(call.id, .toggleMicrophone)))
		await store.receive(\.event.finished)
		await store.send(.ui(.perform(call.id, .toggleCamera)))
		await store.receive(\.event.finished)
		await store.send(.ui(.perform(call.id, .hangUp)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.toggleMicrophone, .toggleCamera, .hangUp])
		#expect(store.state.automaticEntry.returns == [call.id])
	}

	/// A page floating in Page PiP (DEV-950) is on screen already: leaving Arx doesn't float it twice.
	@Test
	internal func aPageFloatingElsewhereNeverFloatsAgain() async throws {
		let call = source()
		var initial = state(call)
		initial.tabsFloatingElsewhere = [call.id.tabID]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.sourceBecameVisible(call.id)))
		await store.send(.event(.applicationActivityChanged(isActive: false)))
		await store.send(.ui(.sourceBecameHidden(call.id)))
		await store.finish()
		#expect(requests.value.isEmpty)
	}

	@Test
	internal func callActionsBelongToCallsOnly() async throws {
		var call = source()
		#expect(call.supports(.toggleMicrophone))
		#expect(call.supports(.enterAutomaticPictureInPicture))
		// A call's Picture in Picture can be the site's own window, without a video.
		call.isInPictureInPicture = true
		#expect(BrowserMediaSnapshot(revision: 1, sources: [call]).isValid)

		var other = call
		other.call = nil
		#expect(!other.supports(.toggleMicrophone))
		#expect(!BrowserMediaSnapshot(revision: 1, sources: [other]).isValid)
	}

	// MARK: - Fixture

	/// A Meet-like call: no video playing in the session, but the camera or microphone in use.
	private func source() -> BrowserMediaSource {
		.init(
			id: .init(
				tabID: .init(rawValue: UUID(1)),
				profileID: .init(rawValue: UUID(10)),
				generation: 1
			),
			revision: 1,
			title: "Meeting",
			site: MediaSite(url: URL(string: "https://meet.example/abc")!),
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
}
