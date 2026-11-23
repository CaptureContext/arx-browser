import BrowserCore
import SoundFeedbackClient
import _ComposableArchitecture

/// Tabs playing sound or in a call, private ones included (DEV-1256).
///
/// The Media page and the sidebars read MediaFeature's snapshot, which leaves private sources out.
/// Sound feedback must hear a private window too, so the app reads each snapshot as the engine
/// sends it, before MediaFeature filters it, and keeps only these tab IDs, which nothing renders.
public struct TabsMakingSound: Equatable, Sendable {
	/// Media playing, in the page or in Picture in Picture. A muted tab is in here too; the app
	/// leaves out its muted tabs when it reports.
	public var playing: Set<BrowserCore.Tab.ID>

	/// Pages in a call, using the microphone or camera.
	public var inCall: Set<BrowserCore.Tab.ID>

	/// How many times the app has reported to sound feedback. Each report carries its number, so
	/// the client can drop one that arrives after a newer one.
	public var reports: Int = 0

	public init(
		playing: Set<BrowserCore.Tab.ID> = [],
		inCall: Set<BrowserCore.Tab.ID> = []
	) {
		self.playing = playing
		self.inCall = inCall
	}

	/// Takes the other's tabs and keeps the count of reports, writing only what differs.
	internal mutating func update(to other: Self) {
		if playing != other.playing { playing = other.playing }
		if inCall != other.inCall { inCall = other.inCall }
	}

	public init(_ snapshot: BrowserMediaSnapshot) {
		self.init(
			playing: Set(snapshot.sources.filter { $0.playback == .playing }.map(\.id.tabID)),
			inCall: Set(snapshot.sources.filter(\.isCall).map(\.id.tabID))
		)
	}
}

/// Keeps ``TabsMakingSound`` from the engine's media snapshots, private sources included.
@Reducer
internal struct AppSoundFeedback {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.media) { state, action in
			switch action {
			// The snapshot as the engine sent it, which MediaFeature took (its revision is now the
			// current one) with its private sources left out.
			case let .event(.changed(snapshot, observationID)):
				guard
					state.media.isObserving,
					observationID == state.media.observationID,
					snapshot.revision == state.media.snapshot.revision
				else { return .none }

				state.tabsMakingSound.update(to: .init(snapshot))

			// Without an observation nothing is known to play. MediaFeature ignores the end of an
			// observation it already replaced, and then it is still observing.
			case .event(.observationEnded):
				guard !state.media.isObserving else { return .none }

				state.tabsMakingSound.update(to: .init())

			case .ui(.dismissed), .ui(.scopeChanged):
				state.tabsMakingSound.update(to: .init())

			default:
				break
			}
			return .none
		}
	}
}

extension AppFeature.State {
	/// What Arx's tabs are doing with sound, as sound feedback needs it: a tab plays sound that
	/// isn't muted or turned down to nothing, in its page or in Picture in Picture, or a tab is in a
	/// call. Private tabs count.
	internal var soundFeedbackPageActivity: SoundFeedbackClient.PageActivity {
		// A tab turned down to nothing is as quiet as a muted one.
		let silenced = mutedTabs.union(tabVolumes.filter { $0.value <= 0 }.keys)
		return .init(
			playsSound: !tabsMakingSound.playing.subtracting(silenced).isEmpty,
			usesMicrophone: !tabsMakingSound.inCall.isEmpty
		)
	}
}

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	/// Tells sound feedback each time a tab starts or stops playing sound or a call, so a sound
	/// never plays over them. Only this state knows; the client keeps the newest report.
	internal func reportingPageActivityToSoundFeedback() -> some Reducer<State, Action> {
		onChange(of: { $0.soundFeedbackPageActivity }, reduce: { state, _, activity in
			@Dependency(\.soundFeedback)
			var soundFeedback

			// Effects may reach the client out of order; the number lets it keep the newest.
			state.tabsMakingSound.reports += 1
			let report = state.tabsMakingSound.reports
			return .run { _ in await soundFeedback.pagesChanged(activity, report) }
		})
	}
}
