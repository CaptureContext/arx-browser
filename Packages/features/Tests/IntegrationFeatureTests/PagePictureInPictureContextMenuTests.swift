@testable import AppFeature
import AppKit
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1123: a page floating in Page PiP that no window shows has its own context menus. Its
/// link menu opens in the floating panel, and its selection and image items act on it from
/// the window it floats from, never on that window's pane.
@Suite(.dependencies)
@MainActor
internal struct PagePictureInPictureContextMenuTests {
	private func fixture() -> (AppFeature.State, hidden: BrowserCore.Tab) {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		return (state, organization.tabs[1])
	}

	/// The link menu checks the page's own window: the floating panel, while its links still
	/// open from the window it floats from.
	@Test
	internal func aFloatingPagesLinkMenuBelongsToItsPanel() throws {
		var (state, hidden) = fixture()
		state.pagePictureInPicture = .init(tabID: hidden.id, windowID: state.main.id, phase: .open)
		let floating = try #require(
			state.nativeContentPlacement(tabID: hidden.id, profileID: hidden.profileID, isPrivate: false)
		)
		expectNoDifference(floating.windowID, state.main.id)
		expectNoDifference(floating.menuWindowIdentifier, NSUserInterfaceItemIdentifier(PagePictureInPicturePanel.identifier))

		// A page a pane shows keeps its window's menu.
		let shown = state.workspace.tabs[0]
		let pane = try #require(
			state.nativeContentPlacement(tabID: shown.id, profileID: shown.profileID, isPrivate: false)
		)
		expectNoDifference(pane.menuWindowIdentifier, LinkSharingClient.windowIdentifier(for: state.main.id))
	}

	@Test
	internal func aFloatingBackgroundTabOffersItsPagesItems() throws {
		var (state, hidden) = fixture()

		// Nothing shows it, so nothing acts on it.
		#expect(state.pageContextHost(showing: hidden.id) == nil)

		state.pagePictureInPicture = .init(tabID: hidden.id, windowID: state.main.id, phase: .open)
		let host = try #require(state.pageContextHost(showing: hidden.id))
		expectNoDifference(host.windowID, state.main.id)
		expectNoDifference(host.floatingTabID, hidden.id)
		expectNoDifference(host.profileID, hidden.profileID)
		expectNoDifference(host.actions, [.search, .shareText, .openInNewTab])

		// Not while it's still on its way, nor once the app is quitting.
		state.pagePictureInPicture?.phase = .opening
		#expect(state.pageContextHost(showing: hidden.id) == nil)
		state.pagePictureInPicture?.phase = .open
		state.shouldQuit = true
		#expect(state.pageContextHost(showing: hidden.id) == nil)
		state.shouldQuit = false

		// A floating page a pane shows keeps that pane as its host.
		let shown = state.workspace.tabs[0]
		state.pagePictureInPicture = .init(tabID: shown.id, windowID: state.main.id, phase: .open)
		let pane = try #require(state.pageContextHost(showing: shown.id))
		#expect(pane.floatingTabID == nil)
		// And the background tab, no longer floating, has no host again.
		#expect(state.pageContextHost(showing: hidden.id) == nil)
	}

	/// Search and Open Image in New Tab open behind the floating page, in its own space, as its
	/// links do; the window's pane keeps its tab. Share shows from the window it floats from.
	@Test
	internal func aFloatingPagesItemsActOnItNotOnTheWindowsPane() async throws {
		var (state, hidden) = fixture()
		state.pagePictureInPicture = .init(tabID: hidden.id, windowID: state.main.id, phase: .open)
		let paneTab = state.main.viewer.item.tab?.id
		let opened = LockIsolated<[URL]>([])
		let shared = LockIsolated<[UUID?]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { tab in
				opened.withValue { $0.append(tab.restoration.url) }
			}
			$0.linkSharing.shareContent = { _, windowID in
				shared.withValue { $0.append(windowID) }
				return .shared
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let engine = state.workspace.profiles[id: hidden.profileID]?.searchEngine ?? .google
		let search = try #require(engine.url(for: "arx"))
		await store.send(.ui(.pageContextMenu(hidden.id, .search("arx"))))
		await store.receive(\.openLinkInBackgroundTab)
		let image = URL(string: "https://capturecontext.dev/image.png")!
		await store.send(.ui(.pageContextMenu(hidden.id, .openInNewTab(image))))
		await store.receive(\.openLinkInBackgroundTab)
		await store.send(.ui(.pageContextMenu(hidden.id, .shareText("selected"))))
		await store.skipReceivedActions(strict: false)
		await store.finish()

		expectNoDifference(store.state.main.viewer.item.tab?.id, paneTab)
		expectNoDifference(opened.value, [search, image])
		let added = store.state.workspace.tabs.filter { [search, image].contains($0.restoration.url) }
		expectNoDifference(added.map(\.profileID), [hidden.profileID, hidden.profileID])
		expectNoDifference(shared.value, [state.main.id])
	}
}
