import BrowserCore
import CustomDump
import FairPlayBridge
import FairPlayProtocol
import Foundation
import Testing

/// DEV-1144: one tab's document owns the helper; its events reach that document with the page's
/// generation; a failure is reported once so the app can fall back to WebKit.
@MainActor
internal struct FairPlayBridgeTests {
	private static let playlist: String = """
	#EXTM3U
	#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://track",KEYFORMATVERSIONS="1",KEYFORMAT="com.apple.streamingkeydelivery"
	#EXTINF:10,
	https://audio.example/file
	#EXT-X-ENDLIST
	"""

	/// A helper and pages that record what they're told.
	@MainActor
	private final class Recorder {
		var started: Int = 0
		var startSucceeds: Bool = true
		var commands: [FairPlayHelperCommand] = []
		var stopped: Int = 0
		var events: (@MainActor (FairPlayHelperEvent) -> Void)?
		var exited: (@MainActor () -> Void)?
		var delivered: [(Tab.ID, UInt64, FairPlayPageEvent)] = []
		var goneDocuments: Set<UInt64> = []
		var failures: [(Tab.ID, FairPlayStep)] = []

		var connection: FairPlayHelperConnection {
			FairPlayHelperConnection(
				start: { [unowned self] events, exited in
					started += 1
					self.events = events
					self.exited = exited
					return startSucceeds
				},
				send: { [unowned self] in commands.append($0) },
				stop: { [unowned self] in stopped += 1 }
			)
		}

		func page(
			_ tab: Tab.ID,
			_ document: UInt64,
			_ text: String
		) -> Bool {
			guard !goneDocuments.contains(document) else { return false }
			delivered.append((tab, document, Self.event(text)))
			return true
		}

		/// The page event `text` encodes, read back through the helper's decoder shape.
		static func event(_ text: String) -> FairPlayPageEvent {
			let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
			let generation = object["generation"] as? Int ?? 0
			switch object["event"] as? String {
			case "request":
				return .request(generation: generation, spc: Data(base64Encoded: object["spc"] as? String ?? "") ?? Data())
			case "ready":
				return .ready(generation: generation, duration: object["duration"] as? Double ?? 0)
			case "position":
				return .position(
					generation: generation,
					time: object["time"] as? Double ?? 0,
					isPlaying: object["playing"] as? Bool ?? false,
					sequence: object["sequence"] as? Int ?? 0
				)
			case "ended":
				return .ended(generation: generation)
			case "failed":
				return .failed(generation: generation, step: FairPlayStep(rawValue: object["step"] as? String ?? "") ?? .playback)
			case "stolen":
				return .stolen(generation: generation)
			default:
				return .remote(FairPlayRemoteCommand(rawValue: object["command"] as? String ?? "") ?? .play, time: object["time"] as? Double)
			}
		}
	}

	private static func load(
		_ generation: Int,
		playlist: String = Self.playlist
	) -> String {
		let escaped = playlist.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
			.replacingOccurrences(of: "\n", with: "\\n")
		return #"{"op":"load","generation":\#(generation),"part":0,"parts":1,"playlist":"\#(escaped)","certificate":"AQIDBA==","volume":0.5,"muted":false}"#
	}

	private func bridge(_ recorder: Recorder) -> FairPlayBridge {
		let bridge = FairPlayBridge(helper: recorder.connection) { tab, document, text in
			recorder.page(tab, document, text)
		}
		bridge.onFailure = { tab, step in recorder.failures.append((tab, step)) }
		return bridge
	}

	@Test
	internal func everyStepTheScriptTracesIsOneTheAppKnows() async throws {
		let script = try #require(FairPlayBridgeScript.source)
		let pattern = try Regex(#"trace\("([a-z-]+)"\)"#)
		let traced = Set(script.matches(of: pattern).compactMap { $0.output[1].substring.map(String.init) })
		#expect(!traced.isEmpty)
		expectNoDifference(traced.filter { FairPlayTrace(rawValue: $0) == nil }, [])

		// The few the script derives at runtime are known too.
		#expect(FairPlayTrace(rawValue: "source-media-source") != nil)
		#expect(FairPlayTrace(rawValue: "source-other") != nil)
	}

	@Test
	internal func aTraceOnlyReachesTheLog() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 7, text: #"{"op":"trace","trace":"playlist-not-keyed"}"#))
		#expect(recorder.started == 0)
		expectNoDifference(recorder.commands, [])
		#expect(recorder.failures.isEmpty)
		#expect(bridge.track == nil)
	}

