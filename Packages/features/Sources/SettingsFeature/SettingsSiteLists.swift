import BrowserCore
import Foundation
import _ComposableArchitecture

/// The Add Site and Edit Site form of Settings' site lists (DEV-1001): WebKit pages' sites and
/// the sites kept loaded. Settings › Advanced presents it while `SettingsFeature.State.siteDraft`
/// holds one.
public struct SettingsSiteDraft: Equatable, Sendable {
	public enum List: Equatable, Sendable {
		/// Advanced › WebKit: sites that open in WebKit pages.
		case webKit

		/// Advanced › Memory: a profile's sites that never unload.
		case keptLoaded
	}

	public enum Failure: Equatable, Sendable {
		/// Not something with a host, such as `netflix.com`.
		case invalidSite

		/// Already in the list.
		case duplicate
	}

	/// A listed site being edited.
	public struct Original: Equatable, Sendable {
		public var site: String

		/// The profile whose kept-loaded list holds it.
		public var profileID: Profile.ID?

		public init(
			site: String,
			profileID: Profile.ID? = nil
		) {
			self.site = site
			self.profileID = profileID
		}
	}

	public var list: List

	/// The site as typed.
	public var site: String

	/// For a kept-loaded site, the profile it's for.
	public var profileID: Profile.ID?

	/// The listed site being edited; nil for a new one.
	public var original: Original?
	public var error: Failure?

	public init(
		list: List,
		site: String = "",
		profileID: Profile.ID? = nil,
		original: Original? = nil,
		error: Failure? = nil
	) {
		self.list = list
		self.site = site
		self.profileID = profileID
		self.original = original
		self.error = error
	}

	public var isNew: Bool {
		original == nil
	}

	/// The site as the list keeps it, or nil while it isn't one.
	public var normalizedSite: String? {
		switch list {
		case .webKit: WebKitPagePreferences.site(from: site)
		case .keptLoaded: KeptLoadedSite.site(from: site)
		}
	}

	/// Whether Add or Save would keep it: a site and, for a kept-loaded one, its profile.
	public var isValid: Bool {
		normalizedSite != nil && (list == .webKit || profileID != nil)
	}

	@CasePathable
	public enum Action: Sendable {
		/// Opens an empty form for `list`; a kept-loaded site starts in `profileID`.
		case new(List, profileID: Profile.ID?)

		/// Opens the form for a listed site.
		case edit(List, site: String, profileID: Profile.ID?)
		case changed(SettingsSiteDraft)

		/// Closes the form without saving.
		case cancel

		/// Validates the site, saves it and closes the form.
		case save

		/// Removes the site being edited and closes the form.
		case delete
	}
}

@Reducer
internal struct SettingsSiteLists {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.siteDraft.new) { state, value in
			let (list, profileID) = value
			state.siteDraft = .init(list: list, profileID: list == .keptLoaded ? profileID : nil)
			return .none
		}

		Pullback(\.ui.siteDraft.edit) { state, value in
			let (list, site, profileID) = value
			state.siteDraft = .init(
				list: list,
				site: site,
				profileID: profileID,
				original: .init(site: site, profileID: profileID)
			)
			return .none
		}

		Pullback(\.ui.siteDraft.changed) { state, draft in
			guard state.siteDraft != nil else { return .none }

			state.siteDraft = draft
			state.siteDraft?.error = nil
			return .none
		}

		Pullback(\.ui.siteDraft.cancel) { state in
			state.siteDraft = nil
			return .none
		}

		Pullback(\.ui.siteDraft.save) { state in
			guard let draft = state.siteDraft else { return .none }
			guard let site = draft.normalizedSite else {
				state.siteDraft?.error = .invalidSite
				return .none
			}

			switch draft.list {
			case .webKit:
				let original = draft.original?.site
				guard site == original || !state.webKitPages.sites.contains(site) else {
					state.siteDraft?.error = .duplicate
					return .none
				}
				state.$webKitPages.withLock { preferences in
					if let original, let index = preferences.sites.firstIndex(of: original) {
						preferences.sites[index] = site
					} else {
						preferences.sites.append(site)
					}
					preferences.declinedSites.removeAll { WebKitPagePreferences.covers($0, host: site) }
				}
				state.siteDraft = nil
				return .none

			case .keptLoaded:
				guard let profileID = draft.profileID else { return .none }
				state.siteDraft = nil

				// Organization changes go through AppFeature, which validates and saves them.
				if let original = draft.original, let originalProfile = original.profileID {
					guard original.site != site || originalProfile != profileID else { return .none }
					return .send(.ui(.changeOrganization(.replaceKeptLoadedSite(
						originalProfile,
						site: original.site,
						newProfile: profileID,
						newSite: site
					))))
				}
				return .send(.ui(.changeOrganization(.setKeptLoadedSite(profileID, site: site, kept: true))))
			}
		}

		Pullback(\.ui.siteDraft.delete) { state in
			guard let draft = state.siteDraft, let original = draft.original else { return .none }

			state.siteDraft = nil
			switch draft.list {
			case .webKit:
				state.$webKitPages.withLock { $0.sites.removeAll { $0 == original.site } }
				return .none

			case .keptLoaded:
				guard let profileID = original.profileID else { return .none }
				return .send(.ui(.changeOrganization(.setKeptLoadedSite(profileID, site: original.site, kept: false))))
			}
		}
	}
}
