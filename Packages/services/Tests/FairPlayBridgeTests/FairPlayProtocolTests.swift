import CustomDump
import FairPlayProtocol
import Foundation
import Testing

/// DEV-1144: the wire shape every side reads, and what it refuses.
internal struct FairPlayProtocolTests {
	private static let certificate: Data = Data([1, 2, 3, 4])
	private static let playlist: String = """
	#EXTM3U
	#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://track",KEYFORMATVERSIONS="1",KEYFORMAT="com.apple.streamingkeydelivery"
	#EXT-X-MAP:URI="https://audio.example/file",BYTERANGE="100@0"
	#EXTINF:10,
	#EXT-X-BYTERANGE:200@100
	https://audio.example/file
	#EXT-X-ENDLIST
	"""

	@Test
	internal func aPagesFirstPartCarriesItsCertificate() async throws {
		let text = ##"{"op":"load","generation":3,"part":0,"parts":2,"playlist":"#EXTM3U","certificate":"AQIDBA==","volume":0.5,"muted":true}"##
		expectNoDifference(
			FairPlayPageMessage(decoding: text),
			.load(generation: 3, part: 0, parts: 2, playlist: "#EXTM3U", certificate: Self.certificate, volume: 0.5, isMuted: true)
		)

		// Without its certificate, the first part is nothing the app can play.
		#expect(FairPlayPageMessage(decoding: ##"{"op":"load","generation":3,"part":0,"parts":2,"playlist":"#EXTM3U"}"##) == nil)
		// A later part needs none.
		expectNoDifference(
			FairPlayPageMessage(decoding: #"{"op":"load","generation":3,"part":1,"parts":2,"playlist":"x"}"#),
			.load(generation: 3, part: 1, parts: 2, playlist: "x", certificate: nil, volume: 1, isMuted: false)
		)
	}

	@Test
	internal func aPagesTraceIsOneOfItsKnownSteps() async throws {
		expectNoDifference(FairPlayPageMessage(decoding: #"{"op":"trace","trace":"playlist-not-keyed"}"#), .trace(.playlistNotKeyed))

		// Anything else, such as a URL, never reaches the log.
		#expect(FairPlayPageMessage(decoding: #"{"op":"trace","trace":"https://example.com/"}"#) == nil)
		#expect(FairPlayPageMessage(decoding: #"{"op":"trace"}"#) == nil)
	}

	@Test
	internal func malformedOrOutOfRangeMessagesReadAsNothing() async throws {
		let refused = [
			"not json",
			#"{"op":"unknown"}"#,
			#"{"op":"license","generation":0,"ckc":"AQ=="}"#,
			#"{"op":"license","generation":1,"ckc":"not base64"}"#,
			#"{"op":"load","generation":1,"part":2,"parts":2,"playlist":"x"}"#,
			#"{"op":"load","generation":1,"part":0,"parts":41,"playlist":"x","certificate":"AQ=="}"#,
			#"{"op":"seek","time":-1,"sequence":1}"#,
			#"{"op":"seek","time":3,"sequence":-1}"#,
		]
		for text in refused {
			#expect(FairPlayPageMessage(decoding: text) == nil, "\(text)")
		}
		let long = String(repeating: "a", count: FairPlayLimits.maximumPlaylistPartLength + 1)
		#expect(FairPlayPageMessage(decoding: #"{"op":"load","generation":1,"part":1,"parts":2,"playlist":"\#(long)"}"#) == nil)
	}

	@Test
	internal func volumeIsClampedAndMetadataBounded() async throws {
		expectNoDifference(FairPlayPageMessage(decoding: #"{"op":"volume","volume":3}"#), .volume(1))
		let title = String(repeating: "t", count: FairPlayLimits.maximumTextLength + 5)
		let message = FairPlayPageMessage(decoding: #"{"op":"metadata","title":"\#(title)","artwork":"http://insecure.example/a.png"}"#)
		guard case let .metadata(metadata) = message else {
			Issue.record("No metadata")
			return
		}
		#expect(metadata.title.count == FairPlayLimits.maximumTextLength)
		#expect(metadata.artwork == nil)
	}

	@Test
	internal func helperCommandsAndEventsRoundTrip() async throws {
		let commands: [FairPlayHelperCommand] = [
			.load(generation: 2, certificate: Self.certificate, playlist: Self.playlist, volume: 0.25, isMuted: false),
			.license(generation: 2, ckc: Data([9])),
			.play,
			.pause,
			.seek(time: 12.5, sequence: 3),
			.volume(0.5),
			.muted(true),
			.metadata(.init(title: "Song", artist: "Artist", album: "Album", artwork: URL(string: "https://images.example/a.jpg"))),
			.stop,
		]
		for command in commands {
			expectNoDifference(FairPlayHelperCommand(decoding: command.encoded), command)
		}
		let events: [FairPlayHelperEvent] = [
			.request(generation: 2, spc: Data([7, 8])),
			.ready(generation: 2, duration: 180),
			.position(generation: 2, time: 4, isPlaying: true, sequence: 1),
			.ended(generation: 2),
			.failed(generation: 2, step: .license),
			.remote(.nextTrack, time: nil),
			.remote(.seek, time: 30),
		]
		for event in events {
			expectNoDifference(FairPlayHelperEvent(decoding: event.encoded), event)
		}
	}

	@Test
	internal func theHelperRefusesAPlaylistItMustNotPlay() async throws {
		let local = Self.playlist.replacingOccurrences(of: "https://audio.example/file\n", with: "file:///etc/passwd\n")
		let command = FairPlayHelperCommand.load(generation: 1, certificate: Self.certificate, playlist: local, volume: 1, isMuted: false)
		#expect(FairPlayHelperCommand(decoding: command.encoded) == nil)
	}

	@Test
	internal func playlistsNeedHTTPSResourcesAndAFairPlayKey() async throws {
		#expect(FairPlayPlaylist.isAcceptable(Self.playlist))
		#expect(FairPlayPlaylist.hasFairPlayKey(Self.playlist))
		#expect(!FairPlayPlaylist.isAcceptable("not a playlist"))
		#expect(!FairPlayPlaylist.isAcceptable(Self.playlist.replacingOccurrences(of: "https://audio", with: "http://audio")))
		#expect(!FairPlayPlaylist.isAcceptable(Self.playlist.replacingOccurrences(of: "skd://track", with: "data:,key")))
		let clear = Self.playlist.replacingOccurrences(of: "skd://track", with: "https://keys.example/key")
		#expect(FairPlayPlaylist.isAcceptable(clear))
		#expect(!FairPlayPlaylist.hasFairPlayKey(clear))
	}

	@Test
	internal func linesSplitOnNewlinesAndRefuseTooLongOnes() async throws {
		var buffer = FairPlayLineBuffer()
		expectNoDifference(try buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)), [Data("{\"a\":1}".utf8)])
		expectNoDifference(try buffer.append(Data(":2}\n".utf8)), [Data("{\"b\":2}".utf8)])
		var long = FairPlayLineBuffer()
		#expect(throws: FairPlayLineBuffer.Failure.lineTooLong) {
			try long.append(Data(count: FairPlayLimits.maximumLineBytes + 1))
		}
	}

	@Test
	internal func pageEventsAreTheScriptsShape() async throws {
		let text = FairPlayPageEvent.position(generation: 4, time: 1.5, isPlaying: true, sequence: 2).text
		let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
		#expect(object["event"] as? String == "position")
		#expect(object["generation"] as? Int == 4)
		#expect(object["playing"] as? Bool == true)
		#expect(object["sequence"] as? Int == 2)
		let stolen = try #require(try JSONSerialization.jsonObject(with: Data(FairPlayPageEvent.stolen(generation: 4).text.utf8)) as? [String: Any])
		#expect(stolen["event"] as? String == "stolen")
	}
}
