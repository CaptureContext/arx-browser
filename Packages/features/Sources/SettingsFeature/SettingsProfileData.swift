import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// A profile's Clear Browsing Data sheet and its downloads folder (DEV-647), from
/// its Profiles page. Only profiles Settings lists can use them; private profiles
/// never appear there. A private window follows the downloads folder of the profile
/// it was opened from (DEV-729).
@Reducer
internal struct SettingsProfileData {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.showClearBrowsingData) { state, id in
			guard let profile = state.extensionProfiles.first(where: { $0.id == id })
			else { return .none }

			state.clearBrowsingData = .init(profileID: profile.id, profileName: profile.name)
			return .none
		}

		Pullback(\.ui.clearBrowsingDataPresented) { state, isPresented in
			guard !isPresented, state.clearBrowsingData?.isClearing != true else { return .none }

			state.clearBrowsingData = nil
			return .none
		}

		Pullback(\.clearBrowsingData.delegate.dismiss) { state in
			state.clearBrowsingData = nil
			return .none
		}

		Pullback(\.clearBrowsingData.delegate.clearHistory) { _, value in
			let (id, since) = value
			guard let since else { return .send(.delegate(.clearHistory(id))) }
			return .send(.delegate(.clearHistorySince(id, since)))
		}

		Pullback(\.clearBrowsingData.delegate.clearedSiteData) { _, id in
			.send(.delegate(.clearedSiteData(id)))
		}

		// A profile that went away takes its sheet and folder with it.
		Pullback(\.configureExtensions) { state, profiles in
			let ids = Set(profiles.map(\.id))
			state.downloadSettings = state.downloadSettings.filter { ids.contains($0.key) }
			state.downloadSettingsNotice = state.downloadSettingsNotice.filter { ids.contains($0.key) }
			state.downloadSettingsChanging.formIntersection(ids)
			guard
				let id = state.clearBrowsingData?.profileID,
				!ids.contains(id)
			else { return .none }

			state.clearBrowsingData = nil
			return .none
		}

		Pullback(\.ui.loadDownloadSettings) { _, id in
			load(id)
		}

		Pullback(\.ui.chooseDownloadFolder) { state, value in
			let (id, folder) = value
			let asks = state.downloadSettings[id]?.asksWhereToSave ?? false
			return change(id, folder: folder, asks: asks, state: &state)
		}

		Pullback(\.ui.asksWhereToSave) { state, value in
			let (id, asks) = value
			return change(id, folder: nil, asks: asks, state: &state)
		}

		Pullback(\.ui.resetDownloadFolder) { state, id in
			guard let settings = state.downloadSettings[id] else { return .none }
			return change(id, folder: settings.defaultDirectory, asks: settings.asksWhereToSave, state: &state)
		}

		Pullback(\.event.downloadSettingsChangeFinished) { state, id in
			state.downloadSettingsChanging.remove(id)
			return .none
		}

		Pullback(\.event.downloadSettingsLoaded) { state, value in
			let (id, result) = value
			guard state.extensionProfiles.contains(where: { $0.id == id }) else { return .none }

			switch result {
			case let .success(settings):
				state.downloadSettings[id] = settings
				state.downloadSettingsNotice[id] = nil
			case let .failure(failure):
				state.downloadSettingsNotice[id] = failure
			}
			return .none
		}
	}

	private func load(_ id: Profile.ID) -> Effect<Action> {
		.run { [engine] send in
			let result: Result<DownloadSettings, ProfileDataFailure>
			do throws(ProfileDataFailure) {
				result = .success(try await engine.downloadSettings(id))
			} catch {
				result = .failure(error)
			}
			await send(.event(.downloadSettingsLoaded(id, result)))
		}
		.cancellable(id: DownloadSettingsID(id), cancelInFlight: true)
	}

	private func change(
		_ id: Profile.ID,
		folder: URL?,
		asks: Bool,
		state: inout State
	) -> Effect<Action> {
		// The engine applies changes as they finish, and a new folder is checked on
		// disk first, so another change is ignored (its controls are disabled) until
		// this one has finished, rather than racing it.
		guard
			state.downloadSettings[id]?.isManaged != true,
			!state.downloadSettingsChanging.contains(id)
		else { return .none }

		state.downloadSettingsChanging.insert(id)
		state.downloadSettingsNotice[id] = nil
		return .run { [engine] send in
			do throws(ProfileDataFailure) {
				let settings = try await engine.changeDownloadSettings(id, folder, asks)
				await send(.event(.downloadSettingsLoaded(id, .success(settings))))
			} catch {
				// A refused change leaves Settings showing what Chromium has, then why.
				if let fresh = try? await engine.downloadSettings(id) {
					await send(.event(.downloadSettingsLoaded(id, .success(fresh))))
				}
				await send(.event(.downloadSettingsLoaded(id, .failure(error))))
			}
			await send(.event(.downloadSettingsChangeFinished(id)))
		}
	}
}

private struct DownloadSettingsID: Hashable {
	internal var profileID: Profile.ID

	internal init(_ id: Profile.ID) {
		self.profileID = id
	}
}
