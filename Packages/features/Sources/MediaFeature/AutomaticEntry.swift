import BrowserCore
import BrowserMediaClient
import Foundation
import _ComposableArchitecture

/// Why a source should float into Picture in Picture on its own, and what is still owed.
///
/// A trigger is recorded once, when it happens: the source's surface stopped being visible because
/// the person switched tabs, its window was minimised or hidden, or its full-screen window's OS
/// workspace (macOS Space) left the display (DEV-1322). Arx only
/// losing focus, with the window still on screen, is not a trigger (DEV-1246): the video keeps
/// playing in place. A source that isn't playing,
/// has its site turned off or is private then is never owed an entry. One that is owed waits
/// for a fresh snapshot or a free command slot and is retried a few times, so a revision bumped
/// by the hide itself or a command already in flight no longer drops the entry (DEV-848).
public struct AutomaticEntry: Equatable, Sendable {
	public enum Trigger: Equatable, Sendable {
		/// The source's surface stopped being visible: another tab, space or pane took its
		/// place, or its window left the display (minimised, hidden, or full screen on another
		/// OS workspace). A window merely covered by another app's, or one that isn't full screen
		/// on another OS workspace, stays visible (DEV-1246, DEV-1322).
		case hidden
	}

	/// How many failed requests a trigger gets before it is dropped.
	public static let maximumFailures: Int = 3

	/// Whether Arx is the active app, as the composing feature reports it.
	public var isApplicationActive: Bool

	/// Sources whose surface was last reported visible.
	public var shown: Set<BrowserMediaSource.ID>

	/// Sources whose surface was last reported not visible.
	public var hidden: Set<BrowserMediaSource.ID>

	/// Sources owed an automatic entry, with what triggered it.
	public var owed: [BrowserMediaSource.ID: Trigger]

	/// Failed requests per owed source.
	public var failures: [BrowserMediaSource.ID: Int]

	/// Floating sources owed a return to the page once Arx is active again with their tab
	/// showing: their tab showed again while Arx was in the background.
	public var deactivationEntries: Set<BrowserMediaSource.ID>

	/// Floating sources owed a return now that Arx is active with their tab showing, kept until
	/// the exit can be sent: another command may be in flight, or the snapshot showing them in
	/// Picture in Picture may not have arrived yet.
	public var returns: Set<BrowserMediaSource.ID>

	/// The revision a source's last request was rejected as stale at; it isn't retried until
	/// a snapshot brings that source a newer one.
	public var staleRevisions: [BrowserMediaSource.ID: UInt64]

	/// Sources owed a new entry whose return exit has finished or is in flight, waiting for the
	/// snapshot that shows them back on the page: Arx left the front again during the return, or
	/// their tab left view (DEV-1213).
	public var awaitingInline: Set<BrowserMediaSource.ID>

	/// Sources whose return exit finished while no snapshot has shown them back on the page yet
	/// (DEV-1213): their Picture in Picture is Arx's own folding away, not one they keep.
	public var landing: Set<BrowserMediaSource.ID>

	/// Sources Arx floated (`deactivationEntries` or `returns`) that a snapshot has shown in
	/// Picture in Picture. Once one shows them back on the page, that session is over, however
	/// it ended, and Arx no longer owns it.
	public var observedFloating: Set<BrowserMediaSource.ID>

	/// Sources whose entry, manual or automatic, Chromium accepted, until a snapshot shows them
	/// floating, so no automatic entry replaces them in the meantime.
	public var awaitingFloat: Set<BrowserMediaSource.ID>

	/// The trigger behind the pending command, when it's an automatic entry.
	public var pendingTrigger: Trigger?

	/// Whether the pending command is the exit of a source in `returns`.
	public var pendingIsReturn: Bool

