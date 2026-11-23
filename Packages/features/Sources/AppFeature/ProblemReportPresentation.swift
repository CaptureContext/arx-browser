import FeedbackFeature
import SettingsFeature
import SwiftUI
import _ComposableArchitecture

/// Report a Problem (DEV-887): opened from the Help menu or Settings › Privacy, shown as a sheet
/// on the main window, and closed by the report itself.
@Reducer
internal struct ProblemReportPresentation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		// Here rather than in AppFeature's chain, which is at the type checker's limit.
		EmptyReducer()
			.ifLet(\.problemReport, action: \.problemReport) { ProblemReportFeature() }

		Pullback(\.ui.reportProblem) { state in
			state.presentProblemReport()
		}

		Pullback(\.settings.delegate.reportProblem) { state in
			state.presentProblemReport()
		}

		Pullback(\.problemReport.delegate.close) { state in
			state.problemReport = nil
			return .none
		}

		// The report is filed on GitHub, in a tab next to the person's others. Arx comes back in
		// front of Finder, which the report's file was just shown in, and the sheet stays to say
		// where that file is until Done.
		Pullback(\.problemReport.delegate.openIssue) { state, url in
			guard state.openMainWindow()
			else { return .none }

			state.appActivationRequest += 1
			state.focusedWindowID = state.main.id
			return .merge(
				.send(.main(.ui(.openInNewTab(url)))),
				// A report file may have been saved: Settings › Privacy's Remove counts it.
				.send(.settings(.ui(.loadDiagnostics)))
			)
		}
	}
}

extension AppFeature.State {
	/// A report already open keeps what was typed. The sheet lives on the main window, so a
	/// closed main window opens; while launch onboarding holds it back, the report shows when it opens.
	fileprivate mutating func presentProblemReport() -> Effect<AppFeature.Action> {
		if problemReport == nil { problemReport = .init() }
		openMainWindow()
		return .none
	}
}
