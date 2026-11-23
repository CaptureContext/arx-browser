import AppKit
import AppUI
import DiagnosticsClient
import SwiftUI
import UniformTypeIdentifiers
import _ComposableArchitecture

/// The Report a Problem sheet: what happened, Include diagnostics with exactly what it adds,
/// the versions filled in on the issue, then Save Report… and Open Issue on GitHub.
public struct ProblemReportView: View {
	@Bindable
	private var store: StoreOf<ProblemReportFeature>

	public init(store: StoreOf<ProblemReportFeature>) {
		self.store = store
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(localized: .appUI.reportProblem.title)
				.font(.title2.weight(.semibold))
				.accessibilityAddTraits(.isHeader)
			if store.isFinished {
				finished
			} else {
				form
			}
		}
		.padding(20)
		.frame(width: 520)
		.task { store.send(.ui(.task)) }
	}

	// MARK: - Form

	private var form: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(localized: .appUI.reportProblem.message)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			TextEditor(text: Binding(get: { store.text }, set: { store.send(.ui(.textChanged($0))) }))
				.font(.body)
				.frame(height: 140)
				.scrollContentBackground(.hidden)
				.padding(6)
				.background(.background.secondary, in: .rect(cornerRadius: 8))
				.overlay(alignment: .topLeading) {
					if store.text.isEmpty {
						Text(localized: .appUI.reportProblem.placeholder)
							.foregroundStyle(.tertiary)
							.padding(.horizontal, 11)
							.padding(.vertical, 6)
							.allowsHitTesting(false)
					}
				}
				.accessibilityLabel(Text(localized: .appUI.reportProblem.placeholder))
				.disabled(store.phase == .opening)
			Toggle(isOn: Binding(get: { store.includesDiagnostics }, set: { store.send(.ui(.includesDiagnostics($0))) })) {
				VStack(alignment: .leading, spacing: 2) {
					Text(localized: .appUI.reportProblem.includeDiagnostics)
					Text(diagnosticsDetail)
						.font(.callout)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.disabled(store.phase == .opening)
			if let versions {
				Text(localized: .appUI.reportProblem.alwaysIncluded(versions))
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			if case let .failed(reason) = store.phase {
				Text(localized: .appUI.reportProblem.failed(reason))
					.font(.callout)
					.foregroundStyle(.red)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				Button(String.localized(.appUI.reportProblem.cancel)) { store.send(.ui(.close)) }
					.keyboardShortcut(.cancelAction)
				Spacer()
				Button(String.localized(.appUI.reportProblem.save)) { save() }
					.disabled(!store.canSubmit)
				Button(String.localized(.appUI.reportProblem.openIssue)) {
					store.send(.ui(.openIssue))
				}
				.keyboardShortcut(.defaultAction)
				.disabled(!store.canSubmit)
			}
		}
	}

	private var finished: some View {
		VStack(alignment: .leading, spacing: 14) {
			switch store.phase {
			case let .opened(file?):
				Text(localized: .appUI.reportProblem.opened(file.lastPathComponent))
					.fixedSize(horizontal: false, vertical: true)
				Text(file.deletingLastPathComponent().path)
					.font(.callout.monospaced())
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
				Text(localized: .appUI.reportProblem.notOpenYet)
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)

			case .opened(nil):
				Text(localized: .appUI.reportProblem.openedWithoutFile)
					.fixedSize(horizontal: false, vertical: true)
				Text(localized: .appUI.reportProblem.notOpenYetSave)
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)

			default:
				Text(localized: .appUI.reportProblem.saved)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				if case .opened(.some) = store.phase {
					Button(String.localized(.appUI.reportProblem.showInFinder)) { store.send(.ui(.showFile)) }
				}
				if store.phase == .opened(file: nil) {
					Button(String.localized(.appUI.reportProblem.save)) { save() }
				}
				Spacer()
				Button(String.localized(.appUI.reportProblem.done)) { store.send(.ui(.close)) }
					.keyboardShortcut(.defaultAction)
			}
		}
	}

	// MARK: - Text

	private var diagnosticsDetail: String {
		let count: Int = store.diagnostics?.crashReports.count ?? 0
		return String.localized(.appUI.reportProblem.diagnosticsDetail(count.formatted()))
	}

	private var versions: String? {
		guard let environment = store.environment
		else { return nil }

		var parts: [String] = ["Arx \(environment.appVersion) (\(environment.appBuild))"]
		if let engine = environment.engineVersion {
			parts.append("Helium \(engine)" + (environment.chromiumVersion.map { ", Chromium \($0)" } ?? ""))
		}
		parts.append(environment.macOSVersion)
		parts.append(environment.architecture)
		return parts.joined(separator: ", ")
	}

	// MARK: - Saving

	private func save() {
		let panel: NSSavePanel = .init()
		panel.allowedContentTypes = [.json]
		panel.nameFieldStringValue = "Arx Problem Report.json"
		panel.canCreateDirectories = true
		guard panel.runModal() == .OK, let url = panel.url
		else { return }

		store.send(.ui(.save(url)))
	}
}
