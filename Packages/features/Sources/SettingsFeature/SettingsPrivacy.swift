import DiagnosticsClient
import _ComposableArchitecture

/// Settings › Privacy (DEV-887): the crash reports kept on this Mac, and Report a Problem….
/// Collecting at launch keeps new crash reports; Arx never sends them anywhere.
@Reducer
internal struct SettingsPrivacy {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	@Dependency(\.diagnostics)
	private var diagnostics

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.startDiagnostics) { _ in
			.run { [diagnostics] send in
				await send(.event(.diagnosticsChanged(diagnostics.collect())))
			}
			.cancellable(id: Cancellation.diagnostics, cancelInFlight: true)
		}

		Pullback(\.ui.loadDiagnostics) { _ in
			.run { [diagnostics] send in
				await send(.event(.diagnosticsChanged(diagnostics.status())))
			}
		}

		Pullback(\.event.diagnosticsChanged) { state, status in
			state.diagnostics = status
			return .none
		}

		Pullback(\.ui.removeCrashReports) { state in
			guard state.diagnostics?.hasReports == true
			else { return .none }

			return .run { [diagnostics] send in
				await send(.event(.diagnosticsChanged(diagnostics.removeCrashReports())))
			}
		}

		Pullback(\.ui.reportProblem) { _ in
			.send(.delegate(.reportProblem))
		}
	}

	private enum Cancellation: Hashable {
		case diagnostics
	}
}
