import AppUI
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func folderTransferStagesEveryDescendantBeforeApprovalsAndCommitsOnce() async throws {
		let original = folderMoveFixture()
		var operations: [String] = []
		var initial = MainFeature.State(organization: original, spaceID: original.spaces[0].id)
		initial.viewer.item.tab = original.tabs[0]
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.uuid = moveUUIDs()
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1) }
			$0.browserEngine.open = { tab in operations.append("open:\(tab.profileID.rawValue)") }
			$0.browserEngine.permitsClosing = { _ in
				operations.append("approve")
				return true
			}
			$0.browserEngine.close = { _ in operations.append("close") }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.transferTabs([.folder(original.folders[0].id.rawValue)], nil, original.spaces[2].id))
		#expect(operations.isEmpty)
		#expect(store.state.pendingTabMove?.plan.replacements.count == 2)
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.movedAcrossProfiles)
		await store.finish()
		expectNoDifference(
			Array(operations.prefix(4)),
			["open:\(original.profiles[1].id.rawValue)", "open:\(original.profiles[1].id.rawValue)", "approve", "approve"]
		)
		expectNoDifference(operations.filter { $0 == "close" }.count, 2)
		expectNoDifference(store.state.sidebar.undo.map(\.before), [original])
		expectNoDifference(store.state.sidebar.organization.folders.map(\.spaceID), [original.spaces[2].id, original.spaces[2].id])
		try store.state.sidebar.organization.validate()
	}

	@Test
	internal func confirmationDoesNotRetargetAfterSelectionChanges() async throws {
		let original = folderMoveFixture()
		var opened: [BrowserCore.Tab.ID] = []
		let initialState = MainFeature.State(organization: original, spaceID: original.spaces[0].id)
		let store = TestStore(initialState: initialState) { MainFeature() } withDependencies: {
			$0.uuid = moveUUIDs()
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1) }
			$0.browserEngine.open = { opened.append($0.id) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.transferTabs([.tab(original.tabs[0].id.rawValue)], nil, original.spaces[2].id))
		await store.send(.sidebar(.ui(.sidebar(.toggleMoveSelection(.tab(original.tabs[1].id.rawValue))))))
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.performTabMove)
		await store.finish()
		#expect(opened.allSatisfy { original.tabs.map(\.id).contains($0) })
		expectNoDifference(store.state.sidebar.organization.tabs, original.tabs)
		#expect(store.state.sidebar.message != nil)
	}

	/// A source page that navigates meanwhile, or reloads its address without a document stamp
	/// (a WebKit page), a move no longer allowed or a page that declines to close rolls the whole
	/// folder back. A page that only reports a color or title meanwhile doesn't
	/// (`CrossProfileUndoTests`).
	@Test(arguments: ["navigation", "reload", "authorization", "decline"])
	internal func changedSourceOrDeclinedCloseRollsBackWholeFolder(_ reason: String) async throws {
		let original = folderMoveFixture()
		var opened: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		var revision: UInt64 = 1
		var url: URL?
		var allowed = true
		var approvals = 0
		var initial = MainFeature.State(organization: original, spaceID: original.spaces[0].id)
		initial.viewer.item.tab = original.tabs[0]
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.uuid = moveUUIDs()
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1) }
			$0.tabMoveAuthorization.check = { _, _ in allowed }
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(url: url), revision: revision) }
			$0.browserEngine.open = { opened.append($0.id) }
			$0.browserEngine.permitsClosing = { _ in
				approvals += 1
				if approvals == 2 {
					if reason == "navigation" {
						revision += 1
						url = URL(string: "https://elsewhere.example")
					}

					// The same address again, with nothing but the revision to say so.
					if reason == "reload" { revision += 1 }
					if reason == "authorization" { allowed = false }
					return reason != "decline"
				}
				return true
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.transferTabs([.folder(original.folders[0].id.rawValue)], nil, original.spaces[2].id))
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.moveFailed)
		await store.finish()
		expectNoDifference(opened.count, 2)
		expectNoDifference(closed, opened)
		expectNoDifference(store.state.sidebar.organization, original)
		expectNoDifference(store.state.sidebar.undo.map(\.before), [])
	}

	@Test
	internal func treeChangeWhileDestinationOpensRejectsCommitAndClosesOnlyNewSession() async throws {
		let original = folderMoveFixture()
		let started = AsyncStream.makeStream(of: Void.self)
		let resume = AsyncStream.makeStream(of: Void.self)
		var opened: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		var initial = MainFeature.State(organization: original, spaceID: original.spaces[0].id)
		initial.viewer.item.tab = original.tabs[0]
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.uuid = moveUUIDs()
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1) }
			$0.browserEngine.open = { tab in
				if tab.profileID == original.profiles[1].id {
					opened.append(tab.id)
					started.continuation.yield()
					for await _ in resume.stream { break }
				}
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.transferTabs([.tab(original.tabs[0].id.rawValue)], nil, original.spaces[2].id))
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.performTabMove)
		for await _ in started.stream { break }
		var changed = original
		changed.folders[0].name = "Edited elsewhere"
		await store.send(.reconcile(changed))
		resume.continuation.yield()
		await store.receive(\.event.movedAcrossProfiles)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization.folders[0].name, "Edited elsewhere")
		expectNoDifference(store.state.sidebar.organization.tabs, original.tabs)
		expectNoDifference(closed, opened)
	}

	@Test
	internal func crossProfileUndoRequestsCloseApprovalAndRestoresWithFreshIdentities() async throws {
		let original = folderMoveFixture()
		var allowed = true
		var closed: [BrowserCore.Tab.ID] = []
		var initial = MainFeature.State(organization: original, spaceID: original.spaces[0].id)
		initial.viewer.item.tab = original.tabs[0]
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.uuid = moveUUIDs()
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1) }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.permitsClosing = { _ in allowed }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.transferTabs([.folder(original.folders[0].id.rawValue)], nil, original.spaces[2].id))
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.movedAcrossProfiles)
		await store.finish()
		let transferred = store.state.sidebar.organization
		allowed = false
		closed.removeAll()
		await store.send(.sidebar(.ui(.undo)))
		await store.receive(\.sidebar.delegate.reverseTransfer)
		#expect(store.state.pendingTabMove?.isUndo == true)
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.moveFailed)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, transferred)
		#expect(Set(closed).isDisjoint(with: transferred.tabs.map(\.id)))
		allowed = true
		await store.send(.sidebar(.ui(.undo)))
		await store.receive(\.sidebar.delegate.reverseTransfer)
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.movedAcrossProfiles)
		await store.finish()
		let restored = store.state.sidebar.organization
		expectNoDifference(restored.folders.map(\.spaceID), original.folders.map(\.spaceID))
		expectNoDifference(restored.tabs.map(\.profileID), original.tabs.map(\.profileID))
		#expect(Set(restored.tabs.map(\.id)).isDisjoint(with: original.tabs.map(\.id)))
		#expect(Set(restored.tabs.map(\.id)).isDisjoint(with: transferred.tabs.map(\.id)))
		expectNoDifference(store.state.sidebar.undo.map(\.before), [])
		try restored.validate()
	}

	@Test
	internal func moveSelectionHasStableOrderAndPickerExcludesDescendantCycles() async throws {
		let original = folderMoveFixture()
		let first = SidebarItem.ID.folder(original.folders[0].id.rawValue)
		let second = SidebarItem.ID.tab(original.tabs[1].id.rawValue)
		let store = TestStore(initialState: SidebarFeature.State(organization: original, spaceID: original.spaces[0].id)) { SidebarFeature() }
		await store.send(.ui(.sidebar(.toggleMoveSelection(second)))) { $0.moveSelection = [second] }
		await store.send(.ui(.sidebar(.toggleMoveSelection(first)))) { $0.moveSelection = [second, first] }
		await store.send(.ui(.sidebar(.toggleMoveSelection(second)))) { $0.moveSelection = [first] }
		let main = TestStore(initialState: MainFeature.State(organization: original, spaceID: original.spaces[0].id)) { MainFeature() }
		main.exhaustivity = .off(showSkippedAssertions: false)
		await main.send(.sidebar(.delegate(.chooseMoveDestination([first]))))
		let destinations = try #require(main.state.movePicker?.destinations)
		#expect(destinations.allSatisfy { $0.folderID == nil })
		expectNoDifference(destinations.map(\.path), ["Default / Work", "Default / Personal", "Other / Destination"])
	}

	@Test
	internal func privateWindowCannotMovePagesToAnotherProfile() async throws {
		let original = folderMoveFixture()
		let initialState = MainFeature.State(organization: original, spaceID: original.spaces[0].id, isPrivate: true)
		let store = TestStore(initialState: initialState) { MainFeature() } withDependencies: {
			$0.uuid = moveUUIDs()
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.transferTabs([.folder(original.folders[0].id.rawValue)], nil, original.spaces[2].id))
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, original)
		#expect(store.state.pendingTabMove == nil)
		#expect(!store.state.transferInProgress)
	}

	@Test
	internal func repeatedCompletionCannotCloseCommittedDestination() async throws {
		let original = folderMoveFixture()
		var closed: [BrowserCore.Tab.ID] = []
		let initialState = MainFeature.State(organization: original, spaceID: original.spaces[0].id)
		let store = TestStore(initialState: initialState) { MainFeature() } withDependencies: {
			$0.uuid = moveUUIDs()
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1) }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.transferTabs([.folder(original.folders[0].id.rawValue)], nil, original.spaces[2].id))
		let request = try #require(store.state.pendingTabMove)
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.movedAcrossProfiles)
		await store.finish()
		closed.removeAll()
		let committed = store.state.sidebar.organization
		await store.send(.event(.movedAcrossProfiles(request)))
		await store.finish()
		expectNoDifference(closed, [])
		expectNoDifference(store.state.sidebar.organization, committed)
	}

	@Test
	internal func nativeSourceGenerationChangeDuringConfirmationRejectsTransfer() async throws {
		let original = folderMoveFixture()
		var initial = MainFeature.State(organization: original, spaceID: original.spaces[0].id)
		initial.viewer.item.tab = original.tabs[0]
		var opened: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.uuid = moveUUIDs()
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 1) }
			$0.browserEngine.open = { opened.append($0.id) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.transferTabs([.folder(original.folders[0].id.rawValue)], nil, original.spaces[2].id))
		await store.send(.viewer(.panes(.element(id: initial.viewer.activePaneID, action: .item(.show(original.tabs[0]))))))
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.performTabMove)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, original)
		#expect(opened.allSatisfy { $0 == original.tabs[0].id })
		#expect(!store.state.transferInProgress)
	}

	@Test
	internal func dormantFolderTransferDoesNotOpenOrApproveAnyPage() async throws {
		let original = folderMoveFixture()
		var opened: [BrowserCore.Tab.ID] = []
		var approvals: [BrowserCore.Tab.ID] = []
		var prepared: [Profile.ID] = []
		let initialState = MainFeature.State(organization: original, spaceID: original.spaces[0].id)
		let store = TestStore(initialState: initialState) { MainFeature() } withDependencies: {
			$0.uuid = moveUUIDs()
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserEngine.prepareProfile = { prepared.append($0) }
			$0.browserEngine.open = { opened.append($0.id) }
			$0.browserEngine.permitsClosing = {
				approvals.append($0)
				return true
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.transferTabs([.folder(original.folders[0].id.rawValue)], nil, original.spaces[2].id))
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.movedAcrossProfiles)
		await store.finish()
		expectNoDifference(opened, [])
		expectNoDifference(approvals, [])
		expectNoDifference(prepared, [])
		expectNoDifference(store.state.sidebar.organization.folders.map(\.spaceID), [original.spaces[2].id, original.spaces[2].id])
	}

	@Test
	internal func newerNativeURLRejectsStagingUntilMetadataCatchesUp() async throws {
		let original = folderMoveFixture()
		var opened: [BrowserCore.Tab.ID] = []
		var prepared: [Profile.ID] = []
		var initial = MainFeature.State(organization: original, spaceID: original.spaces[0].id)
		initial.viewer.item.tab = original.tabs[0]
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.uuid = moveUUIDs()
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(url: URL(string: "https://newer.example")!), revision: 2) }
			$0.browserEngine.prepareProfile = { prepared.append($0) }
			$0.browserEngine.open = { opened.append($0.id) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.transferTabs([.folder(original.folders[0].id.rawValue)], nil, original.spaces[2].id))
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.moveFailed)
		await store.finish()
		expectNoDifference(opened, [])
		expectNoDifference(prepared, [])
		expectNoDifference(store.state.sidebar.organization, original)
	}

	@Test
	internal func sameProfileFolderUndoKeepsLiveIDsAndCurrentNavigation() async throws {
		let original = folderMoveFixture()
		var initial = MainFeature.State(organization: original, spaceID: original.spaces[0].id)
		initial.viewer.item.tab = original.tabs[0]
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: initial) { MainFeature() } withDependencies: {
			$0.uuid = moveUUIDs()
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.transferTabs([.folder(original.folders[0].id.rawValue)], nil, original.spaces[1].id))
		await store.receive(\.performTabMove)
		await store.finish()
		let currentURL = URL(string: "https://unrelated.example/current")!
		await store.send(.viewer(.item(.delegate(.navigation(original.tabs[1].id, .init(url: currentURL))))))
		await store.send(.sidebar(.ui(.undo)))
		await store.receive(\.sidebar.delegate.reverseTransfer)
		await store.receive(\.performTabMove)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization.folders.map(\.spaceID), original.folders.map(\.spaceID))
		expectNoDifference(store.state.sidebar.organization.tabs.map(\.id), original.tabs.map(\.id))
		expectNoDifference(store.state.sidebar.organization.tabs[1].restoration.url, currentURL)
		expectNoDifference(closed, [])
		#expect(store.state.pendingTabMove == nil)
	}

	private func moveUUIDs() -> UUIDGenerator {
		let value = LockIsolated(100)
		return .init { value.withValue { current in
			defer { current += 1 }
			return UUID(current)
		} }
	}

	private func folderMoveFixture() -> BrowserOrganization {
		var organization = fixture()
		let profile = Profile.ID(rawValue: UUID(90))
		let destination = Space.ID(rawValue: UUID(91))
		organization.profiles.append(.init(id: profile, name: "Other"))
		organization.spaces.append(.init(id: destination, profileID: profile, name: "Destination"))
		for index in organization.tabs.indices {
			organization.tabs[index].savedDestination = .init(title: "Saved", url: URL(string: "https://saved.example")!)
		}
		let first = Folder.ID(rawValue: UUID(92))
		let nested = Folder.ID(rawValue: UUID(93))
		organization.folders = [
			.init(
				id: first,
				spaceID: organization.spaces[0].id,
				name: "Root",
				children: [.tab(organization.tabs[0].id), .folder(nested)]
			),
			.init(
				id: nested,
				spaceID: organization.spaces[0].id,
				name: "Nested",
				children: [.tab(organization.tabs[1].id)]
			),
		]
		organization.spaces[0].unpinnedTabs = []
		organization.spaces[0].savedItems = [.folder(first)]
		return organization
	}
}
