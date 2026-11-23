import BrowserCore
import Foundation
import MigrationAssistant
import MigrationAssistantFeature
import OnboardingFeature
import _ComposableArchitecture

/// Owns when onboarding is shown, persists its progress and hands off to the main window.
///
/// Presenting, reopening and dismissing never touch browser sessions. The writes are
/// `OnboardingPreferences.introductionDismissed` when the window first closes or the flow
/// ends, and `completedSteps` when a page reports a finished step, both through the existing
/// preference save path. The first time onboarding ends it also settles the provisional
/// Default profile (DEV-841), which may remove it after an import that made its own profiles.
@Reducer
internal struct OnboardingPresentation {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.presentOnboardingIfNeeded) { state in

			// An onboarding that ended but quit before settling Default finishes that now (DEV-841),
			// and lets a Default held for "Sync with iCloud" sync (DEV-1215).
			guard !state.onboardingProgress.introductionDismissed else {
				return .merge(
					state.releaseProfileHeldForICloud(),
					state.resumeProvisionalProfileSettlement()
				)
			}

			// A Default held for a step this run can't show, or still held after Continue without
			// waiting before a relaunch, syncs again.
			let release: Effect<Action> = state.offersOnboardingICloud && !state.onboardingProgress.isCompleted(.iCloud)
			? .none
			: state.releaseProfileHeldForICloud()
			state.presentOnboarding(.flow)

			// Onboarding comes first on a first launch: the main window opens when it ends (DEV-838).
			if state.windowIsOpen, state.windows.isEmpty {
				state.windowIsOpen = false
				state.mainWindowWaitsForOnboarding = true
			}
			return release
		}

		Pullback(\.ui.openOnboarding) { state in
			state.presentOnboarding(.flow)
			return .none
		}

		Pullback(\.ui.openOnboardingStep) { state, step in
			state.presentOnboarding(.step(step))
			return .none
		}

		Pullback(\.ui.openImport) { state in
			state.presentOnboarding(.step(.migration))
			return .send(.onboarding(.ui(.importData)))
		}

		Pullback(\.ui.closeOnboarding) { state in
			state.dismissOnboarding()
		}

		Pullback(\.onboarding.delegate.dismissed) { state in
			state.dismissOnboarding()
		}

		Pullback(\.onboarding.delegate.handOff) { state, spaceID in
			guard state.onboarding?.canClose == true else { return .none }

			let dismissal: Effect<Action> = state.dismissOnboarding()
			state.onboardingHandOffRequest += 1

			guard
				let spaceID,
				state.main.sidebar.organization.spaces.ids.contains(spaceID),
				state.main.sidebar.spaceID != spaceID
			else { return dismissal }

			return .merge(
				dismissal,
				.send(.main(.sidebar(.ui(.spaceSelected(spaceID)))))
			)
		}

		Pullback(\.onboarding.delegate.stepCompleted) { state, step in
			guard
				!state.onboardingProgress.isCompleted(step),
				!state.profileRetirement.isBusy
			else { return .none }

			state.$onboardingProgress.withLock { $0.complete(step) }
			return state.saveOnboardingPreferences()
		}
	}
}

/// Whether onboarding may open by itself when the app launches.
///
/// Automated test runs, smoke fixtures and headless runs never show it: an extra
/// key window would change what their checks observe. Disposable smoke and fixture
/// profiles always set `ARX_ENGINE_PROFILE`; XCTest sets its configuration path.
internal enum OnboardingLaunchPolicy {
	internal static func presentsAutomatically(
		environment: [String: String],
		isHeadless: Bool
	) -> Bool {
		guard !isHeadless else { return false }

		let automationKeys: [String] = [
			"ARX_ENGINE_PROFILE",
			"ARX_SKIP_ONBOARDING",
			"XCTestConfigurationFilePath",
			"XCTestBundlePath",
			"XCTestSessionIdentifier",
		]
		return automationKeys.allSatisfy { environment[$0] == nil }
	}
}

extension AppFeature.State {
	fileprivate mutating func presentOnboarding(_ mode: OnboardingFeature.Mode) {
		if onboarding == nil {
			// The main window's current space is the default place for imports that
			// don't get new profiles; the other spaces can be chosen while reviewing.
			onboarding = .init(
				mode: mode,
				completedSteps: onboardingProgress.completedSteps,
				destination: .init(
					profileID: main.sidebar.space.profileID,
					spaceID: main.sidebar.spaceID
				),
				spaceOptions: migrationSpaceOptions,
				existingData: migrationExistingData,
				offersICloud: mode == .flow && offersOnboardingICloud,
				// A relaunch partway through keeps what the step decided (DEV-1215).
				iCloudResolution: onboardingProgress.adoptedICloudWorkspace ? .adopted(lastUsedSpaceID: nil) : nil
			)
		} else {
			// Reopened, maybe after an import: offer to clear what Arx holds now (DEV-833).
			refreshMigrationExistingData()
		}
		onboardingFocusRequest += 1
	}

	fileprivate mutating func dismissOnboarding() -> Effect<AppFeature.Action> {
		// An import that may be committing keeps the window open until it ends.
		guard let current = onboarding, current.canClose else { return .none }

		onboarding = nil

		// Only the import, iCloud, outside-agents and default-browser pages start work that outlives
		// an action.
		let cancellation: Effect<AppFeature.Action> = current.page.migration == nil
		&& current.page.iCloud == nil
		&& current.page.outsideAgents == nil
		&& current.page.defaultBrowser == nil
		? .none
		: OnboardingFeature.cancelInFlightWork()

		// "Sync with iCloud" didn't decide: Default syncs again (DEV-1215).
		let release: Effect<AppFeature.Action> = releaseProfileHeldForICloud()

		// Preference writes are paused while a profile is retired; the window still
		// closes and onboarding is offered again on the next launch.
		guard
			!onboardingProgress.introductionDismissed,
			!profileRetirement.isBusy
		else {
			// Opened in the same change, so the hand-off can grow onboarding into it (DEV-838).
			return .merge(cancellation, release, revealMainWindowAfterOnboarding())
		}

		$onboardingProgress.withLock {
			$0.introductionDismissed = true
			$0.adoptedICloudWorkspace = false
		}

		// The first onboarding decides whether the provisional Default profile stays (DEV-841).
		// While its checks run the main window stays held, so nothing done in it can race them;
		// ProvisionalProfileSettlement opens it once Default is settled.
		// An adoption of iCloud's workspace still waiting for its read removes Default itself
		// (DEV-1215): Default stays provisional until then, and the window opens now.
		let adopting: Bool = iCloudAdoption != nil
		if current.importWasShown {
			iCloudAdoption?.importWasShown = true
		}
		let settlement: Effect<AppFeature.Action> = adopting ? .none : settleProvisionalProfile()
		let reveal: Effect<AppFeature.Action> = onboardingProgress.provisionalProfile == nil || adopting
		? revealMainWindowAfterOnboarding()
		: .none
		return .merge(cancellation, release, saveOnboardingPreferences(), settlement, reveal)
	}

	fileprivate mutating func saveOnboardingPreferences() -> Effect<AppFeature.Action> {
		unsavedOrganization = workspace
		return .send(.delegate(.save(workspace)))
	}
}
