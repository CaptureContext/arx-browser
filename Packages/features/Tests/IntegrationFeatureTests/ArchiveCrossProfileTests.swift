import AppFeature
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import TabArchiveFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func confirmedArchiveRestoreStagesFreshProfileSessionsAndPreservesSplitNeighbor() async throws {
		let initial = try crossProfileArchiveFixture()
		let organization = initial.workspace
		let destination = organization.spaces[1]
		let entries = organization.archive
		let layout = try #require(initial.main.viewer.presentations.first)
		let (started, didStart) = AsyncStream<Void>.makeStream()
		let (opening, continueOpening) = AsyncStream<Void>.makeStream()
		var prepared: [Profile.ID] = []
		var opened: [BrowserCore.Tab] = []
		var sessions: Set<BrowserCore.Tab.ID> = []
		let store = Store(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.prepareProfile = { prepared.append($0) }
			$0.browserEngine.open = { tab in
				guard sessions.insert(tab.id).inserted else { return }
				opened.append(tab)
				if opened.count == 1 {
					didStart.yield(())
					for await _ in opening { break }
				}
			}
			$0.browserEngine.events = { _ in .finished }
		}

		await store.send(.main(.ui(.openArchive))).finish()
		await store.send(.main(.archive(.ui(.restoreGroup(entries[0].groupID, .init(space: destination)))))).finish()
		let confirmation = try #require(store.main.archive.restorationConfirmation)
		expectNoDifference(confirmation.profileName, "Other account")
		expectNoDifference(opened, [])

		let task = store.send(.main(.archive(.ui(.restoreConfirmed(confirmation)))))
		for await _ in started { break }
		expectNoDifference(store.main.sidebar.organization, organization)
		expectNoDifference(prepared, [destination.profileID])
		expectNoDifference(opened[0].profileID, destination.profileID)
		#expect(store.main.archive.restorationConfirmation == nil)
		continueOpening.finish()
		await task.finish()

		let restored = store.workspace.tabs.filter { tab in !organization.tabs.ids.contains(tab.id) }
		expectNoDifference(restored.map(\.restoration), entries.map(\.tab.restoration))
		expectNoDifference(restored.map(\.profileID), [destination.profileID, destination.profileID])
		#expect(Set(restored.map(\.id)).isDisjoint(with: entries.map(\.tab.id)))
		expectNoDifference(store.workspace.archive, [])
		expectNoDifference(store.main.sidebar.spaceID, destination.id)
		expectNoDifference(store.main.sidebar.selectedTab?.id, restored.first?.id)
		var expected = layout
		expected.panes[0].tabID = restored.first?.id
		expectNoDifference(store.main.viewer.currentPresentation, expected)
		try store.workspace.validate()

		let committed = store.workspace
		await store.send(.main(.archive(.ui(.restoreConfirmed(confirmation))))).finish()
		expectNoDifference(store.workspace, committed)
	}

	@Test(arguments: ["cancel", "reassign", "remove", "dismiss"])
	internal func crossProfileArchiveConfirmationRejectsStaleOrCancelledChoice(_ change: String) async throws {
		let initial = try crossProfileArchiveFixture()
		let destination = initial.workspace.spaces[1]
		var opened: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial.main) { MainFeature() } withDependencies: {
			$0.browserEngine.open = { opened.append($0.id) }
		}
		await store.send(.ui(.openArchive)).finish()
		await store.send(.archive(.ui(.restoreGroup(initial.workspace.archive[0].groupID, .init(space: destination))))).finish()
		let confirmation = try #require(store.archive.restorationConfirmation)
		var expected = initial.workspace

		switch change {
		case "cancel":
			await store.send(.archive(.ui(.restoreCancelled))).finish()

		case "dismiss":
			await store.send(.archive(.ui(.dismissed))).finish()
			await store.send(.ui(.openArchive)).finish()

		case "reassign":
			// This models a concurrent valid workspace edit after its old profile tabs moved away.
			expected.spaces[1] = .init(
				id: destination.id,
				profileID: initial.workspace.profiles[0].id,
				name: destination.name
			)
			expected.tabs = []
			await store.send(.reconcile(expected)).finish()

		default:
			expected.spaces.removeLast()
			expected.tabs = []
			await store.send(.reconcile(expected)).finish()
		}

		await store.send(.archive(.ui(.restoreConfirmed(confirmation)))).finish()
		expectNoDifference(opened, [])
		expectNoDifference(store.sidebar.organization, expected)
		#expect(store.archive.restorationConfirmation == nil)
	}

	@Test
	internal func crossProfileArchiveFailureRetainsEntriesAndRetryUsesDifferentSessions() async throws {
		let initial = try crossProfileArchiveFixture()
		let organization = initial.workspace
		let entries = organization.archive
		let destination = ArchiveDestination(space: organization.spaces[1])
		var fails: Bool = true
		var attempted: [BrowserCore.Tab] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: initial.main) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			for _ in 0..<200 { _ = $0.uuid() }
			$0.browserEngine.open = { tab in
				attempted.append(tab)
				if fails && attempted.count == 2 { throw BrowserEngineClient.Failure.unavailable }
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.openArchive))
		await store.send(.archive(.delegate(.restore(entries.map(\.id), destination))))
		await store.receive(\.event.archiveFailed)
		expectNoDifference(store.state.sidebar.organization, organization)
		expectNoDifference(closed, attempted.map(\.id))
		#expect(attempted.allSatisfy { $0.profileID == destination.profileID })

		fails = false
		let failedIDs = Set(attempted.map(\.id))
		await store.send(.archive(.delegate(.restore(entries.map(\.id), destination))))
		await store.receive(\.event.archiveRestored)
		await store.finish()
		let restored = store.state.sidebar.organization.tabs.filter { tab in !organization.tabs.ids.contains(tab.id) }
		expectNoDifference(restored.count, 2)
		#expect(failedIDs.isDisjoint(with: restored.map(\.id)))
		expectNoDifference(store.state.sidebar.organization.archive, [])
		let committed = store.state.sidebar.organization
		await store.send(.archive(.delegate(.restore(entries.map(\.id), destination))))
		await store.finish()
		expectNoDifference(store.state.sidebar.organization, committed)
	}

	@Test(arguments: [false, true])
	internal func crossProfileArchiveDiscardsStagedPagesAfterDestinationOrSelectionChanges(reassign: Bool) async throws {
		let initial = try crossProfileArchiveFixture()
		let organization = initial.workspace
		let destination = ArchiveDestination(space: organization.spaces[1])
		let (started, didStart) = AsyncStream<Void>.makeStream()
		let (opening, continueOpening) = AsyncStream<Void>.makeStream()
		var opened: [BrowserCore.Tab.ID] = []
		var closed: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: initial.main) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.open = { tab in
				opened.append(tab.id)
				if opened.count == 1 {
					didStart.yield(())
					for await _ in opening { break }
				}
			}
			$0.browserEngine.close = { closed.append($0) }
		}
		await store.send(.ui(.openArchive)).finish()
		let task = store.send(.archive(.delegate(.restore(organization.archive.map(\.id), destination))))
		for await _ in started { break }
		var changed = organization
		if reassign {
			changed.spaces[1] = .init(
				id: destination.spaceID,
				profileID: organization.profiles[0].id,
				name: organization.spaces[1].name
			)
			changed.tabs = []
			await store.send(.reconcile(changed)).finish()

		} else {
			changed.spaces[1].selectedTabID = organization.tabs[1].id
			await store.send(.present(organization.tabs[1].id, in: initial.main.viewer.activePaneID)).finish()
		}
		continueOpening.finish()
		await task.finish()

		expectNoDifference(store.sidebar.organization, changed)
		expectNoDifference(closed, opened)
		#expect(Set(closed).isDisjoint(with: organization.tabs.map(\.id)))
		#expect(store.archive.message != nil)
	}

	private func crossProfileArchiveFixture() throws -> AppFeature.State {
		var organization = fixture()
		var next = 100
		let entries = organization.archiveEntries(
			for: organization.tabs.map(\.id),
			closedAt: .init(timeIntervalSince1970: 100),
			groupID: UUID(99),
			uuid: {
				defer { next += 1 }
				return UUID(next)
			}
		)
		try organization.archiveClosedTabs(entries)
		let profile = Profile.ID(rawValue: UUID(20))
		organization.profiles.append(.init(id: profile, name: "Other account"))
		organization.spaces[1] = .init(
			id: organization.spaces[1].id,
			profileID: profile,
			name: organization.spaces[1].name
		)
		let neighbors: [BrowserCore.Tab] = [21, 22].map { value in
			.init(
				id: .init(rawValue: UUID(value)),
				profileID: profile,
				restoration: .init(title: "Neighbor", url: URL(string: "https://neighbor.example/\(value)")!)
			)
		}
		organization.tabs = .init(uniqueElements: neighbors)
		organization.spaces[1].unpinnedTabs = neighbors.map(\.id)
		var main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		main.viewer.preservesPresentation = true
		main.viewer.presentations = [.init(
			id: organization.spaces[1].id,
			panes: [.init(id: UUID(30), tabID: neighbors[0].id), .init(id: UUID(31), tabID: neighbors[1].id)],
			activePaneID: UUID(30),
			orientation: .vertical,
			fractions: [0.65, 0.35]
		)]
		return .init(main: main)
	}
}