	public init(
		isApplicationActive: Bool = true,
		shown: Set<BrowserMediaSource.ID> = [],
		hidden: Set<BrowserMediaSource.ID> = [],
		owed: [BrowserMediaSource.ID: Trigger] = [:],
		failures: [BrowserMediaSource.ID: Int] = [:],
		deactivationEntries: Set<BrowserMediaSource.ID> = [],
		returns: Set<BrowserMediaSource.ID> = [],
		staleRevisions: [BrowserMediaSource.ID: UInt64] = [:],
		awaitingInline: Set<BrowserMediaSource.ID> = [],
		landing: Set<BrowserMediaSource.ID> = [],
		observedFloating: Set<BrowserMediaSource.ID> = [],
		awaitingFloat: Set<BrowserMediaSource.ID> = [],
		pendingTrigger: Trigger? = nil,
		pendingIsReturn: Bool = false
	) {
		self.isApplicationActive = isApplicationActive
		self.shown = shown
		self.hidden = hidden
		self.owed = owed
		self.failures = failures
		self.deactivationEntries = deactivationEntries
		self.returns = returns
		self.staleRevisions = staleRevisions
		self.awaitingInline = awaitingInline
		self.landing = landing
		self.observedFloating = observedFloating
		self.awaitingFloat = awaitingFloat
		self.pendingTrigger = pendingTrigger
		self.pendingIsReturn = pendingIsReturn
	}

	/// Forgets sources that left the snapshot.
	internal mutating func keep(_ ids: Set<BrowserMediaSource.ID>) {
		shown.formIntersection(ids)
		hidden.formIntersection(ids)
		owed = owed.filter { ids.contains($0.key) }
		failures = failures.filter { ids.contains($0.key) }
		deactivationEntries.formIntersection(ids)
		returns.formIntersection(ids)
		staleRevisions = staleRevisions.filter { ids.contains($0.key) }
		awaitingInline.formIntersection(ids)
		landing.formIntersection(ids)
		observedFloating.formIntersection(ids)
		awaitingFloat.formIntersection(ids)
	}

	/// Retires the ownership of an automatic Picture in Picture session a snapshot shows ended,
	/// and returns the sources whose session ended.
	@discardableResult
	internal mutating func observe(_ sources: [BrowserMediaSource]) -> Set<BrowserMediaSource.ID> {
		var ended: Set<BrowserMediaSource.ID> = []
		for source in sources {
			if source.isInPictureInPicture { awaitingFloat.remove(source.id) } else { landing.remove(source.id) }
			let isOwned = deactivationEntries.contains(source.id) || returns.contains(source.id)
			if source.isInPictureInPicture {
				if isOwned { observedFloating.insert(source.id) }
			} else if observedFloating.remove(source.id) != nil {
				deactivationEntries.remove(source.id)
				returns.remove(source.id)
				ended.insert(source.id)
			}
		}
		return ended
	}

	/// Records that Arx owns `source`'s session, noting a floating snapshot that arrived before
	/// the request's completion.
	internal mutating func own(
		_ source: BrowserMediaSource?,
		as owned: WritableKeyPath<Self, Set<BrowserMediaSource.ID>>
	) {
		guard let source else { return }
		self[keyPath: owned].insert(source.id)
		if source.isInPictureInPicture { observedFloating.insert(source.id) }
	}

	/// Forgets everything owed, as when observation restarts.
	internal mutating func reset() {
		shown = []
		hidden = []
		owed = [:]
		failures = [:]
		deactivationEntries = []
		returns = []
		staleRevisions = [:]
		awaitingInline = []
		landing = []
		observedFloating = []
		awaitingFloat = []
		pendingTrigger = nil
		pendingIsReturn = false
	}
}

extension MediaFeature.State {
	/// Forgets the command in flight and what it was for: an automatic entry's trigger, or a
	/// return's exit. Its effect is the caller's to cancel.
	internal mutating func dropPending() {
		pending = nil
		automaticEntry.pendingTrigger = nil
		automaticEntry.pendingIsReturn = false
	}

	/// Whether another video floats, or Chromium already took one whose snapshot is on its way.
	internal func isAnotherFloating(than id: BrowserMediaSource.ID) -> Bool {
		visibleSources.contains { $0.id != id && $0.isInPictureInPicture }
		|| automaticEntry.deactivationEntries.contains { $0 != id }
		|| automaticEntry.awaitingFloat.contains { $0 != id }
	}

