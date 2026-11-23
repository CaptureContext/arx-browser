import AppUI
import Foundation
import _ComposableArchitecture

/// Times the sidebar's notice toast (`sidebar.notice`): "workspace changed", an invalid tab
/// move, a split view refusal. The toast starts the timer for each notice it shows, the pointer
/// over it holds it, and the notice clears when the timer runs out.
@Reducer
internal struct SidebarNotices {
	internal typealias State = MainFeature.State
	internal typealias Action = MainFeature.Action

	@Dependency(\.continuousClock)
	private var clock

	/// Per window: the main window and other windows share their reducers' path, so a timer
	/// keyed only by its kind would cancel another window's.
	private enum Cancellation: Hashable {
		case noticeTimer(UUID)
	}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.noticeShown) { state, id in
			guard state.sidebar.notice?.id == id else { return .none }

			// A notice that replaces one under the pointer waits until the pointer leaves.
			guard !state.noticeIsHovered
			else { return .cancel(id: Cancellation.noticeTimer(state.id)) }

			return expire(id, in: state.id, after: ArxToastMetrics.duration)
		}

		Pullback(\.ui.noticeHovered) { state, isHovered in
			guard state.noticeIsHovered != isHovered else { return .none }

			state.noticeIsHovered = isHovered
			guard let id = state.sidebar.notice?.id else { return .none }

			// The toast waits while the pointer is over it, then gives the reader a moment more.
			return isHovered
			? .cancel(id: Cancellation.noticeTimer(state.id))
			: expire(id, in: state.id, after: ArxToastMetrics.resumeDuration)
		}

		Pullback(\.ui.noticeRemoved) { state, id in
			state.noticeIsHovered = false

			// A newer notice may already show in a new toast that the pointer isn't over yet.
			guard let current = state.sidebar.notice?.id, current != id
			else { return .cancel(id: Cancellation.noticeTimer(state.id)) }

			return expire(current, in: state.id, after: ArxToastMetrics.duration)
		}

		Pullback(\.event.noticeExpired) { state, id in
			guard state.sidebar.notice?.id == id, !state.noticeIsHovered else { return .none }

			state.sidebar.message = nil
			return .none
		}
	}
}

extension SidebarNotices {
	private func expire(
		_ id: Int,
		in windowID: UUID,
		after duration: Duration
	) -> Effect<Action> {
		let timer: Effect<Action> = .run { [clock] send in
			try await clock.sleep(for: duration)
			await send(.event(.noticeExpired(id)))
		}
		.cancellable(id: Cancellation.noticeTimer(windowID))

		// `cancelInFlight` cancels when the timer's task registers, off the main actor, so an
		// older timer could cancel this one and leave the newer notice up for good. Cancel in
		// reducer order instead; an older timer that registers late fires for its own notice,
		// which `noticeExpired` ignores.
		return .concatenate(.cancel(id: Cancellation.noticeTimer(windowID)), timer)
	}
}