	@Test
	internal func aLoadedTrackGoesToTheHelperAndItsKeyRequestBackToThePage() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 7, text: Self.load(3)))
		#expect(recorder.started == 1)
		expectNoDifference(
			recorder.commands,
			[.load(generation: 1, certificate: Data([1, 2, 3, 4]), playlist: Self.playlist, volume: 0.5, isMuted: false)]
		)

		recorder.events?(.request(generation: 1, spc: Data([5])))
		expectNoDifference(recorder.delivered.map(\.2), [.request(generation: 3, spc: Data([5]))])
		#expect(recorder.delivered.first?.0 == tab)
		#expect(recorder.delivered.first?.1 == 7)

		bridge.receive(.init(tabID: tab, document: 7, text: #"{"op":"license","generation":3,"ckc":"CQ=="}"#))
		bridge.receive(.init(tabID: tab, document: 7, text: #"{"op":"play"}"#))
		expectNoDifference(Array(recorder.commands.dropFirst()), [.license(generation: 1, ckc: Data([9])), .play])
	}

	@Test
	internal func aPlaylistInPartsIsJoinedInOrder() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())
		let middle = Self.playlist.index(Self.playlist.startIndex, offsetBy: 20)
		let first = String(Self.playlist[..<middle]).replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
		let second = String(Self.playlist[middle...]).replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")

		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"load","generation":1,"part":0,"parts":2,"playlist":"\#(first)","certificate":"AQ=="}"#))
		#expect(recorder.commands.isEmpty)
		// A part from another document is no part of this track.
		bridge.receive(.init(tabID: tab, document: 2, text: #"{"op":"load","generation":1,"part":1,"parts":2,"playlist":"\#(second)"}"#))
		#expect(recorder.commands.isEmpty)
		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"load","generation":1,"part":1,"parts":2,"playlist":"\#(second)"}"#))
		expectNoDifference(
			recorder.commands,
			[.load(generation: 1, certificate: Data([1]), playlist: Self.playlist, volume: 1, isMuted: false)]
		)
	}

	@Test
	internal func anotherTabTakesThePlayerAndTheFirstIsTold() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let first = Tab.ID(rawValue: UUID())
		let second = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: first, document: 1, text: Self.load(4)))
		bridge.receive(.init(tabID: second, document: 2, text: Self.load(9)))
		#expect(recorder.delivered.count == 1)
		#expect(recorder.delivered.first?.0 == first)
		expectNoDifference(recorder.delivered.first?.2, .stolen(generation: 4))

		// The first tab's controls no longer reach the helper; its old track's events are dropped.
		recorder.commands = []
		bridge.receive(.init(tabID: first, document: 1, text: #"{"op":"play"}"#))
		recorder.events?(.ready(generation: 1, duration: 10))
		#expect(recorder.commands.isEmpty)
		#expect(recorder.delivered.count == 1)

		recorder.events?(.ready(generation: 2, duration: 10))
		expectNoDifference(recorder.delivered.last?.2, .ready(generation: 9, duration: 10))
	}

	@Test
	internal func aFailedTrackIsReportedOnceAndStops() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(2)))
		recorder.events?(.failed(generation: 1, step: .license))
		recorder.events?(.failed(generation: 1, step: .license))
		#expect(recorder.failures.count == 1)
		#expect(recorder.failures.first?.1 == .license)
		expectNoDifference(recorder.delivered.map(\.2), [.failed(generation: 2, step: .license)])
		#expect(recorder.commands.last == .stop)
	}

	@Test
	internal func aHelperThatCantStartOrDiesFailsThePlayer() async throws {
		let recorder = Recorder()
		recorder.startSucceeds = false
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(5)))
		#expect(recorder.failures.first?.1 == .player)
		expectNoDifference(recorder.delivered.map(\.2), [.failed(generation: 5, step: .player)])

		recorder.startSucceeds = true
		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(6)))
		recorder.exited?()
		#expect(recorder.failures.count == 2)
		expectNoDifference(recorder.delivered.last?.2, .failed(generation: 6, step: .player))
	}

	@Test
	internal func aPlaylistTheHelperMustNotPlayFailsWithoutReachingIt() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())
		let local = Self.playlist.replacingOccurrences(of: "https://audio.example/file", with: "file:///etc/hosts")

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1, playlist: local)))
		#expect(recorder.started == 0)
		#expect(recorder.commands.isEmpty)
		#expect(recorder.failures.first?.1 == .playback)
	}

	@Test
	internal func theTabsMuteWinsOverThePages() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.setMuted(true, tab: tab)
		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1)))
		expectNoDifference(
			recorder.commands.first,
			.load(generation: 1, certificate: Data([1, 2, 3, 4]), playlist: Self.playlist, volume: 0.5, isMuted: true)
		)
		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"muted","muted":false}"#))
		#expect(recorder.commands.last == .muted(true))
		bridge.setMuted(false, tab: tab)
		#expect(recorder.commands.last == .muted(false))
	}

	@Test
	internal func aGoneDocumentOrClosedTabStopsTheTrack() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())
		var playing: [Bool] = []
		bridge.onPlayingChange = { _, isPlaying in playing.append(isPlaying) }

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1)))
		recorder.events?(.position(generation: 1, time: 1, isPlaying: true, sequence: 0))
		#expect(bridge.playingTab == tab)
		recorder.goneDocuments.insert(1)
		recorder.events?(.position(generation: 1, time: 2, isPlaying: true, sequence: 0))
		#expect(bridge.playingTab == nil)
		#expect(recorder.commands.last == .stop)
		expectNoDifference(playing, [true, false])

		recorder.goneDocuments = []
		bridge.receive(.init(tabID: tab, document: 3, text: Self.load(2)))
		recorder.commands = []
		bridge.pageGone(tab)
		expectNoDifference(recorder.commands, [.stop])
		#expect(recorder.failures.isEmpty)
	}

	@Test
	internal func thePagesOwnGiveUpIsAFailure() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1)))
		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"failed"}"#))
		#expect(recorder.failures.first?.1 == .playback)
		// The page knows; it isn't told again.
		#expect(recorder.delivered.isEmpty)
	}

	@Test
	internal func theTabsVolumeScalesThePages() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.setVolume(0.5, tab: tab)
		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1)))
		expectNoDifference(
			recorder.commands.first,
			.load(generation: 1, certificate: Data([1, 2, 3, 4]), playlist: Self.playlist, volume: 0.25, isMuted: false)
		)
		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"volume","volume":0.8}"#))
		#expect(recorder.commands.last == .volume(0.4))
		bridge.setVolume(1, tab: tab)
		#expect(recorder.commands.last == .volume(0.8))
	}

	@Test
	internal func aPlayingTabSaysSo() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1)))
		#expect(!bridge.isPlaying(tab))
		recorder.events?(.position(generation: 1, time: 1, isPlaying: true, sequence: 0))
		#expect(bridge.isPlaying(tab))
		recorder.events?(.position(generation: 1, time: 2, isPlaying: false, sequence: 0))
		#expect(!bridge.isPlaying(tab))
	}

	/// DEV-1151: the app holds a freeze lease for exactly the document whose track the helper
	/// holds, paused too, so Now Playing's commands still reach a running page.
	@Test
	internal func theDocumentHoldingTheTrackIsReportedWhilePausedToo() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let first = Tab.ID(rawValue: UUID())
		let second = Tab.ID(rawValue: UUID())
		var changes: [HolderChange] = []
		bridge.onHolderChange = { tab, document, holds in
			changes.append(.init(tab: tab, document: document, holds: holds))
		}

		bridge.receive(.init(tabID: first, document: 1, text: Self.load(1)))
		recorder.events?(.position(generation: 1, time: 1, isPlaying: true, sequence: 0))
		recorder.events?(.position(generation: 1, time: 2, isPlaying: false, sequence: 0))

		// Paused, the first still holds it; another tab then takes the player.
		expectNoDifference(changes, [.init(tab: first, document: 1, holds: true)])
		bridge.receive(.init(tabID: second, document: 2, text: Self.load(1)))

		// The same document's next track keeps the hold.
		bridge.receive(.init(tabID: second, document: 2, text: Self.load(2)))
		bridge.receive(.init(tabID: second, document: 2, text: #"{"op":"stop"}"#))

		expectNoDifference(changes, [
			.init(tab: first, document: 1, holds: true),
			.init(tab: first, document: 1, holds: false),
			.init(tab: second, document: 2, holds: true),
			.init(tab: second, document: 2, holds: false),
		])
	}

	/// Codex: a track that's loading or buffering after the page asked it to play keeps its tab
	/// loaded; a paused one doesn't.
	@Test
	internal func aTrackAskedToPlayCountsAsPlayingWhileItBuffers() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1)))
		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"play"}"#))
		#expect(bridge.isPlaying(tab))
		recorder.events?(.position(generation: 1, time: 0, isPlaying: false, sequence: 0))
		#expect(bridge.isPlaying(tab))
		#expect(bridge.playingTab == nil)
		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"pause"}"#))
		#expect(!bridge.isPlaying(tab))
	}

	/// Codex: a helper failure for a document that went without a word doesn't move the tab, which
	/// may show another document by now.
	@Test
	internal func aFailureForAGoneDocumentDoesntFallBack() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1)))
		recorder.goneDocuments.insert(1)
		recorder.events?(.failed(generation: 1, step: .license))
		#expect(recorder.failures.isEmpty)
		#expect(recorder.commands.last == .stop)
	}

	/// Codex: Now Playing never names a private window's track.
	@Test
	internal func aPrivateTabsTrackIsNamedOnlyAsArx() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())
		let metadata = #"{"op":"metadata","title":"Song","artist":"Band","album":"Record","artwork":"https://example.com/a.jpg"}"#

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1), isPrivate: true))
		bridge.receive(.init(tabID: tab, document: 1, text: metadata, isPrivate: true))
		#expect(recorder.commands.last == .metadata(.privateTrack))
		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(2)))
		bridge.receive(.init(tabID: tab, document: 1, text: metadata))
		#expect(recorder.commands.last == .metadata(.init(title: "Song", artist: "Band", album: "Record", artwork: URL(string: "https://example.com/a.jpg"))))
	}

	/// Codex: a replacement track the page doesn't play leaves its tab unloadable again.
	@Test
	internal func aReplacementTrackStartsWithoutPlayIntent() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1)))
		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"play"}"#))
		#expect(bridge.isPlaying(tab))
		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(2)))
		#expect(!bridge.isPlaying(tab))
	}

	private struct HolderChange: Equatable {
		var tab: Tab.ID
		var document: UInt64
		var holds: Bool
	}

	@Test
	internal func aGiveUpFromAPageTheAppNeverTookStillFallsBack() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"failed"}"#))
		#expect(recorder.failures.first?.0 == tab)
		#expect(recorder.failures.first?.1 == .playback)
		#expect(recorder.started == 0)
	}

	// MARK: - The app's speaker and Media page (DEV-1147)

	@Test
	internal func theHeldTrackIsPublishedWithItsNameAndPlayback() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		var tracks: [FairPlayBridge.Track?] = []
		bridge.onTrackChange = { tracks.append($0) }
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1)))
		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"metadata","title":"Song","artist":"Band","album":"","artwork":""}"#))
		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"play"}"#))
		recorder.events?(.position(generation: 1, time: 1, isPlaying: true, sequence: 0))
		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"pause"}"#))
		recorder.events?(.position(generation: 1, time: 2, isPlaying: false, sequence: 0))
		let named = FairPlayMetadata(title: "Song", artist: "Band")
		expectNoDifference(tracks, [
			.init(tabID: tab, number: 1),
			.init(tabID: tab, number: 1, metadata: named),
			.init(tabID: tab, number: 1, metadata: named, isPlaying: true),
			.init(tabID: tab, number: 1, metadata: named, isPlaying: false),
		])

		// The next track starts unnamed and paused; a closed tab holds none.
		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(2)))
		expectNoDifference(bridge.track, .init(tabID: tab, number: 2))
		bridge.pageGone(tab)
		#expect(bridge.track == nil)
		#expect(tracks.last == .some(nil))
	}

	@Test
	internal func aPrivateTabsPublishedTrackIsNamedOnlyAsArx() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())

		bridge.receive(.init(tabID: tab, document: 1, text: Self.load(1), isPrivate: true))
		bridge.receive(.init(tabID: tab, document: 1, text: #"{"op":"metadata","title":"Song","artist":"Band","album":"","artwork":""}"#, isPrivate: true))
		expectNoDifference(bridge.track?.metadata, .privateTrack)
	}

	@Test
	internal func theAppsControlsReachThePagesOwnPlayer() async throws {
		let recorder = Recorder()
		let bridge = bridge(recorder)
		let tab = Tab.ID(rawValue: UUID())
		let other = Tab.ID(rawValue: UUID())

		#expect(!bridge.control(.play, tab: tab))
		bridge.receive(.init(tabID: tab, document: 4, text: Self.load(1)))
		#expect(bridge.control(.play, tab: tab))
		#expect(bridge.control(.pause, tab: tab))
		#expect(bridge.control(.nextTrack, tab: tab))
		#expect(bridge.control(.previousTrack, tab: tab))
		#expect(!bridge.control(.seek, tab: tab))
		#expect(!bridge.control(.play, tab: other))
		expectNoDifference(recorder.delivered.map(\.2), [
			.remote(.play, time: nil),
			.remote(.pause, time: nil),
			.remote(.nextTrack, time: nil),
			.remote(.previousTrack, time: nil),
		])
		#expect(recorder.delivered.allSatisfy { $0.0 == tab && $0.1 == 4 })
		// The page's own player decides: the helper hears nothing until the page tells it.
		expectNoDifference(recorder.commands.count, 1)

		// A document that's gone takes nothing, and its track stops.
		recorder.goneDocuments.insert(4)
		#expect(!bridge.control(.play, tab: tab))
		#expect(bridge.track == nil)
	}
}
