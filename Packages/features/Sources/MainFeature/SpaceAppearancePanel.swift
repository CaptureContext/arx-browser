import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// A space's theme (DEV-1253): its colors, light or dark, intensity and texture, edited from its context menu. A drag shows on the window's chrome
/// through `onPreview` before it's committed.
internal struct SpaceAppearancePanel: View {
	private let store: StoreOf<MainFeature>
	private let spaceID: Space.ID
	private let global: ChromeAppearance
	private let onPreview: (AppearanceOverride?) -> Void

	internal init(
		store: StoreOf<MainFeature>,
		spaceID: Space.ID,
		global: ChromeAppearance,
		onPreview: @escaping (AppearanceOverride?) -> Void
	) {
		self.store = store
		self.spaceID = spaceID
		self.global = global
		self.onPreview = onPreview
	}

	internal var body: some View {
		// Reads the store here, not where the panel is presented, so each commit refreshes the panel.
		let organization = store.sidebar.organization
		if let space = organization.spaces[id: spaceID] {
			VStack(alignment: .leading, spacing: 0) {
				SpaceThemeEditor(
					choices: space.appearance ?? .init(),
					inherited: (organization.profiles[id: space.profileID]?.appearance ?? .init()).applied(to: global),
					offersMatchSite: MatchSiteBackground.isEnabled(),
					offersAccent: ChromeAccent.isEnabled(),
					onPreview: onPreview,
					onCommit: { store.send(.ui(.changeOrganization(.setSpaceAppearance(spaceID, $0)))) },
					onClear: { store.send(.ui(.changeOrganization(.setSpaceAppearance(spaceID, .init())))) }
				)
			}
			.frame(width: SpaceThemeEditor.width)

			// The panel's handle sits above it, in place of most of the top padding.
			.padding([.horizontal, .bottom], 14)
			.padding(.top, 4)
		}
	}
}

/// A space's appearance while one of its sliders is dragged.
internal struct SpaceAppearancePreview: Equatable {
	internal let spaceID: Space.ID
	internal let override: AppearanceOverride

	internal init(
		spaceID: Space.ID,
		override: AppearanceOverride
	) {
		self.spaceID = spaceID
		self.override = override
	}
}

extension BrowserOrganization {
	/// The selected space's appearance, with a drag in progress standing in for its own choices.
	internal func appearance(
		ofSpace id: Space.ID,
		preview: SpaceAppearancePreview?
	) -> AppearanceOverride {
		guard
			let preview,
			preview.spaceID == id,
			let space = spaces[id: id]
		else { return appearance(ofSpace: id) }
		return preview.override.over(profiles[id: space.profileID]?.appearance)
	}
}
