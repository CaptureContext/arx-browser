import BrowserCore
import BrowserExtensionsClient
import ExtensionsFeature
import Foundation
import SettingsFeature
import _ComposableArchitecture

/// The Chrome Web Store (DEV-765): the Extensions sheet's button opens it in the
/// sheet's profile, and its Add to Chrome opens that profile's Extensions sheet
/// with the downloaded package up for review.
///
/// Store updates (DEV-776): ten minutes after launch and then every five hours,
/// the store extensions of each profile with an open window are checked. An
/// update that asks for nothing new installs; one that asks for more permissions
/// is left for the Extensions sheet's Check for Updates, which shows its review.
/// With `ARX_EXTENSION_UPDATE_REVIEW` (DEV-1210) such an update is remembered
/// (`ExtensionUpdateReviews`), so the sheet, Settings and the site menu mark it.
@Reducer
internal struct WebstoreRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserExtensions)
	private var extensions

	@Dependency(\.continuousClock)
	private var clock

	private enum Cancellation: Hashable {
		case requests
		case updateSchedule
		case updateCheck
	}

	internal static let firstUpdateCheck: Duration = .seconds(10 * 60)
	internal static let updateCheckInterval: Duration = .seconds(5 * 60 * 60)

	internal var body: some ReducerOf<Self> {
		// Settings › General › Content blocking reaches the engine (DEV-884). Each switch carries
		// its new value; the other comes from state, which that switch doesn't change. BrowserWindow
		// sets the saved values before the engine starts.
		Pullback(\.settings.ui.blocksContent) { state, isOn in
			guard state.settings.contentBlockingAvailable else { return .none }

			return setContentBlocking(.init(isOn: isOn, blocksCookieBanners: state.settings.general.blocksCookieBanners))
		}

		Pullback(\.settings.ui.blocksCookieBanners) { state, blocks in
			guard state.settings.contentBlockingAvailable else { return .none }

			return setContentBlocking(.init(isOn: state.settings.general.blocksContent, blocksCookieBanners: blocks))
		}

		Pullback(\.observeWebstoreInstalls) { _ in
			.run { [extensions] send in
				for await request in await extensions.webstoreInstallRequests() {
					await send(.event(.webstoreInstallRequested(request)))
				}
			}
			.cancellable(id: Cancellation.requests, cancelInFlight: true)
			.merge(with: .run { [clock] send in
				try await clock.sleep(for: Self.firstUpdateCheck)
				while true {
					await send(.event(.webstoreUpdateCheckDue))
					try await clock.sleep(for: Self.updateCheckInterval)
				}
			}
			.cancellable(id: Cancellation.updateSchedule, cancelInFlight: true))
		}

		Pullback(\.event.webstoreUpdateCheckDue) { state in

			// The open sheet runs its own checks; the two would only refuse each other.
			guard !state.shouldQuit, !state.settings.extensions.isPresented else { return .none }

			let profiles = state.webstoreUpdateProfiles
			guard !profiles.isEmpty else { return .none }

			return .run { [extensions] send in
				guard await extensions.isWebstoreUpdateAvailable else { return }

				for profileID in profiles {
					guard !Task.isCancelled else { break }
					let outcome = await Self.updateWebstoreExtensions(of: profileID, client: extensions)
					await send(.event(.webstoreUpdatesChecked(
						profileID,
						needsReview: outcome.needsReview,
						upToDate: outcome.upToDate,
						inventory: outcome.inventory
					)))
				}
				await send(.event(.webstoreUpdateCheckFinished))
			}
			.cancellable(id: Cancellation.updateCheck, cancelInFlight: true)
		}

		// DEV-1210: what one profile's check left for the person's review.
		Pullback(\.event.webstoreUpdatesChecked) { state, value in
			let (profileID, needsReview, upToDate, inventory) = value
			guard
				state.settings.extensions.updateReviewsEnabled,
				state.workspace.profiles[id: profileID] != nil
			else { return .none }

			state.settings.extensions.$updateReviews.withLock { reviews in
				for extensionID in upToDate { reviews.withdrawn(extensionID, in: profileID) }
				for review in needsReview where review.profileID == profileID { reviews.offered(review) }

				// Last, so an offer whose extension changed or went during the check doesn't stay.
				if let inventory, inventory.profileID == profileID { reviews.reconcile(with: inventory) }
			}
			return .none
		}

		Pullback(\.event.webstoreUpdateCheckFinished) { state in

			// An Extensions sheet opened meanwhile may have been refused as busy, with an Add to
			// Chrome request waiting on its inventory. Reloading it shows the updated versions
			// and lets the waiting request go on.
			guard state.settings.extensions.isPresented else { return .none }

			return .send(.settings(.extensions(.ui(.refresh))))
		}

		Pullback(\.event.webstoreInstallRequested) { state, request in
			guard state.workspace.profiles[id: request.profileID] != nil else {
				return .run { [extensions] _ in await extensions.declineWebstoreInstallation(request) }
			}

			// The request must reach the sheet after it is presented for the profile and has
			// started loading that profile's inventory. Sending `.ui(.openExtensions)` here
			// would queue Settings, the profile and the presentation behind the request,
			// which the closed sheet then declined (DEV-801).
			return .concatenate(
				SiteMenuRouting.openExtensions(request.profileID),
				.send(.settings(.extensions(.webstoreRequested(request))))
			)
		}

		Pullback(\.settings.extensions.delegate.openWebstore) { _, profileID in
			.send(.openWebstore(profileID))
		}

		Pullback(\.settings.delegate.openContentBlockingDashboard) { state in

			// DEV-884: uBlock Origin's dashboard is its options page, in the front ordinary
			// window's profile. It opens the way any extension's options do: the URL router
			// takes only web addresses.
			guard let profileID = state.contentBlockingProfile else { return .none }

			return .send(.ui(.openExtensionOptions(profileID, extensionID: BrowserExtension.contentBlockingID)))
		}

		// DEV-1317: the Chrome Web Store opens in a new Little Arx on a space of the profile, in
		// front with the keyboard, wherever it was asked for: the site menu's Add Extension (a main
		// window's or a floating one's), Window › Chrome Web Store and Settings › Extensions. An
		// install from it asks for that profile, as the store page's own profile is the one asked.
		Pullback(\.openWebstore) { state, profileID in
			guard let space = state.webstoreSpace(for: profileID) else { return .none }

			return .send(.ui(.openURLInSpace(BrowserWebstoreInstallRequest.storeURL, space, .littleArx)))
		}
	}
}

