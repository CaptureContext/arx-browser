import AudioToolbox
import Foundation
@testable import SoundFeedbackClient
import Synchronization
import Testing
import _TestSupport

@Suite
internal struct SoundFeedbackTests {
	/// The sounds the player was asked to make, in order.
	private final class Recorder: Sendable {
		private let sounds: Mutex<[SoundFeedback]> = .init([])

		internal var played: [SoundFeedback] { sounds.withLock { $0 } }

		internal func record(_ sound: SoundFeedback) {
			sounds.withLock { $0.append(sound) }
		}
	}

	private struct Fixture {
		let client: SoundFeedbackClient
		let recorder: Recorder
		let clock: ManualClock
	}

	private func fixture(
		isEnabled: Bool = true,
		isMicrophoneInUse: Bool = false
	) -> Fixture {
		let recorder = Recorder()
		let clock = ManualClock()
		let client = SoundFeedbackClient.deciding(
			isEnabled: { isEnabled },
			isMicrophoneInUse: { isMicrophoneInUse },
			clock: clock,
			player: { recorder.record($0) }
		)
		return .init(client: client, recorder: recorder, clock: clock)
	}

	@Test
	internal func everySoundPlaysWhenNothingKeepsItSilent() async throws {
		for sound in SoundFeedback.allCases {
			let fixture = fixture()
			await fixture.client.play(sound)
			#expect(fixture.recorder.played == [sound])
		}
	}

	@Test
	internal func theSettingOffSilencesEverySound() async throws {
		let fixture = fixture(isEnabled: false)
		for sound in SoundFeedback.allCases {
			await fixture.client.play(sound)
			fixture.clock.advance(by: .seconds(3))
		}
		#expect(fixture.recorder.played.isEmpty)
	}

	@Test(arguments: [
		SoundFeedbackClient.PageActivity(playsSound: true),
		SoundFeedbackClient.PageActivity(usesMicrophone: true),
	])
	internal func aTabPlayingSoundOrInACallSilencesEverySound(
		_ activity: SoundFeedbackClient.PageActivity
	) async throws {
		let fixture = fixture()
		await fixture.client.pagesChanged(activity, 1)
		for sound in SoundFeedback.allCases {
			await fixture.client.play(sound)
			fixture.clock.advance(by: .seconds(3))
		}
		#expect(fixture.recorder.played.isEmpty)

		await fixture.client.pagesChanged(.init(), 2)
		await fixture.client.play(.done)
		#expect(fixture.recorder.played == [.done])
	}

	/// Reports are sent from separate effects, so an older one can arrive last.
	@Test
	internal func aReportThatArrivesAfterANewerOneIsDropped() async throws {
		let fixture = fixture()
		await fixture.client.pagesChanged(.init(), 2)
		await fixture.client.pagesChanged(.init(playsSound: true), 1)
		await fixture.client.play(.done)
		#expect(fixture.recorder.played == [.done])
	}

	@Test
	internal func theMacsMicrophoneInUseSilencesEverySound() async throws {
		let fixture = fixture(isMicrophoneInUse: true)
		for sound in SoundFeedback.allCases {
			await fixture.client.play(sound)
			fixture.clock.advance(by: .seconds(3))
		}
		#expect(fixture.recorder.played.isEmpty)
	}

	@Test
	internal func theSameSoundPlaysOnceInTwoSecondsThenAgain() async throws {
		let fixture = fixture()

		// Five downloads finishing together.
		for _ in 0..<5 { await fixture.client.play(.done) }
		fixture.clock.advance(by: .milliseconds(1_999))
		await fixture.client.play(.done)
		#expect(fixture.recorder.played == [.done])

		fixture.clock.advance(by: .milliseconds(1))
		await fixture.client.play(.done)
		#expect(fixture.recorder.played == [.done, .done])
	}

