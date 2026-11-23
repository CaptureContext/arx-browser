import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1109: the Create a Space page past the last space makes a space with its name, profile and
/// theme, after the others, and shows it.
@Suite(.dependencies)
@MainActor
internal struct SpaceCreationSwipeTests {
	@Test
	internal func createsTheSpaceWithItsNameProfileAndThemeAndShowsIt() async throws {
		var organization = IntegrationFeatureTests().fixture()
		let work = Profile(id: .init(rawValue: UUID(70)), name: "Work")
		organization.profiles.append(work)
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.isLibraryOpen = true
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .constant(UUID(90))
		}
		store.exhaustivity = .off

		let theme = AppearanceOverride(theme: .dark, tintHue: 210, tintIntensity: 0.8)
		await store.send(.sidebar(.ui(.createSpace(name: "  Garden  ", profileID: work.id, appearance: theme))))

		let created = try #require(store.state.sidebar.organization.spaces.last)
		expectNoDifference(created.id.rawValue, UUID(90))
		expectNoDifference(created.name, "Garden")
		expectNoDifference(created.profileID, work.id)
		expectNoDifference(created.appearance, theme)
		#expect(store.state.sidebar.organization.spaces.count == organization.spaces.count + 1)
		#expect(store.state.sidebar.spaceID == created.id)
		#expect(!store.state.isLibraryOpen)
	}

	/// No name, or a profile that's gone, makes nothing; a theme left as the profile's is none of
	/// the space's own.
	@Test
	internal func needsANameAndAProfileAndKeepsNoEmptyTheme() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let profile = organization.profiles[0].id
		let state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off

		await store.send(.sidebar(.ui(.createSpace(name: "   ", profileID: profile, appearance: nil))))
		await store.send(.sidebar(.ui(.createSpace(name: "Gone", profileID: .init(rawValue: UUID(404)), appearance: nil))))
		#expect(store.state.sidebar.organization.spaces.count == organization.spaces.count)

		await store.send(.sidebar(.ui(.createSpace(name: "Plain", profileID: profile, appearance: .init()))))
		let created = try #require(store.state.sidebar.organization.spaces.last)
		expectNoDifference(created.name, "Plain")
		#expect(created.appearance == nil)
	}

	/// Choosing the space already shown, from the switcher or a shortcut, is counted, so the
	/// sidebar leaves the Create a Space page for it (DEV-1126); choosing another isn't.
	@Test
	internal func choosingTheShownSpaceAgainIsCounted() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = TestStore(initialState: state) { MainFeature() }
		store.exhaustivity = .off

		await store.send(.sidebar(.ui(.spaceSelected(organization.spaces[0].id))))
		#expect(store.state.sidebar.spaceReselections == 1)
		let other = try #require(organization.spaces.dropFirst().first)
		await store.send(.sidebar(.ui(.spaceSelected(other.id))))
		#expect(store.state.sidebar.spaceReselections == 1)
		await store.send(.sidebar(.ui(.spaceSelected(other.id))))
		#expect(store.state.sidebar.spaceReselections == 2)
	}
}
