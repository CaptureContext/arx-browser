import Synchronization

extension SoundFeedbackClient {
	/// The same sound never plays twice this close together, so five downloads finishing
	/// together make one sound.
	public static let repeatInterval: Duration = .seconds(2)

	/// A client that decides with these pieces and plays through `player`. The live client is one,
	/// with the system's pieces; a test drives the same decisions with its own.
	///
	/// A sound plays only when all of these hold, checked in this order:
	/// - the person turned Sound feedback on (`isEnabled`);
	/// - no Arx tab plays sound or is in a call, as ``pagesChanged`` last reported;
	/// - no app is using the Mac's microphone (`isMicrophoneInUse`);
	/// - the sound before it has finished (``SoundFeedback/length``), so two never overlap;
	/// - the same sound didn't play in the last ``repeatInterval``.
	///
	/// A sound kept silent leaves no trace: it doesn't hold back a later one.
	///
	/// - Parameters:
	///   - isEnabled: Whether Settings › Appearance & Sound › Sound feedback is on.
	///   - isMicrophoneInUse: Whether any app, Arx included, is recording sound, from any
	///     microphone.
	///   - clock: Measures the gaps between sounds.
	///   - player: Makes the sound. It must return without waiting for the sound to end.
	public static func deciding<C: Clock>(
		isEnabled: @escaping @Sendable () -> Bool,
		isMicrophoneInUse: @escaping @Sendable () -> Bool,
		clock: C,
		player: @escaping @Sendable (SoundFeedback) -> Void
	) -> Self where C.Duration == Duration {
		let gate = SoundFeedbackGate(
			isEnabled: isEnabled,
			isMicrophoneInUse: isMicrophoneInUse,
			clock: clock
		)
		return .init(
			play: { sound in
				guard gate.admits(sound) else { return }

				player(sound)
			},
			pagesChanged: { activity, report in
				gate.pagesChanged(activity, report: report)
			}
		)
	}
}

/// The decision whether a sound plays, apart from playing it.
internal final class SoundFeedbackGate<C: Clock>: Sendable where C.Duration == Duration {
	private struct Record: Sendable {
		var pages: SoundFeedbackClient.PageActivity

		/// The number of the report `pages` came from.
		var report: Int

		/// When the sound playing now, or the last one, ends.
		var busyUntil: C.Instant?
		var lastPlayed: [SoundFeedback: C.Instant]
	}

	private let isEnabled: @Sendable () -> Bool
	private let isMicrophoneInUse: @Sendable () -> Bool
	private let clock: C
	private let record: Mutex<Record>

	internal init(
		isEnabled: @escaping @Sendable () -> Bool,
		isMicrophoneInUse: @escaping @Sendable () -> Bool,
		clock: C
	) {
		self.isEnabled = isEnabled
		self.isMicrophoneInUse = isMicrophoneInUse
		self.clock = clock
		self.record = .init(.init(pages: .init(), report: 0, busyUntil: nil, lastPlayed: [:]))
	}

	/// Keeps the report unless a newer one already arrived.
	internal func pagesChanged(_ activity: SoundFeedbackClient.PageActivity, report: Int) {
		record.withLock { record in
			guard report > record.report else { return }

			record.report = report
			record.pages = activity
		}
	}

	/// Whether `sound` may play now. A yes counts as played.
	internal func admits(_ sound: SoundFeedback) -> Bool {
		guard isEnabled(), record.withLock({ $0.pages.isQuiet }), !isMicrophoneInUse()
		else { return false }

		let now: C.Instant = clock.now
		return record.withLock { record in
			if let busyUntil = record.busyUntil, now < busyUntil { return false }
			if let last = record.lastPlayed[sound], last.duration(to: now) < SoundFeedbackClient.repeatInterval {
				return false
			}

			record.busyUntil = now.advanced(by: sound.length)
			record.lastPlayed[sound] = now
			return true
		}
	}
}
