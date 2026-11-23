import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct FolderLifecycleTests {
	@Test
	func openingDistinguishesImmediatePinsFromDescendantsInTreeOrder() async throws {
		let organization = fixture()
		expectNoDifference(organization.tabs(in: folderID(10)), [tabID(2), tabID(4)])
		expectNoDifference(organization.tabs(in: folderID(10), includingDescendants: true), [tabID(2), tabID(3), tabID(4)])
		expectNoDifference(organization.tabs(in: folderID(99), includingDescendants: true), [])
	}

	@Test
	func ungroupPreservesParentPositionChildOrderAndSelection() async throws {
		var organization = fixture()
		let expectedTabs = organization.tabs
		try organization.ungroupFolder(folderID(10))
		expectNoDifference(
			organization.spaces[0].savedItems,
			[.tab(tabID(1)), .tab(tabID(2)), .folder(folderID(11)), .tab(tabID(4)), .tab(tabID(5))]
		)
		expectNoDifference(organization.folders.map(\.id), [folderID(11)])
		expectNoDifference(organization.tabs, expectedTabs)
		expectNoDifference(organization.spaces[0].selectedTabID, tabID(3))
		try organization.validate()
	}

	@Test
	func nestedUngroupPromotesChildrenIntoTheirImmediateParent() async throws {
		var organization = fixture()
		let roots = organization.spaces[0].savedItems
		try organization.ungroupFolder(folderID(11))
		expectNoDifference(organization.folders[0].children, [.tab(tabID(2)), .tab(tabID(3)), .tab(tabID(4))])
		expectNoDifference(organization.spaces[0].savedItems, roots)
		try organization.validate()
	}

	@Test
	func invalidFolderEditsDoNotMutateTheOrganization() async throws {
		var organization = fixture()
		let previous = organization
		#expect(throws: (any Error).self) { try organization.deleteFolder(folderID(99)) }
		#expect(throws: (any Error).self) { try organization.ungroupFolder(folderID(99)) }
		#expect(throws: (any Error).self) { try organization.updateSavedURL(tabID(99)) }
		expectNoDifference(organization, previous)
	}

	@Test
	func updatingSavedURLIsExplicitUndoableAndPreservesTheName() async throws {
		var organization = fixture()
		organization.tabs[1].customTitle = "My pin"
		organization.tabs[1].restoration.url = URL(string: "https://capturecontext.dev/new")!
		let store = TestStore(initialState: SidebarFeature.State(organization: organization, spaceID: spaceID)) { SidebarFeature() }
		await store.send(.ui(.sidebar(.updateSavedURL(.tab(tabID(2).rawValue))))) {
			$0.organization.tabs[1].savedDestination?.url = URL(string: "https://capturecontext.dev/new")!
			$0.undo.append(.init(before: organization, spaceID: spaceID))
		}
		expectNoDifference(store.state.organization.tabs[1].displayTitle, "My pin")
		expectNoDifference(store.state.organization.tabs[1].savedDestination?.title, "Pin 2")
		await store.send(.ui(.undo)) {
			$0.organization = organization
			$0.undo = []
		}
		await store.receive(\.delegate.undid)
	}

	@Test
	func ungroupCanBeUndoneWithoutClosingAnyPage() async throws {
		let organization = fixture()
		var calls: [BrowserCore.Tab.ID] = []
		let initialState = MainFeature.State(organization: organization, spaceID: spaceID)
		let store = TestStore(initialState: initialState) { MainFeature() } withDependencies: {
			$0.browserEngine.close = { calls.append($0) }
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.sidebar(.ui(.sidebar(.ungroupFolder(.folder(folderID(10).rawValue))))))
		await store.receive(\.delegate.organizationChanged)
		expectNoDifference(store.state.sidebar.organization.folders.map(\.id), [folderID(11)])
		await store.send(.sidebar(.ui(.undo)))
		await store.receive(\.delegate.organizationChanged)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, organization)
		expectNoDifference(calls, [])
	}

	@Test
	func cancellingAnyDescendantCloseLeavesTheWholeSubtreeAndSessionsUntouched() async throws {
		let organization = fixture()
		var requested: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let initialState = MainFeature.State(organization: organization, spaceID: spaceID)
		let store = TestStore(initialState: initialState) { MainFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { id in
				requested.append(id)
				return id != tabID(3)
			}
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.sidebar(.ui(.sidebar(.deleteFolder(.folder(folderID(10).rawValue))))))
		await store.receive(\.event.folderDeletionCancelled)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, organization)
		expectNoDifference(store.state.sidebar.undo.map(\.before), [])
		expectNoDifference(store.state.pendingFolderDeletion, nil)
		expectNoDifference(requested, [tabID(2), tabID(3)])
		expectNoDifference(closed, [])
	}

	@Test
	func deletionClosesOnlyApprovedDescendantsAndUndoSurvivesRestart() async throws {
		let organization = fixture()
		var requested: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let initialState = MainFeature.State(organization: organization, spaceID: spaceID)
		let store = TestStore(initialState: initialState) { MainFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = {
				requested.append($0)
				return true
			}
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.sidebar(.ui(.sidebar(.deleteFolder(.folder(folderID(10).rawValue))))))
		await store.receive(\.event.folderDeletionApproved)
		await store.receive(\.delegate.organizationChanged)
		await store.finish()
		var expected = organization
		expected.folders = []
		expected.tabs.removeSubrange(1...3)
		expected.spaces[0].savedItems.remove(at: 1)
		expected.spaces[0].selectedTabID = nil
		expectNoDifference(store.state.sidebar.organization, expected)
		expectNoDifference(requested, [tabID(2), tabID(3), tabID(4)])
		expectNoDifference(Set(closed), Set(requested))
		expectNoDifference(store.state.sidebar.undo.map(\.before), [organization])

		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserWorkspaceClient(file: directory.appendingPathComponent("workspace.json"))
		try client.save(store.state.sidebar.organization)
		expectNoDifference(try client.load(), expected)
		await store.send(.sidebar(.ui(.undo)))
		await store.receive(\.delegate.organizationChanged)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, organization)
		try client.save(store.state.sidebar.organization)
		expectNoDifference(try client.load(), organization)
	}

	@Test
	func aChangedSubtreeInvalidatesEarlierCloseApproval() async throws {
		let original = fixture()
		var state = MainFeature.State(organization: original, spaceID: spaceID)
		state.pendingFolderDeletion = folderID(10)
		try state.sidebar.organization.ungroupFolder(folderID(11))
		let changed = state.sidebar.organization
		let store = TestStore(initialState: state) { MainFeature() }
		await store.send(.event(.folderDeletionApproved(folderID(10), original.folderSubtree(folderID(10))))) {
			$0.pendingFolderDeletion = nil
			$0.sidebar.message = String.localized(.appUI.management.workspaceChanged)
		}
		expectNoDifference(store.state.sidebar.organization, changed)
		expectNoDifference(store.state.sidebar.undo.map(\.before), [])
	}

	@Test
	func folderOpenReusesIdentitiesAndDoesNotNavigateExistingSessions() async throws {
		var organization = fixture()
		organization.spaces[0].selectedTabID = tabID(1)
		var calls: [BrowserCore.Tab.ID] = []
		let initialState = MainFeature.State(organization: organization, spaceID: spaceID)
		let store = TestStore(initialState: initialState) { MainFeature() } withDependencies: {
			$0.browserEngine.open = { calls.append($0.id) }
			$0.browserEngine.command = { _, _ in Issue.record("Opening a folder must not navigate an existing session") }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.sidebar(.ui(.sidebar(.openFolder(.folder(folderID(10).rawValue), includingDescendants: false)))))
		await store.receive(\.event.folderTabOpened)
		await store.receive(\.event.folderTabOpened)
		await store.finish()
		expectNoDifference(calls.filter { $0 != tabID(1) }, [tabID(2), tabID(4)])
		expectNoDifference(store.state.sidebar.organization.tabs, organization.tabs)
		calls = []
		await store.send(.sidebar(.ui(.sidebar(.openFolder(.folder(folderID(10).rawValue), includingDescendants: true)))))
		await store.receive(\.event.folderTabOpened)
		await store.receive(\.event.folderTabOpened)
		await store.receive(\.event.folderTabOpened)
		await store.finish()
		expectNoDifference(calls, [tabID(2), tabID(3), tabID(4)])
		expectNoDifference(store.state.sidebar.organization.tabs, organization.tabs)
	}

	@Test
	func folderOpeningContinuesAfterAnIndividualPageFails() async throws {
		var organization = fixture()
		organization.spaces[0].selectedTabID = tabID(1)
		var initial = MainFeature.State(organization: organization, spaceID: spaceID)
		initial.viewer.item.tab = organization.tabs[0]
		var opened: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.browserEngine.open = { tab in
				opened.append(tab.id)
				if tab.id == tabID(2) { throw BrowserEngineClient.Failure.unavailable }
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.sidebar(.ui(.sidebar(.openFolder(.folder(folderID(10).rawValue), includingDescendants: false)))))
		await store.receive(\.event.folderTabFailed)
		await store.receive(\.event.folderTabOpened)
		await store.finish()
		expectNoDifference(opened, [tabID(2), tabID(4)])
		expectNoDifference(store.state.sidebar.organization, organization)
		#expect(store.state.sidebar.message != nil)
	}

	@Test
	func aPageOpenedAfterItsPinWasRemovedIsDisposed() async throws {
		var organization = fixture()
		try organization.deleteFolder(folderID(10))
		var closed: [BrowserCore.Tab.ID] = []
		let initialState = MainFeature.State(organization: organization, spaceID: spaceID)
		let store = TestStore(initialState: initialState) { MainFeature() } withDependencies: {
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.folderTabOpened(tabID(2), remaining: [])))
		await store.receive(\.openFolderTabs)
		await store.finish()
		expectNoDifference(closed, [tabID(2)])
		expectNoDifference(store.state.sidebar.organization, organization)
	}

	@Test
	func closingAPinRetainsItsEntryAndResetsTheSavedDestination() async throws {
		var organization = fixture()
		organization.tabs[2].restoration.url = URL(string: "https://capturecontext.dev/changed")!
		var closed: [BrowserCore.Tab.ID] = []
		let initialState = MainFeature.State(organization: organization, spaceID: spaceID)
		let store = TestStore(initialState: initialState) { MainFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.closeTab))
		await store.receive(\.sidebar.event.closeApproved)
		await store.receive(\.sidebar.delegate.resetTab)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization.tabs.map(\.id), organization.tabs.map(\.id))
		expectNoDifference(store.state.sidebar.organization.tabs[2].restoration.url, organization.tabs[2].savedDestination?.url)
		expectNoDifference(closed, [tabID(3)])
		await store.send(.sidebar(.ui(.sidebar(.select(.tab(tabID(3).rawValue))))))
		await store.receive(\.delegate.organizationChanged)
		await store.finish()
		expectNoDifference(store.state.sidebar.selectedTab?.reopeningURL, organization.tabs[2].savedDestination?.url)
	}

	/// DEV-1110: selecting a tab inside collapsed folders, from the sidebar, the command bar or
	/// ⌃Tab, leaves them collapsed; the sidebar shows the tab beneath the nearest one.
	@Test
	func selectingATabInACollapsedFolderLeavesItCollapsed() async throws {
		var organization = fixture()
		organization.spaces[0].selectedTabID = tabID(1)
		for index in organization.folders.indices {
			organization.folders[index].isExpanded = false
		}
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: spaceID)) {
			MainFeature()
		} withDependencies: {
			$0.browserEngine.open = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.sidebar(.ui(.sidebar(.select(.tab(tabID(3).rawValue))))))
		await store.finish()
		expectNoDifference(store.state.sidebar.selectedTab?.id, tabID(3))
		expectNoDifference(store.state.sidebar.organization.folders.map(\.isExpanded), [false, false])

		var sidebar = store.state.sidebar
		sidebar.select(tabID(2))
		expectNoDifference(sidebar.organization.folders.map(\.isExpanded), [false, false])

		// An explicit reveal, such as the command bar's folder result, still opens them.
		sidebar.reveal(folderID(11))
		expectNoDifference(sidebar.organization.folders.map(\.isExpanded), [true, true])
	}

	private var spaceID: Space.ID { .init(rawValue: UUID(20)) }

	private func tabID(_ value: Int) -> BrowserCore.Tab.ID { .init(rawValue: UUID(value)) }
	private func folderID(_ value: Int) -> Folder.ID { .init(rawValue: UUID(value)) }

	private func fixture() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: UUID(0))
		let tabs: [BrowserCore.Tab] = (1...5).map { value in
			.init(
				id: tabID(value),
				profileID: profile,
				savedDestination: .init(title: "Pin \(value)", url: URL(string: "https://capturecontext.dev/\(value)")!),
				restoration: .init(title: "Pin \(value)", url: URL(string: "https://capturecontext.dev/\(value)")!)
			)
		}
		return .init(
			profiles: [.init(id: profile, name: "Default")],
			spaces: [.init(
				id: spaceID,
				profileID: profile,
				name: "Work",
				savedItems: [.tab(tabID(1)), .folder(folderID(10)), .tab(tabID(5))],
				selectedTabID: tabID(3)
			)],
			folders: [
				.init(id: folderID(10), spaceID: spaceID, name: "Parent", children: [.tab(tabID(2)), .folder(folderID(11)), .tab(tabID(4))]),
				.init(id: folderID(11), spaceID: spaceID, name: "Child", children: [.tab(tabID(3))]),
			],
			tabs: tabs
		)
	}
}
