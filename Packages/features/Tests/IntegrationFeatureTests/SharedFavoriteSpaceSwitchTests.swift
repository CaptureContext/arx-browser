@testable import AppFeature
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import Testing
import ViewerFeature
import _ComposableArchitecture
import _TestSupport

/// A Favorite is one page for the whole profile. Switching between spaces that both have it
/// selected keeps its pane, so the page's host view and observation stay as they are (DEV-771).
@MainActor
@Suite(.dependencies, .serialized)
internal struct SharedFavoriteSpaceSwitchTests {
	@Test(arguments: [false, true])
	internal func switchingSpacesKeepsASharedFavoriteLive(preservesPresentation: Bool) async throws {
		let organization = Self.fixture(secondSpaceSelects: .favorite)
		let favorite = organization.tabs[0]
		let recorder = Recorder()
		let store = Self.store(organization, preservesPresentation: preservesPresentation, recorder: recorder)
		let paneID = store.main.viewer.activePaneID
		let generation = store.main.viewer.item.generation

		for space in [organization.spaces[1], organization.spaces[0], organization.spaces[1]] {
			await store.send(.main(.sidebar(.ui(.spaceSelected(space.id))))).finish()

			#expect(store.main.viewer.spaceID == space.id)
			#expect(store.main.viewer.panes.map(\.id) == [paneID])
			#expect(store.main.viewer.item.tab?.id == favorite.id)
			#expect(store.main.viewer.item.generation == generation)
		}
		#expect(recorder.shows.value.isEmpty)
		#expect(recorder.opens.value.isEmpty)
		#expect(store.main.viewer.continuingPaneIDs.isEmpty)
	}

	@Test
	internal func switchingToASpaceWithAnotherSelectionShowsIt() async throws {
		let organization = Self.fixture(secondSpaceSelects: .other)
		let other = organization.tabs[1]
		let recorder = Recorder()
		let store = Self.store(organization, preservesPresentation: true, recorder: recorder)

		await store.send(.main(.sidebar(.ui(.spaceSelected(organization.spaces[1].id))))).finish()

		#expect(store.main.viewer.item.tab?.id == other.id)
		#expect(recorder.shows.value == [other.id])
		#expect(recorder.opens.value == [other.id])
	}

	private enum Selection {
		/// Both spaces show the profile's Favorite.
		case favorite

		/// The first space shows one of its open tabs, the second another.
		case other
	}

	/// Records every page show the window's viewer sends and every page the engine is asked to open.
	private final class Recorder: Sendable {
		let shows = LockIsolated<[BrowserCore.Tab.ID]>([])
		let opens = LockIsolated<[BrowserCore.Tab.ID]>([])
	}

	private static func fixture(secondSpaceSelects selection: Selection) -> BrowserOrganization {
		var organization = IntegrationFeatureTests().fixture()
		let first = organization.tabs[0]
		let other = organization.tabs[1]
		organization.spaces[0].unpinnedTabs = selection == .favorite ? [] : [first.id]
		organization.spaces[1].unpinnedTabs = [other.id]
		if selection == .favorite { organization.profiles[0].favorites = [first.id] }
		organization.spaces[0].selectedTabID = first.id
		organization.spaces[1].selectedTabID = selection == .favorite ? first.id : other.id
		return organization
	}

	private static func store(
		_ organization: BrowserOrganization,
		preservesPresentation: Bool,
		recorder: Recorder
	) -> StoreOf<AppFeature> {
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.item.tab = organization.tabs[0]
		main.viewer.item.generation = 1
		main.viewer.item.isObserving = true
		main.viewer.observationGeneration = 1
		main.viewer.spaceID = organization.spaces[0].id
		main.viewer.preservesPresentation = preservesPresentation

		return Store(initialState: AppFeature.State(main: main)) {
			Reduce<AppFeature.State, AppFeature.Action> { _, action in
				switch action {
				case let .main(.viewer(.item(.show(.some(tab))))),
					let .main(.viewer(.panes(.element(_, .item(.show(.some(tab))))))):
					recorder.shows.withValue { $0.append(tab.id) }
				default:
					break
				}
				return .none
			}
			AppFeature()
		} withDependencies: {
			$0.browserEngine.open = { tab in recorder.opens.withValue { $0.append(tab.id) } }
			$0.browserEngine.events = { _ in .finished }
		}
	}
}
