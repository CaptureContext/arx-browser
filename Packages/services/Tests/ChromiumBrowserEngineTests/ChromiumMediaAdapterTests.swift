import BrowserCore
import BrowserMediaClient
import ChromiumEngine
import CustomDump
import Foundation
import Testing

@testable import ChromiumBrowserEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumMediaAdapterTests {
	@Test
	internal func mapsExactOwnersAndWithholdsPrivateAndUnknownMetadata() async throws {
		let fixture = Fixture()
		fixture.adapter.register(
			page: 2,
			tabID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
			profileID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!),
			isPrivate: true
		)
		var privateSource = fixture.native
		privateSource.page = 2
		privateSource.title = "Private sentinel"
		var unknownSource = fixture.native
		unknownSource.page = 3
		fixture.adapter.receive([fixture.native, privateSource, unknownSource])
		var events = fixture.adapter.client.events().makeAsyncIterator()
		let snapshot = try #require(await events.next())
		expectNoDifference(snapshot.sources, [fixture.source])
		#expect(snapshot.isValid)
		#expect(!snapshot.sources[0].actions.contains(.enterAutomaticPictureInPicture))
	}

	@Test
	internal func automaticActionUsesOnlySeparatelyAdvertisedNativeCapability() async throws {
		let fixture = Fixture()
		await #expect(throws: BrowserMediaClient.Failure.staleSource) {
			try await fixture.adapter.client.perform(
				.init(source: fixture.source, action: .enterAutomaticPictureInPicture)
			)
		}
		#expect(fixture.calls == 0)

		var native = fixture.native
		native.actions.insert(.enterAutomaticPictureInPicture)
		fixture.adapter.receive([native])
		var events = fixture.adapter.client.events().makeAsyncIterator()
		let snapshot = try #require(await events.next())
		let source = try #require(snapshot.sources.first)
		#expect(source.supports(.enterAutomaticPictureInPicture))
		fixture.expectedAction = .enterAutomaticPictureInPicture
		try await fixture.adapter.client.perform(
			.init(source: source, action: .enterAutomaticPictureInPicture)
		)
		#expect(fixture.calls == 1)
	}

	@Test
	internal func tracksArtistAndArtworkReachTheAppAndTrackActionsDispatch() async throws {
		let fixture = Fixture()
		var native = fixture.native
		native.revision += 1
		native.artist = "Artist"
		native.artwork = Data([0x89, 0x50, 0x4E, 0x47])
		native.actions.formUnion([.nextTrack, .previousTrack])
		fixture.adapter.receive([native])
		var events = fixture.adapter.client.events().makeAsyncIterator()
		let source = try #require(await events.next()?.sources.first)
		expectNoDifference(source.artist, "Artist")
		expectNoDifference(source.artwork, native.artwork)
		#expect(source.supports(.nextTrack) && source.supports(.previousTrack))

		fixture.expectedAction = .nextTrack
		try await fixture.adapter.client.perform(.init(source: source, action: .nextTrack))
		fixture.expectedAction = .previousTrack
		try await fixture.adapter.client.perform(.init(source: source, action: .previousTrack))
		#expect(fixture.calls == 2)
	}

	@Test
	internal func staleRevisionGenerationProfileAndCancelledRequestNeverDispatch() async throws {
		let fixture = Fixture()
		let request = BrowserMediaRequest(source: fixture.source, action: .pause)
		var invalid = [request, request, request]
		invalid[0].expectedRevision += 1
		invalid[1].sourceID.generation += 1
		invalid[2].sourceID.profileID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
		for request in invalid {
			await #expect(throws: BrowserMediaClient.Failure.staleSource) {
				try await fixture.adapter.client.perform(request)
			}
		}
		let task = Task { try await fixture.adapter.client.perform(request) }
		task.cancel()
		await #expect(throws: CancellationError.self) { try await task.value }
		#expect(fixture.calls == 0)
	}

	@Test
	internal func exactSourcePerformsAndClosingDuringNativeAwaitRejectsLateSuccess() async throws {
		let fixture = Fixture()
		fixture.suspend = true
		let request = BrowserMediaRequest(source: fixture.source, action: .pause)
		let task = Task { try await fixture.adapter.client.perform(request) }
		var starts = fixture.starts.makeAsyncIterator()
		#expect(await starts.next() == 1)
		fixture.adapter.remove(page: 1)
		fixture.pending?.resume()
		fixture.pending = nil
		await #expect(throws: BrowserMediaClient.Failure.staleSource) { try await task.value }
	}

	@Test
	internal func nativeReturnToTabRequiresTheCurrentGenerationAndOwner() async throws {
		let fixture = Fixture()
		var activations = fixture.adapter.client.activations().makeAsyncIterator()
		fixture.adapter.activate(.init(page: 99, generation: 1))
		fixture.adapter.activate(.init(page: 1, generation: 99))
		fixture.adapter.activate(.init(page: 1, generation: 1))
		let activation = await activations.next()
		expectNoDifference(activation, fixture.source.id)
	}

	@Test
	internal func synchronousValidationIgnoresUnchangedReplayedSwiftSnapshots() async throws {
		let fixture = Fixture()
		let client = fixture.adapter.client
		#expect(client.isSourceCurrent(fixture.source.id))
		fixture.currentGeneration += 1
		#expect(!client.isSourceCurrent(fixture.source.id))
		// Replaying old copied data cannot override the independently queried native identity.
		fixture.adapter.receive([fixture.native])
		var events = client.events().makeAsyncIterator()
		let snapshot = try #require(await events.next())
		expectNoDifference(snapshot.sources, [fixture.source])
		#expect(!client.isSourceCurrent(fixture.source.id))
		expectNoDifference(fixture.validationCalls, 3)
	}

	@Test(arguments: ["missing", "private", "profile", "tab", "zero", "wrongGeneration"])
	internal func synchronousValidationRejectsInvalidOwnership(reason: String) async throws {
		let fixture = Fixture()
		var id = fixture.source.id
		switch reason {
		case "missing": fixture.adapter.remove(page: 1)
		case "private": fixture.adapter.register(page: 1, tabID: id.tabID, profileID: id.profileID, isPrivate: true)
		case "profile": id.profileID = .init(rawValue: UUID())
		case "tab": id.tabID = .init(rawValue: UUID())
		case "zero": id.generation = 0
		default: id.generation += 1
		}
		#expect(!fixture.adapter.client.isSourceCurrent(id))
		expectNoDifference(fixture.validationCalls, reason == "wrongGeneration" ? 1 : 0)
	}

	@Test
	internal func finishedObservationCannotValidateRetainedOwnership() async throws {
		let fixture = Fixture()
		let events = AsyncStream<[ChromiumMediaSource]>.makeStream()
		let activations = AsyncStream<ChromiumMediaActivation>.makeStream()
		fixture.adapter.start(events: events.stream, activations: activations.stream)
		var stream = fixture.adapter.client.events().makeAsyncIterator()
		events.continuation.finish()
		activations.continuation.finish()
		while await stream.next() != nil {}
		#expect(!fixture.adapter.client.isSourceCurrent(fixture.source.id))
		expectNoDifference(fixture.validationCalls, 0)
	}

	@Test
	internal func pagesWithoutMediaAndUnchangedSourcesPublishNoSnapshot() async throws {
		let fixture = Fixture()
		var events = fixture.adapter.client.events().makeAsyncIterator()
		let first = try #require(await events.next())

		// Each snapshot is a store action: opening and closing pages without media, or the same
		// sources again, must not send one (DEV-945).
		for page in UInt64(10) ..< 110 {
			fixture.adapter.register(
				page: page,
				tabID: .init(rawValue: UUID()),
				profileID: fixture.profileID,
				isPrivate: false
			)
		}
		for page in UInt64(10) ..< 110 {
			fixture.adapter.remove(page: page)
		}
		fixture.adapter.receive([fixture.native])

		var paused = fixture.native
		paused.revision += 1
		paused.playback = .paused
		fixture.adapter.receive([paused])
		let next = try #require(await events.next())
		expectNoDifference(next.revision, first.revision + 1)
		expectNoDifference(next.sources.map(\.playback), [.paused])
	}

	@Test
	internal func nativeTimeoutStaysTypedAndNoOptimisticPlaybackIsInvented() async throws {
		let fixture = Fixture()
		fixture.failure = .timedOut
		await #expect(throws: BrowserMediaClient.Failure.timedOut) {
			try await fixture.adapter.client.perform(.init(source: fixture.source, action: .pause))
		}
		var events = fixture.adapter.client.events().makeAsyncIterator()
		let snapshot = try #require(await events.next())
		expectNoDifference(snapshot.sources, [fixture.source])
	}

	// MARK: - Outside Chromium (DEV-1147)

	@Test
	internal func anOutsideTrackStandsInForItsTabsChromiumSource() async throws {
		let fixture = Fixture()
		fixture.adapter.setOutside([fixture.tabID: fixture.outside(.playing)])
		var events = fixture.adapter.client.events().makeAsyncIterator()
		let snapshot = try #require(await events.next())
		#expect(snapshot.isValid)
		let source = try #require(snapshot.sources.first)
		expectNoDifference(snapshot.sources.count, 1)
		expectNoDifference(source.id.tabID, fixture.tabID)
		expectNoDifference(source.id.profileID, fixture.profileID)
		expectNoDifference(source.id.generation, ChromiumMediaAdapter.outsideGeneration | 7)
		expectNoDifference(source.title, "Song")
		expectNoDifference(source.artist, "Artist")
		expectNoDifference(source.playback, .playing)
		#expect(source.supports(.pause) && !source.supports(.play) && !source.supports(.seek))
		#expect(fixture.adapter.client.isSourceCurrent(source.id))
		expectNoDifference(fixture.validationCalls, 0)
		#expect(fixture.adapter.isActive(tabID: fixture.tabID))

		// No outside track: Chromium's source comes back.
		fixture.adapter.setOutside([:])
		events = fixture.adapter.client.events().makeAsyncIterator()
		let snapshot1 = try #require(await events.next())
		expectNoDifference(snapshot1.sources, [fixture.source])
		#expect(!fixture.adapter.client.isSourceCurrent(source.id))
	}

	@Test
	internal func anOutsideTracksControlsReachItsPageAndNeverChromium() async throws {
		let fixture = Fixture()
		fixture.adapter.performOutside = { [fixture] tabID, action in
			fixture.outsideControls.append((tabID, action))
			return true
		}
		fixture.adapter.setOutside([fixture.tabID: fixture.outside(.playing)])
		var events = fixture.adapter.client.events().makeAsyncIterator()
		let playing = try #require(await events.next()?.sources.first)
		try await fixture.adapter.client.perform(.init(source: playing, action: .pause))
		try await fixture.adapter.client.perform(.init(source: playing, action: .nextTrack))

		// Paused, the source's revision moves on: a control for the playing one is stale.
		fixture.adapter.setOutside([fixture.tabID: fixture.outside(.paused)])
		events = fixture.adapter.client.events().makeAsyncIterator()
		let paused = try #require(await events.next()?.sources.first)
		#expect(paused.revision > playing.revision)
		await #expect(throws: BrowserMediaClient.Failure.staleSource) {
			try await fixture.adapter.client.perform(.init(source: playing, action: .pause))
		}
		try await fixture.adapter.client.perform(.init(source: paused, action: .play))
		expectNoDifference(fixture.outsideControls.map { $0.1 }, [.pause, .nextTrack, .play])
		#expect(fixture.outsideControls.allSatisfy { $0.0 == fixture.tabID })
		expectNoDifference(fixture.calls, 0)

		// The page no longer holds it: the control fails.
		fixture.adapter.performOutside = { _, _ in false }
		await #expect(throws: BrowserMediaClient.Failure.staleSource) {
			try await fixture.adapter.client.perform(.init(source: paused, action: .play))
		}
	}

	@Test
	internal func aNewOutsideTrackRetiresThePreviousOnesControls() async throws {
		let fixture = Fixture()
		fixture.adapter.performOutside = { _, _ in true }
		fixture.adapter.setOutside([fixture.tabID: fixture.outside(.playing)])
		var events = fixture.adapter.client.events().makeAsyncIterator()
		let first = try #require(await events.next()?.sources.first)

		var next = fixture.outside(.playing)
		next.track = 8
		fixture.adapter.setOutside([fixture.tabID: next])
		events = fixture.adapter.client.events().makeAsyncIterator()
		let second = try #require(await events.next()?.sources.first)
		#expect(first.id != second.id)
		#expect(!fixture.adapter.client.isSourceCurrent(first.id))
		#expect(fixture.adapter.client.isSourceCurrent(second.id))
		await #expect(throws: BrowserMediaClient.Failure.staleSource) {
			try await fixture.adapter.client.perform(.init(source: first, action: .pause))
		}
	}

	@Test
	internal func aPrivateOrClosedTabsOutsideTrackNeverShows() async throws {
		let fixture = Fixture()
		let privateTab = Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
		fixture.adapter.register(page: 9, tabID: privateTab, profileID: fixture.profileID, isPrivate: true)
		let unknownTab = Tab.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
		fixture.adapter.setOutside([
			privateTab: fixture.outside(.playing),
			unknownTab: fixture.outside(.playing),
		])
		var events = fixture.adapter.client.events().makeAsyncIterator()
		let snapshot2 = try #require(await events.next())
		expectNoDifference(snapshot2.sources, [fixture.source])

		// Its tab's page goes: the track goes with it.
		fixture.adapter.setOutside([fixture.tabID: fixture.outside(.playing)])
		fixture.adapter.remove(page: 1)
		events = fixture.adapter.client.events().makeAsyncIterator()
		let snapshot3 = try #require(await events.next())
		expectNoDifference(snapshot3.sources, [])
	}

	@Test
	internal func anOutsideTrackIsTheTabsPositionSourceWithTheTabsMute() async throws {
		let fixture = Fixture()
		let adapter = ChromiumMediaAdapter(perform: { _, _, _ in }, position: { _ in
			.init(generation: 1, isMuted: true, position: 12, duration: 30, playbackRate: 1)
		})
		adapter.register(page: 1, tabID: fixture.tabID, profileID: fixture.profileID, isPrivate: false)
		adapter.receive([fixture.native])
		adapter.setOutside([fixture.tabID: fixture.outside(.paused)])
		let position = try #require(adapter.client.position(fixture.tabID))
		expectNoDifference(position.sourceID?.generation, ChromiumMediaAdapter.outsideGeneration | 7)
		#expect(position.isMuted)
		#expect(position.position == nil && position.duration == nil)
	}
}

