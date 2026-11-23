import AppUI
import BrowserCore
import BrowserExtensionsClient

internal enum ExtensionsPresentation {
	internal static func message(_ failure: BrowserExtensionsClient.Failure) -> String {
		switch failure {
		case .unavailable: String.localized(.appUI.extensions.unavailable)
		case .missingProfile: String.localized(.appUI.extensions.missingProfile)
		case .staleInventory: String.localized(.appUI.extensions.stale)
		case .blockedByPolicy: String.localized(.appUI.extensions.policy)
		case .reviewRequired: String.localized(.appUI.extensions.permissionReview)
		case .busy: String.localized(.appUI.extensions.busy)
		case .timeout: String.localized(.appUI.extensions.timeout)
		case .limitExceeded: String.localized(.appUI.extensions.limit)
		case .cancelled: String.localized(.appUI.extensions.cancelled)
		case .invalidPackage: String.localized(.appUI.extensions.invalidPackage)
		case .sourceChanged: String.localized(.appUI.extensions.sourceChanged)
		case .directoryMissing: String.localized(.appUI.extensions.directoryMissing)
		case .directoryUnreadable: String.localized(.appUI.extensions.directoryUnreadable)
		case let .invalidManifest(detail) where detail.isEmpty: String.localized(.appUI.extensions.invalidManifest)
		case let .invalidManifest(detail): String.localized(.appUI.extensions.invalidManifestDetail(detail))
		case .upToDate: String.localized(.appUI.extensions.upToDate)
		case .failed, .invalidRequest, .invalidResponse: String.localized(.appUI.extensions.failed)
		}
	}

	/// DEV-776. What a finished Check for Updates did.
	internal static func updateCheck(_ result: ExtensionsFeature.UpdateCheckResult) -> String {
		var lines: [String] = []
		if result.updated > 0 {
			lines.append(String.localized(.appUI.extensions.updatesInstalled(result.updated)))
		}
		if result.declined > 0 {
			lines.append(String.localized(.appUI.extensions.updatesSkipped(result.declined)))
		}

		// "Up to date" only when nothing newer turned up and nothing failed.
		if lines.isEmpty, result.failed == 0 {
			lines.append(String.localized(.appUI.extensions.updatesCurrent))
		}
		if result.failed > 0 {
			lines.append(String.localized(.appUI.extensions.updatesFailed(result.failed)))
		}
		return lines.joined(separator: " ")
	}

	internal static func state(_ state: BrowserExtension.State) -> String {
		switch state {
		case .enabled: String.localized(.appUI.extensions.enabled)
		case .disabled: String.localized(.appUI.extensions.disabled)
		case .terminated: String.localized(.appUI.extensions.terminated)
		case .blocked: String.localized(.appUI.extensions.blocked)
		case .blocklisted: String.localized(.appUI.extensions.blocklisted)
		}
	}

	internal static func location(_ value: Int) -> String {
		switch value {
		case 1: String.localized(.appUI.extensions.installed)
		case 2, 3, 6: String.localized(.appUI.extensions.external)
		case 4, 8: String.localized(.appUI.extensions.developer)
		case 5, 10: String.localized(.appUI.extensions.component)
		case 7, 9: String.localized(.appUI.extensions.managed)
		default: String.localized(.appUI.extensions.unknownLocation(value))
		}
	}

	internal static func reason(_ value: BrowserExtension.DisableReason) -> String {
		switch value.rawValue {
		case 1: String.localized(.appUI.extensions.userDisabled)
		case 1 << 1: String.localized(.appUI.extensions.permissionReview)
		case 1 << 2: String.localized(.appUI.extensions.reloading)
		case 1 << 3: String.localized(.appUI.extensions.unsupportedRequirement)
		case 1 << 8: String.localized(.appUI.extensions.notVerified)
		case 1 << 10: String.localized(.appUI.extensions.corrupted)
		case 1 << 16: String.localized(.appUI.extensions.policy)
		case 1 << 23, 1 << 24: String.localized(.appUI.extensions.unsupportedManifest)
		default: String.localized(.appUI.extensions.unknownReason(value.rawValue))
		}
	}
}
