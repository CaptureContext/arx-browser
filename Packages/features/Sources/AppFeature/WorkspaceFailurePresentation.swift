import AppUI
import BrowserCore
import BrowserWorkspaceClient
import Foundation
import OSLog

/// Workspace storage reports structured failures; the interface owns their wording.
internal enum WorkspaceFailurePresentation {
	internal static func message(for error: any Error) -> String {
		if let failure = error as? BrowserWorkspaceClient.Failure {
			return self.message(for: failure)
		}
		if let failure = error as? BrowserProfileRetirementStore.Failure {
			return self.message(for: failure)
		}

		// The case and its IDs are for the log; the person reads a sentence (DEV-1261).
		if let failure = error as? BrowserOrganization.ValidationError {
			log.error("Workspace save refused: \(String(describing: failure), privacy: .public)")
			return String.localized(.appUI.persistence.failure.invalidOrganization)
		}
		return error.localizedDescription
	}

	internal static func message(for failure: BrowserWorkspaceClient.Failure) -> String {
		switch failure {
		case let .unsupportedVersion(version):
			String.localized(.appUI.persistence.failure.unsupportedVersion(version))
		case .unsupportedOrganization:
			String.localized(.appUI.persistence.failure.unsupportedOrganization)
		case .changedOnDisk:
			String.localized(.appUI.persistence.failure.changedOnDisk)
		case .synchronizationFailed:
			String.localized(.appUI.persistence.failure.synchronizationFailed)
		}
	}

	internal static func message(for failure: BrowserProfileRetirementStore.Failure) -> String {
		switch failure {
		case .ownershipChanged: String.localized(.appUI.retirement.failure.ownershipChanged)
		case .corrupt: String.localized(.appUI.retirement.failure.corrupt)
		case .busy: String.localized(.appUI.retirement.failure.busy)
		case .io: String.localized(.appUI.retirement.failure.io)
		case .limit: String.localized(.appUI.retirement.failure.limit)
		}
	}
}

private let log: Logger = .init(subsystem: "dev.capturecontext.arx", category: "Workspace")