extension WebstoreRouting {
	private func setContentBlocking(_ preference: ContentBlockingPreference) -> Effect<Action> {
		let client = extensions
		MainActor.assumeIsolated { client.setContentBlocking(preference.isOn, preference.blocksCookieBanners) }
		return .none
	}

	/// What one profile's automatic check found (DEV-1210).
	internal struct UpdateOutcome: Equatable, Sendable {
		internal var profileID: Profile.ID

		/// The updates it turned down for asking more permissions.
		internal var needsReview: [ExtensionUpdateReviews.Review] = []

		/// The extensions the store had nothing newer for: a mark they had is withdrawn. One whose
		/// check failed isn't here, so its mark stays.
		internal var upToDate: [String] = []

		/// The profile's inventory after the check, or nil when it couldn't be read.
		internal var inventory: BrowserExtensionInventory?
	}

	/// Installs the store updates of one profile that ask for nothing new. Errors skip to
	/// the next extension; nothing here shows UI. Returns the updates it turned down.
	@MainActor
	@discardableResult
	internal static func updateWebstoreExtensions(
		of profileID: Profile.ID,
		client: BrowserExtensionsClient
	) async -> UpdateOutcome {
		var outcome = UpdateOutcome(profileID: profileID)
		guard var inventory = try? await client.inspect(profileID) else { return outcome }
		outcome.inventory = inventory

		let candidates = inventory.extensions
			.filter { $0.fromWebStore && $0.allows(.remove) }
			.map(\.id)

		for extensionID in candidates {
			guard
				!Task.isCancelled,
				inventory.extensions.contains(where: { $0.id == extensionID })
			else { continue }

			do {
				let prompt = try await client.prepareWebstoreUpdate(.init(
					inventory: inventory,
					extensionID: extensionID
				))
				if prompt.candidate.permissionIncrease {
					// More permissions need the user's review in the Extensions sheet. Declining
					// waits for native cleanup and returns the refreshed inventory, so the next
					// extension doesn't find the profile busy.
					if
						prompt.candidate.extensionID == extensionID,
						let installed = inventory.extensions.first(where: { $0.id == extensionID })
					{
						outcome.needsReview.append(.init(prompt.candidate, profileID: profileID, installedVersion: installed.version))
					}
					inventory = try await client.resolveInstallation(prompt, false)
				} else {
					inventory = try await client.resolveInstallation(prompt, true)
				}
			} catch BrowserExtensionsClient.Failure.upToDate {
				outcome.upToDate.append(extensionID)
				continue
			} catch {
				guard let fresh = try? await client.inspect(profileID) else { return outcome }
				inventory = fresh
			}
			outcome.inventory = inventory
		}
		return outcome
	}
}

extension AppFeature.State {
	/// Ordinary profiles with a window open now. Others aren't loaded just to check.
	fileprivate var webstoreUpdateProfiles: [Profile.ID] {
		var profiles: [Profile.ID] = []
		let spaces = (windowIsOpen ? [main] : []) + Array(windows)
		for window in spaces where !window.isPrivate {
			let profileID = window.sidebar.space.profileID
			if workspace.profiles[id: profileID] != nil, !profiles.contains(profileID) {
				profiles.append(profileID)
			}
		}
		return profiles
	}

	/// Where the store opens for a profile: the space a window shows for it, else
	/// its most recently used space, else any of its spaces.
	/// The profile of the focused ordinary window, else of the main or another ordinary window,
	/// else of the most recent space. uBlock's settings belong to that profile.
	fileprivate var contentBlockingProfile: Profile.ID? {
		if let focusedWindowID {
			if windowIsOpen, main.id == focusedWindowID, !main.isPrivate { return main.sidebar.space.profileID }
			if let window = windows[id: focusedWindowID], !window.isPrivate { return window.sidebar.space.profileID }
		}
		if windowIsOpen, !main.isPrivate { return main.sidebar.space.profileID }
		if let window = windows.first(where: { !$0.isPrivate }) { return window.sidebar.space.profileID }
		let space = recentSpaceIDs.lazy.compactMap { self.workspace.spaces[id: $0] }.first ?? workspace.spaces.first
		return space?.profileID
	}

	fileprivate func webstoreSpace(for profileID: Profile.ID) -> Space.ID? {
		if windowIsOpen, !main.isPrivate, main.sidebar.space.profileID == profileID {
			return main.sidebar.space.id
		}
		if let window = windows.first(where: { !$0.isPrivate && $0.sidebar.space.profileID == profileID }) {
			return window.sidebar.space.id
		}
		let recent = recentSpaceIDs.first { workspace.spaces[id: $0]?.profileID == profileID }
		return recent ?? workspace.spaces.first(where: { $0.profileID == profileID })?.id
	}
}
