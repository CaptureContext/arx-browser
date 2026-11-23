import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// `ungroupFolder` removes its folder, so its result names no target: the response check only
/// lets through targets the client can still see, and refused a successful ungroup as `denied`.
extension AutomationManagementFeatureTests {
	@Test
	internal func anUngroupedFolderReachesTheClientAsCommitted() async throws {
		var state = Self.state()

		// A headless run's own client: its whole profiles, `--allow read,screenshots,content,manage`.
		state.automationPreferences.clients[0].scopes = HeadlessRun.scopes(for: state.workspace)
		state.automationPreferences.clients[0].capabilities = [.read, .screenshots, .pageContent, .organize]
		let folder = Folder(
			id: .init(rawValue: UUID(1010)),
			spaceID: Self.first,
			name: "Group",
			children: [.tab(Self.firstTab)]
		)
		state.workspace.folders.append(folder)
		state.workspace.spaces[id: Self.first]?.unpinnedTabs = []
		state.workspace.spaces[id: Self.first]?.savedItems = [.folder(folder.id)]
		state.workspace.tabs[id: Self.firstTab]?.savedDestination = .init(title: "Page", url: Self.url)
		state.main.sidebar.organization = state.workspace
		let (store, responses) = Self.store(state)
		let request = Self.request(.ungroupFolder, target: folder.id.rawValue, state: state)

		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.workspace.folders.isEmpty)
		let response = try #require(responses.value.last)
		guard case let .command(result) = response else {
			Issue.record("ungroupFolder failed: \(response)")
			return
		}
		expectNoDifference(result.status, .committed)
		#expect(result.targetID == nil)
		// What the IPC host checks before the client sees the reply.
		expectNoDifference(store.state.automationResponseValidation(request, result: response, snapshots: [:]), nil)

		// Naming the folder it removed, as it used to, the reply was refused.
		let named = AutomationResult.command(.init(
			operationID: result.operationID,
			status: .committed,
			targetID: folder.id.rawValue
		))
		expectNoDifference(store.state.automationResponseValidation(request, result: named, snapshots: [:]), .denied)
	}

	@Test
	internal func onlyActionsThatRemoveTheirTargetReturnNone() async throws {
		let removing = AutomationCommand.Action.allCases.filter(\.removesTarget)
		expectNoDifference(
			Set(removing),
			[.closeTab, .deleteProfile, .deleteSpace, .removeSavedEntry, .deleteFolder, .ungroupFolder]
		)
	}
}
