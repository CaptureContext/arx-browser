import AudioToolbox
import BrowserWorkspaceClient
import CoreAudio
import Foundation
import Sharing
import Synchronization

extension SoundFeedbackClient {
	/// The live client: Settings' switch, the Mac's microphone, the continuous clock and the
	/// system's interface sounds.
	public static var system: Self {
		.deciding(
			isEnabled: { SharedReader(.general).wrappedValue.soundsEnabled },
			isMicrophoneInUse: { SystemMicrophone.isInUse },
			clock: ContinuousClock(),
			player: { SystemSoundPlayer.shared.play($0) }
		)
	}
}

extension SoundFeedback {
	/// The bundled file, or nil when the app was built without it.
	public var resourceURL: URL? {
		Bundle.module.url(forResource: resourceName, withExtension: "wav")
	}
}

/// Plays the bundled files through the system's sound-effects path, as interface sounds: they follow
/// the alert volume, the sound-effects output device and the Mac's mute, and stay silent while
/// "Play user interface sound effects" is off. Arx has no volume of its own.
internal final class SystemSoundPlayer: Sendable {
	internal static let shared: SystemSoundPlayer = .init()

	/// System sound IDs by sound, created on first use and kept while the app runs.
	private let sounds: Mutex<[SoundFeedback: SystemSoundID]> = .init([:])

	internal func play(_ sound: SoundFeedback) {
		guard let id = soundID(for: sound) else { return }

		AudioServicesPlaySystemSoundWithCompletion(id, nil)
	}

	/// The sound's system sound ID, registered as an interface sound. Nil when its file is missing
	/// or the system refuses it.
	internal func soundID(for sound: SoundFeedback) -> SystemSoundID? {
		sounds.withLock { sounds in
			if let id = sounds[sound] { return id }
			guard let url = sound.resourceURL else { return nil }

			var id: SystemSoundID = 0
			guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr
			else { return nil }

			// On by default; set so the intent is explicit.
			var isUISound: UInt32 = 1
			AudioServicesSetProperty(
				kAudioServicesPropertyIsUISound,
				UInt32(MemoryLayout<SystemSoundID>.size),
				&id,
				UInt32(MemoryLayout<UInt32>.size),
				&isUISound
			)
			sounds[sound] = id
			return id
		}
	}
}

/// Whether any app is recording sound: from the built-in microphone, a USB or Bluetooth one, or a
/// virtual device. That covers calls in other apps and Arx's own pages alike.
///
/// It asks CoreAudio about each process, not each device: a headset is one device for both
/// directions, and it runs while it only plays music. A process CoreAudio can't answer for counts
/// as not recording.
internal enum SystemMicrophone {
	internal static var isInUse: Bool {
		audioProcesses.contains(where: isRunningInput)
	}

	/// CoreAudio's object for every process that is connected to the audio system.
	internal static var audioProcesses: [AudioObjectID] {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyProcessObjectList,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		let system = AudioObjectID(kAudioObjectSystemObject)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
		else { return [] }

		let count: Int = Int(size) / MemoryLayout<AudioObjectID>.size
		var processes: [AudioObjectID] = .init(repeating: kAudioObjectUnknown, count: count)
		guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr
		else { return [] }

		return Array(processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
	}

	/// Whether the process runs audio with at least one active input stream.
	private static func isRunningInput(_ process: AudioObjectID) -> Bool {
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioProcessPropertyIsRunningInput,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		var isRunning: UInt32 = 0
		var size = UInt32(MemoryLayout<UInt32>.size)
		guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &isRunning) == noErr
		else { return false }

		return isRunning != 0
	}
}
