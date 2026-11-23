import BrowserCore
import BrowserMediaClient
import Foundation
import _ComposableArchitecture

/// ArxPiP controls consume authoritative native snapshots; this feature never creates a video stream.
@Reducer
public struct MediaFeature {
	@ObservableState
	public struct State: Equatable {
		public var profileID: Profile.ID
		public var isPrivate: Bool
		public var includesAllOrdinaryProfiles: Bool
		public var isAvailable: Bool
		public var isObserving: Bool
		public var observationID: Int
		public var snapshot: BrowserMediaSnapshot
		public var automatic: AutomaticPiPPreferences
		public var automaticAttempts: Set<BrowserMediaSource.ID>
		public var automaticEntry: AutomaticEntry
		public var pending: Pending?
		public var failure: BrowserMediaClient.Failure?

		/// Tabs whose page already floats elsewhere, such as in Page PiP (DEV-950): they never
		/// float again on their own.
		public var tabsFloatingElsewhere: Set<BrowserCore.Tab.ID>

		public init(
			profileID: Profile.ID,
			isPrivate: Bool = false,
			includesAllOrdinaryProfiles: Bool = false,
			isAvailable: Bool = false,
			isObserving: Bool = false,
			observationID: Int = 0,
			snapshot: BrowserMediaSnapshot = .init(),
			automatic: AutomaticPiPPreferences = .init(),
			automaticAttempts: Set<BrowserMediaSource.ID> = [],
			automaticEntry: AutomaticEntry = .init(),
			pending: Pending? = nil,
			failure: BrowserMediaClient.Failure? = nil,
			tabsFloatingElsewhere: Set<BrowserCore.Tab.ID> = []
		) {
			self.profileID = profileID
			self.isPrivate = isPrivate
			self.includesAllOrdinaryProfiles = includesAllOrdinaryProfiles
			self.isAvailable = isAvailable
			self.isObserving = isObserving
			self.observationID = observationID
			self.snapshot = snapshot
			self.automatic = automatic
			self.automaticAttempts = automaticAttempts
			self.automaticEntry = automaticEntry
			self.pending = pending
			self.failure = failure
			self.tabsFloatingElsewhere = tabsFloatingElsewhere
		}

		public var visibleSources: [BrowserMediaSource] {
			guard isAvailable else { return [] }
			return snapshot.sources.filter(includes)
		}

		internal func includes(_ source: BrowserMediaSource) -> Bool {
			includesAllOrdinaryProfiles
			? !source.isPrivate
			: source.id.profileID == profileID && source.isPrivate == isPrivate
		}
	}

	public struct Pending: Equatable, Sendable {
		public var id: UUID
		public var request: BrowserMediaRequest
		public var returnToSource: Bool

		public init(
			id: UUID,
			request: BrowserMediaRequest,
			returnToSource: Bool
		) {
			self.id = id
			self.request = request
			self.returnToSource = returnToSource
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case appeared
			case dismissed
			case scopeChanged(Profile.ID, isPrivate: Bool)
			case perform(BrowserMediaSource.ID, BrowserMediaSource.Action)

			/// The sidebar player's bar (DEV-906): seeks to this many seconds in.
			case seek(BrowserMediaSource.ID, to: Double)
			case returnToTab(BrowserMediaSource.ID)
			case setAutomatic(BrowserMediaSource.ID, enabled: Bool)

			/// A tab's own automatic Picture in Picture choice, from its context menu (DEV-1246).
			case setTabChoice(BrowserCore.Tab.ID, AutomaticPiPPreferences.TabChoice)
			case sourceBecameHidden(BrowserMediaSource.ID)
			case sourceBecameVisible(BrowserMediaSource.ID)
		}

		@CasePathable
		public enum Event: Sendable {
			/// Arx became, or stopped being, the active app with one of its browser windows key.
			case applicationActivityChanged(isActive: Bool)
			case changed(BrowserMediaSnapshot, observationID: Int)
			case activated(BrowserMediaSource.ID, observationID: Int)
			case observationEnded(Int)
			case finished(UUID, BrowserMediaClient.Failure?)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case returnToSource(BrowserMediaSource.ID)
			case automaticPreferencesChanged(AutomaticPiPPreferences)

			/// A source owed an automatic entry floats its whole tab in Page PiP (DEV-1246).
			case presentPagePictureInPicture(BrowserMediaSource.ID)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserMedia)
	private var media

	@Dependency(\.uuid)
	private var uuid

