import AppUI
import Foundation

internal struct ProfileRetirementLaunchError: LocalizedError {
	internal init() {}

	internal var errorDescription: String? {
		String.localized(.appUI.retirement.recoveryRequired)
	}
}