	@Test
	internal func aSoundDoesNotStartWhileAnotherPlays() async throws {
		let fixture = fixture()
		await fixture.client.play(.done)
		fixture.clock.advance(by: SoundFeedback.done.length - .milliseconds(1))
		await fixture.client.play(.couldNot)
		#expect(fixture.recorder.played == [.done])

		fixture.clock.advance(by: .milliseconds(1))
		await fixture.client.play(.couldNot)
		#expect(fixture.recorder.played == [.done, .couldNot])
	}

	@Test
	internal func aSilencedSoundDoesNotHoldBackTheNext() async throws {
		let fixture = fixture()
		await fixture.client.pagesChanged(.init(playsSound: true), 1)
		await fixture.client.play(.capture)
		await fixture.client.pagesChanged(.init(), 2)
		await fixture.client.play(.capture)
		#expect(fixture.recorder.played == [.capture])
	}

	@Test
	internal func theTestAndPreviewClientsAreSilent() async throws {
		for client in [SoundFeedbackClient.testValue, .previewValue] {
			for sound in SoundFeedback.allCases { await client.play(sound) }
			await client.pagesChanged(.init(playsSound: true), 1)
		}
	}

	/// The live check asks CoreAudio about every process using audio. Whether one is recording
	/// depends on the Mac, so this only checks that the calls return.
	@Test
	internal func readingTheMacsRecordingProcessesReturns() async throws {
		let processes = SystemMicrophone.audioProcesses
		#expect(Set(processes).count == processes.count)
		_ = SystemMicrophone.isInUse
	}

	/// The app plays what the package bundles: every sound's file is there, is as long as
	/// ``SoundFeedback/length`` says, and the system accepts it as an interface sound.
	@Test
	internal func everySoundIsBundledAndTheSystemAcceptsIt() async throws {
		for sound in SoundFeedback.allCases {
			let url = try #require(sound.resourceURL, "\(sound.resourceName).wav isn't bundled")
			let file = try audioFileLength(url: url)
			let difference: Duration = file > sound.length ? file - sound.length : sound.length - file
			#expect(difference < .milliseconds(1), "\(sound): \(file)")

			let id = try #require(SystemSoundPlayer.shared.soundID(for: sound))
			var isUISound: UInt32 = 0
			var size = UInt32(MemoryLayout<UInt32>.size)
			var specifier: SystemSoundID = id
			let status: OSStatus = AudioServicesGetProperty(
				kAudioServicesPropertyIsUISound,
				UInt32(MemoryLayout<SystemSoundID>.size),
				&specifier,
				&size,
				&isUISound
			)
			#expect(status == noErr)
			#expect(isUISound == 1)
		}
	}
}

/// A clock that moves only when told, at once. `TestClock` yields to every task on each advance,
/// which takes minutes on a busy Mac, and these decisions never sleep.
private final class ManualClock: Clock, Sendable {
	internal typealias Instant = ContinuousClock.Instant

	private let origin: ContinuousClock.Instant = .now
	private let elapsed: Mutex<Duration> = .init(.zero)

	internal var now: Instant { origin.advanced(by: elapsed.withLock { $0 }) }

	internal var minimumResolution: Duration { .zero }

	internal func advance(by duration: Duration) {
		elapsed.withLock { $0 += duration }
	}

	internal func sleep(
		until deadline: Instant,
		tolerance: Duration?
	) async throws {
		Issue.record("Sound feedback's decisions never sleep")
	}
}

/// A WAV file's length, from its frame count and sample rate.
private func audioFileLength(url: URL) throws -> Duration {
	var file: AudioFileID?
	try #require(AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr)
	let audioFile = try #require(file)
	defer { AudioFileClose(audioFile) }

	var format = AudioStreamBasicDescription()
	var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
	try #require(AudioFileGetProperty(audioFile, kAudioFilePropertyDataFormat, &formatSize, &format) == noErr)

	var packets: UInt64 = 0
	var packetsSize = UInt32(MemoryLayout<UInt64>.size)
	try #require(
		AudioFileGetProperty(audioFile, kAudioFilePropertyAudioDataPacketCount, &packetsSize, &packets) == noErr
	)
	return .seconds(Double(packets) / format.mSampleRate)
}
