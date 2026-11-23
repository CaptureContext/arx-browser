# SoundFeedbackClient

Arx's interface sounds (DEV-1256), as `@Dependency(\.soundFeedback)`. Three sounds, one family:

- **`capture`**: a page capture went to the clipboard or a file (PageCaptureFeature's Copy and Save).
- **`done`**: a download finished (DownloadsFeature's outcome watch, which runs while Arx is in the background too).
- **`couldNot`**: a download failed (not one the person cancelled), or a capture couldn't be taken or saved.

Nothing else plays a sound: a sound is for a result that's out of sight, and anything the person can watch happen stays silent.

## Behaviour

- **`play(_:)`** decides, then plays without waiting for the sound to end. A sound plays only when Settings › Appearance & Sound › Sound feedback is on (`GeneralPreferences.soundsEnabled`, read through BrowserWorkspaceClient's `.general` key at each call), no Arx tab plays sound or is in a call, private windows included, no app is recording sound (every process in CoreAudio's `kAudioHardwarePropertyProcessObjectList`, checked with `kAudioProcessPropertyIsRunningInput`, so a USB microphone counts while the built-in one is the default, and a headset that only plays music doesn't; this covers calls in other apps and Arx's own pages, and a process CoreAudio can't answer for counts as not recording), the sound before it has finished (`SoundFeedback.length`, so two never overlap), and the same sound didn't play in the last two seconds (`repeatInterval`, so five downloads finishing together make one sound). A sound kept silent leaves no trace and doesn't hold back the next one. `pagesChanged` takes each report's number, and a report that arrives after a newer one is dropped.
- **`pagesChanged(_:)`** takes AppFeature's report of its tabs (`PageActivity`: a tab plays unmuted sound, in its page or Picture in Picture; a tab is in a call), private tabs included. Only AppFeature knows this, from its own watch of the engine's media, so it reports each change.
- The decision is `deciding(isEnabled:isMicrophoneInUse:clock:player:)`, apart from the playing; `liveValue` (`system`) is that with the setting, the microphone, `ContinuousClock` and the system player, and tests drive the same decisions with a recording player and a manual clock.
- The system player registers each bundled file once with `AudioServicesCreateSystemSoundID`, sets `kAudioServicesPropertyIsUISound` on it (the default, set explicitly), and plays it with `AudioServicesPlaySystemSoundWithCompletion` (the header marks `AudioServicesPlaySystemSound` for deprecation in its favour). So the sounds follow the Mac's alert volume, sound-effects output device and mute, and stay silent while System Settings › Sound › "Play user interface sound effects" is off. Arx has no volume of its own.

`testValue` and `previewValue` are silent and never fail, because many feature tests pass through a moment that plays a sound.

## Resources

`Resources/capture.wav`, `done.wav` and `could-not.wav` (48 kHz, 16-bit, mono) are synthesised by `Scripts/make_sounds.py`, which writes them here by default and reproduces them byte for byte. Nothing is recorded or sampled, so there is no third-party material. To change a sound, edit the script, run `python3 Scripts/make_sounds.py`, and update `SoundFeedback.length` if its length changed; `SoundFeedbackTests` checks the lengths against the files. Xcode copies the package's resource bundle (`arx-services_SoundFeedbackClient.bundle`) into the app's `Contents/Resources`.
