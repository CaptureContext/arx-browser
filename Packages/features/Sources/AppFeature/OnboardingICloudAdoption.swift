import BrowserCore
import Foundation
import MigrationAssistantFeature
import OnboardingFeature
import WorkspaceSync
import _ComposableArchitecture

/// The host side of onboarding's "Sync with iCloud" step (DEV-1215).
///
/// A first launch that may offer the step keeps its provisional Default profile on this Mac
/// (`OnboardingPreferences.heldForICloud`, set by BrowserWindow), so turning sync on from the
/// step doesn't upload it. When the step finds a workspace in iCloud, the workspace is read
/// again, and once no read waits Default's space and profile are removed, as an import's settlement
/// does (DEV-841), and the main window opens on the space any Mac used last.
///
/// Continue without waiting keeps Default held while a background wait asks iCloud again
/// (`joinFromOnboarding(false)`, every 30 seconds while it can't be reached), so a starter never
/// uploads beside a workspace iCloud already has: DEV-1216's merge on joining runs only before
/// Profiles and spaces first starts. When the answer comes, a workspace in iCloud is adopted as
/// above while Default is still provisional (onboarding open, nothing done outside it); otherwise
/// Default syncs, and Settings offers to merge profiles of the same name (DEV-1216). A relaunch
/// doesn't wait again: it can't tell what an import put in Default meanwhile, and Default synced
/// later meets iCloud's the same way. Every other outcome, and onboarding ending before the step decides, lets
/// Default sync again: it's the starter iCloud gets, or what sync uploads once it's turned on.
@Reducer
internal struct OnboardingICloudAdoption {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.onboarding.delegate.iCloudResolved) { state, resolution in
			switch resolution {
			case let .adopted(lastUsedSpaceID):
				return state.adoptICloudWorkspace(lastUsedSpaceID: lastUsedSpaceID)

			case .continuedWithoutWaiting:
				return state.waitForICloudInBackground()

			case .empty, .notNow, .unavailable:
				return state.releaseProfileHeldForICloud()
			}
		}

		Pullback(\.event.onboardingICloudFetched) { state, result in
			guard state.waitsForICloudInBackground else { return .none }

			state.waitsForICloudInBackground = false
			guard let result, result.hasWorkspace else { return state.releaseProfileHeldForICloud() }

			return state.adoptICloudWorkspace(lastUsedSpaceID: result.lastUsedSpaceID, inBackground: true)
		}

		// A read that failed left the workspace as it was, which can't tell whether iCloud has spaces:
		// Default stays held, and the read is tried again shortly, or on the next sync change (DEV-1221).
		Pullback(\.event.workspaceSyncReadFailed) { state in
			guard state.iCloudAdoption != nil else { return .none }

			@Dependency(\.continuousClock)
			var clock

			return .run { [clock] send in
				try await clock.sleep(for: ICloudAdoptionRead.retryInterval)
				await send(.event(.workspaceSyncChanged))
			}
			.cancellable(id: ICloudAdoptionRead.retryID, cancelInFlight: true)
		}

		// Composed after WorkspaceSyncReload: by now the action's read ran, or it's waiting for a save
		// or a page's answer, and the main window takes what it read a step later. A read that found
		// nothing new publishes nothing, so this doesn't wait for `workspaceSyncApplied`, only for a
		// read that reached the store (DEV-1221).
		Reduce { state, action in
			if case .onboarding(.delegate(.iCloudResolved)) = action { return .none }
			if case .event(.onboardingICloudFetched) = action { return .none }

			return state.finishICloudAdoption()
		}
	}
}

/// Onboarding's background wait for iCloud after Continue without waiting (DEV-1215).
private enum ICloudBackgroundWait {
	internal static let id: String = "OnboardingICloudAdoption.backgroundWait"
	internal static let retryInterval: Duration = .seconds(30)
}

/// Adoption's read of the workspace database, tried again after a failure (DEV-1221).
private enum ICloudAdoptionRead {
	internal static let retryID: String = "OnboardingICloudAdoption.readRetry"
	internal static let retryInterval: Duration = .seconds(5)
}

/// iCloud's workspace is being adopted, waiting for the read of what the step fetched (DEV-1215).
internal struct ICloudAdoption: Equatable, Sendable {
	/// The space any Mac used last, which the main window opens on when it's there.
	internal var lastUsedSpaceID: Space.ID?

	/// The answer of the background wait after Continue without waiting.
	internal var isLate: Bool = false

	/// Onboarding closed meanwhile after showing its import page.
	internal var importWasShown: Bool = false

	/// A sync reload read the store since adoption began. Until then the workspace may not hold
	/// what the step fetched, and a failed read must not look like an iCloud without spaces
	/// (DEV-1221).
	internal var hasReadStore: Bool = false
}

extension AppFeature.State {
	/// Whether onboarding's flow includes "Sync with iCloud": Default is held back for it and
	/// sync can run here.
	internal var offersOnboardingICloud: Bool {
		@Dependency(\.workspaceSync)
		var sync

		guard onboardingICloudEnabled, let held = onboardingProgress.heldForICloud else { return false }

		return sync.isAvailable() && workspace.profiles[id: held] != nil
	}

