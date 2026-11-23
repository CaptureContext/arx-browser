import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import TabArchiveFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test(arguments: [false, true], [false, true])
	internal func singleTabCloseTracksPermissionAndResetUntilCompletion(
		pinned: Bool,
		permitted: Bool
	) async throws {
		var organization = fixture()
		let tabID = organization.tabs[0].id
		if pinned { try organization.move(.tab(tabID.rawValue), to: .savedRoot, in: organization.spaces[0].id) }
		let (decisions, continuation) = AsyncStream<Bool>.makeStream()
		var requested: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.permitsClosing = { id in
				requested.append(id)
				for await value in decisions { return value }
				return false
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.sidebar(.delegate(.requestClose(tabID, reset: pinned))))
		expectNoDifference(store.state.pendingTabCloses, [tabID])
		await store.send(.sidebar(.delegate(.requestClose(tabID, reset: pinned))))
		continuation.yield(permitted)
		continuation.finish()
		if permitted {
			await store.receive(\.event.closePermissionGranted)
			await store.receive(\.sidebar.event.closeApproved)
			if pinned {
				expectNoDifference(store.state.pendingTabCloses, [tabID])
				await store.receive(\.event.tabResetCompleted)
			}
		} else {
			await store.receive(\.event.closePermissionDenied)
		}
		await store.finish()
		expectNoDifference(requested, [tabID])
		expectNoDifference(closed, permitted ? [tabID] : [])
		expectNoDifference(store.state.pendingTabCloses, [])
		if !permitted { expectNoDifference(store.state.sidebar.organization, organization) }
	}

	@Test
	internal func closeRecordsArchiveOnlyAfterNativeCloseCompletes() async throws {
		let organization = fixture()
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.closeTab))
		await store.receive(\.sidebar.event.closeApproved)
		expectNoDifference(closed, [organization.tabs[0].id])
		expectNoDifference(store.state.sidebar.organization.archive.map(\.tab), [organization.tabs[0]])
		expectNoDifference(store.state.sidebar.organization.archive.first?.closedAt, Date(timeIntervalSince1970: 100))
		await store.finish()
	}

	@Test
	internal func cancelledGroupCloseLeavesEveryTabAndArchiveUnchanged() async throws {
		let organization = fixture()
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.browserEngine.permitsClosing = { $0 != organization.tabs[1].id }
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.archiveSelectedTabs(organization.tabs.map(\.id))))
		await store.receive(\.event.archiveFailed)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, organization)
		expectNoDifference(closed, [])
	}

	@Test
	internal func failedGroupRestorationRollsBackNewSessionsAndAllowsRetry() async throws {
		var organization = fixture()
		let tabs = organization.tabs
		let entries = archiveFixture(organization)
		try organization.archiveClosedTabs(entries)
		var fail = true
		var waitedForRetry = false
		let (retryGate, continueRetry) = AsyncStream<Void>.makeStream()
		var opened: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)) {
			MainFeature()
		} withDependencies: {
			$0.uuid = .incrementing

			// Retry IDs must not collide with the original archived tab identities.
			for _ in 0..<200 { _ = $0.uuid() }
			$0.browserEngine.open = { tab in
				if fail && opened.count == 1 { throw BrowserEngineClient.Failure.unavailable }
				if !fail, !waitedForRetry {
					waitedForRetry = true
					for await _ in retryGate { break }
				}
				opened.append(tab.id)
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.openArchive))
		await store.send(.archive(.delegate(.restore(entries.map(\.id), nil))))
		await store.receive(\.event.archiveFailed)
		expectNoDifference(store.state.sidebar.organization, organization)
		#expect(closed.count == 2)
		#expect(closed.contains(opened[0]))
		fail = false
		await store.send(.archive(.delegate(.restore(entries.map(\.id), nil))))

		// A repeated request while the first is pending must not start another restoration.
		await store.send(.archive(.delegate(.restore(entries.map(\.id), nil))))
		continueRetry.yield(())
		await store.receive(\.event.archiveRestored)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization.archive, [])
		expectNoDifference(store.state.sidebar.organization.tabs.map(\.restoration), tabs.map(\.restoration))
		expectNoDifference(store.state.sidebar.organization.spaces[0].unpinnedTabs, store.state.sidebar.organization.tabs.map(\.id))
		expectNoDifference(Set(store.state.sidebar.organization.tabs.map(\.id)).count, 2)
		#expect(opened.count >= 3)
		let restored = store.state.sidebar.organization
		await store.send(.archive(.delegate(.restore(entries.map(\.id), nil))))
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, restored)
	}

	@Test
	internal func movedOrPinnedTabsRejectLateCloseApproval() async throws {
		let organization = fixture()
		let (decisions, continuation) = AsyncStream<Bool>.makeStream()
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)) {
			MainFeature()
		} withDependencies: {
			$0.browserEngine.permitsClosing = { _ in
				for await decision in decisions { return decision }
				return false
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.closeTab))
		await store.receive(\.sidebar.delegate.requestClose)
		var updated = organization
		try updated.move(.tab(organization.tabs[0].id.rawValue), to: .savedRoot, in: organization.spaces[0].id)
		await store.send(.reconcile(updated))
		continuation.yield(true)
		continuation.finish()
		await store.receive(\.event.closePermissionGranted)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, updated)
		expectNoDifference(store.state.sidebar.organization.archive, [])
		expectNoDifference(closed, [])
		expectNoDifference(store.state.pendingTabCloses, [])
	}

	@Test
	internal func staleCompletedCloseReopensRetainedPin() async throws {
		var organization = fixture()
		let tabID = organization.tabs[0].id
		let spaceID = organization.spaces[0].id
		try organization.move(.tab(tabID.rawValue), to: .savedRoot, in: spaceID)
		var state = MainFeature.State(organization: organization, spaceID: spaceID)
		state.viewer.item.tab = organization.tabs[0]
		var opened: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.browserEngine.open = { opened.append($0.id) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// Models a completion delivered after another window pinned the closing tab.
		await store.send(.sidebar(.event(.closeApproved(tabID, reset: false, expectedLocation: .unpinned(spaceID)))))
		await store.receive(\.viewer.item.show)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, organization)
		expectNoDifference(opened, [tabID])
	}

	@Test
	internal func privateTabsAndSavedPinsStayOutOfArchive() async throws {
		let original = fixture()
		for isPrivate in [false, true] {
			var organization = original
			if !isPrivate {
				try organization.move(.tab(original.tabs[0].id.rawValue), to: .savedRoot, in: original.spaces[0].id)
			}
			let store = TestStore(
				initialState: MainFeature.State(
					organization: organization,
					spaceID: original.spaces[0].id,
					isPrivate: isPrivate
				)
			) { MainFeature() }
			store.exhaustivity = .off(showSkippedAssertions: false)
			await store.send(.ui(.closeTab))
			await store.receive(\.sidebar.event.closeApproved)
			await store.finish()
			expectNoDifference(store.state.sidebar.organization.archive, [])
			if !isPrivate { #expect(store.state.sidebar.organization.tabs.ids.contains(original.tabs[0].id)) }
		}
	}

	@Test
	internal func archiveSurvivesRestartAndFailedSaveWithoutLosingLiveTabs() async throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("workspace.json")
		let original = fixture()
		try BrowserWorkspaceClient(file: file).save(original)
		var archived = original
		try archived.archiveClosedTabs(archiveFixture(original))
		let failing = BrowserWorkspaceClient(file: file) { data, destination in
			if destination == file { throw CocoaError(.fileWriteOutOfSpace) }
			try data.write(to: destination, options: .atomic)
		}
		#expect(throws: (any Error).self) { try failing.save(archived) }
		expectNoDifference(try BrowserWorkspaceClient(file: file).load(), original)
		try BrowserWorkspaceClient(file: file).save(archived)
		expectNoDifference(try BrowserWorkspaceClient(file: file).load(), archived)
	}

	@Test
	internal func searchClearAndRestorationRemainScopedToThePresentedProfile() async throws {
		var organization = fixture()
		let otherProfile = Profile.ID(rawValue: UUID(20))
		let otherSpace = Space.ID(rawValue: UUID(21))
		let otherTab = BrowserCore.Tab(
			id: .init(rawValue: UUID(22)),
			profileID: otherProfile,
			restoration: .init(title: "Other account", url: URL(string: "https://other.example")!)
		)
		organization.profiles.append(.init(id: otherProfile, name: "Other"))
		organization.spaces.append(.init(id: otherSpace, profileID: otherProfile, name: "Other", unpinnedTabs: [otherTab.id]))
		organization.tabs.append(otherTab)
		let entries = archiveFixture(organization)
		try organization.archiveClosedTabs(entries)
		let otherEntry = try #require(entries.first { $0.tab.profileID == otherProfile })
		let store = TestStore(initialState: MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)) {
			MainFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.openArchive))
		expectNoDifference(store.state.archive.entries.count, 2)
		await store.send(.archive(.delegate(.restore([otherEntry.id], .init(spaceID: otherSpace, profileID: otherProfile)))))
		expectNoDifference(store.state.sidebar.organization, organization)
		await store.send(.archive(.ui(.queryChanged("no matching page"))))
		expectNoDifference(store.state.archive.visibleEntries, [])
		await store.send(.archive(.ui(.clearRequested)))
		#expect(store.state.archive.confirmsClear)
		await store.send(.archive(.ui(.clearConfirmed)))
		await store.receive(\.archive.delegate.clear)
		await store.finish()
		expectNoDifference(store.state.sidebar.organization.archive, [otherEntry])
	}

	@Test
	internal func concurrentWorkspaceChangeRollsBackOnlyThisRestorationAttempt() async throws {
		var previous = fixture()
		let entries = archiveFixture(previous)
		try previous.archiveClosedTabs(entries)
		let candidate = try previous.restoringArchive(entries.map(\.id), uuid: UUID.init)
		var changed = previous
		changed.spaces[0].name = "Renamed in another window"
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: MainFeature.State(organization: changed, spaceID: changed.spaces[0].id)) {
			MainFeature()
		} withDependencies: {
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.openArchive))
		await store.send(.event(.archiveRestored(previous, candidate, Array(candidate.tabs))))
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, changed)
		expectNoDifference(closed, candidate.tabs.map(\.id))
		#expect(Set(closed).isDisjoint(with: entries.map(\.tab.id)))
		#expect(store.state.archive.message != nil)
	}

	private func archiveFixture(_ organization: BrowserOrganization) -> [ArchivedTab] {
		var value = 100
		return organization.archiveEntries(
			for: organization.tabs.map(\.id),
			closedAt: Date(timeIntervalSince1970: 100),
			groupID: UUID(99),
			uuid: {
				defer { value += 1 }
				return UUID(value)
			}
		)
	}
}
