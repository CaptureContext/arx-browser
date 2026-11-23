import Foundation
import _ComposableArchitecture

/// Launch onboarding holds the main window back until it ends (DEV-838), and until the
/// provisional Default profile is settled (DEV-841).
///
/// Every path that would open the main window goes through `openMainWindow()`. While the
/// window is held it brings onboarding forward instead; links routed into Arx wait in the
/// route queue and open once the window appears.
extension AppFeature.State {
	/// Opens the main window, or brings onboarding forward while launch onboarding holds it back.
	/// Returns whether the main window is open.
	@discardableResult
	internal mutating func openMainWindow() -> Bool {
		guard !mainWindowWaitsForOnboarding else {
			bringOnboardingForward()
			return false
		}

		windowIsOpen = true
		return true
	}

	/// Raises the onboarding window and activates Arx, if onboarding is open.
	internal mutating func bringOnboardingForward() {
		guard onboarding != nil else { return }

		onboardingFocusRequest += 1
	}

	/// Opens the main window held back for launch onboarding, if it was, and opens the links
	/// that arrived meanwhile. Its task already started at launch, so only the window opens.
	internal mutating func revealMainWindowAfterOnboarding() -> Effect<AppFeature.Action> {
		guard mainWindowWaitsForOnboarding else { return .none }

		mainWindowWaitsForOnboarding = false
		if !windowIsOpen {
			windowIsOpen = true
			focusedWindowID = main.id
		}
		return .send(.processRouteQueue)
	}
}
