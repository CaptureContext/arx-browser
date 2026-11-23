import DiagnosticsClient
import FeedbackFeature
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

@testable import AppFeature

/// Settings › Privacy and Help › Report a Problem… (DEV-887).
@Suite(.dependencies)
@MainActor
internal struct PrivacySettingsTests {
	nonisolated private static let kept: DiagnosticsClient.Status = .init(crashReports: 2)

	private static func settings(_ diagnostics: DiagnosticsClient.Status?) -> SettingsFeature.State {
		var state: SettingsFeature.State = .init()
		state.diagnostics = diagnostics
		return state
	}

	// MARK: - Crash reports

	@Test
	internal func launchCollectsAndPrivacyReadsTheStatus() async {
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.diagnostics.collect = { Self.kept }
			$0.diagnostics.status = { Self.kept }
		}

		await store.send(.ui(.startDiagnostics))
		await store.receive(\.event.diagnosticsChanged) { $0.diagnostics = Self.kept }
		await store.send(.ui(.loadDiagnostics))
		await store.receive(\.event.diagnosticsChanged)
	}

	@Test
	internal func removingKeptReports() async {
		let store = TestStore(initialState: Self.settings(Self.kept)) {
			SettingsFeature()
		} withDependencies: {
			$0.diagnostics.removeCrashReports = { .init() }
		}

		await store.send(.ui(.removeCrashReports))
		await store.receive(\.event.diagnosticsChanged) { $0.diagnostics = .init() }

		// Nothing left: nothing to remove.
		await store.send(.ui(.removeCrashReports))

		// Only a saved problem report file: Remove still deletes it.
		let files = TestStore(initialState: Self.settings(.init(problemReports: 1))) {
			SettingsFeature()
		} withDependencies: {
			$0.diagnostics.removeCrashReports = { .init() }
		}
		await files.send(.ui(.removeCrashReports))
		await files.receive(\.event.diagnosticsChanged) { $0.diagnostics = .init() }
	}

	// MARK: - Report a Problem

	nonisolated private static let details: ProblemReport.Diagnostics = .init(hardwareModel: "Mac16,10", memoryGB: 24, crashReports: [
		.init(id: "c1", date: Date(timeIntervalSince1970: 0), source: .engine, process: "Arx Helper (Renderer)"),
	])

	@Test
	internal func theHelpMenuAndSettingsOpenOneReport() async {
		let organization = IntegrationFeatureTests().fixture()
		var initial: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))

		// The sheet lives on the main window, which opens when it was closed.
		initial.windowIsOpen = false
		let store = TestStore(initialState: initial) { AppFeature() }

		await store.send(.ui(.reportProblem)) {
			$0.problemReport = .init()
			$0.windowIsOpen = true
		}
		await store.send(.problemReport(.ui(.textChanged("Tabs vanish")))) { $0.problemReport?.text = "Tabs vanish" }

		// Settings' button keeps what was typed.
		await store.send(.settings(.ui(.reportProblem)))
		await store.receive(\.settings.delegate.reportProblem)
		await store.send(.problemReport(.ui(.close)))
		await store.receive(\.problemReport.delegate.close) { $0.problemReport = nil }
	}

	@Test
	internal func withoutDiagnosticsTheIssueOpensWithTheDescriptionAndVersions() async {
		let store = TestStore(initialState: ProblemReportFeature.State()) {
			ProblemReportFeature()
		} withDependencies: {
			$0.diagnostics.environment = { .preview }
			$0.diagnostics.diagnostics = { Self.details }
		}

		await store.send(.ui(.task))
		await store.receive(\.event.loaded) {
			$0.environment = .preview
			$0.diagnostics = Self.details
		}

		// Nothing to file without a description.
		#expect(!store.state.canSubmit)
		await store.send(.ui(.openIssue))

		await store.send(.ui(.textChanged("  Tabs vanish  "))) { $0.text = "  Tabs vanish  " }
		await store.send(.ui(.includesDiagnostics(false))) { $0.includesDiagnostics = false }

		// testValue's keep and reveal are unimplemented: no file is saved without diagnostics.
		await store.send(.ui(.openIssue)) { $0.phase = .opened(file: nil) }
		await store.receive(\.delegate.openIssue, GitHubIssue.newIssueURL(
			description: "Tabs vanish",
			environment: .preview,
			attachment: nil
		))

		// Opened: not filed twice, and there's no file to show.
		await store.send(.ui(.openIssue))
		await store.send(.ui(.showFile))
	}

	@Test
	internal func withDiagnosticsTheReportFileIsSavedAndShownFirst() async {
		let kept: LockIsolated<[ProblemReport]> = .init([])
		let revealed: LockIsolated<[URL]> = .init([])
		let file: URL = URL(fileURLWithPath: "/Users/someone/Library/Problem Reports/Arx Problem Report 1.json")
		let store = TestStore(
			initialState: ProblemReportFeature.State(text: "It froze", environment: .preview, diagnostics: Self.details)
		) {
			ProblemReportFeature()
		} withDependencies: {
			$0.diagnostics.keep = { report in
				kept.withValue { $0.append(report) }
				return file
			}
			$0.diagnostics.reveal = { url in revealed.withValue { $0.append(url) } }
		}

		await store.send(.ui(.openIssue)) { $0.phase = .opening }
		await store.receive(\.event.kept) { $0.phase = .opened(file: file) }
		let url: URL = GitHubIssue.newIssueURL(
			description: "It froze",
			environment: .preview,
			attachment: "Arx Problem Report 1.json"
		)
		await store.receive(\.delegate.openIssue, url)
		#expect(kept.value == [.init(description: "It froze", environment: .preview, diagnostics: Self.details)])
		#expect(revealed.value == [file])
		// The address names the file, never its folder.
		#expect(!url.absoluteString.contains("someone"))

		// The sheet stays, naming the file, for someone GitHub can't show the issue to.
		await store.send(.ui(.showFile))
		await store.finish()
		#expect(revealed.value == [file, file])
	}

	@Test
	internal func afterTheIssueOpensTheReportCanStillBeSaved() async {
		let saved: LockIsolated<[URL]> = .init([])
		let url: URL = URL(fileURLWithPath: "/tmp/Arx Problem Report.json")
		let store = TestStore(
			initialState: ProblemReportFeature.State(
				text: "It froze", includesDiagnostics: false, environment: .preview, phase: .opened(file: nil)
			)
		) {
			ProblemReportFeature()
		} withDependencies: {
			$0.diagnostics.save = { _, url in saved.withValue { $0.append(url) } }
		}

		await store.send(.ui(.save(url)))
		await store.receive(\.event.saveFinished) { $0.phase = .saved }
		#expect(saved.value == [url])
	}

	@Test
	internal func aFailedSaveSaysWhyAndKeepsTheText() async {
		// The file is saved only once the test lets it, so Close lands mid-save.
		let (gate, open) = AsyncStream<Void>.makeStream()
		let store = TestStore(
			initialState: ProblemReportFeature.State(text: "It froze", environment: .preview, diagnostics: Self.details)
		) {
			ProblemReportFeature()
		} withDependencies: {
			$0.diagnostics.keep = { _ in
				for await _ in gate { break }
				throw CocoaError(.fileWriteOutOfSpace)
			}
		}

		await store.send(.ui(.openIssue)) { $0.phase = .opening }

		// Closing waits for the file, and what's being saved can't change.
		await store.send(.ui(.close))
		await store.send(.ui(.textChanged("Something else")))
		await store.send(.ui(.includesDiagnostics(false)))
		open.yield()
		await store.receive(\.event.keepFailed) {
			$0.phase = .failed(CocoaError(.fileWriteOutOfSpace).localizedDescription)
		}
		await store.send(.ui(.textChanged("It froze twice"))) {
			$0.text = "It froze twice"
			$0.phase = .editing
		}
	}

	@Test
	internal func saveReportWritesWhereThePersonPicked() async {
		let saved: LockIsolated<[(ProblemReport, URL)]> = .init([])
		let url: URL = URL(fileURLWithPath: "/tmp/Arx Problem Report.json")
		let store = TestStore(
			initialState: ProblemReportFeature.State(text: "It froze", environment: .preview, diagnostics: Self.details)
		) {
			ProblemReportFeature()
		} withDependencies: {
			$0.diagnostics.save = { report, url in saved.withValue { $0.append((report, url)) } }
		}

		await store.send(.ui(.save(url)))
		await store.receive(\.event.saveFinished) { $0.phase = .saved }
		#expect(saved.value.first?.0.diagnostics == Self.details)
		#expect(saved.value.first?.1 == url)
		// Saved: the issue isn't opened from a finished report.
		await store.send(.ui(.openIssue))
	}

	@Test
	internal func openingTheIssueClosesTheSheetAndOpensATab() async {
		let organization = IntegrationFeatureTests().fixture()
		var initial: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.problemReport = .init(text: "It froze", includesDiagnostics: false, environment: .preview)
		let store = TestStore(initialState: initial) {
			AppFeature()
		} withDependencies: {
			$0.uuid = .incrementing
			$0.diagnostics.status = { .init(problemReports: 1) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let url: URL = GitHubIssue.newIssueURL(description: "It froze", environment: .preview, attachment: nil)
		await store.send(.problemReport(.ui(.openIssue)))
		await store.receive(\.problemReport.delegate.openIssue) {
			$0.problemReport?.phase = .opened(file: nil)

			// Arx comes back in front of Finder.
			$0.appActivationRequest = 1
			$0.focusedWindowID = $0.main.id
		}
		await store.receive(\.main.ui.openInNewTab, url)

		// Settings › Privacy counts the report file that may have been saved.
		await store.receive(\.settings.event.diagnosticsChanged) { $0.settings.diagnostics = .init(problemReports: 1) }
		await store.skipReceivedActions()
	}

	@Test
	internal func aDescriptionTooLongForTheAddressIsSavedEvenWithoutDiagnostics() async {
		let kept: LockIsolated<[ProblemReport]> = .init([])
		let long: String = String(repeating: "Вкладки зникають. ", count: 400)
		let store = TestStore(
			initialState: ProblemReportFeature.State(text: long, includesDiagnostics: false, environment: .preview, diagnostics: Self.details)
		) {
			ProblemReportFeature()
		} withDependencies: {
			$0.diagnostics.keep = { report in
				kept.withValue { $0.append(report) }
				return URL(fileURLWithPath: "/tmp/Arx Problem Report 2.json")
			}
			$0.diagnostics.reveal = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.openIssue)) { $0.phase = .opening }
		await store.receive(\.event.kept) { $0.phase = .opened(file: URL(fileURLWithPath: "/tmp/Arx Problem Report 2.json")) }
		await store.receive(\.delegate.openIssue)

		// The whole description, and no diagnostics: they were turned off.
		#expect(kept.value.first?.description == ProblemReport.trimmedDescription(long))
		#expect(kept.value.first?.diagnostics == nil)
	}
}
