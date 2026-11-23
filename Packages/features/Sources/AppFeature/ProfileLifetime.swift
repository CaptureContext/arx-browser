import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// Loads profiles when something first needs them and lets them go when nothing has for a
/// while (DEV-880).
///
/// Launch prepares only the profiles its windows show, and a window that switches to another
/// profile prepares that one (`preparingShownProfiles`). Others load the first time a window,
/// page, download, Settings sheet or assistant needs one. Every sweep, the engine releases the
/// loaded profiles that nothing has used for the grace period (``ProfileRelease``); the app
/// names what it uses (``AppFeature/State/profilesInUse``) and the engine adds its pages,
/// downloads and work in flight.
@Reducer
internal struct ProfileLifetime {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.continuousClock)
	private var clock

	private enum Cancellation: Hashable { case sweep }

	internal var body: some ReducerOf<Self> {
		Pullback(\.startProfileRelease) { state, release in
			let shown = state.profilesShownInWindows

			return .run { @MainActor [engine, clock] send in
				for profile in shown.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
					try? await engine.prepareProfile(profile)
				}
				for await _ in clock.timer(interval: release.sweepInterval) {
					send(.releaseIdleProfiles(release))
				}
			}
			.cancellable(id: Cancellation.sweep, cancelInFlight: true)
		}

		Pullback(\.releaseIdleProfiles) { state, release in
			let used = state.profilesInUse

			return .run { @MainActor [engine] _ in
				_ = engine.releaseIdleProfiles(used, release.gracePeriod)
			}
		}
	}
}

extension Reducer where State == AppFeature.State {
	/// Prepares a profile as soon as a window shows it, as launch does for the shown ones, so a
	/// space without an open page still gets what its profile provides, such as site icons.
	internal func preparingShownProfiles() -> some Reducer<State, Action> {
		onChange(of: { $0.profilesShownInWindows }, reduce: { _, previous, current in
			let shown = current.subtracting(previous)
			guard !shown.isEmpty else { return .none }

			@Dependency(\.browserEngine)
			var engine

			return .run { @MainActor [engine] _ in
				for profile in shown.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
					try? await engine.prepareProfile(profile)
				}
			}
		})
	}
}

extension AppFeature.State {
	/// The ordinary profiles open windows show.
	internal var profilesShownInWindows: Set<Profile.ID> {
		var profiles: Set<Profile.ID> = []
		if windowIsOpen, !main.isPrivate { profiles.insert(main.sidebar.space.profileID) }
		for window in windows where !window.isPrivate {
			profiles.insert(window.sidebar.space.profileID)
		}
		return profiles.intersection(workspace.profiles.ids)
	}

	/// The ordinary profiles the app shows or works in now (DEV-880).
	///
	/// Windows, Little Arx and peeks show theirs. A Settings sheet holds listings only its
	/// profile's engine can answer. A private window's downloads follow the profile that opened
	/// it. An assistant turn and a password save prompt work in theirs. Pages, downloads and
	/// engine work are the engine's to add.
	internal var profilesInUse: Set<Profile.ID> {
		var profiles: Set<Profile.ID> = profilesShownInWindows
		profiles.formUnion(littleWindows.map(\.tab.profileID))
		profiles.formUnion(peeks.map(\.tab.profileID))
		profiles.formUnion(privateProfileOpeners.values)

		if let sheet = settings.savedPasswords { profiles.insert(sheet.profileID) }
		if let sheet = settings.siteSettings { profiles.insert(sheet.profileID) }
		if let sheet = settings.clearBrowsingData { profiles.insert(sheet.profileID) }
		if settings.extensions.isPresented, let profile = settings.extensions.profile {
			profiles.insert(profile.id)
		}

		for chat in chats where !chat.turns.isEmpty {
			profiles.insert(chat.id)
		}
		if
			let offer = automation.passwordSave,
			let tab = workspace.tabs[id: offer.tabID]
		{
			profiles.insert(tab.profileID)
		}

		return profiles.intersection(workspace.profiles.ids)
	}
}

extension ProfileRelease {
	/// The environment variable a Debug run reads the grace period from, in whole seconds, so a
	/// smoke needn't wait a minute.
	internal static let gracePeriodVariable: String = "ARX_PROFILE_RELEASE_GRACE_SECONDS"

	/// The default grace period, or in a Debug run the one the environment sets.
	internal static func configured(environment: [String: String]) -> Self {
		#if DEBUG
		if
			let value = environment[gracePeriodVariable].flatMap(Int.init),
			(1...3600).contains(value)
		{
			return .init(gracePeriod: .seconds(value))
		}
		#endif
		return .init()
	}
}
