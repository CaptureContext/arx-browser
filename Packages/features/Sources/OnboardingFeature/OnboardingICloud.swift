import Foundation
import WorkspaceSync
import _ComposableArchitecture

/// "Your Arx on every Mac": sets Arx up from iCloud before the first profile is used (DEV-1215).
///
/// The page checks the iCloud account when it appears and steps aside when there's none. Sync
/// with iCloud turns sync on and fetches every category that's on, showing which one it's on.
/// iCloud's workspace is then adopted, or, when iCloud has none, the first launch's Default
/// profile becomes the starter that uploads. After about 20 seconds, or when iCloud can't be
/// reached, Continue without waiting lets the person go on while AppFeature keeps waiting for
/// iCloud's answer in the background. Not now leaves sync off.
///
/// The page only reports the outcome; AppFeature holds Default back from iCloud until then and
/// adopts or restores it.
@Reducer
public struct OnboardingICloud {
	/// How long the first fetch may run before Continue without waiting is offered.
	public static let patience: Duration = .seconds(20)

	@ObservableState
	public struct State: Equatable, Sendable {
		public var phase: Phase

		/// The fetch has run longer than ``OnboardingICloud/patience``.
		public var isSlow: Bool

		public init(
			phase: Phase = .checking,
			isSlow: Bool = false
		) {
			self.phase = phase
			self.isSlow = isSlow
		}

		/// Whether the first fetch is running.
		public var isSyncing: Bool {
			guard case .syncing = phase else { return false }

			return true
		}

		/// Whether Continue without waiting is offered: the fetch is slow, or iCloud can't be reached.
		public var offersContinueWithoutWaiting: Bool {
			switch phase {
			case .syncing: isSlow
			case .failed: true
			case .checking, .ready, .finished: false
			}
		}
	}

	public enum Phase: Equatable, Sendable {
		/// Reading whether there's an iCloud account.
		case checking

		/// Sync with iCloud and Not now.
		case ready

		/// The first fetch is running, on this category once it's known.
		case syncing(SyncCategory?)

		/// Sync couldn't turn on or a fetch failed; `nil` when iCloud can't be reached.
		case failed(String?)

		/// The page already decided, shown again after going back.
		case finished(Resolution)
	}

	/// How the step ended.
	public enum Resolution: Equatable, Sendable {
		/// iCloud had a workspace: it replaces Default, opening on the space used last.
		case adopted(lastUsedSpaceID: UUID?)

		/// iCloud had nothing: Default is the starter that uploads.
		case empty

		/// The person went on while the fetch was slow or failing, or left the page during it.
		case continuedWithoutWaiting

		/// Not now: sync stays off.
		case notNow

		/// No iCloud account: the page stepped aside.
		case unavailable

		/// Whether iCloud's workspace replaced the first launch's.
		public var adoptedWorkspace: Bool {
			guard case .adopted = self else { return false }

			return true
		}

		/// Whether the step counts as finished.
		public var finishesStep: Bool {
			switch self {
			case .adopted, .empty, .continuedWithoutWaiting: true
			case .notNow, .unavailable: false
			}
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
			/// The page appeared; checks the account.
			case task

			/// Sync with iCloud, and Try again after a failure.
			case sync

			/// Not now.
			case notNow

			/// Continue without waiting.
			case continueWithoutWaiting
		}

		@CasePathable
		public enum Event: Sendable {
			/// Whether there's an account, and whether sync is on already: a join this step started
			/// before a relaunch, which the page then resumes instead of asking again.
			case accountChecked(isAvailable: Bool, syncIsOn: Bool)
			case sync(OnboardingSyncEvent)

			/// The join's stream ended without a result.
			case syncEnded

			/// The fetch ran longer than ``OnboardingICloud/patience``.
			case becameSlow
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// The step ended; the parent adopts or restores Default and moves on.
			case resolved(Resolution)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.workspaceSync)
	private var sync

	@Dependency(\.continuousClock)
	private var clock

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.task) { state in
			guard state.phase == .checking else { return .none }

			return .run { [sync] send in
				var syncIsOn: Bool = false
				for await status in await sync.statusUpdates() {
					syncIsOn = status.isEnabled
					break
				}
				await send(.event(.accountChecked(isAvailable: sync.accountIsAvailable(), syncIsOn: syncIsOn)))
			}
			.cancellable(id: Cancellation.account, cancelInFlight: true)
		}

