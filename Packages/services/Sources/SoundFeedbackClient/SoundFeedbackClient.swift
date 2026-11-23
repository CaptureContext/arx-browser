import _Dependencies

/// Arx's three interface sounds (DEV-1256). Each plays only when the result of something the person
/// did is out of sight; anything they can watch happen stays silent.
public enum SoundFeedback: String, CaseIterable, Hashable, Sendable {
	/// A page capture went to the clipboard or a file.
	case capture

	/// A download finished.
	case done

	/// A download failed, or a capture couldn't be taken or saved.
	case couldNot

	/// The bundled file's name, without its `wav` extension.
	public var resourceName: String {
		switch self {
		case .capture: "capture"
		case .done: "done"
		case .couldNot: "could-not"
		}
	}

	/// How long the bundled file plays. No other sound starts before it's over.
	public var length: Duration {
		switch self {
		case .capture: .milliseconds(307)
		case .done: .milliseconds(725)
		case .couldNot: .milliseconds(415)
		}
	}
}

/// Plays ``SoundFeedback`` as macOS interface sounds, when the person wants them and nothing
/// else is using sound.
///
/// The features that own a moment call ``play``; the client decides whether it plays. AppFeature
/// reports what Arx's pages are doing with sound through ``pagesChanged``, because only its state
/// knows which tabs play sound or are in a call.
public struct SoundFeedbackClient: Sendable {
	/// What Arx's pages are doing with sound, private windows included, as AppFeature last
	/// reported it.
	public struct PageActivity: Equatable, Sendable {
		/// A tab plays sound that isn't muted, in its page or in Picture in Picture.
		public var playsSound: Bool

		/// A tab is in a call, using the microphone or camera.
		public var usesMicrophone: Bool

		public init(
			playsSound: Bool = false,
			usesMicrophone: Bool = false
		) {
			self.playsSound = playsSound
			self.usesMicrophone = usesMicrophone
		}

		public var isQuiet: Bool { !playsSound && !usesMicrophone }
	}

	/// Plays the sound unless something keeps it silent. Returns without waiting for the sound.
	public var play: @Sendable (SoundFeedback) async -> Void

	/// AppFeature's report of its pages, each time it changes, with the report's number: one more
	/// than the report before. A report that arrives after a newer one is dropped.
	public var pagesChanged: @Sendable (PageActivity, _ report: Int) async -> Void

	public init(
		play: @escaping @Sendable (SoundFeedback) async -> Void,
		pagesChanged: @escaping @Sendable (PageActivity, _ report: Int) async -> Void
	) {
		self.play = play
		self.pagesChanged = pagesChanged
	}
}

// MARK: - Dependency

extension SoundFeedbackClient: DependencyKey {
	public static var liveValue: Self { .system }

	/// Silent, and never fails: most feature tests pass through a moment that plays a sound.
	public static var testValue: Self { .silent }

	public static var previewValue: Self { .silent }

	public static var silent: Self {
		.init(
			play: { _ in },
			pagesChanged: { _, _ in }
		)
	}
}

extension DependencyValues {
	public var soundFeedback: SoundFeedbackClient {
		get { self[SoundFeedbackClient.self] }
		set { self[SoundFeedbackClient.self] = newValue }
	}
}
