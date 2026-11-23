import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Folder commands for a client granted space by space, as a headless run's own client is.
extension AutomationManagementFeatureTests {
	@Test
	internal func moveTabIntoAFolderOfTheSameProfileMovesIt() async throws {
		let (state, folder) = Self.folderState()
		let (store, responses) = Self.store(state)
		let request = Self.request(.moveTab, target: Self.firstTab.rawValue, state: state, destination: folder.rawValue)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		// Not a cross-profile transfer: the folder belongs to its space's profile.
		guard case .command? = responses.value.last else {
			Issue.record("moveTab into a folder failed: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(store.state.workspace.folders[id: folder]?.children, [.tab(Self.firstTab)])
		#expect(store.state.workspace.tabs[id: Self.firstTab]?.savedDestination != nil)
		#expect(store.state.workspace.spaces[id: Self.first]?.unpinnedTabs.contains(Self.firstTab) == false)
	}

	@Test
	internal func ungroupFolderWorksForASpaceScopedClient() async throws {
		var (state, folder) = Self.folderState()
		state.workspace.spaces[id: Self.first]?.unpinnedTabs = []
		state.workspace.folders[id: folder]?.children = [.tab(Self.firstTab)]
		state.workspace.tabs[id: Self.firstTab]?.savedDestination = .init(title: "Page", url: Self.url)
		state.main.sidebar.organization = state.workspace
		let (store, responses) = Self.store(state)
		let request = Self.request(.ungroupFolder, target: folder.rawValue, state: state)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		guard case .command? = responses.value.last else {
			Issue.record("ungroupFolder failed: \(String(describing: responses.value.last))")
			return
		}
		#expect(store.state.workspace.folders.isEmpty)
	}

	/// An empty folder in the first space, and the client granted each space on its own with
	/// `read,screenshots,content,manage`.
	private static func folderState() -> (AppFeature.State, Folder.ID) {
		var state = state()
		let folder = Folder(id: .init(rawValue: UUID(1010)), spaceID: first, name: "Folder")
		state.workspace.folders.append(folder)
		state.workspace.spaces[id: first]?.savedItems.append(.folder(folder.id))
		state.main.sidebar.organization = state.workspace
		state.automationPreferences.clients[0].scopes = state.workspace.spaces.map {
			.space($0.id, profileID: $0.profileID)
		}
		state.automationPreferences.clients[0].capabilities = [.read, .screenshots, .pageContent, .organize]
		return (state, folder.id)
	}
}
