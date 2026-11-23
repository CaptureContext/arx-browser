import BrowserCore
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func allSpacesRemainVisibleWithTheirOwnProfilesFavorites() throws {
		var organization = fixture()
		let otherProfile = Profile.ID(rawValue: UUID(20))
		let otherSpace = Space.ID(rawValue: UUID(21))
		var favorite = organization.tabs[0]
		favorite.savedDestination = .init(title: "Favorite", url: favorite.restoration.url)
		organization.tabs[0] = favorite
		organization.spaces[0].unpinnedTabs.removeFirst()
		organization.profiles[0].favorites = [favorite.id]
		organization.profiles.append(.init(id: otherProfile, name: "Other"))
		organization.spaces.append(.init(id: otherSpace, profileID: otherProfile, name: "Other"))
		try organization.validate()

		var state = SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		expectNoDifference(state.sidebarSpaces.map(\.id), organization.spaces.map { $0.id.rawValue })
		expectNoDifference(state.sidebarSpaces[0].favorites.count, 1)
		expectNoDifference(state.sidebarSpaces[1].favorites.count, 1)
		expectNoDifference(state.sidebarSpaces[2].favorites.count, 0)

		state.selectSpace(otherSpace)
		expectNoDifference(state.favorites.count, 0)
		expectNoDifference(state.space.profileID, otherProfile)
		expectNoDifference(state.sidebarSpaces.count, 3)
		expectNoDifference(state.selectedTab, nil)

		let main = MainFeature.State(organization: organization, spaceID: otherSpace)
		#expect(main.commandCandidates.contains { $0.intent == .selectSpace(organization.spaces[0].id) })
	}
}
