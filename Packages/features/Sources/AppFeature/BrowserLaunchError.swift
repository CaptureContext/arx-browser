import Foundation

internal enum BrowserLaunchError: Error {
	case invalidWorkspace
	case unexpectedReopenWindow
	case shortcutValidationFailed(String)
	case profileIsolationFailed(String)
	case historyValidationFailed(String)
	case splitValidationFailed(String)
	case peekValidationFailed(String)
	case rendererFailureNotReported
	case rendererRecoveryFailed
}