	/// Lets the profile held back for "Sync with iCloud" sync again, unless it's already gone,
	/// adoption is about to remove it, or the background wait hasn't heard from iCloud (DEV-1215).
	internal mutating func releaseProfileHeldForICloud() -> Effect<AppFeature.Action> {
		guard
			iCloudAdoption == nil,
			!waitsForICloudInBackground,
			let held = onboardingProgress.heldForICloud
		else { return .none }

		$onboardingProgress.withLock { $0.heldForICloud = nil }
		guard workspace.profiles[id: held]?.isThisMacOnly == true else { return saveWorkspace() }

		return .send(.settings(.delegate(.changeOrganization(.setSyncsWithICloud(held, true)))))
	}

	/// Reads the rows the step fetched, which may not be read yet, and adopts once that lands.
	fileprivate mutating func adoptICloudWorkspace(
		lastUsedSpaceID: UUID?,
		inBackground: Bool = false
	) -> Effect<AppFeature.Action> {
		guard onboardingProgress.heldForICloud != nil else { return .none }

		iCloudAdoption = .init(
			lastUsedSpaceID: lastUsedSpaceID.map(Space.ID.init(rawValue:)),
			isLate: inBackground
		)
		return .send(.event(.workspaceSyncChanged))
	}

	/// Asks iCloud what it has without turning sync on, again every 30 seconds while it can't be
	/// reached, until it answers or sync is turned off.
	fileprivate mutating func waitForICloudInBackground() -> Effect<AppFeature.Action> {
		guard onboardingProgress.heldForICloud != nil else { return .none }

		@Dependency(\.workspaceSync)
		var sync

		@Dependency(\.continuousClock)
		var clock

		waitsForICloudInBackground = true
		return .run { [sync, clock] send in
			while true {
				events: for await event in await sync.joinFromOnboarding(false) {
					switch event {
					case .fetching:
						continue
					case let .finished(result):
						await send(.event(.onboardingICloudFetched(result)))
						return
					case .turnedOff:
						await send(.event(.onboardingICloudFetched(nil)))
						return
					case .unavailable, .failed:
						break events
					}
				}
				try await clock.sleep(for: ICloudBackgroundWait.retryInterval)
			}
		}
		.cancellable(id: ICloudBackgroundWait.id, cancelInFlight: true)
	}

	/// Removes the held Default once iCloud's workspace is read, and opens the space used last.
	fileprivate mutating func finishICloudAdoption() -> Effect<AppFeature.Action> {
		guard let adoption = iCloudAdoption else { return .none }

		// Still waiting: no read reached the store yet, another read is due, or the main window
		// hasn't taken the one that ran.
		guard
			adoption.hasReadStore,
			!syncReloadPending,
			!syncReloadAwaitingApproval,
			main.sidebar.organization == workspace
		else { return .none }

		iCloudAdoption = nil
		guard let held = onboardingProgress.heldForICloud else { return .none }

		let candidates: [Space] = workspace.spaces.filter { $0.profileID != held }
		let replacement: Space? = candidates.first { $0.id == adoption.lastUsedSpaceID } ?? candidates.first
		let provisional: ProvisionalProfile? = onboardingProgress.provisionalProfile

		// Once onboarding showed its import page, an import, of passwords and sign-ins too, may have
		// filled Default in ways the workspace doesn't show, and a visible page would point at a
		// profile that's gone: Default stays. An answer that came after Continue without waiting is
		// adopted only while onboarding is still open.
		let importWasShown: Bool = adoption.importWasShown || onboarding?.importWasShown == true
		guard
			!importWasShown,
			!adoption.isLate || onboarding != nil,
			let replacement,
			let provisional,
			provisional.profileID == held,
			provisional.isPristine(in: workspace, ledger: migrationLedger),
			!profileRetirement.isBusy,
			!littleWindows.contains(where: { $0.tab.profileID == held }),
			!peeks.contains(where: { $0.tab.profileID == held })
		else {
			// Nothing to open from iCloud, or Default holds something now: it stays, and syncs.
			// Onboarding that ended meanwhile left Default's settlement to this.
			let settlement: Effect<AppFeature.Action> = onboarding == nil && onboardingProgress.introductionDismissed
			? settleProvisionalProfile()
			: .none
			return .merge(releaseProfileHeldForICloud(), settlement)
		}

		$onboardingProgress.withLock {
			$0.heldForICloud = nil
			$0.provisionalProfile = nil

			// Only while onboarding is open: its end clears this.
			$0.adoptedICloudWorkspace = onboarding != nil
		}
		main.sidebar.selectSpace(replacement.id)

		// The import page that comes next offers only what iCloud doesn't sync.
		onboarding?.iCloudResolution = .adopted(lastUsedSpaceID: replacement.id.rawValue)

		// The import page brings what iCloud doesn't sync into the space the window opens on.
		let spaceOptions: [MigrationAssistantFeature.SpaceOption] = migrationSpaceOptions.filter { $0.profileID != held }
		onboarding?.updateMigrationTargets(
			destination: .init(profileID: replacement.profileID, spaceID: replacement.id),
			spaceOptions: spaceOptions,
			existingData: nil
		)

		// Arx removes it, so it isn't a step for ⌘Z (DEV-1030).
		unrecordedSpaceRemovals.insert(provisional.spaceID)
		return .concatenate(
			saveWorkspace(),
			.send(.settings(.delegate(.changeOrganization(.removeSpace(provisional.spaceID))))),
			.send(.settings(.delegate(.changeOrganization(.removeProfile(held)))))
		)
	}
}