@MainActor
private final class Fixture {
	internal let tabID: Tab.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
	internal let profileID: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
	internal let starts: AsyncStream<UInt64>
	internal let continuation: AsyncStream<UInt64>.Continuation
	internal var pending: CheckedContinuation<Void, Never>?
	internal var suspend: Bool = false
	internal var failure: ChromiumMediaFailure?
	internal var calls: Int = 0
	internal var currentGeneration: UInt64 = 1
	internal var validationCalls: Int = 0
	internal var expectedAction: ChromiumMediaSource.Action = .pause
	internal var outsideControls: [(Tab.ID, BrowserMediaSource.Action)] = []
	internal lazy var adapter: ChromiumMediaAdapter = .init(isCurrent: { [self] page, id in
		validationCalls += 1
		return page == 1 && id.tabID == tabID && id.profileID == profileID && id.generation == currentGeneration
	}) { [self] page, request, action in
		#expect(page == 1 && request.sourceID == source.id && action == expectedAction)
		calls += 1
		continuation.yield(page)
		if suspend { await withCheckedContinuation { pending = $0 } }
		if let failure { throw failure }
	}

	internal init() {
		let pair = AsyncStream<UInt64>.makeStream()
		self.starts = pair.stream
		self.continuation = pair.continuation
		adapter.register(page: 1, tabID: tabID, profileID: profileID, isPrivate: false)
		adapter.receive([native])
	}

	internal var native: ChromiumMediaSource {
		.init(
			page: 1,
			generation: 1,
			revision: 2,
			title: "Media fixture",
			origin: URL(string: "https://capturecontext.dev"),
			hasVideo: true,
			playback: .playing,
			actions: [.pause, .enterPictureInPicture],
			isInPictureInPicture: false
		)
	}

	internal func outside(_ playback: BrowserMediaSource.Playback) -> OutsideChromiumMedia {
		.init(
			track: 7,
			title: "Song",
			artist: "Artist",
			site: .init(url: URL(string: "https://open.spotify.com")!),
			playback: playback,
			actions: [.play, .pause, .nextTrack, .previousTrack]
		)
	}

	internal var source: BrowserMediaSource {
		.init(
			id: .init(tabID: tabID, profileID: profileID, generation: 1),
			revision: 2,
			title: "Media fixture",
			site: .init(url: URL(string: "https://capturecontext.dev")!),
			hasVideo: true,
			playback: .playing,
			actions: [.pause, .enterPictureInPicture]
		)
	}
}
