import BrowserCore
import BrowserMediaClient
import CustomDump
import Foundation
import MediaFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// Automatic Picture in Picture triggers and exclusions (DEV-848).
@Suite(.dependencies)
@MainActor
internal struct AutomaticEntryTests {
	// MARK: - Exclusions and returns

	@Test(arguments: Exclusion.allCases)
	internal func aHiddenSourceRespectsEveryExclusion(_ exclusion: Exclusion) async {
		var video = source()
		var initial = state(video)
		switch exclusion {
		case .siteOptOut:
			initial.automatic.setEnabled(false, for: video)
		case .settingOff:
			initial.automatic.isEnabled = false
		case .paused:
			video.playback = .paused
		case .audioOnly:
			video.hasVideo = false
		case .alreadyFloating:
			video.isInPictureInPicture = true
		case .private:
			video.isPrivate = true
			initial.isPrivate = true
		}
		initial.snapshot = .init(revision: 1, sources: [video])
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.sourceBecameVisible(video.id)))
		await store.send(.event(.applicationActivityChanged(isActive: false)))
		await store.send(.ui(.sourceBecameHidden(video.id)))
		await store.finish()
		#expect(requests.value.allSatisfy { $0.action == .exitPictureInPicture })
		#expect(!requests.value.contains { $0.action == .enterPictureInPicture })
		#expect(!requests.value.contains { $0.action == .enterAutomaticPictureInPicture })
	}

	@Test
	internal func aTabShowingAgainWhileArxIsInactiveKeepsItsPictureInPicture() async {
		var video = source()
		video.isInPictureInPicture = true
		var initial = state(video)
		initial.automaticEntry.isApplicationActive = false
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.sourceBecameVisible(video.id)))
		await store.finish()
		#expect(requests.value.isEmpty)
	}

	@Test
	internal func aStaleReturnExitRetriesWithTheNewerRevisionAndShowsNoFailure() async {
		var video = source()
		video.isInPictureInPicture = true
		var initial = state(video)
		initial.automaticEntry.isApplicationActive = false
		initial.automaticEntry.shown = [video.id]
		initial.automaticEntry.deactivationEntries = [video.id]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let failures = LockIsolated<[BrowserMediaClient.Failure]>([.staleSource])
		let store = makeStore(initial, requests: requests, failures: failures)

		await store.send(.event(.applicationActivityChanged(isActive: true)))
		await store.receive(\.event.finished)
		#expect(store.state.failure == nil)
		#expect(store.state.automaticEntry.returns == [video.id])
		var fresh = video
		fresh.revision = 2
		await store.send(.event(.changed(.init(revision: 2, sources: [fresh]), observationID: 1)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.exitPictureInPicture, .exitPictureInPicture])
		expectNoDifference(requests.value.map(\.expectedRevision), [1, 2])
		#expect(store.state.automaticEntry.returns.isEmpty)
	}

	@Test
	internal func aReturnWhoseSourceLeavesDoesNotSwallowTheNextCommandsFailure() async throws {
		var video = source()
		video.isInPictureInPicture = true
		var initial = state(video)
		initial.automaticEntry.isApplicationActive = false
		initial.automaticEntry.shown = [video.id]
		initial.automaticEntry.deactivationEntries = [video.id]
		let other = source(2)
		let gate = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					if request.action == .exitPictureInPicture {
						try await withCheckedThrowingContinuation { gate.setValue($0) }
					} else {
						throw BrowserMediaClient.Failure.requestFailed
					}
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.applicationActivityChanged(isActive: true)))
		try #require(await eventually { gate.value != nil })

		// The returning source leaves the snapshot while its exit is in flight.
		await store.send(.event(.changed(.init(revision: 2, sources: [other]), observationID: 1)))
		#expect(!store.state.automaticEntry.pendingIsReturn)
		await store.send(.ui(.perform(other.id, .pause)))
		await store.receive(\.event.finished)
		await store.finish()
		#expect(store.state.failure == .requestFailed)
	}

	@Test
	internal func leavingArxAgainDuringAReturnLeavesTheVideoOnThePage() async throws {
		var video = source()
		video.isInPictureInPicture = true
		var initial = state(video)
		initial.automaticEntry.isApplicationActive = false
		initial.automaticEntry.shown = [video.id]
		initial.automaticEntry.deactivationEntries = [video.id]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let gate = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					requests.withValue { $0.append(request) }
					guard request.action == .exitPictureInPicture else { return }
					try await withCheckedThrowingContinuation { gate.setValue($0) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.applicationActivityChanged(isActive: true)))
		try #require(await eventually { gate.value != nil })
		await store.send(.event(.applicationActivityChanged(isActive: false)))
		try #require(gate.value).resume()
		await store.receive(\.event.finished)

		// Leaving Arx with the window on screen floats nothing (DEV-1246).
		#expect(store.state.automaticEntry.owed[video.id] == nil)
		var inline = video
		inline.isInPictureInPicture = false
		inline.revision = 2
		await store.send(.event(.changed(.init(revision: 2, sources: [inline]), observationID: 1)))
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.exitPictureInPicture])
	}

	/// DEV-1213: back in Arx, the person switches tabs while the video's Picture in Picture is
	/// still folding back onto the page. It was playing as it left view, so it floats again, once
	/// a snapshot shows it on the page, whether its tab left while the exit ran or just after.
	@Test(arguments: [true, false])
	internal func leavingTheTabWhileItsPictureInPictureFoldsBackFloatsItOnceInline(whileExiting: Bool) async throws {
		var video = source()
		video.isInPictureInPicture = true
		var initial = state(video)
		initial.automaticEntry.isApplicationActive = false
		initial.automaticEntry.shown = [video.id]
		initial.automaticEntry.deactivationEntries = [video.id]
		initial.automaticEntry.observedFloating = [video.id]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let gate = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					requests.withValue { $0.append(request) }
					guard request.action == .exitPictureInPicture else { return }
					try await withCheckedThrowingContinuation { gate.setValue($0) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.applicationActivityChanged(isActive: true)))
		try #require(await eventually { gate.value != nil })
		if whileExiting {
			await store.send(.ui(.sourceBecameHidden(video.id)))
			try #require(gate.value).resume()
			await store.receive(\.event.finished)
		} else {
			try #require(gate.value).resume()
			await store.receive(\.event.finished)

			// The exit is done, but no snapshot has shown the video back on the page yet.
			#expect(store.state.automaticEntry.landing == [video.id])
			await store.send(.ui(.sourceBecameHidden(video.id)))
		}
		#expect(store.state.automaticEntry.owed[video.id] == .hidden)
		expectNoDifference(requests.value.map(\.action), [.exitPictureInPicture])

		var inline = video
		inline.isInPictureInPicture = false
		inline.revision = 2
		await store.send(.event(.changed(.init(revision: 2, sources: [inline]), observationID: 1)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.exitPictureInPicture, .enterAutomaticPictureInPicture])
		#expect(store.state.automaticEntry.landing.isEmpty)
	}

	/// The return's exit fails after the tab left view: the video still floats, and it's owed
	/// nothing more, so the person closing its Picture in Picture later doesn't float it again.
	@Test
	internal func aFailedReturnWhoseTabLeftOwesNothingMore() async throws {
		var video = source()
		video.isInPictureInPicture = true
		var initial = state(video)
		initial.automaticEntry.isApplicationActive = false
		initial.automaticEntry.shown = [video.id]
		initial.automaticEntry.deactivationEntries = [video.id]
		initial.automaticEntry.observedFloating = [video.id]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let gate = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					requests.withValue { $0.append(request) }
					guard request.action == .exitPictureInPicture else { return }
					try await withCheckedThrowingContinuation { gate.setValue($0) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.applicationActivityChanged(isActive: true)))
		try #require(await eventually { gate.value != nil })
		await store.send(.ui(.sourceBecameHidden(video.id)))
		#expect(store.state.automaticEntry.owed[video.id] == .hidden)
		try #require(gate.value).resume(throwing: BrowserMediaClient.Failure.staleSource)
		await store.receive(\.event.finished)
		#expect(store.state.automaticEntry.owed[video.id] == nil)
		#expect(!store.state.automaticEntry.awaitingInline.contains(video.id))

		// The person closes its Picture in Picture themselves: it stays on its hidden tab.
		var inline = video
		inline.isInPictureInPicture = false
		inline.revision = 2
		await store.send(.event(.changed(.init(revision: 2, sources: [inline]), observationID: 1)))
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.exitPictureInPicture])
	}

	/// A video floating on its own, not folding back, keeps its Picture in Picture when its tab
	/// leaves view: nothing is owed.
	@Test
	internal func aFloatingVideoWhoseTabLeavesIsOwedNothing() async {
		var video = source()
		video.isInPictureInPicture = true
		var initial = state(video)
		initial.automaticEntry.shown = [video.id]
		initial.automaticEntry.observedFloating = [video.id]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.sourceBecameHidden(video.id)))
		await store.finish()
		#expect(store.state.automaticEntry.owed[video.id] == nil)
		#expect(requests.value.isEmpty)
	}

	@Test
	internal func aReturnWaitingOnAnotherCommandSurvivesLeavingAgain() async throws {
		var video = source()
		video.isInPictureInPicture = true
		var initial = state(video)
		initial.automaticEntry.isApplicationActive = false
		initial.automaticEntry.shown = [video.id]
		initial.automaticEntry.deactivationEntries = [video.id]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let gate = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					requests.withValue { $0.append(request) }
					guard request.action == .pause else { return }
					try await withCheckedThrowingContinuation { gate.setValue($0) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.perform(video.id, .pause)))
		try #require(await eventually { gate.value != nil })
		await store.send(.event(.applicationActivityChanged(isActive: true)))
		await store.send(.event(.applicationActivityChanged(isActive: false)))
		#expect(store.state.automaticEntry.deactivationEntries == [video.id])
		try #require(gate.value).resume()
		await store.receive(\.event.finished)
		await store.send(.event(.applicationActivityChanged(isActive: true)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.pause, .exitPictureInPicture])
	}

	@Test
	internal func aSessionClosedWhileArxIsInactiveIsNoLongerArxs() async {
		var floating = source()
		floating.isInPictureInPicture = true
		var initial = state(floating)
		initial.automaticEntry.isApplicationActive = false
		initial.automaticEntry.shown = [floating.id]
		initial.automaticEntry.deactivationEntries = [floating.id]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		floating.revision = 2
		await store.send(.event(.changed(.init(revision: 2, sources: [floating]), observationID: 1)))

		// Closed from its own controls.
		var inline = floating
		inline.isInPictureInPicture = false
		inline.playback = .paused
		inline.revision = 3
		await store.send(.event(.changed(.init(revision: 3, sources: [inline]), observationID: 1)))
		#expect(store.state.automaticEntry.deactivationEntries.isEmpty)
		await store.send(.event(.applicationActivityChanged(isActive: true)))

		// Opened again some other way (an assistant, say): Arx leaves it alone.
		var reopened = inline
		reopened.isInPictureInPicture = true
		reopened.revision = 4
		await store.send(.event(.changed(.init(revision: 4, sources: [reopened]), observationID: 1)))
		await store.finish()
		#expect(requests.value.isEmpty)
	}

	@Test
	internal func aReturnWaitsForTheCoveredWindowToShowAndForAFreeCommand() async throws {
		var video = source()
		video.isInPictureInPicture = true
		var initial = state(video)
		initial.automaticEntry.isApplicationActive = false
		initial.automaticEntry.hidden = [video.id]
		initial.automaticEntry.deactivationEntries = [video.id]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let gate = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					requests.withValue { $0.append(request) }
					guard request.action == .pause else { return }
					try await withCheckedThrowingContinuation { gate.setValue($0) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// Arx is back before the window's visibility report.
		await store.send(.event(.applicationActivityChanged(isActive: true)))
		#expect(store.state.automaticEntry.returns == [video.id])
		await store.send(.ui(.perform(video.id, .pause)))
		try #require(await eventually { gate.value != nil })
		await store.send(.ui(.sourceBecameVisible(video.id)))
		try #require(gate.value).resume()
		await store.receive(\.event.finished)
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.pause, .exitPictureInPicture])
	}

	@Test
	internal func aManualEntryInFlightKeepsPictureInPictureFromTheShowingVideo() async throws {
		let showing = source(1)
		let manual = source(2)
		var initial = state(showing)
		initial.snapshot = .init(revision: 1, sources: [showing, manual])
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let gate = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					let isFirst = requests.withValue { $0.append(request); return $0.count == 1 }
					guard isFirst else { return }
					try await withCheckedThrowingContinuation { gate.setValue($0) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.sourceBecameVisible(showing.id)))
		await store.send(.ui(.perform(manual.id, .enterPictureInPicture)))
		try #require(await eventually { gate.value != nil })
		await store.send(.event(.applicationActivityChanged(isActive: false)))
		try #require(gate.value).resume()
		await store.receive(\.event.finished)
		await store.finish()

		// The manual entry succeeded before its snapshot arrived; nothing replaces it.
		expectNoDifference(requests.value.map(\.sourceID), [manual.id])
	}

	@Test
	internal func aLateVisibleReportSendsTheReturnThroughItsSilentRetryingPath() async {
		var video = source()
		video.isInPictureInPicture = true
		var initial = state(video)
		initial.automaticEntry.hidden = [video.id]
		initial.automaticEntry.returns = [video.id]
		initial.automaticEntry.observedFloating = [video.id]
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let failures = LockIsolated<[BrowserMediaClient.Failure]>([.staleSource])
		let store = makeStore(initial, requests: requests, failures: failures)

		await store.send(.ui(.sourceBecameVisible(video.id)))
		await store.receive(\.event.finished)
		#expect(store.state.failure == nil)
		#expect(store.state.automaticEntry.returns == [video.id])
		var fresh = video
		fresh.revision = 2
		await store.send(.event(.changed(.init(revision: 2, sources: [fresh]), observationID: 1)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.expectedRevision), [1, 2])
	}

	@Test
	internal func aHiddenEntryAcceptedBeforeItsSnapshotKeepsPictureInPicture() async throws {
		let hidden = source(1)
		let showing = source(2)
		var initial = state(hidden)
		initial.snapshot = .init(revision: 1, sources: [hidden, showing])
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let gate = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					let isFirst = requests.withValue { $0.append(request); return $0.count == 1 }
					guard isFirst else { return }
					try await withCheckedThrowingContinuation { gate.setValue($0) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.sourceBecameVisible(showing.id)))
		await store.send(.ui(.sourceBecameHidden(hidden.id)))
		try #require(await eventually { gate.value != nil })
		await store.send(.event(.applicationActivityChanged(isActive: false)))
		try #require(gate.value).resume()
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.sourceID), [hidden.id])
	}

	@Test
	internal func aTabShowingAgainWhileArxIsInactiveReturnsOnActivation() async {
		var video = source()
		video.isInPictureInPicture = true
		var initial = state(video)
		initial.automaticEntry.isApplicationActive = false
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.sourceBecameVisible(video.id)))
		#expect(requests.value.isEmpty)
		await store.send(.event(.applicationActivityChanged(isActive: true)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.exitPictureInPicture])
	}

	@Test
	internal func aStaleEntryWaitsForItsOwnSourcesNewerRevision() async {
		let video = source(1)
		let other = source(2)
		var initial = state(video)
		initial.snapshot = .init(revision: 1, sources: [video, other])
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let failures = LockIsolated<[BrowserMediaClient.Failure]>([.staleSource])
		let store = makeStore(initial, requests: requests, failures: failures)

		await store.send(.ui(.sourceBecameHidden(video.id)))
		await store.receive(\.event.finished)

		// Another source changes; this one keeps its revision, so nothing is sent.
		var changed = other
		changed.revision = 2
		await store.send(.event(.changed(.init(revision: 2, sources: [video, changed]), observationID: 1)))
		#expect(requests.value.count == 1)
		var fresh = video
		fresh.revision = 3
		await store.send(.event(.changed(.init(revision: 3, sources: [fresh, changed]), observationID: 1)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.expectedRevision), [1, 3])
	}


	// MARK: - The tab stopping being visible

	@Test
	internal func aStaleRevisionAtTheHideRetriesWithTheNextSnapshot() async {
		let video = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let failures = LockIsolated<[BrowserMediaClient.Failure]>([.staleSource])
		let store = makeStore(state(video), requests: requests, failures: failures)

		await store.send(.ui(.sourceBecameVisible(video.id)))
		await store.send(.ui(.sourceBecameHidden(video.id)))
		await store.receive(\.event.finished)
		#expect(requests.value.count == 1)
		#expect(store.state.automaticEntry.owed[video.id] == .hidden)

		var fresh = video
		fresh.revision = 2
		await store.send(.event(.changed(.init(revision: 2, sources: [fresh]), observationID: 1)))
		await store.receive(\.event.finished)
		await store.finish()

		// The automatic route failed once, so the retry asks for the entry itself.
		expectNoDifference(
			requests.value.map(\.action),
			[.enterAutomaticPictureInPicture, .enterPictureInPicture]
		)
		expectNoDifference(requests.value.map(\.expectedRevision), [1, 2])
		#expect(store.state.automaticEntry.owed.isEmpty)
		#expect(store.state.failure == nil)
	}

	@Test
	internal func aStaleReplyAfterTheNewerSnapshotRetriesAtOnce() async throws {
		let video = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let gate = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
		let store = TestStore(initialState: state(video)) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					requests.withValue { $0.append(request) }
					guard request.expectedRevision == 1 else { return }
					try await withCheckedThrowingContinuation { gate.setValue($0) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.sourceBecameHidden(video.id)))
		try #require(await eventually { gate.value != nil })
		var fresh = video
		fresh.revision = 2
		await store.send(.event(.changed(.init(revision: 2, sources: [fresh]), observationID: 1)))
		try #require(gate.value).resume(throwing: BrowserMediaClient.Failure.staleSource)
		await store.receive(\.event.finished)
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.expectedRevision), [1, 2])
	}

	@Test
	internal func aRefusedAutomaticEntryFallsBackAtOnce() async {
		let video = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let failures = LockIsolated<[BrowserMediaClient.Failure]>([.unsupportedAction])
		let store = makeStore(state(video), requests: requests, failures: failures)

		await store.send(.ui(.sourceBecameHidden(video.id)))
		await store.receive(\.event.finished)
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(
			requests.value.map(\.action),
			[.enterAutomaticPictureInPicture, .enterPictureInPicture]
		)
	}

	@Test
	internal func aCommandInFlightAtTheHideDelaysTheEntryInsteadOfDroppingIt() async throws {
		let video = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let gate = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
		let store = TestStore(initialState: state(video)) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					requests.withValue { $0.append(request) }
					guard request.action == .pause else { return }
					try await withCheckedThrowingContinuation { gate.setValue($0) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.perform(video.id, .pause)))
		await store.send(.ui(.sourceBecameHidden(video.id)))
		#expect(store.state.automaticEntry.owed[video.id] == .hidden)
		try #require(await eventually { gate.value != nil })
		try #require(gate.value).resume()
		await store.receive(\.event.finished)
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.action), [.pause, .enterAutomaticPictureInPicture])
	}

	@Test
	internal func retriesStopAfterThreeFailures() async {
		let video = source()
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let failures = LockIsolated<[BrowserMediaClient.Failure]>(Array(repeating: .requestFailed, count: 10))
		let store = makeStore(state(video), requests: requests, failures: failures)

		await store.send(.ui(.sourceBecameHidden(video.id)))
		await store.skipReceivedActions()
		await store.finish()
		#expect(requests.value.count == AutomaticEntry.maximumFailures)
		#expect(store.state.automaticEntry.owed.isEmpty)
		#expect(store.state.failure == nil)
	}

	@Test
	internal func aVideoThatStartsAfterItsTabWasLeftStaysPut() async {
		var video = source()
		video.playback = .paused
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(state(video), requests: requests)

		await store.send(.ui(.sourceBecameHidden(video.id)))
		var playing = video
		playing.playback = .playing
		playing.revision = 2
		await store.send(.event(.changed(.init(revision: 2, sources: [playing]), observationID: 1)))
		await store.finish()
		#expect(requests.value.isEmpty)
	}

	@Test
	internal func onlyTheSplitPaneThatDisappearsFloats() async {
		let left = source(1)
		let right = source(2)
		var initial = state(left)
		initial.snapshot = .init(revision: 1, sources: [left, right])
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = makeStore(initial, requests: requests)

		await store.send(.ui(.sourceBecameVisible(left.id)))
		await store.send(.ui(.sourceBecameVisible(right.id)))
		await store.send(.ui(.sourceBecameHidden(right.id)))
		await store.receive(\.event.finished)
		await store.finish()
		expectNoDifference(requests.value.map(\.sourceID), [right.id])
	}

	// MARK: - Helpers

	internal enum Exclusion: CaseIterable, Sendable {
		case siteOptOut, settingOff, paused, audioOnly, alreadyFloating, `private`
	}

	private func makeStore(
		_ initial: MediaFeature.State,
		requests: LockIsolated<[BrowserMediaRequest]>,
		failures: LockIsolated<[BrowserMediaClient.Failure]> = .init([])
	) -> TestStoreOf<MediaFeature> {
		let store = TestStore(initialState: initial) { MediaFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserMedia = .init(
				isAvailable: true,
				perform: { request in
					requests.withValue { $0.append(request) }
					let failure = failures.withValue { $0.isEmpty ? nil : $0.removeFirst() }
					if let failure { throw failure }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	private func eventually(_ condition: () -> Bool) async -> Bool {
		// Until a deadline rather than a fixed number of polls, which a busy Mac used up first.
		try? await waitWhile { !condition() }
		return condition()
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