	private enum Cancellation: Hashable {
		/// Every native observation, cancelled when observation resets.
		case observation

		/// One observation epoch, so a stale observation can be stopped without touching a newer one.
		case observationEpoch(Int)
		case command
	}

	public init() {}

	/// Saves an edit of the automatic preferences, and drops what sources they no longer permit
	/// were still owed, cancelling such an entry in flight.
	private func automaticPreferencesChanged(state: inout State) -> Effect<Action> {
		let save: Effect<Action> = .send(.delegate(.automaticPreferencesChanged(state.automatic)))
		for source in state.visibleSources where !state.automatic.permits(source) {
			state.automaticEntry.owed[source.id] = nil
			state.automaticEntry.failures[source.id] = nil
		}
		let isPendingAutomaticRequestRevoked = state.automaticEntry.pendingTrigger != nil
		&& state.pending.map { pending in
			!state.visibleSources.contains(where: {
				$0.id == pending.request.sourceID && state.automatic.permits($0)
			})
		} ?? false

		guard isPendingAutomaticRequestRevoked else { return save }
		state.dropPending()
		return .merge(save, .cancel(id: Cancellation.command))
	}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.appeared) { state in
			state.isAvailable = MainActor.assumeIsolated { [media] in media.isAvailable }

			guard state.isAvailable, !state.isObserving
			else { return .none }

			state.isObserving = true
			state.observationID += 1
			let observationID = state.observationID

			return .merge(
				.run { [media] send in
					for await snapshot in await media.events() {
						guard !Task.isCancelled else { return }
						await send(.event(.changed(snapshot, observationID: observationID)))
					}

					guard !Task.isCancelled else { return }
					await send(.event(.observationEnded(observationID)))
				},
				.run { [media] send in
					for await source in await media.activations() {
						guard !Task.isCancelled else { return }
						await send(.event(.activated(source, observationID: observationID)))
					}
				}
			)

			// Every path that clears `isObserving` cancels the previous observation synchronously.
			// `cancelInFlight` would cancel only when this task registers off the main actor, so an
			// appear/dismiss/appear burst could let the older observation cancel this one. An
			// older observation that registers late is stopped by its first stale event instead.
			.cancellable(id: Cancellation.observationEpoch(observationID))
			.cancellable(id: Cancellation.observation)
		}

		Pullback(\.ui.dismissed) { state in resetObservation(state: &state) }

		Pullback(\.ui.scopeChanged) { state, value in
			state.profileID = value.0
			state.isPrivate = value.1
			state.automaticAttempts = []
			state.automaticEntry.reset()
			state.failure = nil

			return .concatenate(
				resetObservation(state: &state),
				.send(.ui(.appeared))
			)
		}

		Pullback(\.ui.perform) { state, value in

			// Automatic entry has its own route, and a seek needs a time.
			guard value.1 != .enterAutomaticPictureInPicture, value.1 != .seek
			else { return .none }

			// The person took over this video's Picture in Picture. A call's controls leave its
			// Picture in Picture to the automatic return (DEV-948).
			let isCallControl = [.toggleMicrophone, .toggleCamera, .hangUp].contains(value.1)
			if !isCallControl { state.automaticEntry.returns.remove(value.0) }

			return perform(value.0, action: value.1, state: &state)
		}

		Pullback(\.ui.seek) { state, value in
			let (id, seconds) = value
			guard seconds.isFinite, seconds >= 0 else { return .none }

			return perform(id, action: .seek, seekingTo: seconds, state: &state)
		}

		Pullback(\.ui.returnToTab) { state, id in
			guard
				state.pending == nil,
				let source = state.visibleSources.first(where: { $0.id == id })
			else { return .none }

			if source.isInPictureInPicture {
				return perform(
					id,
					action: .exitPictureInPicture,
					returnToSource: true,
					state: &state
				)
			}

			return .send(.delegate(.returnToSource(id)))
		}

		Pullback(\.ui.setAutomatic) { state, value in
			guard
				let source = state.visibleSources.first(where: { $0.id == value.0 }),
				state.automatic.setEnabled(value.1, for: source)
			else { return .none }

			return automaticPreferencesChanged(state: &state)
		}

		Pullback(\.ui.setTabChoice) { state, value in
			let (tabID, choice) = value
			guard state.automatic.choice(for: tabID) != choice else { return .none }

			state.automatic.setChoice(choice, for: tabID)
			return automaticPreferencesChanged(state: &state)
		}