	/// Whether a source may float into Picture in Picture on its own right now: its site
	/// allows it, it isn't private, and it's playing video or is a call (DEV-948), outside
	/// Picture in Picture.
	/// Whether `source` qualifies for an automatic entry now, or, `onceInline`, as soon as a
	/// snapshot shows it back on the page.
	internal func isEligibleForAutomaticEntry(
		_ source: BrowserMediaSource,
		onceInline: Bool = false
	) -> Bool {
		let isPlayingVideo = source.hasVideo && source.playback == .playing
		return automatic.permits(source)
		&& (isPlayingVideo || source.isCall)
		&& (onceInline || !source.isInPictureInPicture)
		&& !tabsFloatingElsewhere.contains(source.id.tabID)
	}

	/// Whether Arx's own return is folding `id`'s Picture in Picture back onto the page: its exit
	/// in flight, or finished while no snapshot has shown it there yet (DEV-1213).
	internal func isLandingInline(_ id: BrowserMediaSource.ID) -> Bool {
		let exitInFlight = automaticEntry.pendingIsReturn && pending?.request.sourceID == id
		return exitInFlight || automaticEntry.landing.contains(id)
	}
}

extension MediaFeature {
	/// The request an owed source makes next, or nil when it's no longer owed one.
	///
	/// It asks for Chromium's automatic entry first, so a site's own `enterpictureinpicture`
	/// handler runs. After a failure, or when the site advertises no automatic action, it falls
	/// back to the manual entry Arx asks for on the browser's behalf.
	internal static func automaticAction(
		for source: BrowserMediaSource,
		state: State
	) -> BrowserMediaSource.Action? {
		guard state.isEligibleForAutomaticEntry(source) else { return nil }

		// While Arx is in the background, nothing replaces a video already floating.
		if !state.automaticEntry.isApplicationActive, state.isAnotherFloating(than: source.id) { return nil }

		// A failure Chromium answers before the request starts (stale, busy, unsupported) leaves
		// both routes open; one after it started (a site handler that timed out) quarantines the
		// page natively, so the next snapshot drops both entry actions and this entry with them.
		let failures = state.automaticEntry.failures[source.id, default: 0]
		if failures == 0, source.supports(.enterAutomaticPictureInPicture) {
			return .enterAutomaticPictureInPicture
		}
		return source.supports(.enterPictureInPicture) ? .enterPictureInPicture : nil
	}

	/// Sends the next owed automatic entry when no command is pending.
	internal func requestOwedAutomaticEntry(state: inout State) -> Effect<Action> {
		guard state.pending == nil else { return .none }

		// A video owed its return to the page goes first, once Arx is in front.
		for id in state.automaticEntry.returns where state.automaticEntry.isApplicationActive {
			guard state.automatic.closesOnReturn else {
				state.automaticEntry.returns.remove(id)
				continue
			}

			// Not showing yet: its visibility report is on its way. Leaving its tab drops it.
			guard state.automaticEntry.shown.contains(id) else { continue }

			// Not in Picture in Picture yet: its snapshot is still on its way. Or an exit was
			// rejected as stale at this revision: wait for a newer one.
			guard
				let source = state.visibleSources.first(where: { $0.id == id }),
				source.supports(.exitPictureInPicture),
				state.automaticEntry.staleRevisions[id] != source.revision
			else { continue }

			state.automaticEntry.staleRevisions[id] = nil
			state.automaticAttempts.remove(id)
			let effect = perform(id, action: .exitPictureInPicture, state: &state)
			if state.pending != nil {
				// Kept in `returns` until the exit succeeds.
				state.automaticEntry.pendingIsReturn = true
				return effect
			}
			state.automaticEntry.returns.remove(id)
		}

		var pages: [Effect<Action>] = []
		for source in state.visibleSources {
			guard let trigger = state.automaticEntry.owed[source.id] else { continue }

			// Its return just finished: wait until a snapshot shows it back on the page.
			if state.automaticEntry.awaitingInline.contains(source.id) {
				guard !source.isInPictureInPicture else { continue }
				state.automaticEntry.awaitingInline.remove(source.id)
			}

			// Rejected as stale at this revision: wait for the snapshot that brings a newer one.
			if let stale = state.automaticEntry.staleRevisions[source.id] {
				guard stale != source.revision else { continue }
				state.automaticEntry.staleRevisions[source.id] = nil
			}

			// Its tab floats whole, in Page PiP (DEV-1246): the composing feature opens it, and
			// nothing is owed once asked.
			if state.automatic.kind(for: source) == .page {
				state.automaticEntry.owed[source.id] = nil
				state.automaticEntry.failures[source.id] = nil
				guard state.isEligibleForAutomaticEntry(source) else { continue }
				state.automaticAttempts.insert(source.id)
				pages.append(.send(.delegate(.presentPagePictureInPicture(source.id))))
				continue
			}

			guard let action = Self.automaticAction(for: source, state: state) else {
				state.automaticEntry.owed[source.id] = nil
				state.automaticEntry.failures[source.id] = nil
				continue
			}

			state.automaticAttempts.insert(source.id)
			let effect = perform(source.id, action: action, state: &state)
			if state.pending != nil {
				state.automaticEntry.pendingTrigger = trigger
				return .merge(pages + [effect])
			}
			state.automaticEntry.owed[source.id] = nil
		}

		return .merge(pages)
	}

