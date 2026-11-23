import BrowserCore
import BrowserEngineClient
import BrowserExtensionsClient
import BrowserHistoryClient
import Foundation
import _ComposableArchitecture

private enum ProvisionalProfileInspection: Hashable {
	case check
	case timeout
}

extension DependencyValues {
	/// How long the provisional profile's checks may hold the main window back (DEV-841).
	internal var provisionalProfileTimeout: Duration {
		get { self[ProvisionalProfileTimeoutKey.self] }
		set { self[ProvisionalProfileTimeoutKey.self] = newValue }
	}
}

private enum ProvisionalProfileTimeoutKey: DependencyKey {
	internal static let liveValue: Duration = .seconds(5)
	internal static let testValue: Duration = .seconds(5)
}

@CasePathable
public enum ProvisionalProfileAction: Sendable {
	/// The provisional profile's history, saved passwords and extensions were checked once onboarding
	/// ended, or the checks ran out of time (`isUntouched` false).
	case inspected(ProvisionalProfile, isUntouched: Bool)
}

/// Settles the first launch's provisional Default profile when onboarding ends (DEV-841).
///
/// If an import in this onboarding made profiles of its own and Default is still exactly as
/// the first launch made it, Default's space and then the profile are removed through the
/// same organization changes Settings uses, so only the imported profiles remain. Otherwise
/// Default stays and stops being provisional. A profile holding anything the user added is
/// never removed.
@Reducer
internal struct ProvisionalProfileSettlement {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		// Default stays provisional only while the user does nothing but onboarding. Chats,
		// routing rules, download and site settings and the like live outside the workspace,
		// where the pristine check can't see them, so any activity outside onboarding makes
		// Default theirs at once rather than checking each store.
		Reduce { state, action in
			guard
				state.onboardingProgress.provisionalProfile != nil,
				action.isActivityOutsideOnboarding
			else { return .none }

			state.$onboardingProgress.withLock { $0.provisionalProfile = nil }
			return state.saveWorkspace()
		}

		Pullback(\.provisionalProfile.inspected) { state, value in
			let (provisional, isUntouched) = value

			// The main window held back while the checks ran opens whatever they decide (DEV-838).
			let reveal: Effect<Action> = .merge(
				.cancel(id: ProvisionalProfileInspection.check),
				.cancel(id: ProvisionalProfileInspection.timeout),
				state.revealMainWindowAfterOnboarding()
			)
			guard state.onboardingProgress.provisionalProfile == provisional
			else { return reveal }

			state.$onboardingProgress.withLock { $0.provisionalProfile = nil }
			let save: Effect<Action> = .merge(state.saveWorkspace(), reveal)
			let imported = provisional.importedProfiles(in: state.workspace, ledger: state.migrationLedger)
			let replacement = state.workspace.spaces.first { imported.contains($0.profileID) }
			guard
				isUntouched,
				let replacement,
				provisional.isPristine(in: state.workspace, ledger: state.migrationLedger),
				!state.profileRetirement.isBusy,
				!state.littleWindows.contains(where: { $0.tab.profileID == provisional.profileID }),
				!state.peeks.contains(where: { $0.tab.profileID == provisional.profileID })
			else { return save }

			// The window opens in an imported space: Default's goes in the same change.
			if state.main.sidebar.spaceID == provisional.spaceID {
				state.main.sidebar.selectSpace(replacement.id)
			}

			// A space with no tabs commits at once, so the profile has no space by the time
			// its own removal is applied. Arx removes it, so it isn't a step for ⌘Z (DEV-1030).
			state.unrecordedSpaceRemovals.insert(provisional.spaceID)
			return .concatenate(
				save,
				.send(.settings(.delegate(.changeOrganization(.removeSpace(provisional.spaceID))))),
				.send(.settings(.delegate(.changeOrganization(.removeProfile(provisional.profileID)))))
			)
		}
	}
}

extension AppFeature.State {
	/// Settles a provisional profile left by an onboarding that ended without settling it,
	/// such as one that quit before its checks answered. Sent at launch.
	internal mutating func resumeProvisionalProfileSettlement() -> Effect<AppFeature.Action> {
		guard
			onboardingProgress.introductionDismissed,
			onboardingProgress.provisionalProfile != nil,
			!profileRetirement.isBusy
		else { return .none }

		let settlement: Effect<AppFeature.Action> = settleProvisionalProfile()
		guard onboardingProgress.provisionalProfile == nil else { return settlement }

		return .merge(settlement, saveWorkspace())
	}