		Pullback(\.ui.sourceBecameHidden) { state, id in
			state.automaticEntry.shown.remove(id)
			state.automaticEntry.hidden.insert(id)
			state.automaticEntry.returns.remove(id)
			guard
				!state.automaticAttempts.contains(id),
				let source = state.visibleSources.first(where: { $0.id == id })
			else { return .none }

			// Leaving view while Arx's own return folds its Picture in Picture back onto the page
			// (the person came back to Arx and switched tabs at once): it was playing as it left,
			// so it's owed, once a snapshot shows it on the page (DEV-1213).
			let isLanding = source.isInPictureInPicture && state.isLandingInline(id)

			// Owed only if it qualifies as it leaves view; a video that starts later stays put.
			guard state.isEligibleForAutomaticEntry(source, onceInline: isLanding) else {
				state.automaticEntry.owed[id] = nil
				return .none
			}
			if isLanding { state.automaticEntry.awaitingInline.insert(id) }

			state.automaticEntry.owed[id] = .hidden
			state.automaticEntry.failures[id] = nil
			return requestOwedAutomaticEntry(state: &state)
		}

		Pullback(\.ui.sourceBecameVisible) { state, id in
			state.automaticEntry.hidden.remove(id)
			state.automaticEntry.shown.insert(id)

			// Showing again ends what it was owed.
			state.automaticAttempts.remove(id)
			state.automaticEntry.owed[id] = nil
			state.automaticEntry.failures[id] = nil

			let isPendingAutomaticRequest = state.pending?.request.sourceID == id
			&& state.automaticEntry.pendingTrigger != nil

			if isPendingAutomaticRequest {
				state.dropPending()
				return .merge(
					.cancel(id: Cancellation.command),
					requestOwedAutomaticEntry(state: &state)
				)
			}

			// Back on the video's own tab, its PiP folds away, once Arx is in front again.
			if
				!state.automaticEntry.isApplicationActive,
				state.automatic.closesOnReturn,
				state.visibleSources.contains(where: { $0.id == id && $0.isInPictureInPicture })
			{
				state.automaticEntry.returns.insert(id)
				return .none
			}
			guard
				state.automaticEntry.isApplicationActive,
				state.automatic.closesOnReturn,
				let source = state.visibleSources.first(where: { $0.id == id }),
				source.supports(.exitPictureInPicture)
			else { return .none }

			// An automatic return goes through its own path, which retries and stays silent; so
			// does any exit while a command is in flight, once it finishes.
			if state.automaticEntry.returns.contains(id) || state.pending != nil {
				state.automaticEntry.returns.insert(id)
				return requestOwedAutomaticEntry(state: &state)
			}

			state.automaticEntry.deactivationEntries.remove(id)
			return perform(id, action: .exitPictureInPicture, state: &state)
		}

		Pullback(\.event.applicationActivityChanged) { state, isActive in
			guard state.automaticEntry.isApplicationActive != isActive else { return .none }

			state.automaticEntry.isApplicationActive = isActive

			if !isActive {
				// Returns not sent yet go back to waiting for the next activation; one in flight
				// is reconciled when it finishes (`completeAutomaticReturn`).
				let inFlight = state.automaticEntry.pendingIsReturn ? state.pending?.request.sourceID : nil
				for id in state.automaticEntry.returns where id != inFlight {
					state.automaticEntry.deactivationEntries.insert(id)
				}
				state.automaticEntry.returns = inFlight.map { [$0] } ?? []

				// Leaving the front floats nothing by itself (DEV-1246): a showing video keeps
				// playing in place until its window leaves the display.
				return .none
			}

			// Back in Arx with the video's tab still showing, its PiP folds away, as soon as
			// the exit can be sent.
			state.automaticEntry.awaitingFloat = []

			// One whose window's visibility report hasn't caught up stays owed until it shows.
			let returning = state.automaticEntry.deactivationEntries
			state.automaticEntry.deactivationEntries = []
			for id in returning {
				if state.automaticEntry.shown.contains(id) { state.automaticAttempts.remove(id) }
				if state.automatic.closesOnReturn { state.automaticEntry.returns.insert(id) }
			}
			return requestOwedAutomaticEntry(state: &state)
		}

