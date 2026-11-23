import AppKit
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// The favorite tab Peek bug (DEV-1312) as reported, in only the API `main` had, so it fails there: a Favorite's page asks for a new tab
/// (`target="_blank"`, Chromium's foreground tab) with Settings sending Favorites' links to Peek.
@Suite(.dependencies)
@MainActor
internal struct FavoriteNewTabRegressionTests {
	@Test
	internal func aFavoritesPageOpenedTabGoesToPeek() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = withDependencies {
			$0.workspaceDocument = .unsaved(.init())
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let tabID = organization.spaces[0].unpinnedTabs[0]
		state.main.sidebar.select(tabID)
		state.main.viewer.item.tab = organization.tabs[id: tabID]
		state.workspace.spaces[0].unpinnedTabs.removeAll { $0 == tabID }
		state.workspace.profiles[0].favorites.append(tabID)
		let saved = state.workspace.tabs[id: tabID]!
		state.workspace.tabs[id: tabID]!.savedDestination = .init(title: saved.displayTitle, url: saved.restoration.url)
		let source = state.main.viewer.item.tab!
		let offer = BrowserNewContents(
			sourceTabID: source.id,
			sourceSessionRevision: 3,
			sourceDocumentRevision: 7,
			tab: .init(
				id: .init(rawValue: UUID(90)),
				profileID: source.profileID,
				restoration: .init(title: "", url: URL(string: "https://mail.example/mail/u/1/")!)
			),
			disposition: .foregroundTab
		)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.browserEngine.snapshot = { id in
				if id == offer.sourceTabID {
					return .init(navigation: .init(), revision: 3, documentRevision: 7, nativeProfileID: offer.tab.profileID)
				}
				return id == offer.tab.id ? .init(navigation: .init(), revision: 1) : nil
			}
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.browserNewContents(offer)))
		await store.skipReceivedActions()
		await store.finish()

		#expect(store.state.settings.linkClicks.crossSiteLinkFromFavorites == .peek)
		expectNoDifference(store.state.peeks.first?.tab, offer.tab)

		// Before the fix the page's tab joined the space as a regular tab.
		#expect(!store.state.workspace.tabs.ids.contains(offer.tab.id))
		#expect(!store.state.workspace.spaces[0].unpinnedTabs.contains(offer.tab.id))
	}
}
