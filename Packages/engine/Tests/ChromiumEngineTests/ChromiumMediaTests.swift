import ChromiumBridge
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumMediaTests {
	@Test
	internal func callbacksCopyMetadataAndReplayOnlyObservedPages() async throws {
		let fixture = Fixture()
		fixture.publish(page: 99, title: "Unowned private sentinel")
		fixture.publish(title: "Ordinary source")
		var events = fixture.observation.events().makeAsyncIterator()
		let snapshot = try #require(await events.next())
		expectNoDifference(snapshot.map(\.title), ["Ordinary source"])
		#expect(snapshot.first?.origin == URL(string: "https://capturecontext.dev"))
		fixture.publish(revision: 1, title: "Older callback")
		expectNoDifference(fixture.observation.source(page: 1)?.title, "Ordinary source")
		fixture.observation.remove(page: 1, cancel: { _ in })
		fixture.publish(revision: 9)
		let empty = await events.next()
		expectNoDifference(empty, [])
	}

	@Test
	internal func snapshotsCarryTheTrackActionsArtistAndArtwork() throws {
		var native = Fixture.native(generation: 3, revision: 1)
		native.actions |= UInt32(ARX_MEDIA_CAN_NEXT_TRACK | ARX_MEDIA_CAN_PREVIOUS_TRACK)
		let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
		let source = try "Artist".withCString { artist in
			try png.withUnsafeBufferPointer { bytes in
				native.artist = artist
				native.artwork = bytes.baseAddress
				native.artwork_size = bytes.count
				return try #require(ChromiumMediaSource(page: 1, native: native))
			}
		}
		expectNoDifference(source.actions, [.pause, .enterPictureInPicture, .nextTrack, .previousTrack])
		expectNoDifference(source.artist, "Artist")
		expectNoDifference(source.artwork, Data(png))

		// A bit past the ABI's actions is not a snapshot this engine made.
		native.actions |= 2048
		#expect(ChromiumMediaSource(page: 1, native: native) == nil)
	}

	@Test
	internal func nativeConfirmationIsAuthoritativeAndWrongPageCannotComplete() async throws {
		let fixture = Fixture()
		fixture.publish()
		let source = try #require(fixture.observation.source(page: 1))
		let task = Task { try await fixture.perform(source) }
		let request = try #require(await fixture.nextRequest())
		fixture.observation.complete(request: request, page: 99, status: ARX_MEDIA_SUCCESS)
		await #expect(throws: ChromiumMediaFailure.staleSource) { try await task.value }
	}

	@Test
	internal func cancelledBeforeDispatchNeverCallsNative() async throws {
		let fixture = Fixture()
		fixture.publish()
		let source = try #require(fixture.observation.source(page: 1))
		let task = Task { try await fixture.perform(source) }
		task.cancel()
		await #expect(throws: CancellationError.self) { try await task.value }
		#expect(fixture.started.isEmpty)
	}

	@Test
	internal func cancelledRequestDrainsOnceAndLateCompletionCannotTouchNextRequest() async throws {
		let fixture = Fixture()
		fixture.publish()
		let source = try #require(fixture.observation.source(page: 1))
		let task = Task { try await fixture.perform(source) }
		let request = try #require(await fixture.nextRequest())
		task.cancel()
		await #expect(throws: CancellationError.self) { try await task.value }
		expectNoDifference(fixture.cancelled, [request])
		let next = Task { try await fixture.perform(source) }
		let nextRequest = try #require(await fixture.nextRequest())
		fixture.observation.complete(request: request, page: 1, status: ARX_MEDIA_SUCCESS)
		fixture.observation.complete(request: nextRequest, page: 1, status: ARX_MEDIA_SUCCESS)
		try await next.value
	}

	@Test
	internal func changedGenerationInvalidatesLateSuccessAndSourceActivation() async throws {
		let fixture = Fixture()
		fixture.publish()
		let source = try #require(fixture.observation.source(page: 1))
		var activations = fixture.observation.activations().makeAsyncIterator()
		let task = Task { try await fixture.perform(source) }
		let request = try #require(await fixture.nextRequest())
		fixture.publish(generation: 2, revision: 3)
		fixture.observation.activate(page: 1, generation: 1)
		fixture.observation.activate(page: 99, generation: 2)
		fixture.observation.activate(page: 1, generation: 2)
		let activation = await activations.next()
		expectNoDifference(activation, .init(page: 1, generation: 2))
		fixture.observation.complete(request: request, page: 1, status: ARX_MEDIA_SUCCESS)
		await #expect(throws: ChromiumMediaFailure.staleSource) { try await task.value }
		await #expect(throws: ChromiumMediaFailure.staleSource) { try await fixture.perform(source) }
	}

	@Test
	internal func closeCancelsPendingAndShutdownPublishesEmptyThenEnds() async throws {
		let fixture = Fixture()
		fixture.publish()
		let source = try #require(fixture.observation.source(page: 1))
		let task = Task { try await fixture.perform(source) }
		let request = try #require(await fixture.nextRequest())
		fixture.observation.remove(page: 1, cancel: { fixture.cancelled.append($0) })
		await #expect(throws: ChromiumMediaFailure.staleSource) { try await task.value }
		expectNoDifference(fixture.cancelled, [request])
		var events = fixture.observation.events().makeAsyncIterator()
		fixture.observation.finish()
		let empty = await events.next()
		expectNoDifference(empty, [])
		#expect(await events.next() == nil)
		fixture.observation.complete(request: request, page: 1, status: ARX_MEDIA_SUCCESS)
	}

	@Test(arguments: [ARX_MEDIA_TIMEOUT, ARX_MEDIA_UNSUPPORTED, ARX_MEDIA_UNAVAILABLE, ARX_MEDIA_BUSY])
	internal func preservesNativeFailures(_ status: ArxMediaStatus) async throws {
		let fixture = Fixture()
		fixture.publish()
		let source = try #require(fixture.observation.source(page: 1))
		let task = Task { try await fixture.perform(source) }
		let request = try #require(await fixture.nextRequest())
		fixture.observation.complete(request: request, page: 1, status: status)
		await #expect(throws: ChromiumMediaFailure(status: status)) { try await task.value }
	}

	@Test
	internal func automaticCapabilityIsSeparateAndUnknownNativeBitsAreRejected() async throws {
		let fixture = Fixture()
		fixture.publish()
		let manual = try #require(fixture.observation.source(page: 1))
		await #expect(throws: ChromiumMediaFailure.unsupportedAction) {
			try await fixture.observation.perform(
				manual,
				action: .enterAutomaticPictureInPicture,
				start: { _ in Issue.record("Manual capability cannot authorize automatic entry") },
				cancel: { _ in }
			)
		}

		var automatic = Fixture.native(generation: 1, revision: 3)
		automatic.actions = UInt32(ARX_MEDIA_CAN_PAUSE | ARX_MEDIA_CAN_ENTER_AUTOMATIC_PICTURE)
		fixture.observation.receive(page: 1, native: automatic)
		let source = try #require(fixture.observation.source(page: 1))
		#expect(source.actions.contains(.enterAutomaticPictureInPicture))
		#expect(!source.actions.contains(.enterPictureInPicture))

		automatic.revision += 1
		automatic.actions |= 2048
		fixture.observation.receive(page: 1, native: automatic)
		#expect(fixture.observation.source(page: 1) == nil)
	}

	/// ABI54 (DEV-948): a call is present without a playing video, its Picture in Picture can be
	/// the site's own document, and it carries its call actions and devices.
	@Test
	internal func callsCarryTheirActionsAndDevices() async throws {
		let fixture = Fixture()
		var call = Fixture.native(generation: 1, revision: 1)
		call.video = false
		call.call = true
		call.actions = UInt32(
			ARX_MEDIA_CAN_ENTER_AUTOMATIC_PICTURE | ARX_MEDIA_CAN_TOGGLE_MICROPHONE
			| ARX_MEDIA_CAN_TOGGLE_CAMERA | ARX_MEDIA_CAN_HANG_UP
		)
		call.microphone = ARX_MEDIA_DEVICE_OFF
		call.camera = ARX_MEDIA_DEVICE_ON
		fixture.observation.receive(page: 1, native: call)
		let source = try #require(fixture.observation.source(page: 1))
		#expect(source.isCall)
		#expect(source.microphone == .off)
		#expect(source.camera == .on)
		expectNoDifference(
			source.actions,
			[.enterAutomaticPictureInPicture, .toggleMicrophone, .toggleCamera, .hangUp]
		)

		// Meet's Document PiP: in Picture in Picture without a video.
		call.revision += 1
		call.picture = true
		call.actions = UInt32(ARX_MEDIA_CAN_EXIT_PICTURE | ARX_MEDIA_CAN_HANG_UP)
		fixture.observation.receive(page: 1, native: call)
		#expect(fixture.observation.source(page: 1)?.isInPictureInPicture == true)

		// Anything else in Picture in Picture without a video is refused, as before.
		call.revision += 1
		call.call = false
		fixture.observation.receive(page: 1, native: call)
		#expect(fixture.observation.source(page: 1) == nil)
	}

	@Test
	internal func seekIsItsOwnCapability() async throws {
		let fixture = Fixture()
		fixture.publish()
		let source = try #require(fixture.observation.source(page: 1))
		await #expect(throws: ChromiumMediaFailure.unsupportedAction) {
			try await fixture.observation.perform(
				source,
				action: .seek,
				start: { _ in Issue.record("A source without SeekTo cannot seek") },
				cancel: { _ in }
			)
		}

		var seekable = Fixture.native(generation: 1, revision: 3)
		seekable.actions = UInt32(ARX_MEDIA_CAN_PAUSE | ARX_MEDIA_CAN_SEEK)
		fixture.observation.receive(page: 1, native: seekable)
		let current = try #require(fixture.observation.source(page: 1))
		expectNoDifference(current.actions, [.pause, .seek])
	}

	@Test
	internal func positionReadsReportOnlyWhatTheEngineKnows() throws {
		var native = ArxMediaPosition()
		native.muted = true
		expectNoDifference(ChromiumMediaPosition(native: native), .init(generation: nil, isMuted: true))

		native.generation = 4
		native.has_position = true
		native.position = 1.5
		native.duration = -1
		native.playback_rate = 1
		expectNoDifference(
			ChromiumMediaPosition(native: native),
			.init(generation: 4, isMuted: true, position: 1.5, duration: nil, playbackRate: 1)
		)

		native.duration = 2
		expectNoDifference(ChromiumMediaPosition(native: native)?.duration, 2)

		for invalid in [Double.nan, -1, .infinity] {
			var malformed = native
			malformed.position = invalid
			#expect(ChromiumMediaPosition(native: malformed) == nil)
		}
		var sourceless = native
		sourceless.generation = 0
		#expect(ChromiumMediaPosition(native: sourceless) == nil)
	}

	@Test
	internal func unsupportedActionAndMalformedNativeStateCannotDispatch() async throws {
		let fixture = Fixture()
		fixture.publish()
		let source = try #require(fixture.observation.source(page: 1))
		await #expect(throws: ChromiumMediaFailure.unsupportedAction) {
			try await fixture.observation.perform(source, action: .play, start: { _ in Issue.record("Unexpected dispatch") }, cancel: { _ in })
		}
		var invalid = Fixture.native(generation: 1, revision: 3)
		invalid.picture = true
		invalid.video = false
		fixture.observation.receive(page: 1, native: invalid)
		#expect(fixture.observation.source(page: 1) == nil)
	}
}