		Pullback(\.event.accountChecked) { state, value in
			let (isAvailable, syncIsOn) = value
			guard state.phase == .checking else { return .none }

			// Sync is on already: the person chose it before a relaunch, so Not now no longer fits.
			// Without an account now, iCloud can't be reached rather than missing.
			if syncIsOn { return startSync(&state) }
			guard isAvailable else { return state.resolve(.unavailable) }

			state.phase = .ready
			return .none
		}

		Pullback(\.ui.sync) { state in
			switch state.phase {
			case .ready, .failed: break
			case .checking, .syncing, .finished: return .none
			}

			return startSync(&state)
		}

		Pullback(\.event.becameSlow) { state in
			guard state.isSyncing else { return .none }

			state.isSlow = true
			return .none
		}

		Pullback(\.event.sync) { state, event in
			guard state.isSyncing else { return .none }

			switch event {
			case let .fetching(category):
				state.phase = .syncing(category)
				return .none

			case let .finished(result):
				return .merge(
					.cancel(id: Cancellation.patience),
					state.resolve(result.hasWorkspace ? .adopted(lastUsedSpaceID: result.lastUsedSpaceID) : .empty)
				)

			case .unavailable, .turnedOff:
				state.phase = .failed(nil)
				return .cancel(id: Cancellation.patience)

			case let .failed(message):
				state.phase = .failed(message)
				return .cancel(id: Cancellation.patience)
			}
		}

		Pullback(\.event.syncEnded) { state in

			// Cancelled, or ended without saying how: iCloud couldn't be reached.
			guard state.isSyncing else { return .none }

			state.phase = .failed(nil)
			return .cancel(id: Cancellation.patience)
		}

		Pullback(\.ui.notNow) { state in
			switch state.phase {
			case .checking, .ready: return state.resolve(.notNow)
			case .syncing, .failed, .finished: return .none
			}
		}

		Pullback(\.ui.continueWithoutWaiting) { state in
			guard state.offersContinueWithoutWaiting else { return .none }

			// Sync is on: what the fetch still brings arrives in the background.
			return .merge(
				Self.cancelInFlightWork(),
				state.resolve(.continuedWithoutWaiting)
			)
		}
	}

	/// Turns sync on, or starts what didn't start, and waits for the first fetch.
	private func startSync(_ state: inout State) -> Effect<Action> {
		state.phase = .syncing(nil)
		state.isSlow = false
		return .merge(
			.run { [sync] send in
				for await event in await sync.joinFromOnboarding(true) {
					await send(.event(.sync(event)))

					// The join says how it ended once; nothing it says after that counts.
					switch event {
					case .fetching: continue
					case .finished, .unavailable, .failed, .turnedOff: return
					}
				}
				await send(.event(.syncEnded))
			}
			.cancellable(id: Cancellation.join, cancelInFlight: true),
			.run { [clock] send in
				try await clock.sleep(for: Self.patience)
				await send(.event(.becameSlow))
			}
			.cancellable(id: Cancellation.patience, cancelInFlight: true)
		)
	}

	/// Cancels the account check, the first fetch and its timer, so leaving the page drops them.
	/// Sync stays on: only onboarding stops waiting.
	public static func cancelInFlightWork<Action>() -> Effect<Action> {
		.merge(
			.cancel(id: Cancellation.account),
			.cancel(id: Cancellation.join),
			.cancel(id: Cancellation.patience)
		)
	}

	private enum Cancellation: Hashable {
		case account
		case join
		case patience
	}
}

extension OnboardingICloud.State {
	/// What leaving the page now, without its own buttons, means: Not now before syncing starts,
	/// Continue without waiting once it has. `nil` once the page decided.
	public var resolutionOnLeaving: OnboardingICloud.Resolution? {
		switch phase {
		case .checking, .ready: .notNow
		case .syncing, .failed: .continuedWithoutWaiting
		case .finished: nil
		}
	}

	fileprivate mutating func resolve(
		_ resolution: OnboardingICloud.Resolution
	) -> Effect<OnboardingICloud.Action> {
		phase = .finished(resolution)
		isSlow = false
		return .send(.delegate(.resolved(resolution)))
	}
}