		Pullback(\.event.changed) { state, value in
			let (snapshot, observationID) = value
			guard observationID == state.observationID
			else { return .cancel(id: Cancellation.observationEpoch(observationID)) }

			guard
				state.isObserving,
				snapshot.isValid,
				snapshot.revision > state.snapshot.revision
			else { return .none }

			state.snapshot = .init(
				revision: snapshot.revision,
				sources: snapshot.sources.filter(state.includes)
			)

			let ids = Set(state.snapshot.sources.map(\.id))
			state.automaticAttempts.formIntersection(ids)
			state.automaticEntry.keep(ids)

			// A session Arx floated for a source that stayed showing ended, so the next app switch
			// may float it again; a hidden source keeps its attempt until it shows again.
			for id in state.automaticEntry.observe(state.snapshot.sources)
			where state.automaticEntry.shown.contains(id) {
				state.automaticAttempts.remove(id)
			}

			if let pending = state.pending, !ids.contains(pending.request.sourceID) {
				state.dropPending()
				return .merge(
					.cancel(id: Cancellation.command),
					requestOwedAutomaticEntry(state: &state)
				)
			}

			return requestOwedAutomaticEntry(state: &state)
		}

		Pullback(\.event.activated) { state, value in
			guard value.1 == state.observationID
			else { return .cancel(id: Cancellation.observationEpoch(value.1)) }

			guard
				state.isObserving,
				state.visibleSources.contains(where: { $0.id == value.0 })
			else { return .none }

			return .send(.delegate(.returnToSource(value.0)))
		}

		Pullback(\.event.observationEnded) { state, observationID in
			guard state.isObserving, state.observationID == observationID
			else { return .none }

			state.isAvailable = false
			state.failure = .unavailable
			return resetObservation(state: &state)
		}

		Pullback(\.event.finished) { state, value in
			guard let pending = state.pending, pending.id == value.0
			else { return .none }

			state.pending = nil

			// An automatic entry or return is Arx's own doing, so its failure is never shown.
			if state.automaticEntry.pendingIsReturn {
				state.automaticEntry.pendingIsReturn = false
				return completeAutomaticReturn(pending, failure: value.1, state: &state)
			}
			if state.automaticEntry.pendingTrigger != nil {
				state.automaticEntry.pendingTrigger = nil
				return completeAutomaticEntry(pending, failure: value.1, state: &state)
			}

			state.failure = value.1
			if value.1 == nil, pending.request.action == .enterPictureInPicture {
				let source = state.visibleSources.first { $0.id == pending.request.sourceID }
				if source?.isInPictureInPicture != true {
					state.automaticEntry.awaitingFloat.insert(pending.request.sourceID)
				}
			}

			// An automatic entry owed while this command ran goes now.
			let owed = requestOwedAutomaticEntry(state: &state)

			guard
				value.1 == nil,
				pending.returnToSource,
				state.visibleSources.contains(where: { $0.id == pending.request.sourceID })
			else { return owed }

			return .merge(owed, .send(.delegate(.returnToSource(pending.request.sourceID))))
		}
	}

	private func resetObservation(state: inout State) -> Effect<Action> {
		state.isObserving = false
		state.observationID += 1
		state.snapshot = .init()
		state.pending = nil
		state.automaticAttempts = []
		state.automaticEntry.reset()

		return .merge(
			.cancel(id: Cancellation.observation),
			.cancel(id: Cancellation.command)
		)
	}

	internal func perform(
		_ id: BrowserMediaSource.ID,
		action: BrowserMediaSource.Action,
		returnToSource: Bool = false,
		seekingTo seconds: Double? = nil,
		state: inout State
	) -> Effect<Action> {
		guard
			MainActor.assumeIsolated({ [media] in media.isAvailable }),
			state.pending == nil,
			let source = state.visibleSources.first(where: { $0.id == id }),
			source.supports(action)
		else { return .none }

		let pending = Pending(
			id: uuid(),
			request: seconds.map { .init(source: source, seekingTo: $0) } ?? .init(source: source, action: action),
			returnToSource: returnToSource
		)

		state.pending = pending
		state.failure = nil

		return .run { [media] send in
			do {
				try await media.perform(pending.request)
				guard !Task.isCancelled else { return }
				await send(.event(.finished(pending.id, nil)))

			} catch is CancellationError {
				return

			} catch {
				guard !Task.isCancelled else { return }
				let failure: BrowserMediaClient.Failure = error as? BrowserMediaClient.Failure ?? .requestFailed
				await send(.event(.finished(pending.id, failure)))
			}
		}

		// `perform` requires no pending command, and every path that clears one cancels it
		// synchronously. `cancelInFlight` would only let an older command that registers late
		// cancel this one, leaving `pending` without a result.
		.cancellable(id: Cancellation.command)
	}
}
