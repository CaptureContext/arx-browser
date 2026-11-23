import BrowserCore
import BrowserDownloadsClient
import DownloadsFeature
import Foundation
import _ComposableArchitecture

@Reducer
internal struct AppDownloads {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserDownloads)
	private var client

	@Dependency(\.linkSharing)
	private var sharing

	private enum Cancellation: Hashable {
		/// Every configuration, cancelled before a newer one starts.
		case configuration

		/// One configuration, so a stale one can be stopped without touching a newer one.
		case configurationRequest(Int)
	}

	internal var body: some ReducerOf<Self> {
		Scope(state: \.downloads, action: \.downloads) {
			DownloadsFeature()
		}

		Pullback(\.event.downloadsReady) { state in
			guard !state.downloadsReady else { return .none }

			state.downloadsReady = true
			state.main.downloadsAvailable = true

			for id in state.windows.ids {
				state.windows[id: id]?.downloadsAvailable = true
			}

			for id in state.littleWindows.ids {
				state.littleWindows[id: id]?.downloadsAvailable = true
			}

			// Finished and failed transfers sound while Arx runs, in the background too (DEV-1256).
			return .merge(
				configure(state.workspace, state: &state),
				.send(.downloads(.soundOutcomes))
			)
		}

		Pullback(\.ui.openDownloads) { state, sourceID in
			guard
				state.downloadsReady,
				!state.shouldQuit,
				!state.checkingQuit
			else { return .none }

			pointDownloads(at: sourceID, state: &state)

			state.downloads.isPresented = true
			state.downloadsFocusRequest += 1

			return .none
		}

		// Copy Link in a download's menu (DEV-892).
		Pullback(\.downloads.delegate.copyLink) { _, url in
			.run { [sharing] _ in _ = await sharing.copy(url.absoluteString) }
		}

		// The Library button's rows close as they're clicked, so a failure to open shows as the app's alert.
		Pullback(\.downloads.delegate.recentOpenFailed) { _, message in
			.send(.delegate(.commandFailed(message)))
		}

		Pullback(\.ui.downloadsPanelAppeared) { state, windowID in
			pointDownloads(at: windowID, state: &state)
			return .none
		}

		Pullback(\.delegate.save) { state, _ in
			guard state.downloadsReady, !state.discardUnsavedChangesOnQuit
			else { return .none }

			return configure(state.workspace, state: &state)
		}

		// iCloud sync's changes are saved already, so no `delegate.save` configures them (DEV-977).
		Pullback(\.event.workspaceSyncApplied) { state in
			guard state.downloadsReady, !state.discardUnsavedChangesOnQuit
			else { return .none }

			return configure(state.workspace, state: &state)
		}

		Pullback(\.event.downloadsConfigurationStarted) { state, request in
			guard request == state.downloadsConfiguration
			else { return .cancel(id: Cancellation.configurationRequest(request)) }

			return .none
		}
	}

	private func pointDownloads(
		at windowID: UUID?,
		state: inout State
	) {
		let id = windowID ?? state.focusedWindowID ?? state.main.id
		let main = id == state.main.id ? state.main : state.windows[id: id]

		if main?.isPrivate == true {
			state.downloads.filter = .privateTransfers
			state.downloads.profileFilter = []
			state.downloads.profileID = nil

		} else {
			state.downloads.profileID = main?.sidebar.space.profileID
			?? state.littleWindows[id: id]?.tab.profileID
			?? state.main.sidebar.space.profileID

			// Profiles picked in the Library's filter stay picked until they're removed.
			if state.downloads.profileFilter.isEmpty { state.downloads.filter = .currentProfile }
		}
	}

	private func configure(
		_ organization: BrowserOrganization,
		state: inout State
	) -> Effect<Action> {
		state.downloadsConfiguration &+= 1
		let request = state.downloadsConfiguration

		let configuration: Effect<Action> = .run { @MainActor [client] send in
			do {
				// Both cancellation IDs are registered by now. Report in and reach the client in one
				// main-actor turn, so a configuration reduced earlier is never applied after this one.
				send(.event(.downloadsConfigurationStarted(request)))
				try Task.checkCancellation()
				try await client.configure(organization)
			} catch is CancellationError {
				return
			} catch {
				guard !Task.isCancelled else { return }

				send(.downloads(.event(.operationFailed(downloadFailureMessage(error)))))
			}
		}
		.cancellable(id: Cancellation.configurationRequest(request))
		.cancellable(id: Cancellation.configuration)

		// `cancelInFlight` cancels when the effect's task registers, which happens off the
		// main actor, so an older configuration could cancel this one and stay applied.
		// Cancel synchronously in reducer order; one that registers later is stopped when
		// it reports in.
		return .concatenate(.cancel(id: Cancellation.configuration), configuration)
	}
}
