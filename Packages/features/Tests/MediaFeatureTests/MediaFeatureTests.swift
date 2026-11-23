import BrowserCore
import BrowserMediaClient
import CustomDump
import Foundation
import MediaFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct MediaFeatureTests {
	@Test
	internal func unavailableClientCannotExposeOrInvokeControls() async {
		let source = source()
		let store = TestStore(initialState: MediaFeature.State(profileID: source.id.profileID)) { MediaFeature() }
		await store.send(.ui(.appeared))
		await store.send(.ui(.perform(source.id, .enterPictureInPicture)))
		await store.send(.event(.changed(.init(revision: 1, sources: [source]), observationID: 0)))
		await store.finish()
		#expect(store.state.visibleSources.isEmpty)
		#expect(!store.state.isAvailable)
	}

	@Test
	internal func manualEntryDoesNotRequireAutomaticOptInOrInventPlayback() async {
		let source = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = TestStore(initialState: state(source)) { MediaFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in requests.withValue { $0.append(request) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.perform(source.id, .enterPictureInPicture)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value, [.init(source: source, action: .enterPictureInPicture)])
		expectNoDifference(store.state.snapshot.sources, [source])
		#expect(store.state.automatic.enabledSites.isEmpty)
		var active = source
		active.isInPictureInPicture = true
		active.revision += 1
		await store.send(.event(.changed(.init(revision: 2, sources: [active]), observationID: 1)))
		#expect(store.state.visibleSources[0].isInPictureInPicture)
	}

	@Test
	internal func trackControlsReachThePageOnlyWhenItHasThem() async {
		var source = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = TestStore(initialState: state(source)) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in requests.withValue { $0.append(request) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// The page names no next track, so nothing is asked of it.
		await store.send(.ui(.perform(source.id, .nextTrack)))
		await store.finish()
		#expect(requests.value.isEmpty)

		source.actions.formUnion([.nextTrack, .previousTrack])
		source.revision += 1
		await store.send(.event(.changed(.init(revision: 2, sources: [source]), observationID: 1)))
		await store.send(.ui(.perform(source.id, .nextTrack)))
		await store.receive(\.event.finished)
		await store.send(.ui(.perform(source.id, .previousTrack)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value, [
			.init(source: source, action: .nextTrack),
			.init(source: source, action: .previousTrack),
		])
	}

	@Test
	internal func snapshotsRejectStaleRevisionsAndMultipleWindowsBeforeFiltering() async {
		let source = source()
		let store = TestStore(initialState: state(source)) { MediaFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.changed(.init(revision: 1), observationID: 1)))
		await store.send(.event(.changed(.init(revision: 3), observationID: 0)))
		var active = source
		active.isInPictureInPicture = true
		var second = self.source(2)
		second.id.profileID = .init(rawValue: UUID(9))
		second.isInPictureInPicture = true
		await store.send(.event(.changed(.init(revision: 2, sources: [active, second]), observationID: 1)))
		expectNoDifference(store.state.snapshot.sources, [source])
		await store.send(.event(.changed(.init(revision: 2, sources: [active]), observationID: 1)))
		expectNoDifference(store.state.snapshot.sources, [active])
		await store.send(.event(.changed(.init(revision: 1, sources: []), observationID: 1)))
		expectNoDifference(store.state.snapshot.sources, [active])
	}

	@Test
	internal func privateAndOtherProfileSourcesNeverEnterOrdinaryScope() async {
		let normal = source()
		var privateSource = source(2)
		privateSource.isPrivate = true
		var other = source(3)
		other.id.profileID = .init(rawValue: UUID(9))
		let store = TestStore(initialState: state(normal)) { MediaFeature() } withDependencies: {
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { _ in Issue.record("Hidden source was controlled") }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.changed(.init(revision: 2, sources: [normal, privateSource, other]), observationID: 1)))
		expectNoDifference(store.state.snapshot.sources, [normal])
		await store.send(.ui(.perform(privateSource.id, .pause)))
		await store.send(.ui(.returnToTab(other.id)))
		await store.finish()
	}

	@Test
	internal func automaticEntryRespectsSiteOptOutNativeSupportAndOneVisibilityTransition() async {
		let source = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = TestStore(initialState: state(source)) { MediaFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in requests.withValue { $0.append(request) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// On by default; a site the profile turned off never enters automatically.
		await store.send(.ui(.setAutomatic(source.id, enabled: false)))
		await store.receive(\.delegate.automaticPreferencesChanged)
		await store.send(.ui(.sourceBecameHidden(source.id)))
		await store.send(.ui(.perform(source.id, .enterAutomaticPictureInPicture)))
		#expect(requests.value.isEmpty)
		await store.send(.ui(.setAutomatic(source.id, enabled: true)))
		await store.receive(\.delegate.automaticPreferencesChanged)
		await store.send(.ui(.sourceBecameHidden(source.id)))
		await store.receive(\.event.finished)
		await store.send(.ui(.sourceBecameHidden(source.id)))
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.enterAutomaticPictureInPicture])
		await store.send(.ui(.sourceBecameVisible(source.id)))
		var unsupported = source
		unsupported.actions.remove(.enterAutomaticPictureInPicture)
		unsupported.revision += 1
		await store.send(.event(.changed(.init(revision: 2, sources: [unsupported]), observationID: 1)))
		await store.send(.ui(.sourceBecameHidden(source.id)))
		await store.receive(\.event.finished)
		await store.finish()

		// A site without an automatic action still floats, through the entry Arx asks for (DEV-848).
		expectNoDifference(
			requests.value.map(\.action),
			[.enterAutomaticPictureInPicture, .enterPictureInPicture]
		)
	}

	@Test(arguments: [true, false])
	internal func returningVisibleOrDisablingOptInCancelsOnlyPendingAutomaticEntry(visible: Bool) async throws {
		let source = source()
		var initial = state(source)
		initial.automatic.setEnabled(true, for: source)
		let cancelled = LockIsolated(false)
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { _ in
					try await withTaskCancellationHandler {
						try await Task.sleep(for: .seconds(60))
					} onCancel: { cancelled.setValue(true) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.sourceBecameHidden(source.id)))
		#expect(store.state.pending?.request.action == .enterAutomaticPictureInPicture)
		if visible {
			await store.send(.ui(.sourceBecameVisible(source.id)))

		} else {
			await store.send(.ui(.setAutomatic(source.id, enabled: false)))
			await store.receive(\.delegate.automaticPreferencesChanged)
		}
		await store.finish()
		#expect(cancelled.value)
		#expect(store.state.pending == nil)
		await store.send(.event(.finished(UUID(100), .timedOut)))
		#expect(store.state.failure == nil)
	}

	@Test
	internal func returningVisibleDoesNotCancelManualEntry() async throws {
		let source = source()
		let completion = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
		let store = TestStore(initialState: state(source)) { MediaFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { _ in
					try await withCheckedThrowingContinuation { completion.setValue($0) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.perform(source.id, .enterPictureInPicture)))
		await store.send(.ui(.sourceBecameVisible(source.id)))
		#expect(store.state.pending?.request.action == .enterPictureInPicture)
		try #require(completion.value).resume()
		await store.receive(\.event.finished)
		await store.finish()
	}

	@Test
	internal func automaticPreferencesUseExactOriginsProfilesAndExcludePrivateSources() throws {
		let normal = source()
		var preferences = AutomaticPiPPreferences()
		#expect(preferences.permits(normal))
		let disabled = preferences.setEnabled(false, for: normal)
		#expect(disabled)
		#expect(!preferences.permits(normal))
		var privateSource = normal
		privateSource.isPrivate = true
		let privateEnabled = preferences.setEnabled(true, for: privateSource)
		#expect(!privateEnabled)
		#expect(!preferences.permits(privateSource))
		// The opt-out covers only that profile and exact origin.
		var other = normal
		other.id.profileID = .init(rawValue: UUID(9))
		#expect(preferences.permits(other))
		other = normal
		other.site = MediaSite(url: URL(string: "https://other.example")!)
		#expect(preferences.permits(other))
		let exact = try #require(MediaSite(url: URL(string: "https://CAPTURECONTEXT.dev:443/path?q=secret#fragment")!))
		expectNoDifference(exact.origin.absoluteString, "https://capturecontext.dev")
		#expect(MediaSite(url: URL(string: "https://user:pass@capturecontext.dev")!) == nil)
		#expect(MediaSite(url: URL(string: "file:///tmp/example")!) == nil)
		let encoded = try JSONEncoder().encode(preferences)
		expectNoDifference(try JSONDecoder().decode(AutomaticPiPPreferences.self, from: encoded), preferences)
		#expect(throws: (any Error).self) {
			try JSONDecoder().decode(MediaSite.self, from: Data("\"https://capturecontext.dev/path\"".utf8))
		}
	}

	@Test
	internal func sourceReplacementCancelsPendingReturnAndIgnoresItsLateResult() async {
		var source = source()
		source.isInPictureInPicture = true
		let (gate, continuation) = AsyncStream<Void>.makeStream()
		let store = TestStore(initialState: state(source)) { MediaFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { _ in for await _ in gate { break } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.returnToTab(source.id)))
		#expect(store.state.pending?.returnToSource == true)
		var replacement = source
		replacement.id.generation += 1
		replacement.isInPictureInPicture = false
		await store.send(.event(.changed(.init(revision: 2, sources: [replacement]), observationID: 1)))
		#expect(store.state.pending == nil)
		continuation.finish()
		await store.send(.event(.finished(UUID(100), nil)))
		await store.finish()
		expectNoDifference(store.state.snapshot.sources, [replacement])
	}

	@Test
	internal func returnToTabWaitsForExitAndRetainsExactSourceIdentity() async {
		var source = source()
		source.isInPictureInPicture = true
		let requested = LockIsolated<[BrowserMediaRequest]>([])
		let store = TestStore(initialState: state(source)) { MediaFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in requested.withValue { $0.append(request) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.returnToTab(source.id)))
		await store.receive(\.event.finished)
		await store.receive(\.delegate.returnToSource, source.id)
		await store.finish()
		expectNoDifference(requested.value, [.init(source: source, action: .exitPictureInPicture)])
	}

	@Test
	internal func finalNativeValidationFailureLeavesPlaybackStateUnchanged() async {
		let source = source()
		var current = source
		current.revision += 1
		#expect(!BrowserMediaRequest(source: source, action: .pause).isValid(for: current))
		let store = TestStore(initialState: state(source)) { MediaFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { _ in throw BrowserMediaClient.Failure.staleSource }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.perform(source.id, .pause)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(store.state.failure, .staleSource)
		expectNoDifference(store.state.snapshot.sources, [source])
	}

	@Test
	internal func endingNativeObservationClearsControlsWithoutClosingTheTab() async {
		let source = source()
		let (stream, continuation) = AsyncStream<BrowserMediaSnapshot>.makeStream()
		let store = TestStore(initialState: MediaFeature.State(profileID: source.id.profileID)) {
			MediaFeature()
		} withDependencies: {
			$0.browserMedia = .init(
				isAvailable: true,
				events: { stream },
				perform: { _ in Issue.record("Observation teardown changed native playback") }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.appeared))
		continuation.yield(.init(revision: 1, sources: [source]))
		await store.receive(\.event.changed)
		continuation.finish()
		await store.receive(\.event.observationEnded)
		await store.finish()
		#expect(store.state.visibleSources.isEmpty)
		#expect(!store.state.isObserving)
		expectNoDifference(store.state.failure, .unavailable)
	}

	@Test
	internal func nativeReturnToTabUsesTheCurrentObservationAndVisibleSource() async throws {
		let source = source()
		let store = TestStore(initialState: state(source)) { MediaFeature() }
		await store.send(.event(.activated(source.id, observationID: 0)))
		var replaced = source.id
		replaced.generation += 1
		await store.send(.event(.activated(replaced, observationID: 1)))
		var hidden = source.id
		hidden.profileID = .init(rawValue: UUID(9))
		await store.send(.event(.activated(hidden, observationID: 1)))
		await store.send(.event(.activated(source.id, observationID: 1)))
		await store.receive(\.delegate.returnToSource, source.id)
		await store.finish()
	}

	@Test
	internal func nativeActivationStreamRoutesAndStopsWithObservation() async throws {
		let source = source()
		let snapshots = AsyncStream<BrowserMediaSnapshot>.makeStream()
		let activations = AsyncStream<BrowserMediaSource.ID>.makeStream()
		let store = TestStore(initialState: MediaFeature.State(profileID: source.id.profileID)) {
			MediaFeature()
		} withDependencies: {
			$0.browserMedia = .init(
				isAvailable: true,
				events: { snapshots.stream },
				activations: { activations.stream }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.appeared))
		snapshots.continuation.yield(.init(revision: 1, sources: [source]))
		await store.receive(\.event.changed)
		activations.continuation.yield(source.id)
		await store.receive(\.event.activated)
		await store.receive(\.delegate.returnToSource, source.id)
		await store.send(.ui(.dismissed))
		activations.continuation.yield(source.id)
		await store.send(.event(.activated(source.id, observationID: 1)))
		await store.finish()
		snapshots.continuation.finish()
		activations.continuation.finish()
	}

	/// A reappearance races its observation against the dismissed one, which may register off
	/// the main actor after it. The current observation must keep delivering, and the dismissed
	/// one must stop at its first stale event.
	@Test
	internal func reappearingKeepsTheCurrentObservation() async throws {
		let source = source()
		var lost = 0
		var leaked = 0

		for _ in 0..<200 {
			let subscriptions = LockIsolated<(count: Int, terminated: Int)>((0, 0))
			let store = Store(initialState: MediaFeature.State(profileID: source.id.profileID)) {
				MediaFeature()
			} withDependencies: {
				$0.browserMedia = .init(
					isAvailable: true,
					events: {
						let (stream, continuation) = AsyncStream<BrowserMediaSnapshot>.makeStream()
						subscriptions.withValue { $0.count += 1 }
						continuation.onTermination = { _ in subscriptions.withValue { $0.terminated += 1 } }
						continuation.yield(.init(revision: 1, sources: [source]))
						return stream
					}
				)
			}
			store.send(.ui(.appeared))
			store.send(.ui(.dismissed))
			store.send(.ui(.appeared))

			let delivers = await eventually { store.observationID == 3 && store.snapshot.sources == [source] }
			if !delivers { lost += 1 }

			let releasesDismissed = await eventually {
				subscriptions.value.count == 2 && subscriptions.value.terminated == 1
			}
			if !releasesDismissed { leaked += 1 }

			store.send(.ui(.dismissed))
		}

		#expect(lost == 0)
		#expect(leaked == 0)
	}

	@Test
	internal func staleObservationEventCancelsOnlyItsOwnObservation() async throws {
		let source = source()
		let snapshots = AsyncStream<BrowserMediaSnapshot>.makeStream()
		let store = TestStore(initialState: MediaFeature.State(profileID: source.id.profileID)) {
			MediaFeature()
		} withDependencies: {
			$0.browserMedia = .init(isAvailable: true, events: { snapshots.stream })
		}
		await store.send(.ui(.appeared)) {
			$0.isAvailable = true
			$0.isObserving = true
			$0.observationID = 1
		}
		await store.send(.event(.changed(.init(revision: 1, sources: [source]), observationID: 0)))
		await store.send(.event(.activated(source.id, observationID: 0)))
		snapshots.continuation.yield(.init(revision: 1, sources: [source]))
		await store.receive(\.event.changed) {
			$0.snapshot = .init(revision: 1, sources: [source])
		}
		await store.send(.ui(.dismissed)) {
			$0.isObserving = false
			$0.observationID = 2
			$0.snapshot = .init()
		}
		await store.finish()
		snapshots.continuation.finish()
	}

	@Test
	internal func applicationScopeIncludesOtherOrdinaryProfilesAndExcludesAllPrivateSources() async throws {
		let first = source()
		var second = source(2)
		second.id.profileID = .init(rawValue: UUID(11))
		var hidden = source(3)
		hidden.isPrivate = true
		var initial = state(first)
		initial.includesAllOrdinaryProfiles = true
		let store = TestStore(initialState: initial) { MediaFeature() }
		await store.send(.event(.changed(.init(revision: 2, sources: [first, second, hidden]), observationID: 1))) {
			$0.snapshot = .init(revision: 2, sources: [first, second])
		}
		expectNoDifference(store.state.visibleSources, [first, second])
		await store.send(.event(.activated(hidden.id, observationID: 1)))
		await store.send(.event(.activated(second.id, observationID: 1)))
		await store.receive(\.delegate.returnToSource, second.id)
		await store.finish()
		var defensive = store.state
		defensive.isPrivate = true
		defensive.snapshot.sources.append(hidden)
		expectNoDifference(defensive.visibleSources, [first, second])
	}

	private func eventually(_ condition: () -> Bool) async -> Bool {
		// Until a deadline rather than a fixed number of polls, which a busy Mac used up first.
		try? await waitWhile { !condition() }
		return condition()
	}

	@Test(arguments: [true, false])
	internal func returningToTheTabClosesItsPictureInPicture(closes: Bool) async {
		var playing = source()
		playing.isInPictureInPicture = true
		var initial = state(playing)
		initial.automatic.closesOnReturn = closes
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in requests.withValue { $0.append(request) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.sourceBecameVisible(playing.id)))
		await store.finish()
		expectNoDifference(requests.value.map(\.action), closes ? [.exitPictureInPicture] : [])
	}

	@Test
	internal func turningAutomaticPictureInPictureOffCoversEverySite() {
		var preferences = AutomaticPiPPreferences()
		preferences.isEnabled = false
		#expect(!preferences.permits(source()))
	}

	/// DEV-906: the sidebar player's bar seeks, only where the page allows it.
	@Test
	internal func theSidebarPlayersBarSeeks() async {
		var source = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = TestStore(initialState: state(source)) { MediaFeature() } withDependencies: {
			$0.uuid = .constant(UUID(100))
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in requests.withValue { $0.append(request) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.seek(source.id, to: 30)))
		await store.finish()
		expectNoDifference(requests.value, [])

		source.actions.insert(.seek)
		await store.send(.event(.changed(.init(revision: 2, sources: [source]), observationID: 1)))
		await store.send(.ui(.seek(source.id, to: 30)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value, [.init(source: source, seekingTo: 30)])
	}

	private func source(_ number: Int = 1) -> BrowserMediaSource {
		.init(
			id: .init(
				tabID: .init(rawValue: UUID(number)),
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

	private func state(_ source: BrowserMediaSource) -> MediaFeature.State {
		var state = MediaFeature.State(profileID: source.id.profileID, isPrivate: source.isPrivate)
		state.isAvailable = true
		state.isObserving = true
		state.observationID = 1
		state.snapshot = .init(revision: 1, sources: [source])
		return state
	}
}