	/// Records what an automatic return's exit completion means: done, retried with a newer
	/// revision, or given up after a few failures.
	internal func completeAutomaticReturn(
		_ pending: Pending,
		failure: BrowserMediaClient.Failure?,
		state: inout State
	) -> Effect<Action> {
		let id = pending.request.sourceID
		guard let failure else {
			state.automaticEntry.returns.remove(id)
			state.automaticEntry.failures[id] = nil

			// Until a snapshot shows it back on the page, its Picture in Picture is the return's.
			if state.visibleSources.first(where: { $0.id == id })?.isInPictureInPicture == true {
				state.automaticEntry.landing.insert(id)
			}
			return requestOwedAutomaticEntry(state: &state)
		}

		// Its tab left view while the exit ran (DEV-1213): the exit failed, so it still floats,
		// which is where a hidden video goes anyway, and it's owed nothing more. Otherwise a later
		// exit of the person's own would float it again.
		if state.automaticEntry.awaitingInline.contains(id), state.automaticEntry.owed[id] == .hidden {
			state.automaticEntry.awaitingInline.remove(id)
			state.automaticEntry.owed[id] = nil
			state.automaticEntry.failures[id] = nil
			return requestOwedAutomaticEntry(state: &state)
		}

		let failures = state.automaticEntry.failures[id, default: 0] + 1
		state.automaticEntry.failures[id] = failures
		if failures >= AutomaticEntry.maximumFailures {
			state.automaticEntry.returns.remove(id)
			state.automaticEntry.failures[id] = nil
		} else if failure == .staleSource {
			state.automaticEntry.staleRevisions[id] = pending.request.expectedRevision
		}
		return requestOwedAutomaticEntry(state: &state)
	}

	/// Records what an automatic request's completion means for its trigger.
	internal func completeAutomaticEntry(
		_ pending: Pending,
		failure: BrowserMediaClient.Failure?,
		state: inout State
	) -> Effect<Action> {
		let id = pending.request.sourceID

		guard let failure else {
			state.automaticEntry.owed[id] = nil
			state.automaticEntry.failures[id] = nil
			state.automaticEntry.staleRevisions[id] = nil

			// It floats now, whatever its trigger: nothing else takes Picture in Picture before
			// its snapshot arrives.
			if state.visibleSources.first(where: { $0.id == id })?.isInPictureInPicture != true {
				state.automaticEntry.awaitingFloat.insert(id)
			}
			return requestOwedAutomaticEntry(state: &state)
		}

		let failures = state.automaticEntry.failures[id, default: 0] + 1
		state.automaticEntry.failures[id] = failures
		if failures >= AutomaticEntry.maximumFailures || state.automaticEntry.owed[id] == nil {
			state.automaticEntry.owed[id] = nil
			state.automaticEntry.failures[id] = nil

			// A hidden source keeps its attempt until it shows again.
			return requestOwedAutomaticEntry(state: &state)
		}

		// A stale revision means a newer snapshot is on its way, or already here.
		if failure == .staleSource {
			state.automaticEntry.staleRevisions[id] = pending.request.expectedRevision
		}
		return requestOwedAutomaticEntry(state: &state)
	}
}
