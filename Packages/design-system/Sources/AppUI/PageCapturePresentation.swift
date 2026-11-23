import BrowserCore
import Foundation

/// Keeps engine errors language-neutral while the interface uses the shared string catalog.
public enum PageCapturePresentation {
	public static func message(for warning: PageCaptureWarning) -> String {
		switch warning {
		case .protectedMediaMayBeMissing: String.localized(.appUI.capture.protectedMedia)
		}
	}

	public static func message(for error: any Error) -> String {
		guard let failure = error as? PageCaptureFailure
		else { return error.localizedDescription }
		return switch failure {
		case .unavailable: String.localized(.appUI.capture.unavailable)
		case .staleDocument: String.localized(.appUI.capture.staleDocument)
		case .limitExceeded: String.localized(.appUI.capture.limitExceeded)
		case .invalidRegion: String.localized(.appUI.capture.invalidRegion)
		case .invalidImage: String.localized(.appUI.capture.invalidImage)
		case .timedOut: String.localized(.appUI.capture.timedOut)
		case .busy: String.localized(.appUI.capture.busy)
		case .unsupportedRendering: String.localized(.appUI.capture.unsupportedRendering)
		case .encodingFailed: String.localized(.appUI.capture.encodingFailed)
		case .invalidFormat: String.localized(.appUI.capture.invalidFormat)
		}
	}

	/// The note on a Capture Page frame that holds only the visible area.
	public static func visibleAreaMessage(for failure: PageCaptureFailure) -> String {
		switch failure {
		case .limitExceeded: String.localized(.appUI.capture.visibleAreaTooLong)
		default: String.localized(.appUI.capture.visibleAreaUnsupported)
		}
	}

	/// The note on a Capture Page frame cut at the capture's limits (DEV-1172).
	public static func cutMessage(points: Int) -> String {
		String.localized(.appUI.capture.cutAtLimit(points))
	}
}