	/// Ends the provisional state of the first launch's Default profile, if it's still provisional.
	///
	/// Without an import that made profiles of its own, or once Default holds something,
	/// it simply stays; the caller saves the preferences. Otherwise its history, saved passwords
	/// and extensions are checked first, and `ProvisionalProfileSettlement` decides.
	internal mutating func settleProvisionalProfile() -> Effect<AppFeature.Action> {
		guard let provisional = onboardingProgress.provisionalProfile
		else { return .none }

		let imported = provisional.importedProfiles(in: workspace, ledger: migrationLedger)
		guard
			!imported.isEmpty,
			provisional.isPristine(in: workspace, ledger: migrationLedger)
		else {
			$onboardingProgress.withLock { $0.provisionalProfile = nil }
			return .none
		}

		@Dependency(\.browserEngine)
		var engine

		@Dependency(\.browserHistory)
		var history

		@Dependency(\.browserExtensions)
		var extensions

		@Dependency(\.provisionalProfileTimeout)
		var timeout

		// The main window waits for the checks, so after `timeout` Default is settled as
		// holding data even while a check that ignores cancellation is still running; its late
		// answer finds the profile settled and changes nothing.
		return .merge(
			.run { [engine, history, extensions] send in
				let isUntouched = await Self.holdsNoBrowsingData(
					provisional.profileID,
					engine: engine,
					history: history,
					extensions: extensions
				)
				await send(.provisionalProfile(.inspected(provisional, isUntouched: isUntouched)))
			}
			.cancellable(id: ProvisionalProfileInspection.check),
			.run { send in
				try await Task.sleep(for: timeout)
				await send(.provisionalProfile(.inspected(provisional, isUntouched: false)))
			}
			.cancellable(id: ProvisionalProfileInspection.timeout)
		)
	}

	/// Whether the profile has no history, saved passwords or extension the user could remove.
	/// A check that can't answer counts as data, so the profile is kept.
	private static func holdsNoBrowsingData(
		_ profileID: Profile.ID,
		engine: BrowserEngineClient,
		history: BrowserHistoryClient,
		extensions: BrowserExtensionsClient
	) async -> Bool {
		if history.isAvailable {
			guard
				let outcome = try? await history.load(profileID),
				outcome.failure == nil,
				outcome.snapshot.entries.isEmpty
			else { return false }
		}

		// Passwords can be imported into Default before an import makes profiles of its own.
		if await engine.savedPasswordsAreAvailable() {
			guard
				let list = try? await engine.savedPasswords(profileID),
				list.passwords.isEmpty,
				list.neverSaved.isEmpty
			else { return false }
		}
		if await extensions.isAvailable {
			guard let inventory = try? await extensions.inspect(profileID)
			else { return false }

			return !inventory.extensions.contains(where: \.canRemove)
		}
		return true
	}
}

extension AppFeature.Action {
	/// Whether the user did something outside onboarding: opened a window, Little Arx or
	/// Settings, ran a command, edited Settings, used a chat or an agent approval, or routed
	/// a link into Arx. Onboarding's own pages, imports, launch and window lifecycle, and
	/// what reducers send each other don't count. The main window is hidden while launch
	/// onboarding is open, so its actions aren't listed.
	internal var isActivityOutsideOnboarding: Bool {
		switch self {
		case let .ui(action): action.isActivityOutsideOnboarding

		// The Little Arx hotkey.
		case .event(.globalShortcut): true

		case .settings(.ui), .settings(.extensions(.ui)), .settings(.savedPasswords(.ui)),
			.settings(.siteSettings(.ui)), .settings(.clearBrowsingData(.ui)):
			true

		case .windows(.element(_, .ui)), .windows(.element(_, .sidebar(.ui))),
			.windows(.element(_, .commandBar(.ui))):
			true

		case .littleWindows(.element(_, .ui)), .peeks(.element(_, .ui)), .chats(.element(_, .ui)):
			true

		// The chat panel and chat tabs scope their actions to a surface.
		case .chats(.element(_, .surfaces(.element(_, .ui)))):
			true

		case .chat(.allowBrowserTools):
			true

		case .automation(.ui(.approve)), .automation(.ui(.decline)), .automation(.ui(.unattended)),
			.automation(.ui(.unattendedClient)), .automation(.ui(.temporaryGrantWindow)),
			.automation(.ui(.updateClient)), .automation(.ui(.revokeClient)):
			true

		default:
			false
		}
	}
}

extension AppFeature.Action.UI {
	fileprivate var isActivityOutsideOnboarding: Bool {
		switch self {
		case let .command(command, target, _):
			target != .onboarding && command != .onboarding
		case .peekTab, .peekURL, .peekURLFromSource, .dismissPeek, .promotePeek, .copyLinks,
			.shareProxyLinks, .shareLinks, .routeURLs, .openURLInSpace, .chooseRouteDestination,
			.openDownloads, .openMediaLibrary, .toggleMediaMute, .returnToMutedMedia, .setTabMuted,
			.setTabVolume, .capturePage, .capturePageForChat, .pageSetup, .printPage, .savePage,
			.openFile, .pageMenu, .openWindow, .newWindow, .newPrivateWindow, .exportWorkspace,
			.exportBrowserData, .openLittleArx, .openSettings, .openExtensions, .showExtension,
			.reviewExtensionUpdate, .openExtensionOptions, .openSiteSettings:
			true
		default:
			false
		}
	}
}
