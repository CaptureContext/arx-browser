import DiagnosticsClient
import Foundation
import _ComposableArchitecture

/// Help › Report a Problem… (DEV-887): a description, the versions, and diagnostics when the
/// person leaves Include diagnostics on. Open Issue on GitHub opens the Arx repository's new
/// issue page prefilled with the description and versions; with diagnostics, it first saves a
/// report file and selects it in Finder for the person to attach. Save Report… writes the same
/// report where the person picks. Arx itself sends nothing.
@Reducer
public struct ProblemReportFeature {
	@ObservableState
	public struct State: Equatable, Sendable {
		public var text: String
		public var includesDiagnostics: Bool

		/// The versions every report names; `nil` until read.
		public var environment: DiagnosticsEnvironment?

		/// What Include diagnostics adds; `nil` until read.
		public var diagnostics: ProblemReport.Diagnostics?
		public var phase: Phase

		public init(
			text: String = "",
			includesDiagnostics: Bool = true,
			environment: DiagnosticsEnvironment? = nil,
			diagnostics: ProblemReport.Diagnostics? = nil,
			phase: Phase = .editing
		) {
			self.text = text
			self.includesDiagnostics = includesDiagnostics
			self.environment = environment
			self.diagnostics = diagnostics
			self.phase = phase
		}

		public enum Phase: Equatable, Sendable {
			case editing

			/// Saving the report file before the issue page opens.
			case opening
			case saved

			/// The issue page opened in a new tab; the report file, when one was saved, is named
			/// with its folder, since the page can't open for someone the repository isn't open to.
			case opened(file: URL?)
			case failed(String)
		}

		/// The report as it would be filed now, or `nil` while there's no description or versions yet.
		public var report: ProblemReport? {
			guard
				let environment,
				let description = ProblemReport.trimmedDescription(text)
			else { return nil }

			return .init(
				description: description,
				environment: environment,
				diagnostics: includesDiagnostics ? diagnostics : nil
			)
		}

		public var canSubmit: Bool {
			report != nil && phase != .opening
		}

		public var isFinished: Bool {
			switch phase {
			case .saved, .opened: true
			case .editing, .opening, .failed: false
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
			/// The sheet appeared: reads the versions and the diagnostics.
			case task
			case textChanged(String)
			case includesDiagnostics(Bool)

			/// Open Issue on GitHub.
			case openIssue

			/// Show in Finder, for the report file saved for the issue.
			case showFile

			/// Save Report… after the person picked where.
			case save(URL)

			/// Cancel, Done, or Escape.
			case close
		}

		@CasePathable
		public enum Event: Sendable {
			case loaded(DiagnosticsEnvironment, ProblemReport.Diagnostics)

			/// The report file for the issue was saved and selected in Finder.
			case kept(ProblemReport, file: URL)
			case keepFailed(String)
			case saveFinished(String?)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case close

			/// Open the prefilled new issue page; the report is done.
			case openIssue(URL)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.diagnostics)
	private var diagnostics

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.task) { _ in
			.run { [diagnostics] send in

				// Collects this session's crash reports too.
				let details: ProblemReport.Diagnostics = await diagnostics.diagnostics()
				await send(.event(.loaded(diagnostics.environment(), details)))
			}
		}

		Pullback(\.event.loaded) { state, loaded in
			let (environment, details) = loaded
			state.environment = environment
			state.diagnostics = details
			return .none
		}

		Pullback(\.ui.textChanged) { state, text in

			// What's being saved is fixed; the form is locked until it's done.
			guard state.phase != .opening
			else { return .none }

			state.text = text
			if case .failed = state.phase { state.phase = .editing }
			return .none
		}

		Pullback(\.ui.includesDiagnostics) { state, isOn in
			guard state.phase != .opening
			else { return .none }

			state.includesDiagnostics = isOn
			return .none
		}

		Pullback(\.ui.openIssue) { state in
			guard state.canSubmit, !state.isFinished, let report = state.report
			else { return .none }

			// A file goes with the issue for diagnostics, or for a description too long for the
			// address, so nothing the person wrote is lost.
			guard
				report.diagnostics != nil
					|| !GitHubIssue.fits(description: report.description, environment: report.environment)
			else {
				state.phase = .opened(file: nil)
				return .send(.delegate(.openIssue(Self.issueURL(report, file: nil))))
			}

			state.phase = .opening
			return .run { [diagnostics] send in
				do {
					let file: URL = try await diagnostics.keep(report)

					// Finder first, so the issue page opens with the file ready to drag in.
					await diagnostics.reveal(file)
					await send(.event(.kept(report, file: file)))
				} catch {
					await send(.event(.keepFailed(error.localizedDescription)))
				}
			}
		}

		Pullback(\.event.kept) { state, kept in
			let (report, file) = kept
			state.phase = .opened(file: file)
			return .send(.delegate(.openIssue(Self.issueURL(report, file: file))))
		}

		Pullback(\.ui.showFile) { state in
			guard case let .opened(file?) = state.phase
			else { return .none }

			return .run { [diagnostics] _ in await diagnostics.reveal(file) }
		}

		Pullback(\.event.keepFailed) { state, reason in
			state.phase = .failed(reason)
			return .none
		}

		Pullback(\.ui.save) { state, url in

			// Also after the issue opened, for someone GitHub doesn't show it to.
			guard state.canSubmit, state.phase != .saved, let report = state.report
			else { return .none }

			return .run { [diagnostics] send in
				do {
					try await diagnostics.save(report, url)
					await send(.event(.saveFinished(nil)))
				} catch {
					await send(.event(.saveFinished(error.localizedDescription)))
				}
			}
		}

		Pullback(\.event.saveFinished) { state, failure in
			state.phase = failure.map(State.Phase.failed) ?? .saved
			return .none
		}

		Pullback(\.ui.close) { state in

			// A report file being saved finishes first.
			guard state.phase != .opening
			else { return .none }

			return .send(.delegate(.close))
		}
	}

	/// The new issue page names the report file, never its folder.
	private static func issueURL(
		_ report: ProblemReport,
		file: URL?
	) -> URL {
		GitHubIssue.newIssueURL(
			description: report.description,
			environment: report.environment,
			attachment: file?.lastPathComponent
		)
	}
}