@MainActor
private final class Fixture {
	internal let observation: ChromiumMediaObservation = .init()
	internal let requests: AsyncStream<UInt64>
	internal let continuation: AsyncStream<UInt64>.Continuation
	internal var started: [UInt64] = []
	internal var cancelled: [UInt64] = []

	internal init() {
		let pair = AsyncStream<UInt64>.makeStream()
		self.requests = pair.stream
		self.continuation = pair.continuation
		observation.register(1)
	}

	internal func nextRequest() async -> UInt64? {
		var iterator = requests.makeAsyncIterator()
		return await iterator.next()
	}

	internal func publish(
		page: UInt64 = 1,
		generation: UInt64 = 1,
		revision: UInt64 = 2,
		title: String = "Media fixture"
	) {
		var snapshot = Self.native(generation: generation, revision: revision)
		title.withCString { title in
			"https://capturecontext.dev".withCString { origin in
				snapshot.title = title
				snapshot.origin = origin
				observation.receive(page: page, native: snapshot)
			}
		}
	}

	internal func perform(_ source: ChromiumMediaSource) async throws {
		try await observation.perform(
			source,
			action: .pause,
			start: { [self] request in
				started.append(request)
				continuation.yield(request)
			},
			cancel: { [self] in cancelled.append($0) }
		)
	}

	internal static func native(
		generation: UInt64,
		revision: UInt64
	) -> ArxMediaSnapshot {
		.init(
			generation: generation,
			revision: revision,
			present: true,
			video: true,
			picture: false,
			playback: 1,
			actions: UInt32(ARX_MEDIA_CAN_PAUSE | ARX_MEDIA_CAN_ENTER_PICTURE),
			title: nil,
			origin: nil,
			artist: nil,
			artwork: nil,
			artwork_size: 0,
			call: false,
			microphone: ARX_MEDIA_DEVICE_UNKNOWN,
			camera: ARX_MEDIA_DEVICE_UNKNOWN
		)
	}
}
